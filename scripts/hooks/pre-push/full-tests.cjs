"use strict";

const { spawnSync } = require("node:child_process");
const result = spawnSync("pnpm run test:all", { shell: true, stdio: "inherit" });
process.exitCode = result.status === 0 ? 0 : 1;
