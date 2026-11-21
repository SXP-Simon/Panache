# Self-host the web workbench

The browser client connects to a Rust HTTP service that can also serve the Flutter Web files. Prepare the toolchains described in [Local development](site:development), then run from the repository root:

```bash
(cd app && flutter pub get)
python3 scripts/build-flutter-web.py
export HANDWRITING_ACCESS_TOKEN="$(openssl rand -hex 32)"
docker compose -f deploy/rust/compose.yml up --build -d
```

Open `http://127.0.0.1:5006` on the host. Compose binds the port to loopback. The browser uses Basic auth with the configured token as the password. For remote access, use an HTTPS reverse proxy, preserve Host, forward WebSocket Upgrade and set `HANDWRITING_ALLOWED_ORIGINS` to the actual origin.

[Service configuration, data paths and proxy settings](https://github.com/SXP-Simon/Panache/blob/main/deploy/rust/README.md)
