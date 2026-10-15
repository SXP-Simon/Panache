"use strict";

const FLAGS = [
  "frontend", "python", "hooks", "unit_frontend", "unit_python", "unit_desktop",
  "build", "e2e", "sw_upgrade", "docker", "docs", "desktop_e2e",
  "frontend_image", "backend_image", "release",
];

function planChanges(paths, { full = false, reason = "actual Git paths", head_sha = "" } = {}) {
  const plan = Object.fromEntries(FLAGS.map((key) => [key, false]));
  const scopes = new Set();
  const enable = (...flags) => { for (const key of flags) plan[key] = true; };
  const allChecks = () => enable(...FLAGS.filter((key) => key !== "release"));
  const fe = () => enable("frontend", "unit_frontend", "build", "e2e", "sw_upgrade");
  const be = () => enable("python", "unit_python", "e2e");
  const desktop = () => enable("unit_desktop", "desktop_e2e");
  const normalized = [...new Set(paths)].sort();
  for (const file of normalized) {
    // Python configuration and source take precedence over directory labels and documentation suffixes.
    if (/\.(?:py|pyi|spec)$/.test(file)) enable("python");
    if (file.startsWith("docs/") || file === "mkdocs.yml" || file === "CHANGELOG.md") {
      scopes.add("docs"); enable("docs"); continue;
    }
    if (/\.(?:md|rst)$/.test(file) || /(?:^|\/)(?:LICENSE(?:\.[^/]+)?|COPYING|OFL\.txt)$/.test(file)
      || /^[^/]+\.(?:png|jpe?g|gif|webp|svg)$/.test(file)) {
      scopes.add("docs"); continue;
    }
    if (file.startsWith("frontend/")) {
      scopes.add("fe");
      if (file.startsWith("frontend/tests/")) { enable("unit_frontend"); continue; }
      if (/^frontend\/(?:\.oxfmtrc\.json|\.oxlintrc\.json|eslint\.config\.[cm]?js)$/.test(file)) {
        enable("frontend"); continue;
      }
      if (["frontend/dockerfile.frontend", "frontend/nginx.conf"].includes(file)) {
        enable("docker", "frontend_image"); continue;
      }
      fe(); enable("docker", "frontend_image", "release");
      if (file.startsWith("frontend/src/persistence/") || ["frontend/src/env.d.ts", "frontend/src/main.tsx",
        "frontend/src/features/workspace/persistenceRuntime.ts"].includes(file)) desktop();
      continue;
    }
    if (file.startsWith("backend/")) {
      scopes.add("be");
      if (file.startsWith("backend/tests/") || file.startsWith("backend/stubs/") || file === "backend/pytest.ini") {
        enable("python", "unit_python"); continue;
      }
      be(); enable("docker", "backend_image", "release");
      if (file === "backend/desktop_main.py") desktop();
      continue;
    }
    if (["pyproject.toml", "uv.lock", ".python-version"].includes(file)) {
      scopes.add("be"); be(); desktop(); enable("docker", "backend_image", "release"); continue;
    }
    if (file.startsWith("ttf_files/") || file.startsWith("font_assets/")) {
      scopes.add("be"); be(); enable("release");
      if (file.startsWith("ttf_files/")) enable("docker", "backend_image");
      continue;
    }
    if (file.startsWith("desktop/")) {
      scopes.add("desktop"); enable("unit_desktop");
      if (file.startsWith("desktop/tests/")) continue;
      desktop(); enable("release");
      if (file === "desktop/package.json") enable("docker", "frontend_image");
      continue;
    }
    if (file.startsWith("e2e/")) {
      scopes.add("e2e");
      if (file.startsWith("e2e/desktop-tests/") || file === "e2e/playwright.desktop.config.js") desktop();
      else if (file.startsWith("e2e/tests/") || file === "e2e/playwright.config.js") enable("e2e");
      else { enable("e2e"); desktop(); }
      if (file === "e2e/package.json") enable("docker", "frontend_image");
      continue;
    }
    if (["package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", ".npmrc"].includes(file)) {
      scopes.add("shared"); fe(); desktop(); enable("hooks", "docker", "frontend_image", "release");
      if (file === "package.json") be();
      continue;
    }
    if (file.startsWith("scripts/")) {
      scopes.add("ci"); enable("hooks");
      if (file === "scripts/install-hooks.cjs") enable("docker", "frontend_image");
      if (file.includes("service-worker-upgrade")) enable("build", "sw_upgrade");
      if (file === "scripts/smoke-docker-compose.sh") enable("docker");
      if (file === "scripts/run-desktop-tests.cjs") desktop();
      continue;
    }
    if (file.startsWith(".github/workflows/")) {
      scopes.add("ci"); enable("hooks");
      const workflow = file.slice(".github/workflows/".length);
      if (workflow === "deploy-docs.yml") enable("docs");
      else if (workflow === "frontend.yml") enable("docker", "frontend_image");
      else if (workflow === "backend.yml") enable("docker", "backend_image");
      else if (workflow === "test_backend.yml") enable("python", "unit_python");
      else if (workflow === "e2e.yml") enable("e2e");
      else if (workflow === "desktop_release.yml") desktop();
      else if (["semantic_release.yml", "mysql.yml"].includes(workflow)) enable("hooks");
      else allChecks();
      continue;
    }
    if (["docker-compose.yml", "docker-compose.yaml", ".dockerignore"].includes(file)) {
      scopes.add("shared"); enable("docker", "frontend_image", "backend_image"); continue;
    }
    if (file === "lefthook.yml" || file.startsWith(".vscode/") || ["release.config.js", ".gitignore", ".gitattributes"].includes(file)) {
      scopes.add("ci"); enable("hooks"); continue;
    }
    // An unclassified input must never silently turn a required check off.
    scopes.add("shared"); allChecks(); enable("release");
  }
  if (full) { allChecks(); enable("release"); scopes.add("all"); }
  return { ...plan, paths: normalized, scopes: [...scopes].sort(), full, reason, head_sha };
}

module.exports = { FLAGS, planChanges };
