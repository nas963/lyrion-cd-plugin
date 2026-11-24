/* AudioCD: stranica plugina. Vanilla JS, bez biblioteka.
 * Podaci i komande idu preko /jsonrpc.js (["audiocd", ...]); svi tekstovi stizu iz strings.txt
 * (JSON u index.html, element #audiocd-data). Sav tekst iz spoljnih izvora ide kroz textContent. */
(function () {
  'use strict';

  var DATA = JSON.parse(document.getElementById('audiocd-data').textContent);
  var S = DATA.strings || {};
  var CFG = DATA.config || {};
  var POLL_BUSY = 2000;   // ms, dok traje posao
  var POLL_IDLE = 10000;  // ms, inace
  var POLL_PLAYING = 5000;    // ms, dok izabrani plejer svira CD (Pause/Stop prate i promene sa drugih kontrolera)
  var FAST_AFTER_CMD = 15000;
  var PLAYER_KEY = 'audiocd.player';
  var RIP_RETRY = 1000, RIP_TRIES = 8;    // rip posle prekida izvlacenja: cd-paranoia jos umire (drive_busy process)

  // playback: null ili { pid, mode: 'play'|'pause', discid, n } kad izabrani plejer svira/pauzira audiocd:// pesmu
  var state = { snap: null, hist: [], players: [], playback: null, fastUntil: 0, pending: false, offline: false, timer: null };
  var last = {};

  // ---------- pomocne ----------

  function $(id) { return document.getElementById(id); }

  function fmt(s, args) {
    return String(s).replace(/\{(\d+)\}/g, function (m, i) { return args && args[i] != null ? args[i] : ''; });
  }

  function t(key, args) { return fmt(S[key] != null ? S[key] : key, args); }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  // Prikazuje se samo kad se vrednost promenila (da forme i fokus ostanu netaknuti).
  function changed(key, value) {
    var j = JSON.stringify(value);
    if (last[key] === j) return false;
    last[key] = j;
    return true;
  }

  function mmss(sec) {
    if (sec == null || isNaN(sec)) return '';
    sec = Math.round(sec);
    var h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60;
    var ss = (s < 10 ? '0' : '') + s;
    return h ? h + ':' + (m < 10 ? '0' : '') + m + ':' + ss : m + ':' + ss;
  }

  function bytes(n) {
    n = Number(n);
    if (!isFinite(n)) return '?';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i ? n.toFixed(1) : String(Math.round(n))) + ' ' + u[i];
  }

  function store(key, value) {
    try { if (value === undefined) return window.localStorage.getItem(key); window.localStorage.setItem(key, value); } catch (e) { /* privatni mod */ }
    return null;
  }

  // ---------- Material Skin (iframe) ----------

  var FIXED_PLAYER = (function () {
    var v = '';
    try { v = new URLSearchParams(window.location.search).get('player') || ''; } catch (e) { return ''; }
    // MAC ili bezbedan LMS id; sve drugo se ignorise (prikazuje se izbor plejera)
    return /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/i.test(v) || /^[\w.:-]{1,64}$/.test(v) ? v : '';
  })();

  // Roditeljski dokument (isti origin) ili null kad nismo u iframe-u ili nemamo pristup.
  function parentDoc() {
    try {
      if (window.parent && window.parent !== window && window.parent.document) return window.parent.document;
    } catch (e) { /* drugi origin */ }
    return null;
  }

  // Vrednost promenljive iz Materiala: najpre iz roditelja (tamo je izracunata), pa iz nase stranice.
  function materialVar(pdoc, name) {
    var v = '';
    try { v = window.parent.getComputedStyle(pdoc.documentElement).getPropertyValue(name).trim(); } catch (e) { /* ignorisi */ }
    if (v && !/^var\(/.test(v)) return v;
    try { v = getComputedStyle(document.documentElement).getPropertyValue(name).trim(); } catch (e) { /* ignorisi */ }
    return /^var\(/.test(v) ? '' : v;
  }

  // CSS boja (#rgb, #rrggbb, rgb(), rgba()) -> [r, g, b, a] ili null. Bez DOM-a.
  function parseColor(v) {
    if (!v) return null;
    v = String(v).trim();
    var m = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(v);
    if (m) {
      var h = m[1].length === 3 ? m[1].replace(/./g, '$&$&') : m[1];
      return [parseInt(h.substr(0, 2), 16), parseInt(h.substr(2, 2), 16), parseInt(h.substr(4, 2), 16), 1];
    }
    m = /^rgba?\(([^)]+)\)$/i.exec(v);
    if (!m) return null;
    var n = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number);
    if (n.length < 3 || n.some(isNaN)) return null;
    return [n[0], n[1], n[2], n.length > 3 ? n[3] : 1];
  }

  function luma(c) { return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255; }
  function cssColor(c) { return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + c[3] + ')'; }

  // Cista odluka o temi iz Material-ovih promenljivih (objekat naziv -> tekst); bez DOM-a, pa se moze probati odvojeno.
  // Tamna tema = pozadina tamna; tekst je --light-text-color (tamna) ili --dark-text-color (svetla).
  function materialTheme(v) {
    var bg = parseColor(v['--background-color']) || parseColor(v['--std-background-color']);
    if (!bg) return null;
    var dark = luma(bg) < 0.5;
    var text = parseColor(dark ? v['--light-text-color'] : v['--dark-text-color']) || (dark ? [237, 236, 231, 1] : [51, 51, 51, 1]);
    var out = { dark: dark, vars: {} };
    var o = out.vars;
    o['--bg'] = cssColor(bg);
    o['--card'] = cssColor(parseColor(v['--std-popup-background-color']) || parseColor(v['--popup-background-color']) || bg);
    o['--text'] = cssColor(text);
    o['--muted'] = cssColor([text[0], text[1], text[2], 0.7]);
    o['--line'] = cssColor([text[0], text[1], text[2], 0.2]);
    var accent = parseColor(v['--primary-color']);
    if (accent) {
      o['--accent'] = cssColor(accent);
      o['--accent-text'] = luma(accent) > 0.6 ? '#111111' : '#ffffff';
    }
    var link = parseColor(v['--accent-color']);
    if (link) o['--link'] = cssColor(link);
    o['--btn'] = cssColor([text[0], text[1], text[2], 0.12]);
    o['--btn-hover'] = cssColor([text[0], text[1], text[2], 0.22]);
    return out;
  }

  // Serif / Times u roditelju znaci da font nije pravi; tada Roboto pa sans-serif.
  function materialFont(family) {
    var f = String(family || '').trim();
    if (!f || /^["']?(times|serif)/i.test(f) || /^["']?times new roman/i.test(f)) {
      return 'Roboto, "Segoe UI", system-ui, sans-serif';
    }
    return f;
  }

  // Kad je stranica u Material-ovom iframe-u: boje, font i velicina slova iz Materiala, uze margine.
  function adoptMaterial() {
    var pdoc = parentDoc();
    if (!pdoc || !(pdoc.getElementById('iframe-page') || pdoc.querySelector('.v-application') || materialVar(pdoc, '--background-color'))) return;
    var root = document.documentElement;
    root.classList.add('embedded');

    var names = ['--background-color', '--std-background-color', '--std-popup-background-color', '--popup-background-color',
      '--light-text-color', '--dark-text-color', '--primary-color', '--accent-color'];
    var raw = {};
    names.forEach(function (n) { raw[n] = materialVar(pdoc, n); });
    var th = materialTheme(raw);
    if (!th) return;    // nema Material boja: ostaje izgled po prefers-color-scheme

    root.setAttribute('data-theme', th.dark ? 'dark' : 'light');    // odluka iz Materiala, ne iz OS-a
    root.style.colorScheme = th.dark ? 'dark' : 'light';
    Object.keys(th.vars).forEach(function (k) { root.style.setProperty(k, th.vars[k]); });

    var family = '';
    try { family = window.parent.getComputedStyle(pdoc.body).fontFamily; } catch (e) { /* ignorisi */ }
    root.style.setProperty('--font', materialFont(family));
    var fs = materialVar(pdoc, '--std-font-size');
    if (/^[0-9.]+px$/.test(fs)) root.style.setProperty('--font-size', fs);
  }

  // ---------- JSON-RPC ----------

  function rpc(player, params) {
    return fetch('/jsonrpc.js', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: 1, method: 'slim.request', params: [player || '', params] })
    }).then(function (r) {
      if (!r.ok) throw new Error('http ' + r.status);
      return r.json();
    }).then(function (j) { return j.result || {}; });
  }

  function cmd(name) {
    return rpc('', ['audiocd', name].concat(Array.prototype.slice.call(arguments, 1)));
  }

  // Greska iz odgovora ({error, ...}) ili koda -> tekst na jeziku servera.
  function errText(err) {
    var code = typeof err === 'string' ? err : (err && err.error) || 'failed';
    var key = 'ERR_' + String(code).toUpperCase();
    if (S[key] == null) return t('ERR_UNKNOWN', [code]);
    var a = [];
    if (code === 'missing_tools') a = [[].concat(err.tools || []).join(', ')];
    else if (code === 'no_space') a = [bytes(err.needed), bytes(err.free)];
    else if (code === 'bad_args') a = [err && err.field ? ' (' + err.field + ')' : ''];
    var text = t(key, a);
    if (code === 'drive_busy' && err && err.busy && S['UI_BUSY_' + String(err.busy).toUpperCase()]) {
      text += ' (' + t('UI_BUSY_' + String(err.busy).toUpperCase()) + ')';
    }
    return text;
  }

  var msgTimer = null;
  function say(text, kind) {
    var m = $('msg');
    m.textContent = text;
    m.className = 'msg ' + (kind || 'ok');
    m.hidden = false;
    if (msgTimer) clearTimeout(msgTimer);
    if (kind !== 'err') msgTimer = setTimeout(function () { m.hidden = true; }, 8000);
  }

  // Komanda sa porukom o ishodu; obnavlja stanje.
  function run(start, okText) {    // start: funkcija koja salje zahtev (poziva se tek posle provere pending)
    if (state.pending) return Promise.resolve();
    state.pending = true;
    last.releases = null;    // izbor izdanja se vraca na stanje servera ako komanda ne uspe
    setButtons();
    return start().then(function (res) {
      if (res && res.error) say(errText(res), 'err');
      else if (okText) say(okText, 'ok');
      state.fastUntil = Date.now() + FAST_AFTER_CMD;
      return res;
    }).catch(function () {
      say(t('UI_OFFLINE'), 'err');
    }).then(function (res) {
      state.pending = false;
      return refresh().then(function () { return res; });
    });
  }

  // ---------- plejeri ----------

  function loadPlayers() {
    return rpc('', ['players', 0, 99]).then(function (r) {
      var list = (r.players_loop || []).filter(function (p) { return p.connected == null || Number(p.connected) !== 0; });
      state.players = list.map(function (p) { return { id: p.playerid, name: p.name || p.playerid }; });
      renderPlayers();
    }).catch(function () { /* plejeri su dodatak; stranica radi i bez njih */ });
  }

  // Cist parser odgovora ["status", "-", 1, "tags:u"]: svira li plejer pesmu sa CD-a (audiocd://<discid>/<n>).
  function cdPlayback(pid, r) {
    var mode = r && r.mode;
    if (mode !== 'play' && mode !== 'pause') return null;
    var cur = ((r.playlist_loop || [])[0]) || {};
    var m = /^audiocd:\/\/([^\/?#]+)\/(\d+)$/.exec(String(cur.url || ''));
    return m ? { pid: pid, mode: mode, discid: m[1], n: Number(m[2]),
      idx: Number(r.playlist_cur_index) || 0, count: Number(r.playlist_tracks) || 0 } : null;
  }

  // Stanje izabranog plejera; greska ili bez plejera -> nema kontrola (stranica radi i bez toga).
  function loadPlayback() {
    var pid = $('player').value;
    if (!pid) { state.playback = null; return Promise.resolve(); }
    return rpc(pid, ['status', '-', 1, 'tags:u']).then(function (r) {
      if ($('player').value === pid) state.playback = cdPlayback(pid, r);
    }).catch(function () { state.playback = null; });
  }

  function renderPlayers() {
    var sel = $('player');
    var cur = sel.value || store(PLAYER_KEY);
    var list = state.players;
    if (FIXED_PLAYER) {    // otvoreno iz Materiala (?player=): taj plejer, bez izbora
      var known = list.filter(function (p) { return p.id === FIXED_PLAYER; })[0];
      list = [{ id: FIXED_PLAYER, name: known ? known.name : FIXED_PLAYER }];
      cur = FIXED_PLAYER;
    }
    if (!changed('players', list)) return;
    clear(sel);
    if (!list.length) {
      var o = el('option', null, t('UI_NO_PLAYERS'));
      o.value = '';
      sel.appendChild(o);
    }
    list.forEach(function (p) {
      var o = el('option', null, p.name);
      o.value = p.id;
      sel.appendChild(o);
    });
    if (list.some(function (p) { return p.id === cur; })) sel.value = cur;
    setButtons();
  }

  // ---------- prikaz ----------

  function sourceLabel(src) {
    var k = 'UI_SOURCE_' + String(src || '').toUpperCase();
    return S[k] != null ? t(k) : '';
  }

  function releaseLabel(r) {
    var head = [r.artist, r.title].filter(Boolean).join(' - ');
    var tail = [r.date, r.country, r.label, r.format].filter(Boolean).join(', ');
    return (head || '#' + (r.index + 1)) + (tail ? ' (' + tail + ')' : '');
  }

  function discTracks(snap) {
    return (snap.metadata && snap.metadata.tracks) || [];
  }

  function renderBanners() {
    var snap = state.snap, items = [];
    if (state.offline) items.push({ cls: 'banner', text: t('UI_OFFLINE') });
    if (snap) {
      (snap.errors || []).forEach(function (e) { items.push({ cls: 'banner', text: errText(e.code || 'failed') }); });
      var miss = snap.missing_tools || [];
      if (miss.length) {
        items.push({
          cls: 'banner warn',
          text: t('UI_MISSING_TOOLS', [miss.map(function (m) { return m.tool + (m.package && m.package !== m.tool ? ' (' + m.package + ')' : ''); }).join(', ')])
        });
      }
    }
    if (!changed('banners', items)) return;
    var box = $('banners');
    clear(box);
    items.forEach(function (i) { box.appendChild(el('div', i.cls, i.text)); });
  }

  function renderDisc() {
    var snap = state.snap;
    if (!snap) return;
    var ready = snap.status === 'ready' && snap.metadata;
    var md = snap.metadata || {};

    var view = {
      status: snap.status, artist: md.artist, album: md.album, year: md.year, source: md.source,
      dn: md.disc_number, dt: md.disc_total, n: discTracks(snap).length, busy: snap.drive_busy,
      cover: snap.cover ? snap.cover_url : null, rel: snap.release_idx, discid: snap.discid
    };
    if (changed('disc', view)) {
      $('disc-heading').textContent = ready ? (md.album || t('UI_UNTITLED')) : '';
      $('disc-artist').textContent = ready ? (md.artist || '') : '';
      var meta = [];
      if (ready) {
        if (md.year) meta.push(md.year);
        if (Number(md.disc_total) > 1) meta.push('CD ' + md.disc_number + '/' + md.disc_total);
        var total = 0, any = false;
        discTracks(snap).forEach(function (tr) { if (tr.length != null) { total += Number(tr.length); any = true; } });
        meta.push(t('UI_TRACKS') + ': ' + discTracks(snap).length + (any ? ' (' + mmss(total) + ')' : ''));
        var sl = sourceLabel(md.source);
        if (sl) meta.push(t('UI_SOURCE') + ': ' + sl);
      }
      $('disc-meta').textContent = meta.join(' | ');

      var stateText = '';
      if (snap.status === 'reading') stateText = t('UI_READING');
      else if (snap.status === 'empty') stateText = t('UI_NO_DISC');
      else if (snap.status === 'ready' && (snap.drive_busy === 'lookup' || snap.drive_busy === 'process')) {
        stateText = t('UI_DRIVE_BUSY', [t('UI_BUSY_' + snap.drive_busy.toUpperCase())]);
      }
      $('disc-state').textContent = stateText;

      var img = $('cover');
      var generic = '/plugins/AudioCD/cd-generic.png';
      var want = view.cover ? view.cover + '?r=' + encodeURIComponent(view.rel) : generic;
      img.onerror = function () { img.onerror = null; img.src = generic; };
      img.src = want;
    }

    // priblizno poklapanje: vidljiva napomena i izbor izdanja
    var fuzzy = !!(ready && snap.fuzzy);
    $('fuzzy-hint').hidden = !fuzzy;
    if (fuzzy) $('fuzzy-hint').textContent = t('UI_FUZZY_HINT');

    var rels = snap.releases || [];
    var showRel = ready && rels.length > 0 && (rels.length > 1 || fuzzy);
    $('release-box').hidden = !showRel;
    if (showRel && changed('releases', { r: rels, i: snap.release_idx })) {
      var sel = $('release');
      clear(sel);
      rels.forEach(function (r, i) {
        var o = el('option', null, releaseLabel(r));
        o.value = String(i);
        sel.appendChild(o);
      });
      sel.value = String(snap.release_idx || 0);
    }
    setButtons();
  }

  // Pesma koja svira, ako je sa diska u drajvu (za naslov i oznaku u listi pesama).
  function playingTrack() {
    var pb = state.playback, snap = state.snap;
    if (!pb || !snap || pb.discid !== snap.discid) return null;
    return discTracks(snap).filter(function (tr) { return Number(tr.n) === pb.n; })[0] || { n: pb.n };
  }

  // Jedno dugme Play/Pauza/Nastavi; Stop samo dok izabrani plejer svira ili pauzira CD.
  function renderPlayback() {
    var pb = state.playback;
    var tr = playingTrack();
    var view = pb ? { mode: pb.mode, n: pb.n, title: tr && tr.title } : null;
    ['btn-prev', 'btn-next', 'btn-stop'].forEach(function (id) { $(id).hidden = !pb; });
    $('now-playing').hidden = !pb;
    if (!changed('playback', view)) return setButtons();
    $('btn-play').textContent = t(!pb ? 'UI_PLAY' : pb.mode === 'pause' ? 'UI_RESUME' : 'UI_PAUSE');
    if (!pb) return setButtons();
    $('now-playing').textContent = t(pb.mode === 'pause' ? 'UI_NOW_PAUSED' : 'UI_NOW_PLAYING',
      [pb.n + (tr && tr.title ? '. ' + tr.title : '')]);
    setButtons();
  }

  function setButtons() {
    var snap = state.snap;
    var ready = !!(snap && snap.status === 'ready' && snap.metadata);
    var busy = state.pending;
    $('btn-play').disabled = busy || !(state.playback || (ready && $('player').value));
    var pb = state.playback;
    $('btn-stop').disabled = busy || !pb;
    $('btn-prev').disabled = busy || !pb || pb.idx <= 0;
    $('btn-next').disabled = busy || !pb || pb.idx >= pb.count - 1;
    var missing = !!(snap && (snap.missing_tools || []).length);
    $('btn-rip').disabled = busy || !ready || missing;
    $('btn-edit').disabled = busy || !ready;
    $('btn-eject').disabled = busy;
    $('btn-load').disabled = busy;
    var md = (snap && snap.metadata) || {};
    var noData = !!(snap && snap.status === 'ready' && (md.source === 'generic' || !(snap.releases || []).length));
    $('btn-retry').hidden = !noData;
    $('btn-retry').disabled = busy;
    var plays = document.querySelectorAll('#tracks .play');
    for (var i = 0; i < plays.length; i++) plays[i].disabled = busy || !ready || !$('player').value;
  }

  function renderTracks() {
    var snap = state.snap;
    if (!snap) return;
    var ready = snap.status === 'ready' && snap.metadata;
    $('tracks-card').hidden = !ready;
    if (!ready) return;
    var cache = snap.cache && snap.cache.discid === snap.discid ? snap.cache : {};
    var now = playingTrack();
    var view = { tracks: discTracks(snap), artist: snap.metadata.artist, done: cache.done || [], failed: cache.failed || [], now: now ? now.n : null };
    if (!changed('tracks', view)) return;
    $('tracks-title').textContent = t('UI_TRACKS');
    var ol = $('tracks');
    clear(ol);
    view.tracks.forEach(function (tr) {
      var li = el('li', Number(tr.n) === view.now ? 'now' : null);
      li.appendChild(el('span', 'n', String(tr.n)));
      var mid = el('span', 'title');
      mid.appendChild(document.createTextNode(tr.title || ''));
      if (tr.artist && tr.artist !== view.artist) mid.appendChild(el('span', 'sub', tr.artist));
      if (view.done.indexOf(tr.n) >= 0) mid.appendChild(el('span', 'state ready', t('UI_TRACK_READY')));
      else if (view.failed.indexOf(tr.n) >= 0) mid.appendChild(el('span', 'state failed', t('UI_TRACK_FAILED')));
      li.appendChild(mid);
      li.appendChild(el('span', 'len', mmss(tr.length)));
      var b = el('button', 'small play', '▶');
      b.type = 'button';
      b.title = t('UI_PLAY_TRACK');
      b.setAttribute('aria-label', t('UI_PLAY_TRACK') + ' ' + tr.n);
      b.addEventListener('click', function () { play(tr.n); });
      li.appendChild(b);
      ol.appendChild(li);
    });
    setButtons();
  }

  function who(r) { return [r.artist, r.album].filter(Boolean).join(' - '); }

  function renderProgress() {
    var snap = state.snap;
    if (!snap) return;
    var cache = snap.cache || {};
    var rip = snap.rip || {};
    var cur = rip.current, queue = rip.queue || [];
    var caching = snap.drive_busy === 'cache' || cache.current != null;

    $('progress').hidden = !(caching || cur || queue.length);

    $('cache-box').hidden = !caching;
    if (caching) {
      $('cache-title').textContent = t('UI_CACHE_PROGRESS');
      $('cache-bar').value = Number(cache.percent) || 0;
      $('cache-text').textContent = t('UI_CACHE_TRACKS', [(cache.done || []).length, discTracks(snap).length]) + ' | ' + (Number(cache.percent) || 0) + '%';
    }

    $('rip-box').hidden = !cur;
    if (cur) {
      $('rip-title').textContent = t('UI_RIP_PROGRESS');
      $('rip-name').textContent = who(cur);
      $('rip-bar').value = Number(cur.percent) || 0;
      var cancelling = cur.state === 'cancelling';
      $('rip-text').textContent = cancelling ? t('UI_RIP_CANCELLING')
        : (Number(cur.percent) || 0) + '%' + (cur.track != null ? ' | ' + t('UI_RIP_TRACK', [cur.track, Math.round(Number(cur.track_percent) || 0)]) : '');
      $('rip-track-bar').value = Number(cur.track_percent) || 0;
      $('rip-cancel').textContent = t('UI_CANCEL_RIP');
      $('rip-cancel').disabled = cancelling;
      $('rip-cancel').dataset.id = cur.id;
    }

    $('queue-box').hidden = !queue.length;
    if (queue.length && changed('queue', queue)) {
      $('queue-title').textContent = t('UI_QUEUE');
      var ul = $('queue');
      clear(ul);
      queue.forEach(function (q) {
        var li = el('li', 'hist-row');
        li.appendChild(el('span', 'hist-main', who(q)));
        var b = el('button', 'small', t('UI_CANCEL_RIP'));
        b.type = 'button';
        b.addEventListener('click', function () { run(function () { return cmd('cancel', 'id:' + q.id); }); });
        li.appendChild(b);
        ul.appendChild(li);
      });
    }
  }

  var RESULT_CLASS = { ok: 'ok', accurip_mismatch: 'warn', error: 'err', cancelled: '' };

  function accuripText(a) {
    if (!a || typeof a !== 'object') return '';
    if (a.state === 'notfound') return t('UI_ACCURIP_NOTFOUND');
    if (a.state === 'match') return t('UI_ACCURIP_MATCH', [a.ok, a.total]);
    if (a.state === 'mismatch') return t('UI_ACCURIP_MISMATCH', [a.ok, a.total]);
    return '';
  }

  function canMove(e) {
    var root = String(CFG.ripsDir || '').replace(/\/+$/, '');
    return (e.result === 'ok' || e.result === 'accurip_mismatch') && !e.moved && e.path && root && String(e.path).indexOf(root + '/') === 0;
  }

  function renderHistory() {
    $('hist-title').textContent = t('UI_HISTORY');
    $('hist-clear').hidden = !state.hist.length;
    $('hist-clear').disabled = state.pending;
    if (!changed('history', state.hist)) return;
    var ul = $('history');
    clear(ul);
    if (!state.hist.length) {
      ul.appendChild(el('li', 'muted', t('UI_HISTORY_EMPTY')));
      return;
    }
    state.hist.forEach(function (e) {
      var li = el('li', 'hist-row');
      var main = el('div', 'hist-main');
      main.appendChild(el('div', 'hist-title', who(e) || t('UI_UNTITLED')));

      var line = el('div', 'muted');
      if (e.time) line.appendChild(document.createTextNode(new Date(Number(e.time) * 1000).toLocaleString(document.documentElement.lang || undefined) + ' | '));
      var rk = 'UI_RESULT_' + String(e.result || '').toUpperCase();
      var badge = el('span', 'badge ' + (RESULT_CLASS[e.result] || ''), S[rk] != null ? t(rk) : String(e.result || ''));
      line.appendChild(badge);
      if (e.profile) line.appendChild(document.createTextNode(' | ' + e.profile));
      // trajanje ripa: od pocetka prvog pokusaja do upisa u istoriju (stari unosi nemaju 'started')
      var secs = Number(e.time) - Number(e.started);
      if (e.started && e.time && secs >= 0) line.appendChild(document.createTextNode(' | ' + t('UI_DURATION', [mmss(secs)])));
      main.appendChild(line);

      var ar = accuripText(e.accurip);
      if (ar) main.appendChild(el('div', 'muted', ar));
      // napomene iz istorije: 'check_offset' (sve pesme AccurateRip mismatch), 'no_speed', ... (zarezom)
      String(e.note || '').split(',').forEach(function (n) {
        if (!n) return;
        var nk = 'UI_NOTE_' + n.toUpperCase();
        if (S[nk] != null) main.appendChild(el('div', n === 'check_offset' ? 'warn-text' : 'muted', t(nk)));
      });
      if (e.result === 'cancelled' && e.reason) {
        var rr = 'UI_REASON_' + String(e.reason).toUpperCase();
        main.appendChild(el('div', 'muted', S[rr] != null ? t(rr) : String(e.reason)));
      }
      if (e.result === 'error' && e.message) main.appendChild(el('div', 'err-text', String(e.message)));

      var mv = e.move || {};
      if (mv.last_error) main.appendChild(el('div', 'err-text', errText(mv.last_error)));
      if (mv.warning) {
        var wk = 'ERR_WARN_' + String(mv.warning).toUpperCase();
        main.appendChild(el('div', 'warn-text', S[wk] != null ? t(wk) : String(mv.warning)));
      }
      if (e.path && (e.result === 'ok' || e.result === 'accurip_mismatch')) {
        main.appendChild(el('div', 'muted', e.moved ? t('UI_MOVED_TO', [e.path]) : String(e.path)));
      }
      li.appendChild(main);

      if (mv.moving) {
        li.appendChild(el('span', 'muted', t('UI_MOVING')));
      } else if (canMove(e)) {
        var b = el('button', 'small', t('UI_MOVE'));
        b.type = 'button';
        b.addEventListener('click', function () { moveToLibrary(e); });
        li.appendChild(b);
      }
      ul.appendChild(li);
    });
  }

  function render() {
    renderBanners();
    renderDisc();
    renderPlayback();
    renderTracks();
    renderProgress();
    renderHistory();
  }

  // ---------- osvezavanje ----------

  function isBusy() {
    var s = state.snap;
    if (Date.now() < state.fastUntil) return true;
    if (!s) return false;
    if (s.status === 'reading' || (s.drive_busy && s.drive_busy !== 'none')) return true;
    var rip = s.rip || {};
    if (rip.current || (rip.queue || []).length) return true;
    return state.hist.some(function (e) { return e.move && e.move.moving; });
  }

  function schedule() {
    if (state.timer) clearTimeout(state.timer);
    state.timer = setTimeout(refresh, isBusy() ? POLL_BUSY : state.playback ? POLL_PLAYING : POLL_IDLE);
  }

  function refresh() {
    if (state.timer) { clearTimeout(state.timer); state.timer = null; }
    return Promise.all([rpc('', ['audiocd', 'status']), rpc('', ['audiocd', 'history']), loadPlayback()]).then(function (r) {
      state.offline = false;
      state.snap = r[0];
      state.hist = r[1].history || [];
      render();
    }).catch(function () {
      state.offline = true;
      renderBanners();
    }).then(schedule);
  }

  // ---------- komande ----------

  function play(n) {
    var pid = $('player').value;
    if (!pid) { say(errText('no_player'), 'err'); return; }
    if (!FIXED_PLAYER) store(PLAYER_KEY, pid);
    var name = $('player').options[$('player').selectedIndex].text;
    var track = n || 1;
    run(function () { return cmd('play', 'player:' + pid, 'track:' + track); }, null).then(function (res) {
      if (res && !res.error) say(t('UI_PLAY_STARTED', [name]), 'ok');
    });
  }

  // Pause/Nastavi/Stop: obicne LMS komande plejera koji svira CD (["pause", 1|0], ["stop"]).
  function transport(params) {
    var pb = state.playback;
    if (!pb) return;
    run(function () { return rpc(pb.pid, params); });
  }

  // Play/Pauza: prvo svez status plejera (pauza sa drugog kontrolera), da Play ne krene disk iz pocetka
  // dok je pauziran, a zastarelo dugme ne uradi suprotno od onoga sto na njemu pise.
  function playPause() {
    var shown = state.playback ? state.playback.mode : 'stop';
    var pid = $('player').value;
    loadPlayback().then(function () {
      if ($('player').value !== pid) return;
      var now = state.playback ? state.playback.mode : 'stop';
      if (now === 'pause' && shown !== 'play') transport(['pause', 0]);
      else if (now === 'play' && shown === 'play') transport(['pause', 1]);
      else if (now === 'stop' && shown === 'stop') play(1);
      else renderPlayback();
    });
  }

  // Izbor odredista (glavni folder -> izvodjac -> ime foldera albuma), pa premestanje.
  function moveToLibrary(e) {
    var base = String(e.path || '').replace(/\/+$/, '').replace(/^.*\//, '').replace(/ \(\d+\)$/, '');    // bez " (2)" ponovljenog ripa
    window.FolderPicker.open({
      prefix: 'audiocd', t: t, artist: e.artist || '', name: base, start: CFG.libraryDir || '',
      rpc: function (args) { return rpc('', args); },
      onPick: function (dir, name) {
        run(function () { return cmd('move', 'id:' + e.id, 'dir:' + dir, 'name:' + name); }, t('UI_MOVE_STARTED'));
      }
    });
  }

  // Brise samo spisak (albumi ostaju na disku); unos koji se upravo premesta u biblioteku ostaje.
  function clearHistory() {
    if (!window.confirm(t('UI_HISTORY_CLEAR_CONFIRM'))) return;
    run(function () { return cmd('history_clear'); }, t('UI_HISTORY_CLEARED'));
  }

  function eject() {
    var s = state.snap || {};
    var jobs = (s.drive_busy && s.drive_busy !== 'none' && s.drive_busy !== 'process') || (s.rip && s.rip.current);
    if (jobs && !window.confirm(t('UI_EJECT_CONFIRM'))) return;
    run(function () { return cmd('eject'); }, t('UI_EJECTING'));
  }

  function openDialog(dlg) {
    if (typeof dlg.showModal === 'function') dlg.showModal(); else dlg.setAttribute('open', '');
  }

  function closeDialog(dlg) {
    if (typeof dlg.close === 'function') dlg.close(); else dlg.removeAttribute('open');
  }

  function openRip() {
    $('rip-dir').value = '';
    $('rip-dir').placeholder = CFG.ripsDir || '';
    $('rip-dir-hint').textContent = t('UI_RIP_FOLDER_HINT', [CFG.ripsDir || '']);
    $('rip-profile').value = CFG.profile || 'balanced';
    $('rip-eject').checked = !!CFG.ejectAfterRip;
    // CD svira na izabranom plejeru ili drajv izvlaci pesme za slusanje: ponudi da se to prvo zaustavi
    var s = state.snap || {};
    var playing = !!state.playback || s.drive_busy === 'cache';
    $('rip-stop-box').hidden = !playing;
    $('rip-stop').checked = playing;
    openDialog($('dlg-rip'));
  }

  function later(ms) { return new Promise(function (ok) { setTimeout(ok, ms); }); }

  // Rip; sa stop_cache server prekida izvlacenje za slusanje, a dok cd-paranoia jos umire
  // vraca drive_busy (busy: process) -> ponovi za trenutak.
  function startRip(params, tries) {
    return cmd.apply(null, ['rip'].concat(params)).then(function (res) {
      if (res && res.error === 'drive_busy' && res.busy === 'process' && tries > 1) {
        return later(RIP_RETRY).then(function () { return startRip(params, tries - 1); });
      }
      return res;
    });
  }

  function submitRip(ev) {
    ev.preventDefault();
    var params = ['profile:' + $('rip-profile').value, 'eject:' + ($('rip-eject').checked ? 1 : 0)];
    var dir = $('rip-dir').value.trim();
    if (dir) params.push('dir:' + dir);
    var stop = !$('rip-stop-box').hidden && $('rip-stop').checked;
    var pb = stop ? state.playback : null;
    if (stop) params.push('stop_cache:1');
    closeDialog($('dlg-rip'));
    run(function () {
      var first = pb ? rpc(pb.pid, ['stop']).catch(function () { /* rip ide i ako stop ne uspe */ }) : Promise.resolve();
      return first.then(function () { return startRip(params, RIP_TRIES); });
    }, t('UI_RIP_STARTED'));
  }

  function openEdit() {
    var md = state.snap && state.snap.metadata;
    if (!md) return;
    $('ed-artist').value = md.artist || '';
    $('ed-album').value = md.album || '';
    $('ed-year').value = md.year || '';
    var box = $('ed-tracks');
    clear(box);
    (md.tracks || []).forEach(function (tr) {
      var row = el('div', 'ed-row');
      row.dataset.n = tr.n;
      row.appendChild(el('span', 'n', String(tr.n)));
      var ti = el('input');
      ti.type = 'text';
      ti.className = 'ed-title';
      ti.value = tr.title || '';
      ti.setAttribute('aria-label', t('UI_TITLE') + ' ' + tr.n);
      row.appendChild(ti);
      var ar = el('input');
      ar.type = 'text';
      ar.className = 'ed-artist';
      ar.value = tr.artist || '';
      ar.placeholder = t('UI_ARTIST');
      ar.setAttribute('aria-label', t('UI_ARTIST') + ' ' + tr.n);
      row.appendChild(ar);
      box.appendChild(row);
    });
    openDialog($('dlg-edit'));
  }

  function submitEdit(ev) {
    ev.preventDefault();
    var data = { artist: $('ed-artist').value.trim(), album: $('ed-album').value.trim(), year: $('ed-year').value.trim(), tracks: [] };
    var rows = $('ed-tracks').querySelectorAll('.ed-row');
    for (var i = 0; i < rows.length; i++) {
      data.tracks.push({
        n: Number(rows[i].dataset.n),
        title: rows[i].querySelector('.ed-title').value.trim(),
        artist: rows[i].querySelector('.ed-artist').value.trim()
      });
    }
    closeDialog($('dlg-edit'));
    run(function () { return cmd('edit', 'json:' + JSON.stringify(data)); }, t('UI_SAVED'));
  }

  // ---------- pokretanje ----------

  function setStaticText() {
    var map = {
      'h-title': 'TITLE', 'settings-link': 'UI_SETTINGS', 'release-label': 'UI_RELEASE', 'player-label': 'UI_PLAYER',
      'btn-play': 'UI_PLAY', 'btn-stop': 'UI_STOP', 'rip-stop-label': 'UI_RIP_STOP_PLAYBACK', 'btn-rip': 'UI_RIP', 'btn-edit': 'UI_EDIT', 'btn-eject': 'UI_EJECT', 'btn-load': 'UI_LOAD_CD', 'btn-retry': 'UI_RETRY',
      'rip-dlg-title': 'UI_RIP_DIALOG_TITLE', 'rip-dir-label': 'UI_RIP_FOLDER', 'rip-profile-label': 'UI_PROFILE',
      'rip-eject-label': 'UI_EJECT_AFTER', 'rip-dlg-cancel': 'UI_CANCEL', 'rip-dlg-go': 'UI_START_RIP',
      'edit-title': 'UI_EDIT_TITLE', 'ed-artist-label': 'UI_ARTIST', 'ed-album-label': 'UI_ALBUM', 'ed-year-label': 'UI_YEAR',
      'edit-cancel': 'UI_CANCEL', 'edit-save': 'UI_SAVE', 'hist-clear': 'UI_HISTORY_CLEAR'
    };
    Object.keys(map).forEach(function (id) { $(id).textContent = t(map[id]); });
    var opts = $('rip-profile').options;
    for (var i = 0; i < opts.length; i++) opts[i].textContent = t('UI_PROFILE_' + opts[i].value.toUpperCase());
    $('disc-heading').textContent = '';
    document.title = t('TITLE');
  }

  function init() {
    setStaticText();
    adoptMaterial();
    window.addEventListener('load', adoptMaterial);    // Material kopira svoje promenljive tek posle ucitavanja
    if (FIXED_PLAYER) {
      $('player').closest('.player-pick').hidden = true;
      renderPlayers();
    }
    // Settings: samo novi tab. Material hvata klikove na veze u iframe-u i vodi iframe na njih,
    // pa u iframe-u zaustavljamo klik pre njegovog handlera i otvaramo tab sami.
    // Hvatamo u capture fazi na document-u, pa Material-ov handler ne moze da stigne prvi bez obzira na redosled.
    document.addEventListener('click', function (ev) {
      var a = ev.target && ev.target.closest ? ev.target.closest('#settings-link') : null;
      if (!a || !parentDoc()) return;    // klasicni web: obicna veza (target=_blank)
      ev.preventDefault();
      ev.stopImmediatePropagation();
      window.open(a.href, '_blank', 'noopener');
    }, true);
    $('player').addEventListener('change', function () {
      if (!FIXED_PLAYER) store(PLAYER_KEY, $('player').value);
      state.playback = null;
      renderPlayback();
      loadPlayback().then(function () { if (state.snap) render(); else renderPlayback(); });
    });
    $('release').addEventListener('change', function () {
      run(function () { return cmd('select_release', 'index:' + $('release').value); });
    });
    $('btn-play').addEventListener('click', playPause);
    $('btn-prev').addEventListener('click', function () { transport(['playlist', 'index', '-1']); });
    $('btn-next').addEventListener('click', function () { transport(['playlist', 'index', '+1']); });
    [['btn-prev', 'UI_PREV'], ['btn-next', 'UI_NEXT']].forEach(function (b) {
      $(b[0]).title = t(b[1]);
      $(b[0]).setAttribute('aria-label', t(b[1]));
    });
    $('btn-stop').addEventListener('click', function () { transport(['stop']); });
    $('btn-rip').addEventListener('click', openRip);
    $('btn-edit').addEventListener('click', openEdit);
    $('btn-eject').addEventListener('click', eject);
    $('hist-clear').addEventListener('click', clearHistory);
    $('btn-retry').addEventListener('click', function () { run(function () { return cmd('load', 'force:1'); }, t('UI_LOADING')); });
    $('btn-load').addEventListener('click', function () { run(function () { return cmd('load'); }, t('UI_LOADING')); });
    $('rip-cancel').addEventListener('click', function () { run(function () { return cmd('cancel', 'id:' + $('rip-cancel').dataset.id); }); });
    $('form-rip').addEventListener('submit', submitRip);
    $('rip-dlg-cancel').addEventListener('click', function () { closeDialog($('dlg-rip')); });
    $('form-edit').addEventListener('submit', submitEdit);
    $('edit-cancel').addEventListener('click', function () { closeDialog($('dlg-edit')); });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) refresh(); });

    loadPlayers();
    setInterval(loadPlayers, 30000);
    refresh();
  }

  init();
})();
