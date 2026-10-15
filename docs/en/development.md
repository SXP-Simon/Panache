# Local Development

This page applies to `custom-base`. See [Architecture and Technology Stack](architecture.md) for
module responsibilities and data flow, and
[AGENTS.md](https://github.com/SXP-Simon/handwriting-web/blob/custom-base/AGENTS.md) for branch rules
and development conventions.

## Environment and dependencies

Use Node.js 24+, pnpm 10.13.1, Python 3.12+, and uv. From the repository root:

```bash
pnpm install --frozen-lockfile
uv sync --locked --extra dev
```

pnpm manages the frontend, Electron, and E2E workspaces. uv maintains the root `.venv` from
`pyproject.toml` and `uv.lock`. Use that environment for the backend and checks.

## Start the application

Run these in separate terminals:

```bash
# Terminal one: repository root
pnpm --filter handwrite run serve

# Terminal two: enter backend from the repository root
cd backend
uv run --project .. uvicorn app:app --reload --host 127.0.0.1 --port 5005
```

Open <http://127.0.0.1:8080>. Vite proxies `/api` to `127.0.0.1:5005`; the frontend uses
same-origin `/api` URLs.

In VS Code, `Ctrl+Shift+B` installs dependencies, starts both servers, and opens the browser.
`F5` offers Chrome / Edge debugging. See `.vscode/tasks.json` and `.vscode/launch.json`.

## Checks, tests, and builds

Run these from the repository root:

```bash
# Full quality checks: frontend/backend analysis, hooks, and desktop storage
pnpm run quality:check

# Preview checks selected for staged paths; run their affected tests
pnpm run checks:plan -- --staged
pnpm run test:affected -- --staged

# Commit conventions, frontend conversion/generation, desktop storage, backend unit tests
pnpm run test:unit

# Web E2E: install Chromium on first use
pnpm --filter handwriting-web-e2e exec playwright install chromium
pnpm --filter handwriting-web-e2e run test

# Production frontend build; PWA cache upgrade checks
pnpm --filter handwrite run build
pnpm run test:sw-upgrade

# Unit tests + frontend build + PWA upgrades + Web E2E
pnpm run test:all
```

Web E2E uses the real frontend and backend for rendering and downloads, with route interception for
selected error cases. Missing development servers are started and stopped automatically; existing
local servers are reused. Automatically started backends receive `CPU_USAGE_LIMIT=100`; reused
servers retain their existing environment. Set `E2E_PYTHON` if interpreter discovery fails.
Failure screenshots and traces go to `e2e/test-results/`. Open the HTML report with
`pnpm --filter handwriting-web-e2e run report`.

Desktop tests build and drive the packaged application separately and are not included in `test:all`:

```bash
pnpm run test:desktop
```

To test an existing packaged directory, run `pnpm --filter handwriting-web-e2e run test:desktop` directly.

The desktop build uses uv's `build` extra. Prepare dependencies yourself before `--skip-deps`:

```bash
uv sync --locked --extra dev --extra build
bash desktop/build.sh --app-only --skip-deps
```

Electron and PyInstaller build for the current platform; the backend is not cross-compiled.
`uv sync` / `uv run` adjust the environment to the requested extras. Do not run quality checks
or installation commands that resynchronize the same `.venv` concurrently with desktop packaging.
See [Desktop App](desktop.md) for packaging and data directories.

## Where to make changes

- UI composition and local interactions: `frontend/src/components/`; shared UI: `src/shared/`.
- Shared client state: `frontend/src/features/*/store.ts`; cross-domain actions: `features/workspace/`.
- Server contracts and Query options: `frontend/src/api/`; storage adapters: `src/persistence/`.
- Pure text, math, and layout conversion: `frontend/src/utils/`; translations: `src/i18n.ts`.
- Backend tasks and rendering: `backend/app.py`, `task_store.py`, and math layout modules.
- Desktop processes and bridge: `desktop/main.js`, `preload.js`, and `studio-storage.js`.

Consult the [architecture page](architecture.md) for ownership, draft recovery, and task resumption.
Read source and tests for exact fields and parameters.

## Commit conventions

`pnpm install` installs Lefthook. Integrate existing custom hooks before installation instead of
overwriting them. Each commit should contain one reviewable change,
use `type(scope): description`, and include separate, non-empty `背景：`, `解决手段：`, and `收益：`
paragraphs explaining the background, solution, and benefit.

Use scopes that describe actual paths, with `fe/` and `be/` aliases for frontend and backend:

```text
fix(fe/src/components): improve keyboard access to parameter controls
fix(be/math_page_layout.py): correct formula page boundaries
test(scripts): cover changed-path check selection
ci(scripts): connect affected checks with workflows
docs(docs/development.md): explain local validation commands
```

`fe/` maps to `frontend/`; `be/` maps to `backend/`. The file or directory named by a scope should
cover the actual change. This convention does not require rewriting historical commits.
Commit messages are always validated; ordinary commits cannot opt out with skip-CI markers.

Provide both Chinese and English user-visible strings and `data-testid` attributes for E2E actions.
semantic-release manages release versions, tags, and `CHANGELOG.md`.

## Selective checks and CI

Local hooks and CI share `scripts/change-impact.cjs`. The planner reads actual Git paths rather
than commit types or scopes. Multiple areas select the union of their checks; deletions and renames
also count.
For CI pushes, application paths since the latest stable release tag are also included, so a later
documentation push cannot cancel earlier application validation and leave those changes unpublished.

- Before a commit, hooks inspect staged paths, run the related quality checks, and check whitespace errors. Related unstaged changes stop validation so that checks cannot test a newer working-tree version in place of the staged version.
- Before a push, hooks read every ref supplied by Git and test the affected commit ranges. Resolve related uncommitted changes first; switch to the pushed version if it differs from the current checkout.
- A new branch or missing comparison baseline selects full validation. Manual Engineering quality runs also select full validation. Deleting remote refs alone does not require application tests.
- `pnpm run quality:check` retains full quality validation. `test:all` retains the complete Web test suite, while `test:desktop` validates the packaged desktop app separately. Use `pnpm run test:affected -- --all` to run every affected-test group explicitly.

Ordinary prose-only changes do not trigger application checks; changes to `docs/` or MkDocs
configuration select the documentation build. Frontend changes select frontend quality, unit tests,
builds, and relevant browser checks. Backend changes select Python quality, unit tests, and relevant
API checks. Desktop bridge, storage, and packaging entry points add desktop validation. Shared
dependencies and unclassified inputs expand the check set. Read `scripts/change-impact.cjs` and its
tests for exact mappings.

Engineering quality runs for pushes to `custom-base`, PRs targeting `custom-base`, and manual runs.
Lightweight planning and `Engineering quality gate` always run; quality, Docker, documentation,
and packaged desktop jobs run when selected. Use the stable `Engineering quality gate` check for
branch protection.

Automatic release and image workflows consume the plan and commit SHA from the same successful
check run. Only application changes enter release analysis; images build when their inputs change.
Desktop releases consume the corresponding release result and build its exact tag, with manual
rebuilds still available. Documentation deploys follow documentation inputs on `custom-base`.
`main` mirrors upstream and does not trigger custom application builds or releases. Legacy standalone
backend and E2E workflows retain manual entry points without duplicating automatic checks.

Docker publishing requires your own `FRONTEND_IMAGE` and `BACKEND_IMAGE` repository variables and
the corresponding registry credentials. Without an image address, login, building, and pushing are
skipped. Configure your own namespace instead of the upstream account.

## Documentation site

MkDocs builds the Markdown under `docs/` into a static site. `mkdocs.yml` configures navigation,
the theme, repository links, and the site URL. The documentation is hosted at
<https://heliannuits.me/handwriting-web/> using GitHub Pages; it does not run the FastAPI handwriting app.
See [Docker Deployment](self-hosting/docker.md) or the local startup instructions above to run the app.

Select GitHub Actions as the build source in Settings → Pages. `Deploy Docs` publishes documentation
changes on `custom-base`, and can also be dispatched manually for a selected branch. The
`github-pages` environment must allow that deployment branch. The site inherits the domain already
configured for the account's Pages site; update both `site_url` and documentation links when changing it.

```bash
uv tool run --with mkdocs-material --with mkdocs-static-i18n mkdocs build --strict
```

Flutter/Rust packages use the [pinned-source asset workflow](flutter-release.md) and are attached to the same `custom-base` release. APK publishing requires formal Android signing secrets.
