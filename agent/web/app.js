// Porthole's web page: the overview and each container's log, from the agent's API.
"use strict";

const LEVELS = ["trace", "debug", "info", "warning", "error", "critical"];
const LEVEL_NAMES = { trace: "Trace", debug: "Debug", info: "Info", warning: "Warning", error: "Error", critical: "Critical" };
const MAX_LINES = 20000;

const state = {
  info: null,
  containers: [],
  problems: { containers: {} },
  load: null,
  page: null,        // null = overview, or a container name
  source: null,      // the open EventSource
  lines: [],
  levels: new Set(LEVELS),
  search: "",
};

const $ = (id) => document.getElementById(id);

/// "· 65 from Docker's restart at 18:27 not counted", when there are any.
function restartNote() {
  const noise = Object.values(state.problems.containers || {}).reduce((sum, p) => sum + (p.around_restart || 0), 0);
  const started = state.problems.dockerd_started;
  if (!noise || !started) return null;
  const at = new Date(started * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return el("span", { class: "muted", title: "When Docker restarts, every container logs its shutdown and startup. Those lines stay in the logs but don't count as problems." },
    `· ${noise} from Docker's restart at ${at} not counted`);
}
const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === "class") node.className = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (value !== undefined && value !== null && value !== false) node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat()) {
    if (child !== null && child !== undefined && child !== false) node.append(child instanceof Node ? child : String(child));
  }
  return node;
};

// --- API -------------------------------------------------------------------

async function api(path, options) {
  const response = await fetch(path, options);
  if (response.status === 401) {
    askForToken();
    throw new Error("token needed");
  }
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}

function askForToken() {
  if (askForToken.asked) return;
  askForToken.asked = true;
  const token = prompt("This Porthole agent needs its token (PORTHOLE_TOKEN).");
  if (token) {
    document.cookie = `porthole_token=${encodeURIComponent(token)}; path=/; max-age=31536000; SameSite=Strict; Secure`;
    location.reload();
  }
}

// --- Formatting ------------------------------------------------------------

const percent = (v) => (v < 10 ? v.toFixed(1) : v.toFixed(0)) + "%";
function bytes(v) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(i >= 3 ? 2 : 0)} ${units[i]}`;
}
function duration(seconds) {
  const d = Math.floor(seconds / 86400), h = Math.floor((seconds % 86400) / 3600), m = Math.floor((seconds % 3600) / 60);
  return d > 0 ? `${d} days ${h} h` : h > 0 ? `${h} h ${m} min` : `${m} min`;
}
function clock(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  const sameDay = date.toDateString() === new Date().toDateString();
  const time = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  return sameDay ? time : `${date.toLocaleDateString([], { month: "2-digit", day: "2-digit" })} ${time}`;
}
function ago(iso) {
  const seconds = (Date.now() - new Date(iso)) / 1000;
  if (seconds < 90) return "just now";
  if (seconds < 5400) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 129600) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86400)} days ago`;
}

function sparkline(values, max) {
  const width = 200, height = 28;
  if (values.length < 2) return el("svg", { viewBox: `0 0 ${width} ${height}`, "aria-hidden": true });
  const top = max || Math.max(...values, 1);
  const points = values.map((v, i) => [(i / (values.length - 1)) * width, height - (v / top) * (height - 2) - 1]);
  const line = points.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join("");
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("preserveAspectRatio", "none");
  svg.setAttribute("aria-hidden", "true");
  svg.innerHTML = `<path class="area" d="${line}L${width},${height}L0,${height}Z"/><path class="line" d="${line}"/>`;
  return svg;
}

// --- Containers ------------------------------------------------------------

function look(container) {
  if (container.health === "unhealthy" || container.state === "restarting") return "warn";
  if (container.state === "running") return "ok";
  const code = /^Exited \((\d+)\)/.exec(container.status);
  return code && code[1] !== "0" && code[1] !== "143" ? "bad" : "off";
}

function needsLook(container) {
  const l = look(container);
  return l === "warn" || l === "bad";
}

