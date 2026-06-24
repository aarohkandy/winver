"use strict";

const fs = require("fs");
const http = require("http");
const path = require("path");
const { repoScript, runLocal, sshPowerShell } = require("./remote");

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8"
};

const SNAPSHOT_TIMEOUT_MS = 10000;
const LOG_TIMEOUT_MS = 15000;
const PULL_TIMEOUT_MS = 45000;

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
  const publicDir = path.join(config.root, "dashboard");

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://localhost");
      if (url.pathname === "/api/snapshot") {
        await sendSnapshot(config, res);
        return;
      }
      if (url.pathname === "/api/logs") {
        await sendLogs(config, url.searchParams.get("target") || "latest", res);
        return;
      }
      if (url.pathname === "/api/pull-log") {
        await sendPullLog(config, req, url.searchParams.get("target") || "latest", res);
        return;
      }
      await sendStatic(publicDir, url.pathname === "/" ? "/index.html" : url.pathname, res);
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error.message || String(error) });
    }
  });
}

async function sendSnapshot(config, res) {
  const result = await sshPowerShell(
    config,
    repoScript(config, "windows\\dashboard.ps1", []),
    { capture: true, allowFailure: true, timeoutMs: SNAPSHOT_TIMEOUT_MS }
  );
  if (result.code !== 0) {
    sendJson(res, 502, { ok: false, error: result.stderr || result.stdout || "Could not reach Surface." });
    return;
  }
  try {
    const data = JSON.parse(result.stdout);
    sendJson(res, 200, { ok: true, data });
  } catch (error) {
    sendJson(res, 502, { ok: false, error: "Surface returned unreadable dashboard data.", raw: result.stdout });
  }
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
    sendJson(res, 502, { ok: false, error: result.stderr || result.stdout || "Could not read logs." });
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
    sendJson(res, 502, { ok: false, error: result.stderr || result.stdout || "Could not archive logs." });
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
    sendJson(res, 502, { ok: false, error: copy.stderr || copy.stdout || "Could not pull archive to the Mac." });
    return;
  }

  sendJson(res, 200, { ok: true, path: localPath, name: path.basename(localPath) });
}

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  res.end(body);
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

module.exports = {
  createDashboardServer,
  isLoopbackHost,
  isSafeJobTarget,
  parseDashboardArgs
};
