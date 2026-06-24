"use strict";

const JOB_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const JOB_ACTIONS = new Set(["list", "start", "logs", "paths", "monitor", "pull"]);
const PULL_KINDS = new Set(["logs", "runs", "data"]);

function validateJobName(name) {
  const value = String(name || "");
  if (!JOB_NAME_PATTERN.test(value)) {
    throw new Error("Job names may use only letters, numbers, hyphens, and underscores, and must start with a letter or number.");
  }
  return value;
}

function encodeJobArgs(args) {
  return Buffer.from(JSON.stringify(args.map(String)), "utf8").toString("base64");
}

function decodeJobArgs(encoded) {
  return JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
}

function parseJobArgs(args) {
  const [action = "list", ...rest] = args;
  if (!JOB_ACTIONS.has(action)) {
    throw new Error(`Unknown job action "${action}". Use: winver job <list|start|logs|paths|monitor|pull>`);
  }

  if (action === "list" || action === "paths") {
    if (rest.length > 0) throw new Error(`winver job ${action} does not take extra arguments.`);
    return { title: action, psArgs: ["-Action", action] };
  }

  if (action === "logs") {
    const target = rest[0] || "latest";
    if (rest.length > 1) throw new Error("Usage: winver job logs [latest|list|JOB_ID]");
    return { title: `logs ${target}`, psArgs: ["-Action", "logs", "-Target", target] };
  }

  if (action === "monitor") {
    const options = parseMonitorArgs(rest);
    return {
      mode: "monitor",
      title: `monitor ${options.target}`,
      target: options.target,
      intervalSeconds: options.intervalSeconds,
      tail: options.tail
    };
  }

  if (action === "pull") {
    const options = parsePullArgs(rest);
    return {
      mode: "pull",
      title: `pull ${options.kind} ${options.target}`,
      kind: options.kind,
      target: options.target,
      localDir: options.localDir,
      psArgs: ["-Action", "archive", "-Kind", options.kind, "-Target", options.target]
    };
  }

  const [name, ...rawJobArgs] = rest;
  if (!name) throw new Error("Usage: winver job start <name> -- <args...>");
  const jobName = validateJobName(name);
  const jobArgs = rawJobArgs[0] === "--" ? rawJobArgs.slice(1) : rawJobArgs;

  return {
    title: `start ${jobName}`,
    psArgs: [
      "-Action", "start",
      "-Name", jobName,
      "-ArgsJsonBase64", encodeJobArgs(jobArgs)
    ]
  };
}

function parseMonitorArgs(args) {
  let target = "latest";
  let intervalSeconds = 5;
  let tail = 40;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--interval") {
      intervalSeconds = parsePositiveInteger(args[++i], "--interval");
    } else if (arg === "--tail") {
      tail = parsePositiveInteger(args[++i], "--tail");
    } else if (target === "latest") {
      target = arg;
    } else {
      throw new Error("Usage: winver job monitor [latest|JOB_ID] [--interval SECONDS] [--tail LINES]");
    }
  }
  return { target, intervalSeconds, tail };
}

function parsePullArgs(args) {
  const [kind = "logs", targetArg, localDir] = args;
  if (!PULL_KINDS.has(kind)) {
    throw new Error("Usage: winver job pull <logs|runs|data> [TARGET] [LOCAL_DIR]");
  }
  if (args.length > 3) throw new Error("Usage: winver job pull <logs|runs|data> [TARGET] [LOCAL_DIR]");
  const target = targetArg || (kind === "logs" ? "latest" : "");
  if (!target) throw new Error(`winver job pull ${kind} needs a target folder name.`);
  return { kind, target, localDir: localDir || "" };
}

function parsePositiveInteger(value, option) {
  if (!/^[1-9][0-9]*$/.test(String(value || ""))) {
    throw new Error(`${option} needs a positive whole number.`);
  }
  return Number(value);
}

module.exports = {
  JOB_NAME_PATTERN,
  decodeJobArgs,
  encodeJobArgs,
  parseJobArgs,
  parseMonitorArgs,
  parsePullArgs,
  validateJobName
};
