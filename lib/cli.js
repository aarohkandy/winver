"use strict";

const fs = require("fs");
const { loadConfig, remoteRepoExpression } = require("./config");
const { powershellCommand, repoCommand, repoScript, runLocal, ssh, sshPowerShell } = require("./remote");
const ui = require("./ui");

function help() {
  console.log(`winver

Usage:
  winver help
  winver doctor
  winver check
  winver connect
  winver update
  winver codex
  winver run "<command>"
  winver start "<command>"
  winver logs [latest|list|JOB_ID]
  winver control <status|server-mode|balanced|reboot|shutdown>
  winver status
  winver server-mode

Setup:
  ./mac/setup-mac.sh
  ./windows/setup.ps1 -MacPublicKey "ssh-ed25519 ..."
`);
}

async function doctor(config) {
  ui.title("winver doctor");
  ui.line("Host", config.host, "info");
  ui.line("Remote repo", remoteRepoExpression(config).value, "info");
  ui.line("Repo URL", config.repoUrl, "info");
  ui.line("SSH key", fs.existsSync(config.macKeyPath) ? config.macKeyPath : "missing", fs.existsSync(config.macKeyPath) ? "ok" : "warn");

  const checks = [
    ["ssh", ["-V"]],
    ["git", ["--version"]]
  ];
  for (const [cmd, args] of checks) {
    const result = await runLocal(cmd, args, { capture: true, allowFailure: true });
    ui.line(cmd, result.code === 0 ? (result.stdout || result.stderr).trim().split(/\r?\n/)[0] : "missing", result.code === 0 ? "ok" : "bad");
  }

  ui.hint("");
  ui.hint("Remote checks need the Surface to be awake, on Tailscale, and already set up.");
}

async function check(config) {
  ui.title("winver check");
  ui.line("Target", config.host, "info");

  const result = await sshPowerShell(
    config,
    "$PSVersionTable.PSVersion.ToString(); whoami; hostname",
    { capture: true, allowFailure: true }
  );

  if (result.code !== 0) {
    ui.line("SSH", "not reachable yet", "bad");
    ui.hint(result.stderr.trim() || "Run ./mac/setup-mac.sh, then windows/setup.ps1 on the Surface.");
    process.exitCode = 1;
    return;
  }

  const rows = result.stdout.trim().split(/\r?\n/).filter(Boolean);
  ui.line("SSH", "connected", "ok");
  if (rows[0]) ui.line("PowerShell", rows[0], "ok");
  if (rows[1]) ui.line("User", rows[1], "ok");
  if (rows[2]) ui.line("Computer", rows[2], "ok");
}

async function connect(config) {
  await ssh(config, []);
}

async function update(config) {
  ui.title("winver update");
  await sshPowerShell(config, repoCommand(config, "git pull --ff-only"));
}

async function codex(config) {
  const script = repoCommand(config, "codex");
  await runLocal("ssh", [...config.sshOptions, "-t", config.host, ...powershellCommand(script)]);
}

async function run(config, args) {
  const command = args.join(" ");
  if (!command) throw new Error("Pass a command, for example: winver run \"git status\"");
  await sshPowerShell(config, repoCommand(config, command));
}

async function start(config, args) {
  const command = args.join(" ");
  if (!command) throw new Error("Pass a command, for example: winver start \"npm run build\"");
  ui.title("winver start");
  await sshPowerShell(config, repoScript(config, "windows\\run-job.ps1", ["-Command", command]));
}

async function logs(config, args) {
  const target = args[0] || "latest";
  await sshPowerShell(config, repoScript(config, "windows\\logs.ps1", ["-Target", target]));
}

async function control(config, args) {
  const action = args[0] || "status";
  await sshPowerShell(config, repoScript(config, "windows\\control.ps1", ["-Action", action]));
}

async function printInstall(config) {
  ui.title("winver install command");
  ui.hint("Run this on the Surface after installing Git and Tailscale:");
  ui.command(`git clone ${config.repoUrl} $env:USERPROFILE\\winver`);
  ui.command("cd $env:USERPROFILE\\winver");
  ui.command('.\\windows\\setup.ps1 -MacPublicKey "PASTE_MAC_PUBLIC_KEY"');
}

async function main(argv) {
  const config = loadConfig();
  const [cmd = "help", ...args] = argv;

  switch (cmd) {
    case "help":
    case "--help":
    case "-h":
      help();
      break;
    case "doctor":
      await doctor(config);
      break;
    case "check":
      await check(config);
      break;
    case "connect":
    case "ssh":
      await connect(config);
      break;
    case "update":
    case "pull":
    case "sync":
      await update(config);
      break;
    case "codex":
      await codex(config);
      break;
    case "run":
      await run(config, args);
      break;
    case "start":
      await start(config, args);
      break;
    case "logs":
      await logs(config, args);
      break;
    case "control":
      await control(config, args);
      break;
    case "status":
      await control(config, ["status"]);
      break;
    case "server-mode":
      await control(config, ["server-mode"]);
      break;
    case "install-command":
      await printInstall(config);
      break;
    default:
      throw new Error(`Unknown command "${cmd}". Run winver help.`);
  }
}

module.exports = { main };
