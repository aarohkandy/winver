"use strict";

const fs = require("fs");
const http = require("http");
const path = require("path");
const { loadAdminKey, makeRequestId, signAdminRequest } = require("./admin");
const { repoScript, runLocal, sshPowerShell } = require("./remote");

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8"
};

const SNAPSHOT_TIMEOUT_MS = 10000;
const SNAPSHOT_REMOTE_MIN_MS = 2500;
const SNAPSHOT_MAX_STALE_MS = 20000;
const LOG_TIMEOUT_MS = 15000;
const CONTROL_TIMEOUT_MS = 20000;
const PULL_TIMEOUT_MS = 45000;
const COOLING_PROFILES = new Set(["max", "cool", "balanced", "quiet"]);

function parseDashboardArgs(args) {
  const options = { host: "127.0.0.1", port: 8787, open: false };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--host") {
      options.host = args[++i] || options.host;
      if (!isLoopbackHost(options.host)) {
        throw new Error("--host must stay local-only. Use 127.0.0.1, localhost, or ::1.");
      }
    } else if (arg === "--port") {
      const value = Number(args[++i]);
      if (!Number.isInteger(value) || value <= 0) throw new Error("--port needs a positive number.");
      options.port = value;
    } else if (arg === "--open") {
      options.open = true;
    } else {
      throw new Error("Usage: winver dashboard [--host 127.0.0.1] [--port 8787] [--open]");
    }
  }
  return options;
}

function createDashboardServer(config) {
  const dashboardConfig = withDashboardSshReuse(config);
  const publicDir = path.join(config.root, "dashboard");
  const snapshotCache = createSnapshotCache((options) => collectSnapshot(dashboardConfig, options), {
    minRefreshMs: readPositiveInteger(process.env.WINVER_DASHBOARD_REMOTE_MS, SNAPSHOT_REMOTE_MIN_MS),
    maxStaleMs: readPositiveInteger(process.env.WINVER_DASHBOARD_MAX_STALE_MS, SNAPSHOT_MAX_STALE_MS)
  });

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://localhost");
      if (url.pathname === "/api/snapshot") {
        await sendSnapshot(snapshotCache, res, url.searchParams.get("force") === "1");
        return;
      }
      if (url.pathname === "/api/logs") {
        await sendLogs(dashboardConfig, url.searchParams.get("target") || "latest", res);
        return;
      }
      if (url.pathname === "/api/pull-log") {
        await sendPullLog(dashboardConfig, req, url.searchParams.get("target") || "latest", res);
        return;
      }
      if (url.pathname === "/api/control") {
        await sendControl(dashboardConfig, req, res, snapshotCache);
        return;
      }
      await sendStatic(publicDir, url.pathname === "/" ? "/index.html" : url.pathname, res);
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error.message || String(error) });
    }
  });
}

function withDashboardSshReuse(config) {
  const sshOptions = Array.isArray(config.sshOptions) ? config.sshOptions : [];
  const alreadyConfigured = sshOptions.some((option) => String(option).includes("ControlMaster") || String(option).includes("ControlPath"));
  if (alreadyConfigured) return config;

  const uid = typeof process.getuid === "function" ? process.getuid() : "user";
  const controlPath = `/tmp/wv-dashboard-${uid}-%C`;
  return {
    ...config,
    sshOptions: [
      ...sshOptions,
      "-o", "ControlMaster=auto",
      "-o", "ControlPersist=60s",
      "-o", `ControlPath=${controlPath}`
    ]
  };
}

