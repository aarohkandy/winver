"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { decodeJobArgs, encodeJobArgs, parseJobArgs, validateJobName } = require("../lib/jobs");
const { repoScript } = require("../lib/remote");

test("job names accept simple repo recipe names", () => {
  assert.equal(validateJobName("hello"), "hello");
  assert.equal(validateJobName("train_v1"), "train_v1");
  assert.equal(validateJobName("train-overnight"), "train-overnight");
});

test("job names reject traversal and shell-like names", () => {
  for (const name of ["", "../train", "jobs/hello", "hello.ps1", ".hidden", "-bad", "bad name", "bad;name"]) {
    assert.throws(() => validateJobName(name), /Job names/);
  }
});

test("job args encode and decode as JSON base64", () => {
  const args = ["--epochs", "3", "quote's ok", "spaces are ok"];
  assert.deepEqual(decodeJobArgs(encodeJobArgs(args)), args);
});

test("job start strips the separator and passes encoded args", () => {
  const parsed = parseJobArgs(["start", "python", "--", "--version"]);
  assert.equal(parsed.title, "start python");
  assert.deepEqual(parsed.psArgs.slice(0, 5), ["-Action", "start", "-Name", "python", "-ArgsJsonBase64"]);
  assert.deepEqual(decodeJobArgs(parsed.psArgs[5]), ["--version"]);
});

test("job actions generate the Windows job wrapper command", () => {
  const parsed = parseJobArgs(["logs", "latest"]);
  const command = repoScript({ remotePath: "" }, "windows\\job.ps1", parsed.psArgs);
  assert.match(command, /windows\\job\.ps1/);
  assert.match(command, /-Action 'logs'/);
  assert.match(command, /-Target 'latest'/);
});

test("job list and paths do not accept extra arguments", () => {
  assert.throws(() => parseJobArgs(["list", "extra"]), /does not take extra/);
  assert.throws(() => parseJobArgs(["paths", "extra"]), /does not take extra/);
});

test("job monitor parses target and polling options", () => {
  const parsed = parseJobArgs(["monitor", "20260624-job", "--interval", "10", "--tail", "25"]);
  assert.equal(parsed.mode, "monitor");
  assert.equal(parsed.target, "20260624-job");
  assert.equal(parsed.intervalSeconds, 10);
  assert.equal(parsed.tail, 25);
});

test("job monitor rejects bad numeric options", () => {
  assert.throws(() => parseJobArgs(["monitor", "--interval", "0"]), /positive whole number/);
  assert.throws(() => parseJobArgs(["monitor", "--tail", "nope"]), /positive whole number/);
});

test("job pull parses kind, target, and local destination", () => {
  const parsed = parseJobArgs(["pull", "runs", "myproject", "./downloads"]);
  assert.equal(parsed.mode, "pull");
  assert.equal(parsed.kind, "runs");
  assert.equal(parsed.target, "myproject");
  assert.equal(parsed.localDir, "./downloads");
  assert.deepEqual(parsed.psArgs, ["-Action", "archive", "-Kind", "runs", "-Target", "myproject"]);
});

test("job pull defaults logs to latest and requires data or runs target", () => {
  assert.equal(parseJobArgs(["pull", "logs"]).target, "latest");
  assert.throws(() => parseJobArgs(["pull", "data"]), /needs a target/);
  assert.throws(() => parseJobArgs(["pull", "runs"]), /needs a target/);
});
