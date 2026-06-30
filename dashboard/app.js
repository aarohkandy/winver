const state = {
  paused: false,
  selectedJob: null,
  timer: null,
  refreshing: false,
  pendingForceRefresh: false
};

const els = {
  machineName: document.querySelector("#machine-name"),
  connection: document.querySelector("#connection-pill"),
  pause: document.querySelector("#pause-button"),
  refresh: document.querySelector("#refresh-button"),
  cpuLoad: document.querySelector("#cpu-load"),
  cpuBar: document.querySelector("#cpu-bar"),
  memoryLoad: document.querySelector("#memory-load"),
  memoryBar: document.querySelector("#memory-bar"),
  maxTemp: document.querySelector("#max-temp"),
  tempBar: document.querySelector("#temp-bar"),
  battery: document.querySelector("#battery"),
  lastUpdated: document.querySelector("#last-updated"),
  taskSummary: document.querySelector("#task-summary"),
  taskList: document.querySelector("#task-list"),
  controlStatus: document.querySelector("#control-status"),
  services: document.querySelector("#services"),
  thermalSummary: document.querySelector("#thermal-summary"),
  thermals: document.querySelector("#thermal-list"),
  processes: document.querySelector("#processes"),
  selectedJob: document.querySelector("#selected-job"),
  pullStatus: document.querySelector("#pull-status"),
  logOutput: document.querySelector("#log-output")
};

els.pause.addEventListener("click", () => {
  state.paused = !state.paused;
  els.pause.textContent = state.paused ? "Resume" : "Pause";
});

els.refresh.addEventListener("click", () => refresh({ force: true }));
document.querySelectorAll("[data-control='cooling']").forEach((button) => {
  button.addEventListener("click", () => applyCooling(button.dataset.profile));
});

async function refresh(options = {}) {
  if (state.refreshing) {
    if (options.force) state.pendingForceRefresh = true;
    return;
  }
  state.refreshing = true;
  const force = options.force || state.pendingForceRefresh;
  state.pendingForceRefresh = false;
  try {
    const suffix = force ? "?force=1" : "";
    const response = await fetch(`/api/snapshot${suffix}`, { cache: "no-store" });
    const payload = await response.json();
    if (!payload.ok) throw new Error(payload.error || "Surface unavailable");
    render(payload.data);
    setConnection("online", false);
  } catch (error) {
    setConnection("offline", true);
    els.lastUpdated.textContent = error.message;
  } finally {
    state.refreshing = false;
    if (state.pendingForceRefresh) {
      refresh({ force: true });
    }
  }
}

function render(data) {
  const computer = data.computer || {};
  const cpu = data.cpu || {};
  const memory = data.memory || {};
  const thermal = data.thermal || {};

  els.machineName.textContent = computer.name || "winver";
  setPercent(els.cpuLoad, els.cpuBar, cpu.loadPercent);
  setPercent(els.memoryLoad, els.memoryBar, memory.usedPercent);
  setTemperature(thermal.maxCelsius);
  els.battery.textContent = data.battery ? `${data.battery.percent}%` : "AC";
  els.lastUpdated.textContent = formatFreshness(data);

  renderTasks(data.jobs || []);
  renderServices(data.services || []);
  renderThermals((thermal.zones || []).filter((zone) => zone.valid), thermal.maxCelsius);
  renderProcesses(data.processes || []);
}

function setConnection(text, bad) {
  els.connection.textContent = text;
  els.connection.classList.toggle("bad", bad);
}

function setPercent(label, bar, value) {
  const number = clamp(Number(value || 0), 0, 100);
  label.textContent = `${Math.round(number)}%`;
  bar.style.width = `${number}%`;
}

function setTemperature(value) {
  if (value === null || value === undefined) {
    els.maxTemp.textContent = "-- C";
    els.tempBar.style.width = "0%";
    return;
  }
  const number = Number(value);
  els.maxTemp.textContent = `${number.toFixed(1)} C`;
  els.tempBar.style.width = `${clamp((number / 100) * 100, 0, 100)}%`;
}