function createSnapshotCache(collector, options = {}) {
  const minRefreshMs = Number.isInteger(options.minRefreshMs) ? options.minRefreshMs : SNAPSHOT_REMOTE_MIN_MS;
  const maxStaleMs = Number.isInteger(options.maxStaleMs) ? options.maxStaleMs : SNAPSHOT_MAX_STALE_MS;
  const now = options.now || (() => Date.now());
  let cached = null;
  let cachedAt = 0;
  let inFlight = null;
  let lastError = "";
  let forceNextRefresh = false;

  async function refresh(forceRefresh) {
    try {
      const data = await collector({ forceRefresh });
      cached = data;
      cachedAt = now();
      lastError = "";
      return data;
    } catch (error) {
      lastError = error.message || String(error);
      throw error;
    }
  }

  async function startRefresh(forceRefresh) {
    if (!inFlight) {
      inFlight = refresh(forceRefresh).finally(() => {
        inFlight = null;
      });
    }
    return inFlight;
  }

  async function get(getOptions = {}) {
    if (getOptions.forceRefresh) forceNextRefresh = true;
    const ageMs = cached ? now() - cachedAt : Number.POSITIVE_INFINITY;
    const needsRefresh = forceNextRefresh || !cached || ageMs >= minRefreshMs;
    const shouldWait = forceNextRefresh || !cached || ageMs >= maxStaleMs;

    if (needsRefresh) {
      const forceRefresh = forceNextRefresh;
      forceNextRefresh = false;
      const pending = startRefresh(forceRefresh);
      if (shouldWait) {
        try {
          const data = await pending;
          return okSnapshot(data, "fresh", 0);
        } catch (error) {
          if (!cached) return { ok: false, error: error.message || String(error) };
        }
      }
    }

    if (!cached) return { ok: false, error: lastError || "No dashboard snapshot yet." };
    return okSnapshot(cached, inFlight ? "refreshing" : "cached", Math.max(0, now() - cachedAt));
  }

  function okSnapshot(data, state, ageMs) {
    return {
      ok: true,
      data: {
        ...data,
        dashboard: {
          ...(data.dashboard || {}),
          cache: {
            state,
            ageMs,
            minRefreshMs,
            maxStaleMs,
            lastError
          }
        }
      }
    };
  }

  function invalidate() {
    forceNextRefresh = true;
    cachedAt = 0;
  }

  return { get, invalidate };
}

async function collectSnapshot(config, options = {}) {
  const psArgs = options.forceRefresh ? ["-ForceRefresh"] : [];
  const result = await sshPowerShell(
    config,
    repoScript(config, "windows\\dashboard.ps1", psArgs),
    { capture: true, allowFailure: true, timeoutMs: SNAPSHOT_TIMEOUT_MS }
  );
  if (result.code !== 0) {
    throw new Error(cleanPowerShellError(result.stderr || result.stdout || "Could not reach Surface."));
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error("Surface returned unreadable dashboard data.");
  }
}

async function sendSnapshot(snapshotCache, res, forceRefresh = false) {
  const snapshot = await snapshotCache.get({ forceRefresh });
  if (!snapshot.ok) {
    sendJson(res, 502, { ok: false, error: snapshot.error || "Could not reach Surface." });
    return;
  }
  sendJson(res, 200, { ok: true, data: snapshot.data });
}

async function sendLogs(config, target, res) {
  if (!isSafeJobTarget(target)) {
    sendJson(res, 400, { ok: false, error: "Unsafe job target." });
    return;
  }
  const result = await sshPowerShell(
    config,
    repoScript(config, "windows\\job.ps1", ["-Action", "logs", "-Target", target, "-Tail", "220"]),
    { capture: true, allowFailure: true, timeoutMs: LOG_TIMEOUT_MS }
  );
  if (result.code !== 0) {
    sendJson(res, 502, { ok: false, error: cleanPowerShellError(result.stderr || result.stdout || "Could not read logs.") });
    return;
  }
  sendJson(res, 200, { ok: true, text: result.stdout });
}

