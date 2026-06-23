"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  needsApplySignature,
  parseAdminArgs,
  parseUefiArgs,
  redact,
  signAdminRequest,
  signaturePayload
} = require("../lib/admin");

test("admin parser defaults to safe dry-run status", () => {
  assert.deepEqual(parseAdminArgs([]), {
    action: "status",
    mode: "DryRun",
    force: false,
    skipBitLockerCheck: false,
    command: ""
  });
});

test("admin parser accepts signed apply shape", () => {
  assert.deepEqual(parseAdminArgs(["server-profile", "--apply", "--skip-bitlocker-check"]), {
    action: "server-profile",
    mode: "Apply",
    force: false,
    skipBitLockerCheck: true,
    command: ""
  });
});

test("admin-shell requires explicit apply and force", () => {
  assert.throws(() => parseAdminArgs(["admin-shell", "Get-Service"]), /--apply --force/);
  assert.equal(parseAdminArgs(["admin-shell", "--apply", "--force", "Get-Service"]).command, "Get-Service");
});

test("dangerous apply actions need signatures", () => {
  assert.equal(needsApplySignature("server-profile", "Apply"), true);
  assert.equal(needsApplySignature("lockdown", "Apply"), true);
  assert.equal(needsApplySignature("unlock", "Apply"), true);
  assert.equal(needsApplySignature("server-profile", "DryRun"), false);
  assert.equal(needsApplySignature("status", "Apply"), false);
});

test("admin parser accepts lockdown and unlock", () => {
  assert.equal(parseAdminArgs(["lockdown", "--dry-run"]).action, "lockdown");
  assert.equal(parseAdminArgs(["unlock", "--apply"]).mode, "Apply");
});

test("signature payload and hmac are stable", () => {
  const request = {
    action: "server-profile",
    mode: "Apply",
    requestId: "abc",
    command: ""
  };
  assert.equal(signaturePayload(request), "server-profile|Apply|abc|");
  assert.equal(signAdminRequest("secret", request), "2962533db21d0b0ae45edc73290c55f7b291ef57054a3f7b3700814260d77ec2");
});

test("uefi parser is read-oriented by default", () => {
  assert.deepEqual(parseUefiArgs([]), {
    action: "inventory",
    format: "text",
    localConfirm: false
  });
  assert.deepEqual(parseUefiArgs(["plan", "--json"]), {
    action: "plan",
    format: "json",
    localConfirm: false
  });
});

test("redaction hides admin and external tokens", () => {
  const githubToken = "ghp_" + "abcdefghijklmnopqrstuvwxyz";
  const tailscaleKey = "tskey" + "-example";
  const text = `WINVER_ADMIN_KEY=supersecret Signature deadbeefdeadbeefdeadbeefdeadbeef ${githubToken} ${tailscaleKey}`;
  const out = redact(text);
  assert.doesNotMatch(out, /supersecret/);
  assert.doesNotMatch(out, /ghp_/);
  assert.doesNotMatch(out, /tskey-/);
});