function renderTasks(jobs) {
  const running = jobs.filter((job) => job.running);
  const failed = jobs.filter((job) => !job.running && job.exit !== "pending" && job.exit !== "0");
  const ordered = [...jobs].sort(compareJobs);
  els.taskSummary.textContent = `${running.length} running, ${failed.length} failed`;
  els.taskList.innerHTML = "";

  if (!jobs.length) {
    els.taskList.append(empty("No jobs yet."));
    return;
  }

  for (const job of ordered) {
    const status = getJobStatus(job);
    const item = document.createElement("article");
    item.className = `task ${status.className}`;
    item.innerHTML = `
      <div class="task-top">
        <span class="task-id">${escapeHtml(job.id)}</span>
        <span class="status ${status.className}">${status.label}</span>
      </div>
      <div class="task-command">${escapeHtml(job.commandPreview || "no command")}</div>
      <div class="task-meta">
        <span>${escapeHtml(formatTime(job.startedAt))}</span>
        <span>${formatBytes(job.stdoutBytes)} out / ${formatBytes(job.stderrBytes)} err</span>
      </div>
      <div class="task-actions">
        <button class="task-open" data-action="logs" data-job-id="${escapeHtml(job.id)}" type="button">Logs</button>
        <button class="task-pull" data-action="pull-log" data-job-id="${escapeHtml(job.id)}" type="button">Pull</button>
        ${job.running ? `<button class="task-stop danger" data-action="stop-job" data-job-id="${escapeHtml(job.id)}" type="button">Stop</button>` : ''}
      </div>
    `;
    item.querySelector(".task-open").addEventListener("click", () => loadLogs(job.id));
    item.querySelector(".task-pull").addEventListener("click", () => pullLogs(job.id));
    const stopButton = item.querySelector(".task-stop");
    if (stopButton) stopButton.addEventListener("click", () => stopJob(job.id));
    els.taskList.append(item);
  }
}

function compareJobs(a, b) {
  const rank = (job) => {
    if (job.running) return 0;
    if (!job.running && job.exit !== "pending" && job.exit !== "0") return 1;
    if (job.exit === "pending") return 2;
    return 3;
  };
  const diff = rank(a) - rank(b);
  if (diff !== 0) return diff;
  return new Date(b.startedAt || 0).getTime() - new Date(a.startedAt || 0).getTime();
}

function getJobStatus(job) {
  if (job.running) return { label: "running", className: "running" };
  if (job.exit === "pending") return { label: "pending", className: "" };
  if (job.exit === "0") return { label: "done", className: "done" };
  return { label: `exit ${job.exit}`, className: "failed" };
}

async function loadLogs(jobId) {
  state.selectedJob = jobId;
  els.selectedJob.textContent = jobId;
  els.logOutput.textContent = "Loading...";
  try {
    const response = await fetch(`/api/logs?target=${encodeURIComponent(jobId)}`, { cache: "no-store" });
    const payload = await response.json();
    if (!payload.ok) throw new Error(payload.error || "Could not read logs");
    els.logOutput.textContent = payload.text || "(empty)";
  } catch (error) {
    els.logOutput.textContent = error.message;
  }
}

async function pullLogs(jobId) {
  els.pullStatus.textContent = "pulling";
  els.pullStatus.classList.remove("bad");
  try {
    const response = await fetch(`/api/pull-log?target=${encodeURIComponent(jobId)}`, {
      method: "POST",
      headers: { "X-Winver-Dashboard": "1" },
      cache: "no-store"
    });
    const payload = await response.json();
    if (!payload.ok) throw new Error(payload.error || "Could not pull logs");
    els.pullStatus.textContent = payload.name || "pulled";
    els.selectedJob.textContent = jobId;
    els.logOutput.textContent = `Pulled to ${payload.path}`;
  } catch (error) {
    els.pullStatus.textContent = "pull failed";
    els.pullStatus.classList.add("bad");
    els.logOutput.textContent = error.message;
  }
}

async function applyCooling(profile) {
  await sendControl({ type: "cooling", profile }, `cooling: ${profile}`);
}

