# Docker Deployment

Docker Compose builds the frontend and backend from this fork by default. Automatic image updates
are optional.

## Requirements

- Docker and Docker Compose installed
- Enough memory and disk allocated to Docker; larger sheets and longer text consume more resources

## Bring it up

```shell
git clone --branch custom-base https://github.com/SXP-Simon/Panache.git
cd handwriting-web
docker compose up -d --build frontend backend
```

The default port is **2345** — open <http://localhost:2345>.

## Services and images

| Service | Image | Role |
|---|---|---|
| `frontend` | `handwriting-frontend:local` | Built locally. Nginx serves the pages and proxies `/api/`; host `2345` → container `80`. |
| `backend` | `handwriting-backend:local` | Built locally. FastAPI is bound to host `127.0.0.1:5005` only. |
| `watchtower` | `containrrr/watchtower:latest` | Optional `auto-update` profile; updates only containers carrying the enabled label. |

Both application services use `pull_policy: never` by default and do not pull upstream images.
`FRONTEND_IMAGE` and `BACKEND_IMAGE` override image tags; explicitly choose local building or
registry pulls for your deployment.

The backend is deliberately not exposed to the internet — outside traffic always goes through Nginx
first. To change the public port, edit the left-hand number in the frontend's `"2345:80"` mapping
in `docker-compose.yml`.

## Fonts

Fonts live in `ttf_files/` at the repository root, which Compose mounts at `/app/font_assets_host`:

```yaml
volumes:
  - ./ttf_files:/app/font_assets_host
  - ./logs:/app/logs
```

After adding fonts, **restart the backend container**:

```shell
docker compose restart backend
```

These fonts are what appears in the font dropdown.

!!! note "Why not mount straight into the font directory"
    `ttf_files` is mounted at an intermediate `_host` location rather than directly onto the directory
    where the backend reads fonts, and the backend syncs it on startup. Mounting it directly would let
    the host's empty directory shadow the fonts pre-packaged in the image.

## Logs

- Backend logs land in `./logs/` on the host.
- You can also read the container output directly:

  ```shell
  docker compose logs -f backend
  ```

## Updating local builds

Save any local changes before updating the custom branch and rebuilding:

```shell
git pull --ff-only origin custom-base
docker compose up -d --build frontend backend
```

## Optional: automatic registry image updates

Watchtower is useful only if you publish your own images. Set your image addresses and enable
the labels in `.env`, for example:

```dotenv
FRONTEND_IMAGE=your-account/handwriting-frontend:latest
BACKEND_IMAGE=your-account/handwriting-backend:latest
WATCHTOWER_ENABLE=true
```

Pull and start them explicitly:

```shell
docker compose pull --policy always frontend backend
docker compose --profile auto-update up -d --no-build frontend backend watchtower
```

Watchtower checks enabled containers every six hours. Private registries also require pull
credentials. It controls containers through the Docker socket; enable it only when automatic
updates are needed. Local builds do not depend on it.

## Stopping and cleaning up

```shell
docker compose down          # stop and remove the containers
docker compose down -v       # the same, plus remove Docker-managed volumes
```

!!! note "`-v` does not delete your fonts or logs"
    `ttf_files` and `logs` are **bind mounts** onto host directories, not Docker-managed volumes, so
    `-v` leaves them alone. This Compose file defines no named volumes. Manage host font and log
    directories separately when you need to remove those files.

## Reverse proxy and HTTPS

The Nginx in the Compose file serves plain HTTP only. To put it behind a domain with a certificate,
add another layer in front (Caddy, Traefik, or a host Nginx) and forward to `127.0.0.1:2345`.

!!! warning "Timeouts on large uploads"
    Rendering long text takes anywhere from tens of seconds to several minutes. If the proxy in
    front has too short a timeout, the request fails in the browser while the backend is still
    working. Raise the proxy's read timeout.
