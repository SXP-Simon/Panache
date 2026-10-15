# Local Development

!!! info "The deep material lives in AGENTS.md"
    This page only covers getting the project running. Architecture, coding conventions, the release
    pipeline and all the accumulated gotchas are in
    [`AGENTS.md`](https://github.com/14790897/handwriting-web/blob/main/AGENTS.md) at the repository
    root — read it before changing code. (It is written in Chinese.)

## Requirements

- **Python 3.10 or 3.11** (3.8 – 3.13 all work)
- **Node.js 20 or higher** (a Playwright requirement, for E2E)

## Start the backend (port 5005)

**Use the repository's venv, not your system Python.** The system environment's `fastapi` +
`starlette` combination prevents the app from starting, with
`TypeError: Router.__init__() got an unexpected keyword argument 'on_startup'`.

Create the virtualenv and install dependencies first:

```shell
python -m venv venv
venv/Scripts/python.exe -m pip install -r backend/requirements.txt
```

(On Linux / macOS use `venv/bin/python` instead of `venv/Scripts/python.exe`.)

Then start it:

```shell
cd backend
../venv/Scripts/python.exe -m uvicorn app:app --reload --host 0.0.0.0 --port 5005
```

## Start the frontend (port 8080)

```shell
cd frontend
npm install
npm run serve
```

Open <http://localhost:8080>. The dev server proxies `/api` to `127.0.0.1:5005`, so no CORS setup is
needed locally.

VS Code users can press `Ctrl+Shift+B` — there are tasks that bring up both sides in parallel.

## Running the tests

**Backend unit tests** —

```shell
cd backend
../venv/Scripts/python.exe -m pytest
```

**End-to-end tests (Playwright)** — `e2e/` drives the **real frontend and backend** through complete
flows (actually rendering images, actually downloading attachments); a few branches that are hard to
trigger for real (such as the queue-full 503) are simulated with route interception.

```shell
cd e2e
npm install
npx playwright install chromium
npm test
```

- Dev servers that are not running are started automatically (backend 5005, frontend 8080) and shut
  down afterwards.
- Ones that are already running are reused rather than restarted.
- The run sets `CPU_USAGE_LIMIT=100` so that a dev machine saturated by webpack does not trip the
  backend's overload guard.
- Failure screenshots, videos and traces go to `e2e/test-results/`; open the HTML report with
  `npm run report`.
- If no Python interpreter is found, point at one with `E2E_PYTHON`.

Every pull request runs this via `.github/workflows/e2e.yml`.

**Desktop end-to-end** — this drives the real packaged build, so build it first:

```shell
bash desktop/build.sh --app-only
cd e2e && npm run test:desktop
```

## What the code looks like

| Path | Contents |
|---|---|
| `frontend/src/views/HomeView.vue` | The main page: parameters, preview, generation flow |
| `frontend/src/views/TextInput.vue` | Text box and document upload |
| `frontend/src/components/` | Letter layout, generation status, splash animation, PWA prompt |
| `frontend/src/i18n.js` | Chinese and English strings |
| `backend/app.py` | Every route plus the rendering logic (~1300 lines) |
| `backend/task_store.py` | SQLite task queue (WAL, 30-minute expiry) |
| `backend/identify.py` | Detects margins and line spacing from a background image |
| `backend/pdf.py` | PDF generation |

A request comes in, the task is submitted and written to SQLite, a `task_id` is returned immediately,
a background coroutine queues the render, the frontend gets progress over a WebSocket (falling back to
polling), and finally fetches the result.

## Mathematics conversion and limits (2026-10-15)

The Vue/Python pipeline is input → optional Markdown cleanup → explicit LaTeX conversion → Unicode
mathematical text → dynamic fraction/radical glyphs → handwriting. Word uploads use a separate
extraction pipeline. The backend is not a complete LaTeX interpreter; direct API requests additionally
recognize only a limited fraction/radical syntax.

The audit fixed several cases that changed mathematical meaning:

| Previous failure | Current behavior |
|---|---|
| Removing delimiters before parsing caused entire English paragraphs to lose spaces | Shared scanning isolates formulas and protects code, URLs, paths and images |
| Markdown deleted `$a<b>c$` as HTML and split formula pipes into table columns | Formulas, including incomplete or oversized ones, are stashed and restored unchanged |
| `a^b` became `ab` and `x_A` became `xA` | Unicode scripts require a complete mapping; otherwise use `a^(b)` and `x_(A)` |
| Binomials became division and powers lost their grouped base | `\binom{n}{k}` becomes `C(n, k)` and `{a+b}^2` becomes `(a+b)²` |
| Mathematical fonts, case conditions and unsupported AST contents disappeared | Blackboard sets, cases, nested matrices and common annotations are supported; unsupported formulas retain their source |
| Dates/URLs became fractions and `2√x` lost its coefficient | Literal ranges bypass conversion and only superscript root indices are consumed |
| The 513th dynamic fraction collided with a radical private-use character | Separate supplementary private-use ranges and bounded registries retain existing references |

Matrices and cases are linearized with spaces between columns and semicolons between rows. Augmented
matrix rules, cancellation marks, unsupported fonts and unknown commands retain the original formula.
This is not full two-dimensional TeX layout. Nested heights/baselines, combining marks and uncommon
Unicode glyphs still depend on the renderer and available fonts. Parsing success alone is not proof
that final rendering is correct.

Scanning limits each formula to 32768 characters and 64 nesting levels. AST conversion further limits
formulas to 16000 characters, 64 levels and 500 macro expansions; exceeding a limit preserves source.
Backend math depth is limited to 48, with at most approximately 4096 registered fractions and radicals
each. When full, new expressions retain readable source while existing references remain valid.
KaTeX `__parse` is an internal API: run the semantic regressions when upgrading. See the
[KaTeX options](https://katex.org/docs/options) for error handling and expansion limits.

```shell
pnpm --filter handwrite run test:latex-unicode
pnpm --filter handwrite run test:clean-markdown
uv run --extra dev python -m pytest backend/tests
pnpm --filter handwriting-web-e2e exec playwright test tests/math-support.spec.js
```

The separate `flutter` branch preserves HakimYu's Flutter/Rust migration. These improvements target
Vue/Python and have not been ported to Dart/Rust. The migration still has issues with prose spacing,
unmapped scripts, higher roots and private-use fraction characters. Its `Math.tex` preview also differs
from the Rust output renderer; port these regressions before assessing it as a replacement.

## Commit conventions

- **Commit messages must follow [Conventional Commits](https://www.conventionalcommits.org/) —**
  semantic-release derives the version number from them, and getting it wrong bumps the wrong version.
- User-visible strings need **both Chinese and English**, added to `frontend/src/i18n.js`.
- Elements that E2E needs to click get a `data-testid`; tests use `getByTestId` only and never rely on
  copy or CSS classes.
- Do not hand-edit `CHANGELOG.md` or version numbers — the release pipeline owns them.
