/**
 * AudioCD: stavka "Audio CD" na Material Skin pocetnoj strani.
 * Ucitava je custom.js koji postavlja plugin AudioCD. Klik otvara stranicu plugina u
 * Material-ovom iframe dijalogu (isti put kao Extras stavke: dlg.open "iframe").
 * Sve je u jednoj funkciji, da ne dira globalne nazive drugih skripti.
 */
(function () {
    'use strict';

    var AUDIOCD_PAGE = "/plugins/AudioCD/index.html";
    var AUDIOCD_TITLE = "Audio CD";
    var WAIT_MS = 200;
    var WAIT_LIMIT = 300;

    function globalType(name) {
        try {
            return (0, eval)("typeof " + name);
        } catch (e) {
            return "undefined";
        }
    }

    function missingGlobals() {
        return ["bus", "app", "TOP_ID_PREFIX"].filter(function (name) { return "undefined" == globalType(name); });
    }

    function itemId() {
        return TOP_ID_PREFIX + "audiocd";
    }

    // Material otvara "extra" stavke u iframe dijalogu: bus.$emit("dlg.open", "iframe", url + "player=<id>", naslov, ...)
    function topItem() {
        return { id: itemId(), title: AUDIOCD_TITLE, icon: "album", type: "extra", url: AUDIOCD_PAGE + "?", weight: 96 };
    }

    function showOnHome(view) {
        if (!view.top.some(function (i) { return i.id == itemId(); })) {
            view.top.push(topItem());
        }
        if (view.isTop && view.history.length < 1) {
            view.items = view.topExtra && view.$store.state.detailedHomeItems.length > 0 && view.grid.use ? view.topExtra.concat(view.top) : view.top;
            view.layoutGrid(true);
        }
    }

    // Nasa stavka se ne snima u korisnikov spisak pocetne strane.
    function patchView(view) {
        if (view.audiocdPatched) {
            return;
        }
        view.audiocdPatched = true;
        var originalSave = view.saveTopList;
        view.saveTopList = function () {
            var all = view.top;
            view.top = all.filter(function (i) { return i.id != itemId(); });
            originalSave.call(view);
            view.top = all;
        };
    }

    function attach(view) {
        patchView(view);
        showOnHome(view);
    }

    function findBrowseView(vm) {
        if (vm.initItems && vm.top) {
            return vm;
        }
        for (var i = 0; i < vm.$children.length; ++i) {
            var found = findBrowseView(vm.$children[i]);
            if (found) {
                return found;
            }
        }
        return undefined;
    }

    // Za ostale skripte i konzolu: otvara stranicu direktno.
    window.audiocdOpen = function () {
        bus.$emit("dlg.open", "iframe", AUDIOCD_PAGE, AUDIOCD_TITLE);
    };

    function install() {
        bus.$on("homeScreenItems", function (view) {
            if (view.initItems && view.top) {
                attach(view);
            }
        });
        var view = findBrowseView(app);
        if (view) {
            attach(view);
        }
    }

    function waitForMaterial(attempt) {
        var missing = missingGlobals();
        if (0 == missing.length) {
            install();
        } else if (attempt < WAIT_LIMIT) {
            setTimeout(function () { waitForMaterial(attempt + 1); }, WAIT_MS);
        } else {
            console.warn("AudioCD: Material Skin changed, the Audio CD item is disabled. Missing: " + missing.join(", "));
        }
    }

    waitForMaterial(0);
})();
