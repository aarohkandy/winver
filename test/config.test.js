"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { psQuote, remoteRepoExpression } = require("../lib/config");
const { powershellCommand, psArg, repoCommand, repoScript, runLocal, sshArgs } = require("../lib/remote");

test("psQuote escapes single quotes for PowerShell", () => {
  assert.equal(psQuote("C:\\Users\\Aaroh's PC\\winver"), "'C:\\Users\\Aaroh''s PC\\winver'");
});

test("default remote path uses USERPROFILE expression", () => {
  const expr = remoteRepoExpression({ remotePath: "" });
  assert.equal(expr.kind, "default");
  assert.match(expr.ps, /USERPROFILE/);
});

test("custom remote path becomes a literal assignment", () => {
  const expr = remoteRepoExpression({ remotePath: "D:\\worker\\winver" });
  assert.equal(expr.kind, "literal");
  assert.match(expr.ps, /D:\\worker\\winver/);
});

test("sshArgs keeps options before host", () => {
  assert.deepEqual(sshArgs({ host: "winver", sshOptions: ["-i", "key"] }, ["echo", "hi"]), ["-i", "key", "winver", "echo", "hi"]);
});

test("powershell command is explicit and non-profile", () => {
  assert.deepEqual(powershellCommand("Write-Host ok").slice(0, 7), ["powershell.exe", "-NonInteractive", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand"]);
});

test("powershell command uses an encoded payload for cmd-safe SSH transport", () => {
  const command = "& (Join-Path $RepoPath 'windows\\run-job.ps1') -Command 'Write-Output hello'";
  const args = powershellCommand(command);
  const encoded = args.at(-1);
  const decoded = Buffer.from(encoded, "base64").toString("utf16le");
  assert.match(decoded, /\$ProgressPreference = 'SilentlyContinue'/);
  assert.match(decoded, /windows\\run-job\.ps1/);
  assert.equal(encoded.includes("&"), false);
  assert.equal(encoded.includes("'"), false);
});

test("repo commands set the repo path before running", () => {
  const command = repoCommand({ remotePath: "" }, "git status");
  assert.match(command, /Set-Location/);
  assert.match(command, /git status/);
});

test("repoScript invokes scripts below the remote repo", () => {
  const command = repoScript({ remotePath: "" }, "windows\\doctor.ps1", ["-Json"]);
  assert.match(command, /Join-Path/);
  assert.match(command, /windows\\doctor\.ps1/);
  assert.match(command, /-Json/);
});

test("PowerShell flags stay unquoted while values are quoted", () => {
  assert.equal(psArg("-Command"), "-Command");
  assert.equal(psArg("npm run build"), "'npm run build'");
});

test("runLocal can time out a stuck command", async () => {
  const result = await runLocal(
    process.execPath,
    ["-e", "setTimeout(() => {}, 10000)"],
    { capture: true, allowFailure: true, timeoutMs: 50 }
  );
  assert.equal(result.code, 124);
  assert.equal(result.timedOut, true);
  assert.match(result.stderr, /Timed out/);
});
