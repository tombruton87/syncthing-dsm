// Syncthing's tabs on the chassis window: Devices, Folders, Conflicts, Activity, Privacy & network,
// the overview's tiles, the Network setting on Site address and the Storage tab's folders.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var DSM_IGNORES = ["(?d)@eaDir", "(?d)#recycle", "(?d)#snapshot", "(?d).DS_Store", "(?d)._*", "(?d)Thumbs.db", "(?d)desktop.ini", "(?d).SynologyWorkingDirectory"].join("\n");
  var TYPES = { sendreceive: "Send & receive", sendonly: "Send only", receiveonly: "Receive only" };
  function A(st) { return (st && st.app) || {}; }
  function stUrl(st) { return (A(st).url || "").replace(/\/$/, ""); }
  function num(n) { return (n || 0).toLocaleString(); }
  function empty(tb, text, span) { var r = P.el("tr"), c = P.cell(text, "empty"); c.colSpan = span || 1; r.appendChild(c); tb.appendChild(r); }
  function changed(node, sig) { if (node.dataset.sig === sig) return false; node.dataset.sig = sig; return true; }
  function rate(n) { return n ? P.bytes(n) + "/s" : "–"; }
  function short(id) { return (id || "").slice(0, 7); }
  function devName(a, id) { var d = (a.devices || []).filter(function (x) { return x.id === id; })[0]; return d ? (d.name || short(id)) : short(id); }
  function shareRoot(st, p) {
    var a = A(st), m = /^(\/volume(USB)?[0-9]+(-[0-9]+)?\/[^/]+)/.exec(p || ""); if (m) return m[1];
    var sh = (a.shares || []).filter(function (s) { return p === s.path || p.indexOf(s.path + "/") === 0; })[0]; return sh ? sh.path : p;
  }
  function baseName(p) { return (p || "").replace(/\/$/, "").split("/").pop(); }
  function fixLines(root, what) {
    var d = P.el("div", null, "fix"); d.appendChild(P.el("b", what)); d.appendChild(P.el("br"));
    d.appendChild(document.createTextNode("Give the package's user access: in DSM, Control Panel → Shared Folder → select " + baseName(root) + " → Edit → Permissions → in the drop-down at the top pick System internal user → tick Read/Write for syncthing → Save. The window checks again within ten minutes (or now: "));
    var a = P.el("a", "check now"); a.href = "#"; a.onclick = function (e) { e.preventDefault(); P.act("sharescan"); }; d.appendChild(a); d.appendChild(document.createTextNode(")."));
    return d;
  }
  function folderStatus(f) {
    if (f.paused) return { text: "paused", cls: "warn" };
    if (f.place === "waiting") return { text: "waiting for its shared folder", cls: "bad" };
    if (f.state === "error") return { text: "error: " + (f.error || "see Syncthing"), cls: "bad" };
    if (f.state === "scanning" || f.state === "scan-waiting") return { text: "scanning", cls: "warn" };
    var pct = f.global_bytes ? Math.floor(f.in_sync_bytes * 100 / f.global_bytes) : 100;
    if (f.state === "syncing" || f.state === "sync-preparing" || f.state === "sync-waiting") return { text: "syncing " + Math.min(pct, 99) + "%", cls: "warn" };
    if (f.pull_errors) return { text: f.pull_errors + " file" + (f.pull_errors > 1 ? "s" : "") + " failing", cls: "bad" };
    if (f.type === "receiveonly" && f.ro_changed) return { text: f.ro_changed + " local change" + (f.ro_changed > 1 ? "s" : ""), cls: "warn" };
    if (f.need_files) return { text: "out of sync: " + num(f.need_files) + " item" + (f.need_files > 1 ? "s" : ""), cls: "warn" };
    if (f.state === "idle") return { text: "up to date", cls: "ok" };
    return { text: f.state || "unknown", cls: "" };
  }
  function outOfSync(f) { var s = folderStatus(f); return s.cls === "bad" || /^out of sync|failing/.test(s.text); }
  function verText(v) {
    var p = (v && v.params) || {};
    switch (v && v.type) {
      case "trashcan": return "trash can" + (+p.cleanoutDays ? ", " + p.cleanoutDays + " days" : "");
      case "simple": return "simple, last " + (p.keep || 5) + " versions";
      case "staggered": return "staggered, up to " + Math.round((+p.maxAge || 31536000) / 86400) + " days";
      case "external": return "external command";
      default: return "off";
    }
  }
  function vShow(box) {   // the versioning fields that matter for the chosen kind
    var t = box.querySelector(".vtype").value;
    box.querySelectorAll(".vkeep").forEach(function (x) { x.hidden = t !== "simple"; });
    box.querySelectorAll(".vdays").forEach(function (x) { x.hidden = t === "none"; });
  }
  function devChecks(box, a, ticked, cls) {   // a checkbox per paired device
    P.clear(box);
    if (!(a.devices || []).length) { box.appendChild(P.el("span", "No devices paired yet — pair one on the Devices tab; you can share the folder with it later.", "muted small")); return; }
    (a.devices || []).forEach(function (d) { var l = P.el("label"), c = P.el("input"); c.type = "checkbox"; c.value = d.id; c.className = cls || ""; c.checked = (ticked || []).indexOf(d.id) >= 0; l.appendChild(c); l.appendChild(document.createTextNode(" " + (d.name || short(d.id)))); box.appendChild(l); });
  }
  function ticked(box) { return Array.prototype.slice.call(box.querySelectorAll("input[type=checkbox]:checked")).map(function (c) { return c.value; }).join("+") || "none"; }
  function sel(options, value) { var s = P.el("select"); options.forEach(function (o) { var op = P.el("option", o[1]); op.value = o[0]; s.appendChild(op); }); if (value != null) s.value = value; return s; }
  function field(label, input, cls) { var l = P.el("label", null, "f" + (cls ? " " + cls : "")); l.appendChild(P.el("span", label)); l.appendChild(input); return l; }
  function input(type, value, attrs) { var i = P.el("input"); i.type = type; if (value != null) i.value = value; Object.keys(attrs || {}).forEach(function (k) { i.setAttribute(k, attrs[k]); }); return i; }
  function versionFields(v) {   // a row of versioning fields → {box, values()}
    var p = (v && v.params) || {}, box = P.el("div", null, "row3");
    var t = sel([["none", "Off"], ["trashcan", "Trash can"], ["simple", "Simple — the last N versions"], ["staggered", "Staggered — fewer as they age"]], (v && v.type) || "none"); t.className = "vtype";
    var k = input("number", p.keep || 5, { min: 1, max: 999 }), d = input("number", v && v.type === "staggered" ? Math.round((+p.maxAge || 31536000) / 86400) : (p.cleanoutDays || (v && v.type ? 0 : 30)), { min: 0, max: 3650 });
    box.appendChild(field("File versioning", t)); box.appendChild(field("Versions to keep", k, "vkeep")); box.appendChild(field("Keep for (days, 0 = always)", d, "vdays"));
    t.addEventListener("change", function () { vShow(box); }); vShow(box);
    return { box: box, values: function () { return { vtype: t.value, vkeep: k.value || 5, vdays: d.value || 0 }; } };
  }
  function fits(body) { var n = new URLSearchParams(body).toString().length; if (n > 4000) { P.showErr("That's too much for the window to send at once (ignore patterns are the usual reason): keep them shorter, or edit them in Syncthing's own interface."); return false; } return true; }

  // ---------------------------------------------------------------- overview tiles and badges
  P.register("overview", { tiles: function (t, st) {
    var a = A(st); if (!a.up) return;
    var devs = a.devices || [], on = devs.filter(function (d) { return d.connected; }).length, fs = a.folders || [];
    P.tile(t, on + " of " + devs.length, "devices connected"); P.tile(t, num(fs.length), "folders");
    P.tile(t, num(fs.filter(outOfSync).length), "out of sync"); P.tile(t, num((a.conflicts || {}).count), "conflicts");
  } });
  P.register("badges", { badge: function (st) {
    var a = A(st), pd = (a.pending_devices || []).length, pf = (a.pending_folders || []).length, bad = (a.folders || []).filter(function (f) { return outOfSync(f) || (f.access !== "rw" && f.access !== "unknown" && !(f.access === "ro" && f.type === "sendonly")); }).length, cf = (a.conflicts || {}).count || 0;
    $("badge-devices").hidden = !pd; $("badge-devices").textContent = pd;
    $("badge-folders").hidden = !(pf + bad); $("badge-folders").textContent = pf + bad;
    $("badge-conflicts").hidden = !cf; $("badge-conflicts").textContent = cf;
  } });

  // ---------------------------------------------------------------- Devices
  $("me-copy").onclick = function () { P.copy($("me-id").textContent, $("me-copy"), $("me-id")); };
  P.register("devices", {
    render: function (st) {
      var a = A(st);
      $("me-id").textContent = a.my_id || "Syncthing is starting…"; $("me-name").textContent = a.my_name || "This Synology";
      if (a.qr) { $("me-qr").src = "data:image/png;base64," + a.qr; $("me-qr").hidden = false; }
      $("me-addr").textContent = a.lan_ip ? "On your network it listens at tcp://" + a.lan_ip + ":" + (a.sync_port || 22000) + " (and quic://, the same port) — the address to give a device that can't find it by itself." : "";
      // Asking to connect
      var pd = a.pending_devices || [], tb = $("pd-rows"); $("pd-card").hidden = !pd.length;
      if (changed(tb, JSON.stringify(pd) + P.busy + P.role)) { P.clear(tb);
        pd.forEach(function (d) {
          var name = input("text", d.name || "", { maxlength: 60, placeholder: "a name for it" }), acts = P.el("span", null, "row");
          acts.appendChild(P.btn("Accept", "primary", function () { var n = name.value.trim(); if (!n) { P.showErr("Give it a name first."); return; } P.act("devaccept", { dev: d.id, name: n }); }));
          acts.appendChild(P.btn("Ignore", "", function () { P.act("devignore", { dev: d.id }, "Ignore " + (d.name || short(d.id)) + "? It isn't shown here again when it asks."); }));
          var who = P.el("span"); who.appendChild(P.el("b", d.name || "(no name)")); who.appendChild(P.el("span", d.id, "sub mono"));
          P.row(tb, [P.cell(who), P.cell(P.el("span", d.address || "–", "mono nowrap")), P.when(d.at), P.cell(name), P.cell(acts, "n")]);
        }); }
      // Paired devices
      var dv = a.devices || [], tb2 = $("dv-rows"); P.clear(tb2);
      if (!a.up) empty(tb2, "Syncthing isn't answering yet.", 6);
      else if (!dv.length) empty(tb2, "No devices yet. Pair one with the QR code or ID above.", 6);
      dv.forEach(function (d) {
        var who = P.el("span"); who.appendChild(P.el("b", d.name || short(d.id))); who.appendChild(P.el("span", short(d.id) + "…" + (d.folders.length ? " · " + d.folders.join(", ") : " · no folders shared"), "sub"));
        var stc = P.el("span"); stc.appendChild(d.paused ? P.chip("paused", "warn") : d.connected ? P.chip("connected", "ok") : P.chip("not connected", "bad"));
        if (!d.connected) stc.appendChild(P.el("span", "last seen " + (d.last_seen ? P.ago(d.last_seen) : "never"), "sub"));
        else if (d.client) stc.appendChild(P.el("span", d.client, "sub"));
        var addr = P.el("span"); addr.appendChild(P.el("span", d.connected ? d.address : (d.addresses || []).join(", "), "mono nowrap"));
        if (d.connected) addr.appendChild(P.el("span", (d.conn_type || "").replace(/-(client|server)$/, "") + (d.lan ? " · local network" : " · internet") + (/relay/.test(d.conn_type) ? " (through a relay)" : ""), "sub"));
        var sync = P.el("span");
        if (d.completion != null) { var b = P.el("span", null, "bar2"), i = P.el("i"); i.style.width = Math.max(0, Math.min(100, d.completion)) + "%"; b.appendChild(i); sync.appendChild(b); sync.appendChild(document.createTextNode(Math.floor(d.completion) + "%")); if (d.need_bytes) sync.appendChild(P.el("span", P.bytes(d.need_bytes) + " to go", "sub")); }
        else sync.textContent = "–";
        var acts = P.el("span", null, "row");
        acts.appendChild(P.btn(d.paused ? "Resume" : "Pause", "", function () { P.act("devpause", { dev: d.id, pause: d.paused ? 0 : 1 }); }));
        acts.appendChild(P.btn("Rename", "", function () { var n = window.prompt("A name for " + (d.name || short(d.id)) + ":", d.name || ""); if (n && n.trim()) P.act("devrename", { dev: d.id, name: n.trim() }); }));
        acts.appendChild(P.btn("Remove", "danger", function () { P.act("devremove", { dev: d.id }, "Remove " + (d.name || short(d.id)) + "? Nothing syncs with it any more; files stay where they are. It can ask to pair again."); }));
        P.row(tb2, [P.cell(who), P.cell(stc), P.cell(addr), P.cell(d.connected ? "↓ " + rate(d.in_rate) + "  ↑ " + rate(d.out_rate) : "–", "n"), P.cell(sync), P.cell(acts, "n")]);
      });
      var ig = a.ignored_devices || []; $("ig-devs").textContent = ig.length ? "Ignored when they ask: " + ig.map(function (d) { return (d.name || "") + " " + short(d.id) + "…"; }).join(", ") + ". (Syncthing's own interface can un-ignore them.)" : "";
    }
  });
  $("ad-add").onclick = function () {
    var id = $("ad-id").value.trim(), n = $("ad-name").value.trim();
    if (!id || !n) { P.showErr("The device's ID and a name for it, please."); return; }
    P.act("devadd", { dev: id, name: n, addr: $("ad-addr").value.trim() }).then(function () { $("ad-id").value = ""; $("ad-name").value = ""; $("ad-addr").value = ""; });
  };

  // ---------------------------------------------------------------- Folders
  var folderEls = {};
  function shareOptions(selectEl, st, keep) {   // the shared folders, with what the package's user may do in each
    var a = A(st), cur = keep != null ? keep : selectEl.value, shares = a.shares || [];
    P.clear(selectEl);
    shares.forEach(function (s) { var o = P.el("option", s.path + (s.access === "rw" ? "" : s.access === "ro" ? "  (read only for syncthing)" : "  (no access for syncthing)")); o.value = s.path; selectEl.appendChild(o); });
    var other = P.el("option", shares.length ? "Another path…" : "Type the path…"); other.value = "*"; selectEl.appendChild(other);
    selectEl.value = cur && Array.prototype.some.call(selectEl.options, function (o) { return o.value === cur; }) ? cur : (shares.length ? shares[0].path : "*");
  }
  function accessOf(st, path) { var s = (A(st).shares || []).filter(function (x) { return x.path === path; })[0]; return s ? s.access : null; }
  function renderPending(st) {
    var a = A(st), pf = a.pending_folders || [], tb = $("pf-rows"); $("pf-card").hidden = !pf.length;
    if (!changed(tb, JSON.stringify(pf) + JSON.stringify(a.shares || []) + P.busy + P.role)) return;
    P.clear(tb);
    pf.forEach(function (f) { f.by.forEach(function (b) {
      var tr = P.el("tr"), td = P.el("td"); tr.appendChild(td); tb.appendChild(tr);
      var hd = P.el("p"); hd.appendChild(P.el("b", f.label)); hd.appendChild(document.createTextNode(" from " + b.name + ", offered " + P.ago(b.at))); hd.appendChild(P.el("span", "folder ID " + f.id, "sub mono")); td.appendChild(hd);
      var share = P.el("select"); shareOptions(share, st, ""); var sub = input("text", f.label.replace(/[\/\\]/g, "-"), { placeholder: "a folder in it" }), path = input("text", "", { placeholder: "/volume1/sync/" + f.label });
      var type = sel([["sendreceive", "Send & receive"], ["sendonly", "Send only"], ["receiveonly", "Receive only"]], "sendreceive");
      var r = P.el("div", null, "row3"); r.appendChild(field("Into the shared folder", share)); r.appendChild(field("Folder inside it", sub)); var pw = field("Folder path", path); r.appendChild(pw); r.appendChild(field("Type", type)); td.appendChild(r);
      var vf = versionFields({ type: "trashcan", params: { cleanoutDays: "30" } }); td.appendChild(vf.box);
      var note = P.el("p", null, "small"); td.appendChild(note);
      function upd() { pw.hidden = share.value !== "*"; sub.parentNode.hidden = share.value === "*"; var acc = accessOf(st, share.value); note.textContent = ""; if (acc && acc !== "rw") note.appendChild(fixLines(share.value, "syncthing can't write in " + share.value + " yet.")); }
      share.addEventListener("change", upd); upd();
      var acts = P.el("p", null, "row");
      acts.appendChild(P.btn("Accept", "primary", function () {
        var p = share.value === "*" ? path.value.trim() : share.value + (sub.value.trim() ? "/" + sub.value.trim().replace(/^\/+|\/+$/g, "") : "");
        if (!p) { P.showErr("Where should it go?"); return; }
        var body = Object.assign({ fid: f.id, dev: b.id, label: f.label, path: p, type: type.value, devices: b.id, ignores: DSM_IGNORES }, vf.values());
        if (fits(body)) P.act("folderaccept", body);
      }));
      acts.appendChild(P.btn("Decline", "", function () { P.act("folderdecline", { fid: f.id, dev: b.id }, "Decline " + f.label + " from " + b.name + "? It isn't offered here again."); }));
      td.appendChild(acts);
    }); });
  }
  function buildEdit(f, st, box) {   // the folder's settings: name, type, devices; versioning; ignore patterns; removal
    var a = A(st); P.clear(box);
    var d1 = P.el("details"); d1.appendChild(P.el("summary", "Name, type and devices"));
    var lab = input("text", f.label, { maxlength: 100 }), type = sel([["sendreceive", "Send & receive"], ["sendonly", "Send only"], ["receiveonly", "Receive only"]], f.type);
    var r = P.el("div", null, "row3"); r.appendChild(field("Name", lab)); r.appendChild(field("Type", type)); d1.appendChild(r);
    d1.appendChild(P.el("p", "Shared with", "small")); var ch = P.el("div", null, "checks"); devChecks(ch, a, f.devices); d1.appendChild(ch);
    d1.appendChild(P.btn("Save", "primary", function () { P.act("folderedit", { fid: f.id, label: lab.value.trim(), type: type.value, devices: ticked(ch) }).then(function () { box.dataset.touched = ""; box.dataset.dirty = ""; }); }));
    var d2 = P.el("details"); d2.appendChild(P.el("summary", "File versioning: " + verText(f.versioning)));
    d2.appendChild(P.el("p", "Versions of files that other devices change or delete are kept in .stversions inside the folder. Changes made on this Synology itself aren't versioned — Hyper Backup or snapshots cover those.", "muted small"));
    var vf = versionFields(f.versioning); d2.appendChild(vf.box);
    d2.appendChild(P.btn("Save", "primary", function () { P.act("folderversions", Object.assign({ fid: f.id }, vf.values())).then(function () { box.dataset.touched = ""; box.dataset.dirty = ""; }); }));
    var d3 = P.el("details"); d3.appendChild(P.el("summary", "Ignore patterns (" + (f.ignores || []).length + ")"));
    d3.appendChild(P.el("p", "One per line, as Syncthing's .stignore: a name matches at any depth, / anchors it to the folder's top, * and ** are wildcards, ! keeps something a later line would ignore.", "muted small"));
    var ta = P.el("textarea"); ta.spellcheck = false; ta.value = (f.ignores || []).join("\n"); d3.appendChild(ta);
    var r3 = P.el("p", null, "row"); r3.appendChild(P.btn("Save", "primary", function () { var b = { fid: f.id, ignores: ta.value }; if (fits(b)) P.act("folderignores", b).then(function () { box.dataset.touched = ""; box.dataset.dirty = ""; }); }));
    r3.appendChild(P.btn("Add the Synology defaults", "", function () { var have = ta.value.split("\n"); ta.value = (ta.value.trim() ? ta.value.replace(/\n*$/, "\n") : "") + DSM_IGNORES.split("\n").filter(function (l) { return have.indexOf(l) < 0; }).join("\n"); box.dataset.touched = "1"; }));
    d3.appendChild(r3);
    // While a section is open or edited, the refresh leaves it alone; closed unedited, it follows Syncthing again.
    [d1, d2, d3].forEach(function (d) { box.appendChild(d);
      d.addEventListener("toggle", function () { if (d.open) box.dataset.touched = "1"; else if (!box.dataset.dirty && ![d1, d2, d3].some(function (x) { return x.open; })) box.dataset.touched = ""; });
      ["input", "change"].forEach(function (ev) { d.addEventListener(ev, function () { box.dataset.touched = "1"; box.dataset.dirty = "1"; }); }); });
    var rm = P.el("p", null, "row"); rm.style.marginTop = "10px";
    rm.appendChild(P.btn("Stop syncing this folder", "danger", function () { P.act("folderremove", { fid: f.id }, "Stop syncing " + f.label + "? Its files stay in " + f.path + "; other devices keep their copies."); }));
    box.appendChild(rm);
  }
  function renderFolder(f, st, el) {
    var a = A(st), s = folderStatus(f);
    var hd = el.querySelector(".hd"); P.clear(hd);
    hd.appendChild(P.el("b", f.label || f.id)); hd.appendChild(P.chip(s.text, s.cls)); hd.appendChild(P.el("span", TYPES[f.type] || f.type, "pill"));
    var acts = P.el("span", null, "row");
    acts.appendChild(P.btn("Rescan", "", function () { P.act("folderscan", { fid: f.id }); }));
    acts.appendChild(P.btn(f.paused ? "Resume" : "Pause", "", function () { P.act("folderpause", { fid: f.id, pause: f.paused ? 0 : 1 }); }));
    if (f.type === "sendonly" && f.need_files) acts.appendChild(P.btn("Override changes", "", function () { P.act("folderoverride", { fid: f.id }, "Send this Synology's version of " + f.label + " to the other devices, over the changes they made? Their changes are lost (unless they keep versions)."); }));
    if (f.type === "receiveonly" && f.ro_changed) acts.appendChild(P.btn("Revert local changes", "", function () { P.act("folderrevert", { fid: f.id }, "Undo the " + f.ro_changed + " local change(s) in " + f.label + "? Files added here are removed and changed ones are brought back as the other devices have them."); }));
    hd.appendChild(acts);
    var bd = el.querySelector(".bd .info"), tb = P.el("tbody"), t = P.el("table"); t.appendChild(tb); P.clear(bd); bd.appendChild(t);
    var pathCell = P.el("span"); pathCell.appendChild(P.el("span", f.path, "mono"));
    if (f.place === "outside") pathCell.appendChild(P.el("span", "not in a shared folder the package mounts — Syncthing can't see it", "sub"));
    P.kv(tb, "Path", pathCell);
    var names = (f.devices || []).map(function (id) { return devName(a, id); }); P.kv(tb, "Shared with", names.length ? names.join(", ") : "no device yet — tick some under Name, type and devices");
    P.kv(tb, "Here", P.bytes(f.local_bytes) + " in " + num(f.local_files) + " files" + (f.global_bytes !== f.local_bytes || f.global_files !== f.local_files ? " (all devices: " + P.bytes(f.global_bytes) + ", " + num(f.global_files) + " files)" : ""));
    if (f.need_files) P.kv(tb, "To fetch", num(f.need_files) + " items, " + P.bytes(f.need_bytes) + (f.out_since ? " · out of sync since " + P.ago(f.out_since) : ""));
    P.kv(tb, "Last scan", (f.last_scan ? P.ago(f.last_scan) : "not yet") + (f.watcher ? " · changes are noticed as they happen" : " · every " + Math.round((f.rescan_s || 3600) / 60) + " min"));
    if (f.last_file && f.last_file.name) P.kv(tb, "Last change", f.last_file.name + (f.last_file.deleted ? " (deleted)" : "") + ", " + P.ago(f.last_file.at));
    var root = shareRoot(st, f.path);
    if (f.place === "waiting") { var w = P.el("div", "The shared folder " + root + " isn't there (renamed, deleted, or on a disk that's away). The package doesn't create it: Syncthing waits, and picks it up within ten minutes of it being back.", "fix"); bd.appendChild(w); }
    else if (f.access === "none") bd.appendChild(fixLines(root, "Syncthing (the package's user, syncthing) can't read " + f.path + "."));
    else if (f.access === "ro" && f.type !== "sendonly") bd.appendChild(fixLines(root, "Syncthing can read " + f.path + " but not write in it, so it can't save what other devices change."));
    if (f.error && f.state === "error") bd.appendChild(P.el("div", "Syncthing: " + f.error, "fix"));
    if ((f.failing || []).length) {
      var fx = P.el("div", null, "fix warn"); fx.appendChild(P.el("b", f.pull_errors + " file" + (f.pull_errors > 1 ? "s" : "") + " couldn't be synced:"));
      var ul = P.el("ul"); ul.style.margin = "4px 0 0"; (f.failing || []).slice(0, 15).forEach(function (e) { var li = P.el("li"); li.appendChild(P.el("span", e.path, "mono")); li.appendChild(P.el("span", e.error, "sub")); ul.appendChild(li); }); fx.appendChild(ul);
      if (f.failing.length > 15) fx.appendChild(P.el("span", "…and " + (f.failing.length - 15) + " more.", "sub")); bd.appendChild(fx);
    }
    var edit = el.querySelector(".bd .edit"), sig = JSON.stringify([f.label, f.type, f.devices, f.versioning, f.ignores, (a.devices || []).map(function (d) { return d.id + d.name; }), P.role]);
    if (edit.dataset.sig !== sig && !edit.dataset.touched) { edit.dataset.sig = sig; buildEdit(f, st, edit); }
    edit.querySelectorAll("button.btn").forEach(function (b) { b.disabled = P.busy || P.role !== "admin"; });
  }
  P.register("folders", {
    render: function (st) {
      var a = A(st), list = $("fd-list"), fs = a.folders || [], errs = a.errors || [];
      $("fd-errs").hidden = !errs.length; $("fd-errs").textContent = errs.length ? "Syncthing reported: " + errs.slice(-3).map(function (e) { return e.message; }).join(" · ") : "";
      renderPending(st);
      if (!fs.length && !list.querySelector(".empty-f")) { P.clear(list); folderEls = {}; var c = P.el("div", null, "card"); c.className = "card empty-f"; c.appendChild(P.el("div", a.up ? "No folders synced yet. Add one below, or accept one another device offers." : "Syncthing isn't answering yet.", "empty")); list.appendChild(c); }
      if (fs.length) { var e0 = list.querySelector(".empty-f"); if (e0) list.removeChild(e0); }
      var seen = {};
      fs.forEach(function (f) {
        var el = folderEls[f.id];
        if (!el) { el = P.el("div", null, "fold"); el.appendChild(P.el("div", null, "hd")); var bd = P.el("div", null, "bd"); bd.appendChild(P.el("div", null, "info")); bd.appendChild(P.el("div", null, "edit")); el.appendChild(bd); folderEls[f.id] = el; }
        list.appendChild(el); seen[f.id] = 1; renderFolder(f, st, el);
      });
      Object.keys(folderEls).forEach(function (id) { if (!seen[id]) { if (folderEls[id].parentNode) folderEls[id].parentNode.removeChild(folderEls[id]); delete folderEls[id]; } });
      // Add a folder
      if (changed($("af-share"), JSON.stringify(a.shares || []))) shareOptions($("af-share"), st);
      if (changed($("af-devs"), JSON.stringify((a.devices || []).map(function (d) { return [d.id, d.name]; })))) devChecks($("af-devs"), a, Array.prototype.slice.call($("af-devs").querySelectorAll("input:checked")).map(function (c) { return c.value; }));
      if (!$("af-ign").dataset.filled) { $("af-ign").value = DSM_IGNORES; $("af-ign").dataset.filled = "1"; }
      afShow(st);
    }
  });
  function afShow(st) {
    var v = $("af-share").value, acc = accessOf(st || P.S.status, v), note = $("af-access"); $("af-path-wrap").hidden = v !== "*"; $("af-sub").parentNode.hidden = v === "*";
    P.clear(note);
    if (v === "*") note.appendChild(P.el("span", (A(st || P.S.status).shares || []).length ? "A folder in one of this Synology's shared folders, like /volume1/photos/Phone." : "The shared folders couldn't be listed here; type the path of one, like /volume1/photos.", "muted"));
    else if (acc === "rw") note.appendChild(P.chip("syncthing can read and write here", "ok"));
    else if (acc) note.appendChild(fixLines(v, acc === "ro" ? "syncthing can only read " + v + " — fine for Send only; for the other types it needs Read/Write." : "syncthing has no access to " + v + "."));
    vShow($("af-vtype").closest(".in"));
  }
  $("af-share").addEventListener("change", function () { afShow(); });
  $("af-vtype").addEventListener("change", function () { vShow($("af-vtype").closest(".in")); });
  $("af-add").onclick = function () {
    var share = $("af-share").value, p = share === "*" ? $("af-path").value.trim() : share + ($("af-sub").value.trim() ? "/" + $("af-sub").value.trim().replace(/^\/+|\/+$/g, "") : "");
    var label = $("af-label").value.trim() || baseName(p);
    if (!p) { P.showErr("Pick a shared folder (or type a path)."); return; }
    var body = { label: label, path: p, type: $("af-type").value, devices: ticked($("af-devs")), vtype: $("af-vtype").value, vkeep: $("af-vkeep").value || 5, vdays: $("af-vdays").value || 0, ignores: $("af-ign").value };
    if (fits(body)) P.act("folderadd", body).then(function () { $("af-label").value = ""; $("af-sub").value = ""; $("af-path").value = ""; });
  };

  // ---------------------------------------------------------------- Conflicts
  var cfAt = -1;
  function loadConflicts(force) {
    var st = P.S && P.S.status, at = st && A(st).conflicts ? A(st).conflicts.at : 0;
    if (!force && at === cfAt) return; cfAt = at;
    P.api("action=conflicts").then(renderConflicts).catch(function (e) { P.showErr(e.message); });
  }
  function renderConflicts(d) {
    var tb = $("cf-rows"), list = (d && d.conflicts) || []; P.clear(tb);
    $("cf-when").textContent = d && d.at ? "looked " + P.ago(d.at) : "";
    if (!list.length) { empty(tb, d && d.at ? "No conflicting copies." : "Not looked yet — it happens within a few minutes of Syncthing starting.", 5); return; }
    var groups = {}; list.forEach(function (c) { (groups[c.original] = groups[c.original] || []).push(c); });
    Object.keys(groups).sort().forEach(function (o) {
      var g = groups[o], f = g[0], tr = P.el("tr", null, "grp"), td = P.el("td"); td.colSpan = 5;
      td.appendChild(P.el("span", f.orig_rel, "mono")); td.appendChild(P.el("span", " in " + f.label + " · the file now: " + (f.orig_size != null ? P.bytes(f.orig_size) + ", saved " + P.when(f.orig_at) : "deleted since"), "muted small"));
      tr.appendChild(td); tb.appendChild(tr);
      g.sort(function (x, y) { return y.at - x.at; }).forEach(function (c) {
        var acts = P.el("span", null, "row");
        acts.appendChild(P.btn("Keep this version", "", function () { P.act("conflictkeep", { file: c.path }, "Put this copy (from " + c.by + ") in place of " + baseName(c.original) + "? The current file is replaced on every device."); }));
        acts.appendChild(P.btn("Keep the original", "", function () { P.act("conflictdrop", { file: c.path }, "Delete this conflicting copy and keep " + baseName(c.original) + " as it is?"); }));
        var nm = P.el("span"); nm.appendChild(P.el("span", baseName(c.path), "mono"));
        P.row(tb, [P.cell(nm), c.by, P.cell(P.bytes(c.size), "n"), P.when(c.at), P.cell(acts, "n")]);
      });
    });
  }
  P.register("conflicts", { show: function () { loadConflicts(true); }, tick: function () { loadConflicts(false); }, render: function () { loadConflicts(false); } });

  // ---------------------------------------------------------------- Activity
  var acData = null;
  function loadActivity() { P.api("action=activity").then(function (d) { acData = d; renderActivity(); }).catch(function (e) { P.showErr(e.message); }); }
  var VERB = { added: "added", modified: "changed", deleted: "deleted", update: "changed" };
  function renderActivity() {
    var tb = $("ac-rows"), items = (acData && acData.items) || [], fsel = $("ac-folder"), want = fsel.value, labels = {};
    items.forEach(function (i) { if (i.folder) labels[i.folder] = i.label || i.folder; });
    var fsig = JSON.stringify(labels); if (changed(fsel, fsig)) { P.clear(fsel); var o0 = P.el("option", "All folders"); o0.value = ""; fsel.appendChild(o0); Object.keys(labels).forEach(function (k) { var o = P.el("option", labels[k]); o.value = k; fsel.appendChild(o); }); fsel.value = labels[want] ? want : ""; }
    P.clear(tb); var shown = items.filter(function (i) { return !fsel.value || i.folder === fsel.value; }).slice(0, 200);
    if (!shown.length) { empty(tb, "No file changes seen yet.", 5); return; }
    shown.forEach(function (i) {
      var what = i.kind === "error" ? P.el("span", "failed: " + (i.error || ""), "act-error") : P.el("span", (VERB[i.action] || i.action) + (i.type === "dir" ? " (folder)" : ""), i.kind === "local" ? "act-local" : "act-remote");
      P.row(tb, [P.cell(P.el("span", P.when(i.at), "nowrap")), P.cell(what), P.cell(i.path || "", "mono"), i.label || i.folder || "", i.by || "–"]);
    });
  }
  $("ac-folder").addEventListener("change", renderActivity);
  P.register("activity", { show: loadActivity, tick: loadActivity });

  // ---------------------------------------------------------------- Privacy & network
  function pvTouch() { $("pv-save").dataset.touched = "1"; }
  document.querySelectorAll("input[name=pv-mode]").forEach(function (r) { r.addEventListener("change", pvTouch); });
  ["pv-send", "pv-recv", "pv-lan"].forEach(function (id) { $(id).addEventListener("input", pvTouch); $(id).addEventListener("change", pvTouch); });
  $("pv-port").addEventListener("input", function () { $("pv-port").dataset.touched = "1"; });
  P.register("privacy", {
    render: function (st) {
      var a = A(st), o = a.options || {};
      document.querySelectorAll(".st-link").forEach(function (x) { x.href = stUrl(st) || "#"; });
      if (!$("pv-save").dataset.touched && a.options) {
        document.querySelectorAll("input[name=pv-mode]").forEach(function (r) { r.checked = r.value === a.privacy; });
        $("pv-send").value = o.maxSendKbps || 0; $("pv-recv").value = o.maxRecvKbps || 0; $("pv-lan").checked = !!o.limitBandwidthInLan;
      }
      if (!$("pv-port").dataset.touched) $("pv-port").value = a.sync_port || 22000;
      var tb = $("pv-info"); P.clear(tb);
      P.kv(tb, "Network", a.net === "host" ? "the NAS's own network (local discovery works)" : "Docker's network (ports " + (a.sync_port || 22000) + " TCP/UDP published; no local discovery)");
      P.kv(tb, "Listening on", (o.listenAddresses || []).join(", ") || "–");
      (a.listeners || []).forEach(function (l) { P.kv(tb, l.address.replace(/^dynamic\+/, ""), l.error ? P.chip(l.error, "bad") : P.chip("listening", "ok")); });
      P.kv(tb, "Global discovery", o.globalAnnounceEnabled ? "on" : "off"); P.kv(tb, "Relays", o.relaysEnabled ? "on" : "off"); P.kv(tb, "NAT traversal", o.natEnabled ? "on (UPnP / NAT-PMP)" : "off");
      (a.discovery || []).filter(function (d) { return d.error; }).slice(0, 3).forEach(function (d) { P.kv(tb, d.name, P.chip(d.error, "warn")); });
      $("pv-hint").textContent = a.privacy === "anywhere" ? "Away from home, devices connect best when port " + (a.sync_port || 22000) + " (TCP and UDP) is forwarded to " + (a.lan_ip || "this Synology") + " in your router; without that, NAT traversal or a relay usually still works, just slower. DSM's firewall, if on, must allow it too (Control Panel → Security → Firewall: Syncthing is in the list of applications)." : "Devices at home find this Synology by local discovery (UDP port 21027) or by tcp://" + (a.lan_ip || "this-address") + ":" + (a.sync_port || 22000) + ". If DSM's firewall is on, allow Syncthing (Control Panel → Security → Firewall).";
    }
  });
  $("pv-save").onclick = function () {
    var m = document.querySelector("input[name=pv-mode]:checked"); if (!m) { P.showErr("Anywhere, or the local network only?"); return; }
    P.act("privacy", { mode: m.value, maxsend: $("pv-send").value || 0, maxrecv: $("pv-recv").value || 0, lanlimit: $("pv-lan").checked ? 1 : 0 }, m.value === "local" ? "Keep Syncthing on your own network? Devices away from home stop syncing until they're back." : null).then(function () { $("pv-save").dataset.touched = ""; });
  };
  $("pv-port-save").onclick = function () { P.act("syncport", { port: $("pv-port").value }, "Move syncing to port " + $("pv-port").value + "? Syncthing restarts; devices that have this Synology's old address written down need the new port.").then(function () { $("pv-port").dataset.touched = ""; }); };
  // Show password: asked for only when the button is pressed, never kept in the page longer than it's shown.
  $("show-pw").onclick = function () {
    P.api("action=showpw").then(function (d) { $("pw-text").textContent = d.password; $("pw-when").textContent = "Made by the package " + P.ago(d.at) + "."; $("pw-box").hidden = false; }).catch(function (e) { P.showErr(e.message); });
  };
  $("pw-copy").onclick = function () { P.copy($("pw-text").textContent, $("pw-copy"), $("pw-text")); };
  $("pw-hide").onclick = function () { $("pw-text").textContent = ""; $("pw-box").hidden = true; };
  P.register("secretNote", function () { return "For Syncthing's web interface, user admin. It's kept for you too: Privacy & network → Show password."; });

  // ---------------------------------------------------------------- Site address: the network
  // The window's refresh puts saved settings back into the Site address fields unless one has been touched;
  // the core watches only its own fields, so Network marks the form as touched too.
  $("set-net").addEventListener("change", function () { $("set-url").dataset.touched = "1"; });
  P.register("site", {
    fill: function (st) { $("set-net").value = A(st).net || "host"; },
    values: function () { return { net: $("set-net").value }; }
  });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    if (!box || !box.nodeType) return;   // the core also calls a tab's render(st, S); the storage part comes through renderStorage
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Syncthing")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    P.kv(tb, "Index (in the config volume)", P.mb(app.index || 0), true);
    (app.folders || []).forEach(function (f) { P.kv(tb, f.label + " — " + f.path, P.bytes(f.bytes) + ", " + num(f.files) + " files", true); });
    box.appendChild(c);
  } });
})(window.Panel);