async function sendPullLog(config, req, target, res) {
  if (req.method !== "POST" || req.headers["x-winver-dashboard"] !== "1") {
    sendJson(res, 405, { ok: false, error: "Pull requests must come from the local dashboard." });
    return;
  }
  if (!isSafeJobTarget(target)) {
    sendJson(res, 400, { ok: false, error: "Unsafe job target." });
    return;
  }

  const result = await sshPowerShell(
    config,
    repoScript(config, "windows\\job.ps1", ["-Action", "archive", "-Kind", "logs", "-Target", target]),
    { capture: true, allowFailure: true, timeoutMs: LOG_TIMEOUT_MS }
  );
  if (result.code !== 0) {
    sendJson(res, 502, { ok: false, error: cleanPowerShellError(result.stderr || result.stdout || "Could not archive logs.") });
    return;
  }

  const fields = parseKeyValueLines(result.stdout);
  if (!fields.archive || !fields.name) {
    sendJson(res, 502, { ok: false, error: "Surface did not report a log archive path." });
    return;
  }

  const localDir = path.join(config.root, "winver-pulls");
  const localPath = path.join(localDir, path.basename(fields.name));
  fs.mkdirSync(localDir, { recursive: true });

  const remoteArchive = `${config.host}:${windowsPathForScp(fields.archive)}`;
  const copy = await runLocal("scp", ["-O", ...config.sshOptions, remoteArchive, localPath], {
    capture: true,
    allowFailure: true,
    timeoutMs: PULL_TIMEOUT_MS
  });
  if (copy.code !== 0) {
    sendJson(res, 502, { ok: false, error: cleanPowerShellError(copy.stderr || copy.stdout || "Could not pull archive to the Mac.") });
    return;
  }

  sendJson(res, 200, { ok: true, path: localPath, name: path.basename(localPath) });
}

async function sendControl(config, req, res, snapshotCache) {
  if (req.method !== "POST" || req.headers["x-winver-dashboard"] !== "1") {
    sendJson(res, 405, { ok: false, error: "Control requests must come from the local dashboard." });
    return;
  }

  let body;
  try {
    body = JSON.parse(await readRequestBody(req, 2048));
  } catch (error) {
    sendJson(res, 400, { ok: false, error: "Control request must be small JSON." });
    return;
  }

  if (body.type === "cooling") {
    await sendCoolingControl(config, body.profile, res, snapshotCache);
    return;
  }
  if (body.type === "stop-process") {
    await sendStopProcess(config, body.pid, res, snapshotCache);
    return;
  }
  if (body.type === "stop-job") {
    await sendStopJob(config, body.target, res, snapshotCache);
    return;
  }

  sendJson(res, 400, { ok: false, error: "Unknown control action." });
}

async function sendCoolingControl(config, profile, res, snapshotCache) {
  const value = String(profile || "").toLowerCase();
  if (!COOLING_PROFILES.has(value)) {
    sendJson(res, 400, { ok: false, error: "Cooling profile must be max, cool, balanced, or quiet." });
    return;
  }

  const key = loadAdminKey();
  if (!key) {
    sendJson(res, 400, { ok: false, error: "Missing admin signing key. Run ./mac/setup-admin-key.sh first." });
    return;
  }

  const requestId = makeRequestId();
  const request = { action: "cooling", mode: "Apply", requestId, command: "", profile: value };
  const signature = signAdminRequest(key, request);
  const result = await sshPowerShell(
    config,
    repoScript(config, "windows\\admin\\broker.ps1", [
      "-Action", "cooling",
      "-Mode", "Apply",
      "-RequestId", requestId,
      "-CoolingProfile", value,
      "-Signature", signature
    ]),
    { capture: true, allowFailure: true, timeoutMs: CONTROL_TIMEOUT_MS }
  );
  if (result.code !== 0) {
    sendJson(res, 502, { ok: false, error: friendlyControlError(result.stderr || result.stdout, "Could not apply cooling profile.") });
    return;
  }
  if (snapshotCache) snapshotCache.invalidate();
  sendJson(res, 200, { ok: true, text: result.stdout, profile: value });
}

async function sendStopProcess(config, pid, res, snapshotCache) {
  const value = Number(pid);
  if (!Number.isInteger(value) || value <= 0) {
    sendJson(res, 400, { ok: false, error: "A positive process id is required." });
    return;
  }
  const result = await sshPowerShell(
    config,
    repoScript(config, "windows\\dashboard-action.ps1", ["-Action", "stop-process", "-ProcessId", String(value)]),
    { capture: true, allowFailure: true, timeoutMs: CONTROL_TIMEOUT_MS }
  );
  sendControlResult(result, res, "Could not stop process.", snapshotCache);
}