function icon(container) {
  return container.icon
    ? el("img", { src: container.icon, alt: "", loading: "lazy", onerror: (e) => e.target.replaceWith(el("span", { class: "glyph" })) })
    : el("span", { class: "glyph" });
}

function renderSidebar() {
  const query = $("filter").value.trim().toLowerCase();
  const shown = state.containers.filter((c) => !query || c.name.toLowerCase().includes(query) || c.image.toLowerCase().includes(query));
  const problemCount = state.containers.filter(needsLook).length
    + Object.values(state.problems.containers).filter((p) => p.errors > 0).length;
  const item = (container) => el("a", {
    class: `item${state.page === container.name ? " selected" : ""}`,
    href: `#/c/${encodeURIComponent(container.name)}`,
  }, icon(container), el("span", { class: "name" }, el("span", {}, container.name), el("span", { class: "muted" }, container.status)),
    el("span", { class: `dot ${look(container)}`, title: container.health || container.state }));
  const running = shown.filter((c) => c.state === "running");
  const stopped = shown.filter((c) => c.state !== "running");
  $("nav").replaceChildren(...[
    el("a", { class: `item${state.page === null ? " selected" : ""}`, href: "#/" },
      el("span", { class: "name" }, el("span", {}, "Overview")),
      problemCount ? el("span", { class: "badge" }, problemCount) : null),
    running.length ? el("div", { class: "section" }, "Running") : null,
    running.map(item),
    stopped.length ? el("div", { class: "section" }, "Stopped") : null,
    stopped.map(item),
  ].flat().filter(Boolean));
}

// --- Overview ----------------------------------------------------------------

function renderOverview() {
  const load = state.load || { cpu: [], memory_used: [], memory_total: 0, load: [], uptime: 0 };
  const running = state.containers.filter((c) => c.state === "running").length;
  const unhealthy = state.containers.filter((c) => c.health === "unhealthy").length;
  const last = (values) => values[values.length - 1];
  const tile = (label, big, ...rest) => el("div", { class: "tile" }, el("span", { class: "label" }, label), el("span", { class: "big" }, big), ...rest);

  const tiles = el("div", { class: "tiles" },
    tile("CPU", load.cpu.length ? percent(last(load.cpu)) : "—", sparkline(load.cpu, 100),
      load.dockerd_busy
        ? el("span", { class: "busy", title: "dockerd has been this busy for 5 minutes. Stuck log readers can do this; restarting Docker clears them." },
          `⚠ Docker at ${Math.round(load.dockerd_busy)}%`)
        : el("span", { class: "muted", title: load.dockerd_cpu?.length ? `Docker itself: ${Math.round(last(load.dockerd_cpu))}% of one core` : "" },
          load.load.length ? `Load ${load.load.map((v) => v.toFixed(2)).join("  ")}` : "")),
    tile("Memory", load.memory_used.length ? bytes(last(load.memory_used)) : "—", sparkline(load.memory_used, load.memory_total),
      el("span", { class: "muted" }, load.memory_total ? `of ${bytes(load.memory_total)}` : "")),
    tile("Containers", `${running} running`,
      el("span", { class: "muted" }, `${state.containers.length - running} stopped${unhealthy ? `, ${unhealthy} unhealthy` : ""}`)),
    tile("Up For", load.uptime ? duration(load.uptime) : "—"),
  );

  const attention = state.containers.filter(needsLook);
  const attentionList = attention.length ? el("div", {},
    el("h2", {}, "Needs a Look"),
    el("div", { class: "list" }, attention.map((c) => el("a", { class: "row", href: `#/c/${encodeURIComponent(c.name)}/problems` },
      icon(c), el("span", { class: "name" }, el("span", {}, c.name), el("span", {}, c.status)))))) : null;

  const problems = Object.entries(state.problems.containers)
    .filter(([, p]) => p.warnings + p.errors > 0)
    .sort(([a, x], [b, y]) => y.errors - x.errors || y.warnings - x.warnings || a.localeCompare(b));
  const byName = Object.fromEntries(state.containers.map((c) => [c.name, c]));
  const scanned = state.problems.scanned ? new Date(state.problems.scanned * 1000) : null;
  const problemList = el("div", {},
    el("h2", {}, "Warnings and Errors, Last 24 Hours",
      el("span", { class: "muted" }, scanned ? `Read ${scanned.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}` : "Reading…"),
      restartNote()),
    el("div", { class: "list" }, problems.length ? problems.map(([name, p]) => el("a", { class: "row", href: `#/c/${encodeURIComponent(name)}/problems` },
      byName[name] ? icon(byName[name]) : el("span", { class: "glyph" }),
      el("span", { class: "name" }, el("span", {}, name),
        el("span", {}, p.latest ? `${p.latest.time ? ago(p.latest.time) + ": " : ""}${p.latest.message}` : "")),
      p.errors ? el("span", { class: "count error" }, `✕ ${p.errors} ${p.errors === 1 ? "error" : "errors"}`) : null,
      p.warnings ? el("span", { class: "count warning" }, `⚠ ${p.warnings} ${p.warnings === 1 ? "warning" : "warnings"}`) : null,
    )) : el("div", { class: "calm" }, scanned ? "No warnings or errors in the last day." : "Reading every container's log…")));

  $("overview").replaceChildren(...[tiles, attentionList, problemList].filter(Boolean));
}

