"use strict";
const $ = (id) => document.getElementById(id);
let intervals = [];
let connections = [];
const testResults = {};
let clusters = [], csList = [], tab = "pick", discLoaded = false;

async function api(method, url, body) {
  const opt = { method, headers: { "X-Requested-With": "docdb-ui" } };
  if (body !== undefined) { opt.headers["Content-Type"] = "application/json"; opt.body = JSON.stringify(body); }
  const r = await fetch(url, opt);
  if (!r.ok) {
    let d = r.statusText;
    try { d = (await r.json()).detail || d; } catch (e) { /* ignore */ }
    throw new Error(typeof d === "string" ? d : JSON.stringify(d));
  }
  return r.status === 204 ? null : r.json();
}
function el(tag, text, attrs) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  Object.assign(e, attrs || {});
  return e;
}
let toastTimer;
function say(t, bad) {
  const m = $("toast");
  m.textContent = t;
  m.className = "toast " + (bad ? "bad" : "ok");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => m.classList.add("hidden"), bad ? 8000 : 3500);
}
function fillIntervals(sel, cur) {
  sel.replaceChildren();
  intervals.forEach((i) => sel.append(el("option", i, { value: i, selected: i === cur })));
}
async function update(name, patch) {
  try { await api("PUT", "/api/connections/" + encodeURIComponent(name), patch); say("저장됨: " + name); }
  catch (e) { say(e.message, true); }
  load();
}
function toggle(label, checked, onchange) {
  const l = el("label");
  const i = el("input", undefined, { type: "checkbox", checked });
  i.onchange = () => onchange(i.checked);
  l.append(i, document.createTextNode(label));
  return l;
}
function card(c) {
  const st = c.status;
  const state = !c.enabled ? "off" : st ? (st.up ? "up" : "down") : "";
  const div = el("div", undefined, { className: "card " + state });

  const head = el("div", undefined, { className: "card-head" });
  head.append(el("span", c.name, { className: "card-name" }),
    el("span", !c.enabled ? "비활성" : st ? (st.up ? "UP" : "DOWN") : "대기", { className: "pill " + (c.enabled ? state : "") }));
  div.append(head, el("div", c.host, { className: "host" }));
  if (c.note) div.append(el("div", c.note, { className: "note" }));
  if (c.enabled && st && !st.up && st.error) div.append(el("div", st.error, { className: "err" }));

  const meta = el("div", undefined, { className: "meta" });
  const sel = el("select"); fillIntervals(sel, c.interval);
  sel.onchange = () => update(c.name, { interval: sel.value });
  const lbl = el("label", "주기 "); lbl.append(sel);
  meta.append(lbl,
    toggle("사용", c.enabled, (v) => update(c.name, { enabled: v })),
    toggle("CollStats", c.collstats, (v) => update(c.name, { collstats: v })));
  div.append(meta);

  const foot = el("div", undefined, { className: "card-foot" });
  const bt = el("button", "연결 테스트", { className: "btn" });
  bt.onclick = async () => {
    bt.disabled = true; testResults[c.name] = { text: "테스트 중...", cls: "" }; load();
    try {
      const r = await api("POST", "/api/test", { name: c.name });
      testResults[c.name] = r.up ? { text: `OK (${r.duration}s)`, cls: "ok" } : { text: "실패: " + r.error, cls: "bad" };
    } catch (e) { testResults[c.name] = { text: e.message, cls: "bad" }; }
    load();
  };
  const bu = el("button", "문자열 변경", { className: "btn" });
  bu.onclick = () => { $("dlgName").textContent = c.name; $("dlgUri").value = ""; $("dlg").showModal(); };
  const bd = el("button", "삭제", { className: "btn danger" });
  bd.onclick = async () => {
    if (!confirm(c.name + " 연결을 삭제할까요?")) return;
    try { await api("DELETE", "/api/connections/" + encodeURIComponent(c.name)); say("삭제됨: " + c.name); }
    catch (e) { say(e.message, true); }
    load();
  };
  foot.append(bt, bu, bd);
  div.append(foot);
  const tr = testResults[c.name];
  if (tr) div.append(el("div", tr.text, { className: "tres " + tr.cls }));
  return div;
}
function render() {
  const on = connections.filter((c) => c.enabled);
  $("stTotal").textContent = connections.length;
  $("stUp").textContent = on.filter((c) => c.status && c.status.up).length;
  $("stDown").textContent = on.filter((c) => c.status && !c.status.up).length;
  $("stOff").textContent = connections.length - on.length;
  $("empty").classList.toggle("hidden", connections.length > 0);
  $("cards").replaceChildren(...connections.map(card));
}
async function load() {
  try {
    connections = await api("GET", "/api/connections");
    const a = document.activeElement;
    if (!(a && a.tagName === "SELECT" && $("cards").contains(a))) render();
  } catch (e) { say(e.message, true); }
}

