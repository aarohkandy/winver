"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");

const DEFAULTS = {
  host: "winver",
  repoUrl: "https://github.com/aarohkandy/winver.git",
  remotePath: "",
  sshOptions: []
};

function readDotEnv(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const lines = fs.readFileSync(filePath, "utf8").split(/\r?\n/);
  const values = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(trimmed);
    if (!match) continue;
    values[match[1]] = match[2].replace(/^["']|["']$/g, "");
  }
  return values;
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) return {};
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function loadConfig(env = process.env) {
  const dotEnv = readDotEnv(path.join(ROOT, ".env"));
  const local = readJson(path.join(ROOT, "winver.local.json"));
  const merged = {
    ...DEFAULTS,
    ...local,
    host: env.WINVER_HOST || dotEnv.WINVER_HOST || local.host || DEFAULTS.host,
    repoUrl: env.WINVER_REPO_URL || dotEnv.WINVER_REPO_URL || local.repoUrl || DEFAULTS.repoUrl,
    remotePath: env.WINVER_REMOTE_PATH || dotEnv.WINVER_REMOTE_PATH || local.remotePath || DEFAULTS.remotePath
  };

  if (!Array.isArray(merged.sshOptions)) merged.sshOptions = [];

  return {
    ...merged,
    root: ROOT,
    macKeyPath: path.join(os.homedir(), ".ssh", "winver_ed25519")
  };
}

function remoteRepoExpression(config) {
  if (config.remotePath && config.remotePath.trim()) {
    return {
      kind: "literal",
      value: config.remotePath.trim(),
      ps: `$RepoPath = ${psQuote(config.remotePath.trim())}`
    };
  }

  return {
    kind: "default",
    value: "%USERPROFILE%\\winver",
    ps: "$RepoPath = Join-Path $env:USERPROFILE 'winver'"
  };
}

function psQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

module.exports = {
  DEFAULTS,
  ROOT,
  loadConfig,
  psQuote,
  remoteRepoExpression
};

