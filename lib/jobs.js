"use strict";

const JOB_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const JOB_ACTIONS = new Set(["list", "start", "logs", "paths"]);

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
    throw new Error(`Unknown job action "${action}". Use: winver job <list|start|logs|paths>`);
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

module.exports = {
  JOB_NAME_PATTERN,
  decodeJobArgs,
  encodeJobArgs,
  parseJobArgs,
  validateJobName
};
