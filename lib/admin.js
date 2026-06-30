"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ADMIN_KEY_PATH = path.join(os.homedir(), ".winver", "admin.key");

const APPLY_REQUIRED_ACTIONS = new Set([
  "server-profile",
  "lockdown",
  "cooling",
  "unlock",
  "rollback",
  "export-recovery",
  "break-glass",
  "reboot",
  "shutdown",
  "admin-shell"
]);

const ADMIN_ACTIONS = new Set([
  "status",
  "power",
  "services",
  "updates",
  "defender",
  "firewall",
  "bitlocker",
  "tpm",
  "battery",
  "thermal",
  ...APPLY_REQUIRED_ACTIONS
]);

const UEFI_ACTIONS = new Set([
  "inventory",
  "plan",
  "prepare-local"
]);

function makeRequestId() {
  return crypto.randomUUID();
}

function signaturePayload({ action, mode, requestId, command = "", profile = "" }) {
  return [
    String(action || "").toLowerCase(),
    String(mode || "DryRun"),
    String(requestId || ""),
    String(command || ""),
    String(profile || "")
  ].join("|");
}

function signAdminRequest(key, request) {
  if (!key) throw new Error("Missing admin signing key.");
  return crypto
    .createHmac("sha256", String(key).trim())
    .update(signaturePayload(request), "utf8")
    .digest("hex");
}

function loadAdminKey(env = process.env) {
  if (env.WINVER_ADMIN_KEY) return env.WINVER_ADMIN_KEY.trim();
  if (fs.existsSync(ADMIN_KEY_PATH)) return fs.readFileSync(ADMIN_KEY_PATH, "utf8").trim();
  return "";
}

function needsApplySignature(action, mode) {
  return String(mode) === "Apply" && APPLY_REQUIRED_ACTIONS.has(String(action).toLowerCase());
}

function redact(text) {
  return String(text)
    .replace(/WINVER_ADMIN_KEY=([^\s]+)/gi, "WINVER_ADMIN_KEY=[redacted]")
    .replace(/(AdminKey\s+)([A-Za-z0-9+/=_-]{16,})/gi, "$1[redacted]")
    .replace(/(Signature\s+)([a-f0-9]{32,})/gi, "$1[redacted]")
    .replace(/(gh[pousr]_[A-Za-z0-9_]{10,})/g, "[redacted-github-token]")
    .replace(/(tskey-[A-Za-z0-9_-]+)/g, "[redacted-tailscale-key]");
}

function parseAdminArgs(args) {
  const action = (args[0] || "status").toLowerCase();
  if (!ADMIN_ACTIONS.has(action)) {
    throw new Error(`Unknown admin action "${action}".`);
  }

  const rest = args.slice(1);
  const options = {
    action,
    mode: "DryRun",
    force: false,
    skipBitLockerCheck: false,
    command: "",
    profile: ""
  };

  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    if (arg === "--dry-run") options.mode = "DryRun";
    else if (arg === "--apply") options.mode = "Apply";
    else if (arg === "--force") options.force = true;
    else if (arg === "--skip-bitlocker-check") options.skipBitLockerCheck = true;
    else if (arg === "--profile") {
      options.profile = String(rest[++i] || "").toLowerCase();
      if (!["max", "cool", "balanced", "quiet", "status"].includes(options.profile)) {
        throw new Error("--profile must be one of: max, cool, balanced, quiet, status.");
      }
    }
    else if (arg === "--command") {
      options.command = rest.slice(i + 1).join(" ");
      break;
    } else if (action === "admin-shell") {
      options.command = rest.slice(i).join(" ");
      break;
    } else {
      throw new Error(`Unknown admin option "${arg}".`);
    }
  }

  if (action === "admin-shell" && !options.command) {
    throw new Error("admin-shell requires a command and must use --apply --force.");
  }

  if (action === "admin-shell" && (options.mode !== "Apply" || !options.force)) {
    throw new Error("admin-shell requires --apply --force.");
  }

  if (options.profile && action !== "cooling") {
    throw new Error("--profile is only supported with winver admin cooling.");
  }

  if (action === "cooling" && !options.profile) {
    options.profile = "status";
  }

  return options;
}

function parseUefiArgs(args) {
  const action = (args[0] || "inventory").toLowerCase();
  if (!UEFI_ACTIONS.has(action)) {
    throw new Error(`Unknown uefi action "${action}".`);
  }

  const options = {
    action,
    format: "text",
    localConfirm: false
  };

  for (const arg of args.slice(1)) {
    if (arg === "--json") options.format = "json";
    else if (arg === "--local-confirm") options.localConfirm = true;
    else throw new Error(`Unknown uefi option "${arg}".`);
  }

  return options;
}

module.exports = {
  ADMIN_ACTIONS,
  ADMIN_KEY_PATH,
  APPLY_REQUIRED_ACTIONS,
  UEFI_ACTIONS,
  loadAdminKey,
  makeRequestId,
  needsApplySignature,
  parseAdminArgs,
  parseUefiArgs,
  redact,
  signAdminRequest,
  signaturePayload
};
