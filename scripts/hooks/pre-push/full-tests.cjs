"use strict";

const fs = require("node:fs");
const { main } = require("../../run-affected-tests.cjs");
try { process.exitCode = main(["--push"], fs.readFileSync(0, "utf8")); }
catch (error) { console.error(`推送前检查失败：${error.message}`); process.exitCode = 1; }
