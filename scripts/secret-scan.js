"use strict";

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const denyFilePatterns = [
  /\.pem$/i,
  /\.key$/i,
  /id_rsa$/i,
  /id_ed25519$/i,
  /\.env$/i,
  /winver\.local\.json$/i
];
const secretPatterns = [
  /-----BEGIN (?:OPENSSH|RSA|EC|DSA)? ?PRIVATE KEY-----/,
  /tailscale[_-]?auth/i,
  /tskey-[A-Za-z0-9_-]+/,
  /gh[pousr]_[A-Za-z0-9_]{20,}/,
  /github_pat_[A-Za-z0-9_]+/
];

function walk(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if ([".git", "node_modules", "coverage"].includes(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...walk(full));
    if (entry.isFile()) files.push(full);
  }
  return files;
}

const failures = [];
for (const file of walk(root)) {
  const rel = path.relative(root, file);
  if (denyFilePatterns.some((pattern) => pattern.test(rel)) && !rel.endsWith(".example")) {
    failures.push(`${rel}: private-looking file should not be committed`);
    continue;
  }
  const text = fs.readFileSync(file, "utf8");
  for (const pattern of secretPatterns) {
    if (pattern.test(text)) {
      failures.push(`${rel}: matched ${pattern}`);
    }
  }
}

if (failures.length) {
  console.error("Secret scan failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Secret scan passed.");

