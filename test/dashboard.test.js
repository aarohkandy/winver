"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  cleanPowerShellError,
  createSnapshotCache,
  isSafeJobTarget,
  parseDashboardArgs
} = require("../lib/dashboard");

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

test("dashboard snapshot cache reuses fresh data", async () => {
  let now = 0;
  let calls = 0;
  const cache = createSnapshotCache(async () => ({ collectedAt: `call-${++calls}` }), {
    minRefreshMs: 100,
    maxStaleMs: 1000,
    now: () => now
  });

  const first = await cache.get();
  now = 50;
  const second = await cache.get();

  assert.equal(calls, 1);
  assert.equal(first.data.collectedAt, "call-1");
  assert.equal(second.data.collectedAt, "call-1");
  assert.equal(second.data.dashboard.cache.state, "cached");
});

test("dashboard snapshot cache force-refreshes after invalidation", async () => {
  let now = 0;
  let calls = 0;
  const cache = createSnapshotCache(async ({ forceRefresh }) => ({
    collectedAt: `call-${++calls}`,
    forceRefresh
  }), {
    minRefreshMs: 1000,
    maxStaleMs: 2000,
    now: () => now
  });

  await cache.get();
  now = 25;
  cache.invalidate();
  const refreshed = await cache.get();

  assert.equal(calls, 2);
  assert.equal(refreshed.data.collectedAt, "call-2");
  assert.equal(refreshed.data.forceRefresh, true);
  assert.equal(refreshed.data.dashboard.cache.state, "fresh");
});

test("dashboard cleans PowerShell CLIXML errors", () => {
  const text = '#< CLIXML <Objs Version="1.1.0.1"><S S="Error">Missing Windows admin signing key._x000D__x000A_</S><S S="Error">At C:&amp;\\Users\\arvin\\winver\\windows\\admin\\broker.ps1:49 char:5_x000D__x000A_</S></Objs>';
  const clean = cleanPowerShellError(text);
  assert.match(clean, /Missing Windows admin signing key/);
  assert.doesNotMatch(clean, /CLIXML|<Objs|_x000D_/);
});
