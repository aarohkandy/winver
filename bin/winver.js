#!/usr/bin/env node

const { main } = require("../lib/cli");

main(process.argv.slice(2)).catch((error) => {
  const message = error && error.message ? error.message : String(error);
  console.error(`\nwinver could not finish: ${message}`);
  process.exitCode = 1;
});