// --- Log -----------------------------------------------------------------------

function openLog(name, problemsOnly) {
  if (state.source) state.source.close();
  state.lines = [];
  state.levels = new Set(problemsOnly ? ["warning", "error", "critical"] : LEVELS);
  $("rows").replaceChildren();
  const since = problemsOnly ? Math.floor(Date.now() / 1000) - 86400 : null;
  const url = `/api/containers/${encodeURIComponent(name)}/logs?` + (since ? `since=${since}` : "tail=1000");
  const source = new EventSource(url);
  state.source = source;
  let pending = [];
  let scheduled = false;
  source.onmessage = (event) => {
    pending.push(JSON.parse(event.data));
    if (!scheduled) {
      scheduled = true;
      // A timer, not requestAnimationFrame: that one stops in a background tab, and lines would pile up.
      setTimeout(() => {
        scheduled = false;
        addLines(pending);
        pending = [];
      }, 50);
    }
  };
  source.onerror = () => {
    if (source.readyState === EventSource.CLOSED) $("title-sub").textContent = "The log stream closed.";
  };
  renderChips();
}

function matches(line) {
  if (!state.levels.has(line.level)) return false;
  if (!state.search) return true;
  return line.message.toLowerCase().includes(state.search) || (line.source || "").toLowerCase().includes(state.search);
}

function lineRow(line) {
  return el("div", { class: `line ${line.level}` },
    el("span", { class: "time", title: line.time || "" }, clock(line.time)),
    el("span", { class: "lvl" }, line.code || LEVEL_NAMES[line.level].toUpperCase()),
    el("span", { class: "src", title: line.source || "" }, line.source || ""),
    el("span", { class: "msg" }, line.message));
}

function addLines(lines) {
  const rows = $("rows");
  const atBottom = rows.scrollHeight - rows.scrollTop - rows.clientHeight < 40;
  state.lines.push(...lines);
  if (state.lines.length > MAX_LINES) {
    state.lines.splice(0, state.lines.length - MAX_LINES);
    renderLines();
  } else {
    const fragment = document.createDocumentFragment();
    for (const line of lines) if (matches(line)) fragment.append(lineRow(line));
    rows.append(fragment);
  }
  renderChips();
  $("log-empty").hidden = rows.childElementCount > 0 || state.lines.length === 0;
  if ($("follow").checked && atBottom) rows.scrollTop = rows.scrollHeight;
}

function renderLines() {
  const rows = $("rows");
  rows.replaceChildren(...state.lines.filter(matches).map(lineRow));
  $("log-empty").hidden = rows.childElementCount > 0 || state.lines.length === 0;
  if ($("follow").checked) rows.scrollTop = rows.scrollHeight;
}

