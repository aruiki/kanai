const state = {
  timer: null,
  connected: false,
};

const $ = (id) => document.getElementById(id);

function setText(id, value) {
  const node = $(id);
  if (node) node.textContent = value;
}

function relativeTime(iso) {
  if (!iso) return "heartbeat待命中";
  const delta = Math.max(0, Date.now() - Date.parse(iso));
  if (delta < 5000) return "たった今";
  if (delta < 60000) return `${Math.floor(delta / 1000)}秒前`;
  return `${Math.floor(delta / 60000)}分前`;
}

function setConnection(online, label) {
  state.connected = online;
  const node = $("connection");
  node.className = `connection ${online ? "connection--online" : "connection--error"}`;
  node.textContent = label;
}

function renderCommands(results) {
  const list = $("command-list");
  if (!results?.length) {
    list.innerHTML = '<div class="empty-state">このcycleのコマンド結果はまだありません。</div>';
    return;
  }
  list.replaceChildren(...results.map((result) => {
    const row = document.createElement("div");
    row.className = "command-row";
    row.dataset.state = result.state ?? (result.ok ? "PASS" : "FAIL");
    const marker = document.createElement("span");
    marker.className = "state";
    marker.textContent = row.dataset.state === "PASS" ? "✓" : row.dataset.state === "FAIL" ? "!" : "…";
    const name = document.createElement("span");
    name.textContent = result.id;
    const duration = document.createElement("span");
    duration.className = "duration";
    duration.textContent = result.durationMs == null ? "" : `${result.durationMs}ms`;
    row.append(marker, name, duration);
    return row;
  }));
}

function render(data) {
  const loop = data.loop ?? {};
  const supervisor = data.supervisor ?? {};
  const progress = data.progress ?? {};
  setText("technical-progress", `${progress.technical ?? "--"}%`);
  setText("technical-progress-bar", `${progress.technical ?? 0}%`);
  $("technical-progress-bar").style.width = `${progress.technical ?? 0}%`;
  setText("niche-progress", `${progress.niche ?? "--"}%`);
  setText("public-progress", `${progress.publicBeta ?? "--"}%`);
  setText("cycle-value", loop.cycle == null ? "--" : String(loop.cycle).padStart(2, "0"));
  setText("cycle-time", relativeTime(loop.heartbeatAt));
  setText("loop-status", String(loop.status ?? "UNKNOWN").toUpperCase());
  setText("restart-value", `restart ${supervisor.restarts ?? "--"}`);
  setText("revision-value", data.codeRevision?.short ?? "--");
  setText("revision-time", `最終変更 ${relativeTime(data.codeRevision?.committedAt)}`);
  setText("supervisor-status", String(supervisor.status ?? "UNKNOWN").toUpperCase());
  setText("supervisor-pid", `pid ${supervisor.pid ?? "--"}`);
  setText("last-updated", `最終更新 ${relativeTime(loop.heartbeatAt)}`);
  setText("focus-title", data.focus?.title ?? "Windows x64 TSFを実機でInstallingする");
  setText("focus-copy", data.focus?.copy ?? "Mozc TIPのbuildは完了。次にTSF registrationとNotepadの入力receiptを接続します。");
  setText("blocker-text", data.focus?.blocker ?? "ITfInputProcessorProfiles::Registerが非管理者sessionでEFAILを返す。");
  renderCommands(loop.results);
  const log = data.log?.lines?.slice(-9).join("\n") ?? "logはありません。";
  setText("log-output", log);
}

async function refresh() {
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json());
    setConnection(true, "LIVE");
  } catch (error) {
    setConnection(false, "OFFLINE");
  }
}

function updateClock() {
  const now = new Date();
  setText("clock", now.toLocaleTimeString("ja-JP", { hour12: false }));
}

updateClock();
refresh();
state.timer = setInterval(() => { updateClock(); refresh(); }, 2000);
