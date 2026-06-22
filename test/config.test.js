"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { psQuote, remoteRepoExpression } = require("../lib/config");
const { powershellCommand, psArg, repoCommand, repoScript, sshArgs } = require("../lib/remote");

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
  assert.deepEqual(powershellCommand("Write-Host ok").slice(0, 5), ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass"]);
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
