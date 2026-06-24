"use strict";

const { spawn } = require("child_process");
const { psQuote, remoteRepoExpression } = require("./config");

function sshArgs(config, extra = []) {
  return [
    ...config.sshOptions,
    config.host,
    ...extra
  ];
}

function runLocal(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
      shell: false
    });
    let stdout = "";
    let stderr = "";
    if (child.stdout) child.stdout.on("data", (d) => { stdout += d; });
    if (child.stderr) child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0 || options.allowFailure) {
        resolve({ code, stdout, stderr });
      } else {
        const error = new Error(`${command} exited with ${code}`);
        error.code = code;
        error.stdout = stdout;
        error.stderr = stderr;
        reject(error);
      }
    });
  });
}

function powershellCommand(script) {
  const payload = [
    "$ProgressPreference = 'SilentlyContinue'",
    String(script)
  ].join("; ");
  const encoded = Buffer.from(payload, "utf16le").toString("base64");
  return [
    "powershell.exe",
    "-NonInteractive",
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-EncodedCommand",
    encoded
  ];
}

function repoScript(config, relativeScript, args = []) {
  const repo = remoteRepoExpression(config);
  const argText = args.map(psArg).join(" ");
  return [
    repo.ps,
    "Set-Location -LiteralPath $RepoPath",
    `& (Join-Path $RepoPath ${psQuote(relativeScript)}) ${argText}`
  ].join("; ");
}

function psArg(value) {
  const text = String(value);
  if (/^-[A-Za-z][A-Za-z0-9-]*$/.test(text)) return text;
  return psQuote(text);
}

function repoCommand(config, script) {
  const repo = remoteRepoExpression(config);
  return [
    "$ErrorActionPreference = 'Stop'",
    repo.ps,
    "Set-Location -LiteralPath $RepoPath",
    script
  ].join("; ");
}

function ssh(config, remoteArgs, options = {}) {
  return runLocal("ssh", sshArgs(config, remoteArgs), options);
}

function sshPowerShell(config, script, options = {}) {
  return ssh(config, powershellCommand(script), options);
}

module.exports = {
  powershellCommand,
  psArg,
  repoCommand,
  repoScript,
  runLocal,
  ssh,
  sshArgs,
  sshPowerShell
};