// ---- add dialog ---------------------------------------------------------------------------------------------
function setResult(text, cls) {
  const r = $("addResult");
  r.textContent = text || "";
  r.className = "result " + (cls || "") + (text ? "" : " hidden");
}
function setTab(t) {
  tab = t;
  document.querySelectorAll(".tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === t));
  $("pane-pick").classList.toggle("hidden", t !== "pick");
  $("pane-manual").classList.toggle("hidden", t !== "manual");
  if (t === "pick") discover();
}
async function discover() {
  if (discLoaded) return;
  $("discHint").textContent = "클러스터 목록을 불러오는 중...";
  try {
    clusters = await api("GET", "/api/discovery/clusters");
    discLoaded = true;
    $("discCluster").replaceChildren(...clusters.map((c, i) => el("option",
      `${c.name}  (${c.resourceGroup}, ${c.location}${c.privateEndpoint ? ", Private Endpoint" : ""})`, { value: i })));
    $("discCluster").disabled = !clusters.length;
    $("discHint").textContent = clusters.length ? clusters.length + "개 클러스터. 사용자/비밀번호는 직접 입력합니다." : "조회된 클러스터가 없습니다. '직접 입력'을 사용하세요.";
    loadCs();
  } catch (e) { $("discHint").textContent = "조회 실패: " + e.message; }
}
async function loadCs() {
  const c = clusters[$("discCluster").selectedIndex];
  $("discCs").replaceChildren(); $("discCs").disabled = true;
  if (!c) return;
  try {
    csList = await api("GET", `/api/discovery/clusters/${encodeURIComponent(c.resourceGroup)}/${encodeURIComponent(c.name)}/connection-strings`);
    csList.forEach((s, i) => $("discCs").append(el("option", s.description || s.name || "connection string", { value: i })));
    $("discCs").disabled = !csList.length;
    const f = $("add");
    if (!f.name.value || f.name.dataset.auto === "1") { f.name.value = c.name.toLowerCase().slice(0, 40); f.name.dataset.auto = "1"; }
  } catch (e) { $("discHint").textContent = e.message; }
}
function currentUri() {
  const f = $("add");
  if (tab === "manual") return f.uri.value;
  const s = csList[$("discCs").value];
  if (!s) throw new Error("클러스터/연결 문자열을 선택하세요");
  const user = $("discUser").value, pw = $("discPw").value;
  if (!user || !pw) throw new Error("사용자/비밀번호를 입력하세요");
  return s.uri.replace("<user>", () => encodeURIComponent(user)).replace("<password>", () => encodeURIComponent(pw));
}
function openAdd() {
  const f = $("add");
  f.reset(); f.name.dataset.auto = "1"; setResult("");
  fillIntervals($("addInterval"), "1m");
  $("addDlg").showModal();
  setTab("pick");
  if (discLoaded) loadCs();
}
function closeAdd() { $("discPw").value = ""; $("add").uri.value = ""; $("addDlg").close(); }

$("btnNew").onclick = openAdd;
$("btnNew2").onclick = openAdd;
$("addClose").onclick = closeAdd;
$("addCancel").onclick = closeAdd;
document.querySelectorAll(".tab").forEach((b) => { b.onclick = () => setTab(b.dataset.tab); });
$("discCluster").onchange = () => { $("add").name.dataset.auto = "1"; $("add").name.value = ""; loadCs(); };
$("add").name.oninput = (e) => { e.target.dataset.auto = "0"; };

$("btnTest").onclick = async () => {
  const btn = $("btnTest");
  try {
    const uri = currentUri();
    btn.disabled = true; setResult("테스트 중...", "");
    const r = await api("POST", "/api/test", { uri });
    setResult(r.up ? `연결 OK (${r.duration}s)` : "실패: " + r.error, r.up ? "ok" : "bad");
  } catch (e) { setResult(e.message, "bad"); }
  btn.disabled = false;
};
$("add").onsubmit = async (ev) => {
  ev.preventDefault();
  const f = ev.target;
  try {
    await api("POST", "/api/connections", { name: f.name.value, uri: currentUri(), interval: f.interval.value,
      enabled: f.enabled.checked, collstats: f.collstats.checked, note: f.note.value });
    closeAdd(); say("추가됨: " + f.name.value); load();
  } catch (e) { setResult(e.message, "bad"); }
};

// ---- change connection string dialog --------------------------------------------------------------------
$("dlgCancel").onclick = () => $("dlg").close();
$("uriForm").onsubmit = (ev) => {
  if (ev.submitter && ev.submitter.value === "ok") update($("dlgName").textContent, { uri: $("dlgUri").value });
  $("dlgUri").value = "";
};

(async () => {
  const m = await api("GET", "/api/meta");
  intervals = m.intervals; $("who").textContent = m.user;
  load(); setInterval(load, 15000);
})().catch((e) => say(e.message, true));
