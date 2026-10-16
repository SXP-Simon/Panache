# Architecture and Technology Stack

This page describes the React / Python / Electron application on `custom-base`. `main` tracks
upstream, while `flutter` maintains the separate Flutter / Rust application. Their implementations
are outside this page's scope. See [Local Development](development.md) for commands and
[AGENTS.md](https://github.com/SXP-Simon/Panache/blob/custom-base/AGENTS.md) for branch rules.

## Technology stack

| Responsibility | Technology and purpose |
|---|---|
| Frontend and build | React, TypeScript, Vite; Tailwind CSS and project styles, Motion animations, Lucide icons |
| Client business state | Zustand stores for the document, settings, preview, preferences, and notifications |
| Server data | TanStack Query; native Fetch requests and Valibot validation of responses and saved formats |
| Mathematics and text conversion | KaTeX parsing and project converters; Markdown cleanup, letter layout, image placeholders |
| Local storage | localStorage + IndexedDB on the Web; a restricted Electron IPC bridge and application data files on desktop |
| Generation service | Python and FastAPI; Uvicorn in development, Gunicorn / Uvicorn Worker in production |
| Layout and export | handrightbeta, Pillow, project math glyph and layout modules; OpenCV background detection and PyMuPDF export |
| Backend tasks | A persistent SQLite queue; WebSocket updates with HTTP polling as fallback |
| Desktop and offline entry | Electron + PyInstaller; a project TypeScript Service Worker caches the Web application shell |
| Engineering and validation | Playwright, Node tests, pytest; Oxlint / Oxfmt, Ruff / Pyright, Lefthook, semantic-release |

Consult package manifests and lockfiles for exact versions. UI text uses LXGW WenKai. Text rendered
on paper uses the selected handwriting font and the backend's missing-glyph fallback logic.

## Module responsibilities

The main UI is a single workspace; help and desktop-download information open in dialogs.
Business modules are organized under `features/`.

| Location | Responsibility |
|---|---|
| `frontend/src/main.tsx` | Restore the workspace before installing persistence subscriptions, Query Provider, and business actions |
| `frontend/src/App.tsx`, `components/` | Screen composition, forms, and interactions with selective state subscriptions |
| `frontend/src/shared/` | Shared UI, icons, and animation primitives |
| `frontend/src/features/*/store.ts` | Domain memory state and synchronous state updates |
| `frontend/src/features/workspace/` | Cross-domain document, settings, and generation actions; workspace hydration and save subscriptions |
| `frontend/src/features/settings/` | Configuration parsing, legacy conversion, and the preset repository |
| `frontend/src/features/generation/` | Generation operations, task sessions, Query cache subscriptions, and retry countdowns |
| `frontend/src/api/` | Transport, response validation, Query options, task endpoints, and download adaptation |
| `frontend/src/persistence/` | Record contracts, Web / desktop adapters, asset snapshots, and reference protection |
| `frontend/src/utils/`, `i18n.ts` | Pure text / math conversion and centralized Chinese / English strings |
| `frontend/worker/` | Application-shell caching; API requests bypass offline caching |
| `backend/app.py` | HTTP / WebSocket routes, task scheduling, and the generation flow |
| `backend/task_store.py`, `task_types.py` | Task persistence and data contracts |
| `backend/symbol_fallback.py`, `math_*.py` | Math glyph fallback, geometry, and page layout |
| `backend/identify.py`, `pdf.py`, `logging_setup.py` | Background detection, PDF export, and shared logging |
| `desktop/main.js`, `preload.js` | Backend process, windows, downloads, and the isolated renderer bridge |
| `desktop/studio-storage.js` | Fixed-key storage IPC, source validation, atomic file writes, and queue draining |
| `e2e/` | Web and real packaged-desktop validation |

The UI delegates operations to workspace actions. Actions combine stores, APIs, repositories, and
resource services. APIs own transport and data contracts; adapters own persistence. Stores hold
state and synchronous updates rather than requests, file writes, or object-URL creation and disposal.

## State ownership

| State | Owner | Persistence |
|---|---|---|
| Text, image map, imported filename | Document store | Workspace snapshot and binary assets |
| Handwriting parameters, fonts, backgrounds, generation options | Settings store | Workspace snapshot; uploaded files become assets |
| Language, theme, table conversion mode | Preferences store | Workspace snapshot |
| Preview URLs, current page, download display information | Preview store | Memory only |
| Font catalog, version, task state, raw generation results | TanStack Query | Memory cache; the whole Query cache is not persisted |
| Generation task ID and export mode | Generation flow / `studio.generation` | Resume observation after refresh |
| Notifications and save status | Separate stores | Memory only |
| Dialogs, accordions, selection, temporary number-input text | Component state and refs | Component lifetime |

Components subscribe through field selectors or `useShallow`. Editing text does not propagate a
large Context value through the page; status components subscribe to task progress separately.
Context provides the language environment and stable workspace actions. `QueryClientProvider`
provides server-data caching.

## Generation flow

1. Workspace actions read a document / settings snapshot and validate it. Image placeholders are
   expanded when building the request payload.
2. The API submits a task. The backend persists it in SQLite and returns a task ID.
3. The client saves the ID and export mode, then observes progress through WebSocket with HTTP
   polling as fallback.
4. Both transports update the same Query task cache. On completion, the client fetches images,
   ZIP, or PDF and passes them to preview / download adapters.
5. After refresh, the client resumes the saved task without another POST, provided that task
   remains available on the server.

Generation POSTs are not retried automatically. A full queue disables submission until the returned
retry deadline. Cancellation, unmounting, or leaving the page aborts client requests and releases
observation connections; it does not delete the backend task. Temporary network errors and timeouts
retain task identity. Success, explicit task failure, or an unavailable task clears it. The uploaded
snapshot reference is released when the POST finishes.

## Local persistence

### Separate metadata and binary assets

| Content | Web | Desktop |
|---|---|---|
| `studio.workspace`, presets, active task records | localStorage for the current origin | `studio/records/` under the application data directory |
| Illustrations, uploaded fonts, paper backgrounds | IndexedDB database `handwriting-studio`, store `assets` | `studio/assets/` under the application data directory |

The desktop main process selects the data directory: `%LOCALAPPDATA%/HandwritingWeb` on Windows,
or `~/Library/Application Support/HandwritingWeb` on macOS. Storage is independent of the backend's
random port. The backend SQLite queue and editor drafts have separate data and lifecycles.

`studio.workspace` combines text, configuration, preferences, and asset references in one snapshot.
Presets have a separate record. Assets are deduplicated by content hash. Records contain asset IDs
and file metadata rather than `blob:` URLs or full Base64 illustrations. Restoration recreates
Files, the illustration map, and required object URLs.

### Save and restore boundaries

- Ordinary edits are debounced; blur, visibility changes, and page exit flush pending changes.
  Prepared assets allow synchronous Web metadata writes.
- Uploads persist their binary content before publishing the corresponding UI state. If storage
  fails, editing remains available in memory and the UI reports that saving failed.
- Binary assets commit before the complete referencing metadata snapshot. A partial new snapshot
  does not replace the previous complete draft.
- Desktop writes replace files through a temporary file, sync, and rename. Writes to the same
  record are serialized; reads wait for previously accepted writes.
- Startup prefers the current snapshot, then falls back to legacy `studio.*`, camelCase settings,
  and `myPreset` when no snapshot exists. Failed restoration is reported and automatic overwriting
  of the unreadable workspace is blocked.
- Resource services revoke old object URLs when previews or backgrounds change. Late asynchronous
  results must not overwrite newer edits.

Web storage is origin-scoped and does not merge edits across tabs. Web asset reclamation is disabled
to avoid deleting another tab's in-flight resources. Desktop reclamation only considers application
assets identified during this run and unreferenced by the workspace, preset, or in-flight operations.
Read or save failures disable automatic reclamation for the session.

### Desktop shutdown

A normal window close or application quit keeps the renderer alive, requests a save, waits for its
acknowledgement and accepted file writes, then exits. A failed or timed-out save allows cancelling
the quit. Forced termination or power loss can only rely on previously committed snapshots.
The bridge accepts only the current main window's main frame at its exact origin and restricts
record keys, asset IDs, sizes, and in-flight calls. It exposes no arbitrary filesystem paths.

## Extension rules

- Assign client state to a business domain; keep temporary interactions in components and server
  data in the Query cache.
- Define new endpoint contracts, validation, and Query keys in `api/`. Compose cross-domain side
  effects through workspace actions.
- Extend persistence through its adapters, including migration and failure handling. Keep the
  renderer contract and desktop record whitelist aligned.
- Changes to refresh recovery, task observation, or shutdown saving require the relevant unit and
  end-to-end coverage.
- Consult source and tests for exact fields, limits, timeouts, and cache parameters. This page does
  not duplicate release versions or a work log.
