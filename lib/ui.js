"use strict";

const tty = process.stdout.isTTY;

const color = {
  dim: (s) => tty ? `\x1b[2m${s}\x1b[0m` : s,
  green: (s) => tty ? `\x1b[32m${s}\x1b[0m` : s,
  red: (s) => tty ? `\x1b[31m${s}\x1b[0m` : s,
  cyan: (s) => tty ? `\x1b[36m${s}\x1b[0m` : s,
  yellow: (s) => tty ? `\x1b[33m${s}\x1b[0m` : s,
  bold: (s) => tty ? `\x1b[1m${s}\x1b[0m` : s
};

function title(text) {
  console.log("");
  console.log(color.bold(text));
  console.log(color.dim("=".repeat(Math.min(text.length, 72))));
}

function line(label, value, state = "info") {
  const icon = state === "ok" ? "✓" : state === "warn" ? "!" : state === "bad" ? "x" : "•";
  const paint = state === "ok" ? color.green : state === "warn" ? color.yellow : state === "bad" ? color.red : color.cyan;
  console.log(`${paint(icon)} ${label.padEnd(18)} ${value}`);
}

function hint(text) {
  console.log(color.dim(text));
}

function command(text) {
  console.log(color.cyan(text));
}

module.exports = {
  color,
  title,
  line,
  hint,
  command
};

