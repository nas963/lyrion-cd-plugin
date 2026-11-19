/* Izbor foldera biblioteke za "Premesti u biblioteku" (isti fajl u AudioCD i AudioIn pluginu).
 * Dijalog se pravi ovde (bez HTML-a u sablonu): glavni folderi -> izvodjaci -> izabrani folder, filter po
 * imenu (unapred popunjen imenom izvodjaca), nov folder, ime foldera albuma i prikaz odredista.
 * Server: [<prefix>, 'browse', 'path:..'] i [<prefix>, 'mkdir', 'path:..', 'name:..'].
 *
 * FolderPicker.open({ prefix, rpc: fn(args) -> Promise(result), t: fn(key) -> tekst, artist, name,
 *                     onPick: fn(dir, name) })
 * Pamti se glavni folder poslednjeg izbora (localStorage <prefix>.pick.base), pa sledeci put pocinje tu. */
(function () {
  'use strict';

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function store(key, value) {
    try {
      if (value === undefined) return window.localStorage.getItem(key);
      window.localStorage.setItem(key, value);
    } catch (e) { /* privatni mod */ }
    return null;
  }

  function norm(s) {
    s = String(s || '').toLowerCase();
    try { s = s.normalize('NFD').replace(/[̀-ͯ]/g, ''); } catch (e) { /* stari pregledac */ }
    return s.replace(/đ/g, 'dj').replace(/[^a-z0-9]+/g, ' ').trim();
  }

  var dlg = null;

  function open(o) {
    var t = o.t;
    var st = { path: '', parent: null, dirs: [], roots: [] };
    if (dlg) dlg.remove();
    dlg = el('dialog', 'fp-dialog');
    var form = el('form', 'fp-form');
    form.method = 'dialog';
    dlg.appendChild(form);
    form.appendChild(el('h3', null, t('UI_PICK_TITLE')));

    var nav = el('div', 'fp-nav');
    var up = el('button', 'fp-small', '↑ ' + t('UI_PICK_UP')); up.type = 'button';
    var home = el('button', 'fp-small', t('UI_PICK_ROOTS')); home.type = 'button';
    var where = el('div', 'fp-path');
    nav.appendChild(up); nav.appendChild(home);
    form.appendChild(nav);
    form.appendChild(where);

    var filter = el('input', 'fp-filter');
    filter.type = 'search'; filter.placeholder = t('UI_PICK_FILTER'); filter.autocomplete = 'off';
    filter.value = o.artist || '';
    form.appendChild(filter);

    var list = el('ul', 'fp-list');
    form.appendChild(list);
    var info = el('div', 'fp-info');
    form.appendChild(info);

    var newRow = el('div', 'fp-row');
    var newName = el('input', 'fp-new'); newName.type = 'text'; newName.placeholder = t('UI_PICK_NEW'); newName.autocomplete = 'off';
    newName.value = o.artist || '';
    var newBtn = el('button', 'fp-small', t('UI_PICK_CREATE')); newBtn.type = 'button';
    newRow.appendChild(newName); newRow.appendChild(newBtn);
    form.appendChild(newRow);

    var nameLbl = el('label', 'fp-label', t('UI_PICK_NAME'));
    var name = el('input', 'fp-name'); name.type = 'text'; name.autocomplete = 'off'; name.value = o.name || '';
    form.appendChild(nameLbl); form.appendChild(name);

    var dest = el('div', 'fp-dest');
    form.appendChild(dest);

    var btns = el('div', 'fp-buttons');
    var cancel = el('button', null, t('UI_CANCEL')); cancel.type = 'button';
    var go = el('button', 'primary', t('UI_PICK_MOVE')); go.type = 'submit';
    btns.appendChild(cancel); btns.appendChild(go);
    form.appendChild(btns);
    document.body.appendChild(dlg);

    function updateDest() {
      var ok = !!st.path && name.value.trim() !== '';
      go.disabled = !ok;
      dest.textContent = st.path ? t('UI_PICK_DEST') + ' ' + st.path + '/' + name.value.trim() : t('UI_PICK_CHOOSE_FOLDER');
      newRow.hidden = !st.path;
    }

    function render() {
      while (list.firstChild) list.removeChild(list.firstChild);
      where.textContent = st.path || t('UI_PICK_ROOTS');
      up.disabled = !st.parent && !st.path;
      var q = st.path ? norm(filter.value) : '';    // na nivou muzickih foldera filter ne vazi
      var items = st.dirs.filter(function (d) { return !q || norm(d.name).indexOf(q) >= 0; });
      // tacno poklapanje prvo (folder izvodjaca)
      items.sort(function (a, b) { return (norm(b.name) === q) - (norm(a.name) === q); });
      items.forEach(function (d) {
        var li = el('li', norm(d.name) === q && q ? 'fp-hit' : null);
        var b = el('button', 'fp-dir', (st.path ? '' : '') + d.name); b.type = 'button';
        b.title = d.path;
        b.addEventListener('click', function () { browse(d.path, true); });
        li.appendChild(b);
        list.appendChild(li);
      });
      info.textContent = items.length ? (st.truncated ? '…' : '') : t('UI_PICK_EMPTY');
      updateDest();
    }

    function browse(path, clearFilter) {
      return o.rpc([o.prefix, 'browse', 'path:' + (path || '')]).then(function (r) {
        if (r.error) {
          if (path) return browse('', clearFilter);    // nestao/nedozvoljen folder: na korene
          info.textContent = r.error;
          return;
        }
        st.path = r.path || '';
        st.parent = r.parent || null;
        st.truncated = r.truncated;
        st.dirs = r.dirs || [];
        // glavni folder (CD, SACD...): filter = ime izvodjaca; dublje: prazan
        if (clearFilter) filter.value = r.path && !r.parent ? (o.artist || '') : '';
        filter.hidden = !st.path;
        render();
      });
    }

    up.addEventListener('click', function () {
      browse(st.parent || '', true);
    });
    home.addEventListener('click', function () { browse('', true); });
    filter.addEventListener('input', render);
    filter.addEventListener('keydown', function (ev) {
      if (ev.key !== 'Enter') return;
      ev.preventDefault();
      var first = list.querySelector('.fp-dir');
      if (first) first.click();
    });
    name.addEventListener('input', updateDest);
    newBtn.addEventListener('click', function () {
      var n = newName.value.trim();
      if (!n || !st.path) return;
      o.rpc([o.prefix, 'mkdir', 'path:' + st.path, 'name:' + n]).then(function (r) {
        if (r.error) { info.textContent = t('ERR_' + String(r.error).toUpperCase()); return; }
        browse(r.path, true);
      });
    });
    cancel.addEventListener('click', function () { dlg.close(); });
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (!st.path || !name.value.trim()) return;
      // pamti se glavni folder (roditelj izabranog, npr. .../CD kad je izabran .../CD/Izvodjac)
      store(o.prefix + '.pick.base', st.parent || st.path);
      dlg.close();
      o.onPick(st.path, name.value.trim());
    });
    dlg.addEventListener('close', function () { dlg.remove(); dlg = null; });

    if (typeof dlg.showModal === 'function') dlg.showModal(); else dlg.setAttribute('open', '');
    browse(store(o.prefix + '.pick.base') || o.start || '', true);
  }

  window.FolderPicker = { open: open };
})();
