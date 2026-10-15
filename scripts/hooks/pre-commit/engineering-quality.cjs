"use strict";

const { runQualityChecks } = require("../../run-quality-checks.cjs");
process.exitCode = runQualityChecks();