function renderChips() {
  const counts = Object.fromEntries(LEVELS.map((l) => [l, 0]));
  for (const line of state.lines) counts[line.level]++;
  $("chips").replaceChildren(...LEVELS.map((level) => el("button", {
    class: `chip ${level}${state.levels.has(level) ? " on" : ""}`,
    "aria-pressed": state.levels.has(level) ? "true" : "false",
    title: "Click to show or hide. Option-click to show only this level.",
    onclick: (event) => {
      if (event.altKey) state.levels = new Set([level]);
      else if (state.levels.has(level)) state.levels.delete(level);
      else state.levels.add(level);
      renderChips();
      renderLines();
    },
  }, `${LEVEL_NAMES[level]} ${counts[level]}`)));
}

function renderActions(container) {
  const actions = $("actions");
  actions.replaceChildren();
  if (!container) return;
  if (container.web_ui && /^https?:\/\/(?!\[IP\])/.test(container.web_ui)) {
    actions.append(el("a", { class: "button", href: container.web_ui, target: "_blank", rel: "noopener" }, "Web Page"));
  }
  if (!state.info?.actions) return;
  const act = (label, action, confirmText) => el("button", {
    class: "button",
    onclick: async (event) => {
      if (confirmText && !confirm(confirmText)) return;
      event.target.disabled = true;
      try {
        await api(`/api/containers/${encodeURIComponent(container.name)}/${action}`, { method: "POST" });
        await refreshContainers();
      } catch (error) {
        alert(error.message);
      }
      event.target.disabled = false;
    },
  }, label);
  if (container.state === "running") {
    actions.append(act("Restart", "restart"), act("Stop", "stop", `Stop ${container.name}?`));
  } else {
    actions.append(act("Start", "start"));
  }
}

// --- Pages -------------------------------------------------------------------

function route() {
  const match = /^#\/c\/([^/]+)(\/problems)?$/.exec(location.hash);
  const name = match ? decodeURIComponent(match[1]) : null;
  const problemsOnly = !!(match && match[2]);
  $("sidebar").classList.remove("open");
  if (name !== state.page || problemsOnly) {
    state.page = name;
    if (name) openLog(name, problemsOnly);
    else if (state.source) { state.source.close(); state.source = null; }
  }
  render();
}

function render() {
  renderSidebar();
  const container = state.containers.find((c) => c.name === state.page);
  $("overview").hidden = state.page !== null;
  $("log").hidden = state.page === null;
  if (state.page === null) {
    $("title").textContent = "Overview";
    $("title-sub").textContent = state.info ? `Docker ${state.info.docker} · ${state.info.cores} cores` : "";
    renderOverview();
    renderActions(null);
  } else {
    $("title").textContent = state.page;
    $("title-sub").textContent = container ? `${container.image} · ${container.status}` : "";
    renderActions(container);
  }
  document.title = state.page ? `${state.page} – Porthole` : `${state.info?.hostname || "Porthole"} – Porthole`;
}

async function refreshContainers() {
  state.containers = await api("/api/containers");
  render();
}

async function start() {
  $("filter").addEventListener("input", renderSidebar);
  $("search").addEventListener("input", () => { state.search = $("search").value.trim().toLowerCase(); renderLines(); });
  $("menu").addEventListener("click", () => $("sidebar").classList.toggle("open"));
  window.addEventListener("hashchange", route);
  try {
    state.info = await api("/api/info");
    $("hostname").textContent = state.info.hostname || "Porthole";
    $("subtitle").textContent = state.info.actions ? "Start, stop and restart on" : "Read only";
    await refreshContainers();
  } catch (error) {
    $("subtitle").textContent = `Can't reach the agent: ${error.message}`;
    return;
  }
  route();
  const poll = async () => {
    try {
      state.load = await api("/api/host");
      state.problems = await api("/api/problems");
      if (state.page === null) renderOverview();
      renderSidebar();
    } catch { /* shown on the next successful poll */ }
  };
  poll();
  setInterval(poll, 4000);
  setInterval(() => refreshContainers().catch(() => {}), 15000);
}

start();