async function sendStopJob(config, target, res, snapshotCache) {
  if (!isSafeJobTarget(target)) {
    sendJson(res, 400, { ok: false, error: "Unsafe job target." });
    return;
  }
  const result = await sshPowerShell(
    config,
    repoScript(config, "windows\\dashboard-action.ps1", ["-Action", "stop-job", "-Target", target]),
    { capture: true, allowFailure: true, timeoutMs: CONTROL_TIMEOUT_MS }
  );
  sendControlResult(result, res, "Could not stop job.", snapshotCache);
}

function sendControlResult(result, res, fallback, snapshotCache) {
  if (result.code !== 0) {
    sendJson(res, 502, { ok: false, error: friendlyControlError(result.stderr || result.stdout, fallback) });
    return;
  }
  if (snapshotCache) snapshotCache.invalidate();
  try {
    sendJson(res, 200, { ok: true, data: JSON.parse(result.stdout) });
  } catch {
    sendJson(res, 200, { ok: true, text: result.stdout });
  }
}

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  res.end(body);
}

function readRequestBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body, "utf8") > maxBytes) {
        reject(new Error("Request body too large."));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

async function sendStatic(publicDir, requestPath, res) {
  const root = path.resolve(publicDir);
  const relativePath = path.normalize(requestPath).replace(/^[/\\]+/, "").replace(/^(\.\.[/\\])+/, "");
  const filePath = path.resolve(root, relativePath);
  if (filePath !== root && !filePath.startsWith(`${root}${path.sep}`)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    res.writeHead(404);
    res.end("Not found");
    return;
  }
  const ext = path.extname(filePath);
  res.writeHead(200, {
    "Content-Type": MIME_TYPES[ext] || "application/octet-stream",
    "Cache-Control": "no-store"
  });
  fs.createReadStream(filePath).pipe(res);
}

function isLoopbackHost(host) {
  return new Set(["127.0.0.1", "localhost", "::1", "[::1]"]).has(String(host || "").toLowerCase());
}

function isSafeJobTarget(target) {
  const value = String(target || "");
  return value === "latest" || /^[0-9]{8}-[0-9]{6}-[A-Za-z0-9_.-]{1,80}$/.test(value);
}

function parseKeyValueLines(text) {
  const fields = {};
  for (const line of String(text || "").split(/\r?\n/)) {
    const match = /^([A-Za-z][A-Za-z0-9_-]*)=(.*)$/.exec(line.trim());
    if (match) fields[match[1]] = match[2];
  }
  return fields;
}

function windowsPathForScp(value) {
  return String(value).replace(/\\/g, "/");
}

function friendlyControlError(text, fallback) {
  const clean = cleanPowerShellError(text || fallback);
  if (/Missing Windows admin signing key/i.test(clean)) {
    return "Cooling controls need one Windows setup step first: run the elevated init-admin command on the Surface. Logs, Pull, Refresh, and Stop still work.";
  }
  if (/Missing admin request signature|Missing admin signing key/i.test(clean)) {
    return "Cooling controls need the Mac admin signing key first. Run ./mac/setup-admin-key.sh on the Mac, then initialize it once on the Surface.";
  }
  return clean || fallback;
}

function cleanPowerShellError(text) {
  let value = String(text || "");
  if (value.includes("#< CLIXML") || /<Objs\b/.test(value)) {
    value = value
      .replace(/^#< CLIXML\s*/i, "")
      .replace(/_x000D__x000A_/g, "\n")
      .replace(/<S\b[^>]*>/g, " ")
      .replace(/<\/S>/g, " ")
      .replace(/<[^>]+>/g, " ");
  }
  return decodeXmlEntities(value)
    .replace(/\r/g, "\n")
    .split(/\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

function decodeXmlEntities(text) {
  return String(text)
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function readPositiveInteger(value, fallback) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) return fallback;
  return parsed;
}

module.exports = {
  cleanPowerShellError,
  createSnapshotCache,
  createDashboardServer,
  isLoopbackHost,
  isSafeJobTarget,
  parseDashboardArgs
};