async function stopJob(jobId) {
  await sendControl({ type: "stop-job", target: jobId }, `stopped job ${jobId}`);
  await refresh({ force: true });
}

async function stopProcess(pid) {
  await sendControl({ type: "stop-process", pid }, `stopped process ${pid}`);
  await refresh({ force: true });
}

async function sendControl(body, successText) {
  els.controlStatus.textContent = "working";
  els.controlStatus.classList.remove("bad");
  try {
    const response = await fetch("/api/control", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Winver-Dashboard": "1"
      },
      body: JSON.stringify(body),
      cache: "no-store"
    });
    const payload = await response.json();
    if (!payload.ok) throw new Error(payload.error || "Control failed");
    els.controlStatus.textContent = successText;
  } catch (error) {
    els.controlStatus.textContent = error.message;
    els.controlStatus.classList.add("bad");
  }
}

function renderServices(services) {
  els.services.innerHTML = "";
  if (!services.length) {
    els.services.append(empty("No service data."));
    return;
  }
  for (const service of services) {
    els.services.append(row(service.name, `${service.status} / ${service.startType}`));
  }
}

function renderThermals(zones, maxCelsius) {
  els.thermals.innerHTML = "";
  const maxText = maxCelsius === null || maxCelsius === undefined ? "-- C" : `${Number(maxCelsius).toFixed(1)} C`;
  els.thermalSummary.textContent = zones.length
    ? `${zones.length} sensors · max ${maxText}`
    : "no valid sensors";
  if (!zones.length) {
    els.thermals.append(empty("No thermal sensors."));
    return;
  }
  for (const zone of zones) {
    els.thermals.append(row(shortZone(zone.zone), `${Number(zone.celsius).toFixed(1)} C`));
  }
}

function renderProcesses(processes) {
  els.processes.innerHTML = "";
  if (!processes.length) {
    els.processes.append(empty("No worker processes."));
    return;
  }
  for (const process of processes) {
    els.processes.append(processRow(process));
  }
}

function processRow(process) {
  const el = row(`${process.name} #${process.id}`, `${process.cpuSeconds}s CPU / ${process.memoryMB} MB`);
  el.classList.add("action-row");
  const stop = document.createElement("button");
  stop.type = "button";
  stop.className = "row-action danger";
  stop.textContent = "Stop";
  stop.dataset.action = "stop-process";
  stop.dataset.pid = String(process.id);
  stop.addEventListener("click", () => stopProcess(process.id));
  el.append(stop);
  return el;
}

function row(label, value) {
  const el = document.createElement("div");
  el.className = "row";
  el.innerHTML = `<strong>${escapeHtml(label)}</strong><span class="value">${escapeHtml(value)}</span>`;
  return el;
}

function formatFreshness(data) {
  const pieces = [`Updated ${formatTime(data.collectedAt)}`];
  const cache = data.dashboard && data.dashboard.cache;
  if (cache && cache.state) {
    const age = Math.round(Number(cache.ageMs || 0) / 1000);
    pieces.push(cache.state === "fresh" ? "fresh" : `${cache.state} ${age}s`);
  }
  if (data.dashboard && data.dashboard.slowCollectedAt) {
    pieces.push(`deep ${formatTime(data.dashboard.slowCollectedAt)}`);
  }
  return pieces.join(" · ");
}

function empty(text) {
  const el = document.createElement("div");
  el.className = "subtle";
  el.textContent = text;
  return el;
}

function formatTime(value) {
  if (!value) return "unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" });
}

function formatBytes(value) {
  const number = Number(value || 0);
  if (number < 1024) return `${number} B`;
  if (number < 1024 * 1024) return `${(number / 1024).toFixed(1)} KB`;
  return `${(number / (1024 * 1024)).toFixed(1)} MB`;
}

function shortZone(value) {
  const text = String(value || "");
  const match = text.match(/MSHW[0-9A-F]+\\(.+)$/i);
  return match ? match[1] : text;
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[char]);
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

refresh();
state.timer = setInterval(() => {
  if (!state.paused) refresh();
}, 1000);
