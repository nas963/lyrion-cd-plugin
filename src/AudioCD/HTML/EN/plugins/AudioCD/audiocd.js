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
  var FAST_AFTER_CMD = 15000;
  var PLAYER_KEY = 'audiocd.player';

  var state = { snap: null, hist: [], players: [], fastUntil: 0, pending: false, offline: false, timer: null };
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

  function renderPlayers() {
    var sel = $('player');
    var cur = sel.value || store(PLAYER_KEY);
    if (!changed('players', state.players)) return;
    clear(sel);
    if (!state.players.length) {
      var o = el('option', null, t('UI_NO_PLAYERS'));
      o.value = '';
      sel.appendChild(o);
    }
    state.players.forEach(function (p) {
      var o = el('option', null, p.name);
      o.value = p.id;
      sel.appendChild(o);
    });
    if (state.players.some(function (p) { return p.id === cur; })) sel.value = cur;
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

  function setButtons() {
    var snap = state.snap;
    var ready = !!(snap && snap.status === 'ready' && snap.metadata);
    var busy = state.pending;
    $('btn-play').disabled = busy || !ready || !$('player').value;
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
    var view = { tracks: discTracks(snap), artist: snap.metadata.artist, done: cache.done || [], failed: cache.failed || [] };
    if (!changed('tracks', view)) return;
    $('tracks-title').textContent = t('UI_TRACKS');
    var ol = $('tracks');
    clear(ol);
    view.tracks.forEach(function (tr) {
      var li = el('li');
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
      $('cache-text').textContent = t('UI_CACHE_TRACKS', [(cache.done || []).length, discTracks(snap).length]);
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
    state.timer = setTimeout(refresh, isBusy() ? POLL_BUSY : POLL_IDLE);
  }

  function refresh() {
    if (state.timer) { clearTimeout(state.timer); state.timer = null; }
    return Promise.all([rpc('', ['audiocd', 'status']), rpc('', ['audiocd', 'history'])]).then(function (r) {
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
    store(PLAYER_KEY, pid);
    var name = $('player').options[$('player').selectedIndex].text;
    var track = n || 1;
    run(function () { return cmd('play', 'player:' + pid, 'track:' + track); }, null).then(function (res) {
      if (res && !res.error) say(t('UI_PLAY_STARTED', [name]), 'ok');
    });
  }

  function moveToLibrary(e) {
    if (!window.confirm(t('UI_MOVE_CONFIRM', [who(e)]))) return;
    run(function () { return cmd('move', 'id:' + e.id); }, t('UI_MOVE_STARTED'));
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
    openDialog($('dlg-rip'));
  }

  function submitRip(ev) {
    ev.preventDefault();
    var params = ['profile:' + $('rip-profile').value, 'eject:' + ($('rip-eject').checked ? 1 : 0)];
    var dir = $('rip-dir').value.trim();
    if (dir) params.push('dir:' + dir);
    closeDialog($('dlg-rip'));
    run(function () { return cmd.apply(null, ['rip'].concat(params)); }, t('UI_RIP_STARTED'));
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
      'btn-play': 'UI_PLAY', 'btn-rip': 'UI_RIP', 'btn-edit': 'UI_EDIT', 'btn-eject': 'UI_EJECT', 'btn-load': 'UI_LOAD_CD', 'btn-retry': 'UI_RETRY',
      'rip-dlg-title': 'UI_RIP_DIALOG_TITLE', 'rip-dir-label': 'UI_RIP_FOLDER', 'rip-profile-label': 'UI_PROFILE',
      'rip-eject-label': 'UI_EJECT_AFTER', 'rip-dlg-cancel': 'UI_CANCEL', 'rip-dlg-go': 'UI_START_RIP',
      'edit-title': 'UI_EDIT_TITLE', 'ed-artist-label': 'UI_ARTIST', 'ed-album-label': 'UI_ALBUM', 'ed-year-label': 'UI_YEAR',
      'edit-cancel': 'UI_CANCEL', 'edit-save': 'UI_SAVE'
    };
    Object.keys(map).forEach(function (id) { $(id).textContent = t(map[id]); });
    var opts = $('rip-profile').options;
    for (var i = 0; i < opts.length; i++) opts[i].textContent = t('UI_PROFILE_' + opts[i].value.toUpperCase());
    $('disc-heading').textContent = '';
    document.title = t('TITLE');
  }

  function init() {
    setStaticText();
    $('player').addEventListener('change', function () { store(PLAYER_KEY, $('player').value); setButtons(); });
    $('release').addEventListener('change', function () {
      run(function () { return cmd('select_release', 'index:' + $('release').value); });
    });
    $('btn-play').addEventListener('click', function () { play(1); });
    $('btn-rip').addEventListener('click', openRip);
    $('btn-edit').addEventListener('click', openEdit);
    $('btn-eject').addEventListener('click', eject);
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
