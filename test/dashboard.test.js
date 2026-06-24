"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { isSafeJobTarget, parseDashboardArgs } = require("../lib/dashboard");

test("dashboard args default to local-only server", () => {
  assert.deepEqual(parseDashboardArgs([]), { host: "127.0.0.1", port: 8787, open: false });
});

test("dashboard args accept port, loopback host, and open", () => {
  assert.deepEqual(parseDashboardArgs(["--host", "localhost", "--port", "8799", "--open"]), {
    host: "localhost",
    port: 8799,
    open: true
  });
});

test("dashboard args reject unknown or bad values", () => {
  assert.throws(() => parseDashboardArgs(["--port", "nope"]), /--port/);
  assert.throws(() => parseDashboardArgs(["--host", "0.0.0.0"]), /local-only/);
  assert.throws(() => parseDashboardArgs(["--wat"]), /Usage/);
});

test("dashboard job targets reject traversal and raw paths", () => {
  assert.equal(isSafeJobTarget("latest"), true);
  assert.equal(isSafeJobTarget("20260624-111213-hello"), true);
  assert.equal(isSafeJobTarget("../secret"), false);
  assert.equal(isSafeJobTarget("C:\\Users\\aaroh"), false);
});
