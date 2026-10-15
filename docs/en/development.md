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
# TypeScript, Oxlint, formatting, Ruff, and Pyright
pnpm run quality:check

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

Desktop tests drive the packaged application separately and are not included in `test:all`:

```bash
bash desktop/build.sh --app-only
pnpm --filter handwriting-web-e2e run test:desktop
```

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

`pnpm install` installs Lefthook. Commits run the complete quality gate; pushes run the full test
command. Fix failures instead of skipping hooks. Each commit should contain one reviewable change,
use `type(scope): description`, and include separate, non-empty `背景：`, `解决手段：`, and `收益：`
paragraphs explaining the background, solution, and benefit.

Provide both Chinese and English user-visible strings and `data-testid` attributes for E2E actions.
semantic-release manages release versions, tags, and `CHANGELOG.md`.
