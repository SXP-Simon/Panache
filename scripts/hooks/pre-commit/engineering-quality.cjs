"use strict";

const { main } = require("../../run-quality-checks.cjs");
try { process.exitCode = main(["--staged"]); }
catch (error) { console.error(`提交前检查失败：${error.message}`); process.exitCode = 1; }
