# uptime-kuma

Self-maintaining deploy repo for [Uptime Kuma](https://github.com/louislam/uptime-kuma)
on a Docker-Compose platform (e.g. Coolify), behind an Authentik single sign-on proxy.

This is a *packaging/deploy* repo — no application code. The platform deploys straight
from this repo; two GitHub Actions keep the versions current.

## Architecture

```
kuma.example.com ──> ingress ──> outpost:9000 ──> uptime-kuma:3001
                                 (published)      (internal only)
                                                        │
                                                        ▼
                                   MariaDB = separate managed resource
```

- **`outpost`** (Authentik proxy outpost) is the only published container and the single
  way in. Uptime Kuma has no domain of its own.
- The **database is not part of the compose file**. It runs as a separate, managed MariaDB
  resource and is only referenced via `MARIADB_SERVER`, so all data survives every
  redeploy. Take backups on the database resource itself.

### Why MariaDB and not PostgreSQL

Uptime Kuma 2.x speaks `sqlite` and `mariadb` only. PostgreSQL is not supported, so this
stack pairs with a managed **MariaDB** resource.

### Why a proxy outpost and not OIDC

Uptime Kuma has no built-in SSO — OIDC has been an open feature request since 2021
([#553](https://github.com/louislam/uptime-kuma/issues/553)). The supported route is a
proxy in front of it with Kuma's own login switched off.

There is **no environment variable** for that. `UPTIME_KUMA_DISABLE_AUTH` circulates on
forums but does not exist in the source; disabling auth is a one-off UI action after the
first admin account is created. Note that it also disables Kuma's API keys — anything
using the REST API (a Home Assistant integration, say) stops working. Push monitors
(`/api/push/<token>`) keep working.

## Layout

| Path | Purpose |
|------|---------|
| `compose.yml` | The whole stack: Uptime Kuma + Authentik proxy outpost. |
| `.upstream-ref` | The pinned Uptime Kuma version (single source of truth). |
| `.authentik-ref` | The pinned Authentik proxy version. |
| `.env.example` | Every variable the platform must supply. |
| `ci/outpost-check.sh` | The gate on the Authentik proxy pin. |
| `.github/workflows/upstream-update.yml` | Daily Uptime Kuma version bump → auto-redeploy. |
| `.github/workflows/authentik-sync.yml` | Daily Authentik proxy version bump → auto-redeploy. |
| `.github/workflows/validate.yml` | Compose lint + smoke test on every push/PR. |
| `.github/dependabot.yml` | Monthly bumps for the Actions. |

## Self-maintenance

1. `upstream-update.yml` runs daily (06:00 UTC), reads the latest stable release of
   `louislam/uptime-kuma` and — if newer — bumps the pinned tag in `compose.yml` plus
   `.upstream-ref`, commits and pushes. Major-version jumps are reported as a warning
   and *not* applied: 2.0 changed the database layer, and that deserves a human.
2. `authentik-sync.yml` runs daily (07:00 UTC), takes the newest stable Authentik
   release and bumps `AUTHENTIK_TAG` plus `.authentik-ref`. Before merging it checks that
   the tag exists and that the health check command is still in the image. It sorts the
   release tags itself rather than trusting "latest": Authentik ships patches on older
   minors after a new minor is out, so that pointer regularly moves backwards.
3. Both push to `main`, and the push triggers an automatic redeploy on the platform
   (git webhook).
4. `validate.yml` lints the compose file, runs `ci/outpost-check.sh`, and boots Uptime
   Kuma against a throwaway MariaDB — asserting both that the schema was actually created
   (the setup wizard answers HTTP 200 even when the database is unreachable) and that the
   health check command exists inside the image. On failure it opens a `ci-failure` issue.

Force either one manually: **Actions → the workflow → Run workflow**. `authentik-sync`
takes an optional version, to pin an exact release instead of the newest one.

## Platform setup (Coolify)

- Project → destination on the target server:
  - **MariaDB** as a Coolify-managed database (with scheduled backups)
  - this repo as a **Docker Compose** app, compose path `/compose.yml`
- Turn on **Connect to Predefined Network**. Without it the stack sits in its own isolated
  network and `MARIADB_SERVER` will not resolve.
- Domain: set it on **`outpost`**, port 9000. If the origin sits behind a tunnel or a CDN
  that terminates TLS, set it as `http://kuma.example.com:9000` — Let's Encrypt's HTTP-01
  challenge cannot validate an origin with no public ports, and the `X-Forwarded-Proto`
  label in `compose.yml` is what tells the outpost that the browser is on https anyway.
- Set the variables from `.env.example` in the platform's env editor. Never tick Coolify's
  **"Shown once"** on any of them: it is a one-way lock that masks the value as `null` in
  both the UI and the API, and the only write that unlocks it wipes the value.

## Authentik

One **Proxy Provider** (mode *Proxy*), one **Application**, one **proxy outpost**. The
outpost token goes into the platform environment as `AUTHENTIK_OUTPOST_TOKEN` (not in this
repo).

- External host: `https://kuma.example.com`
- Internal host: `http://uptime-kuma:3001`
- Unauthenticated Paths — keeps published status pages, badges and push endpoints outside
  the gate while the dashboard stays behind it:

```
^/status(/.*)?$
^/status-page$
^/assets/.*
^/api/push/.*
^/api/badge/.*
^/api/status-page/.*
^/icon.svg$
^/upload/.*
```

## First run

Order matters here — Kuma's auth can only be switched off once an account exists.

1. Deploy, open the domain, sign in through Authentik. Kuma's setup wizard appears (it
   skips the database screen because the `UPTIME_KUMA_DB_*` variables are set).
2. Create the admin account.
3. **Settings → Reverse Proxy → Trust Proxy: Yes**, otherwise every visit is logged with
   the reverse proxy's IP.
4. **Settings → Security → Advanced → Disable Auth**, confirm with the password. Authentik
   is now the only gatekeeper.
5. **Settings → About → Globalping API token** — a free account doubles the hourly test
   budget from 250 to 500 and bills it to the account instead of the outgoing IP.
6. **Settings → Notifications** — add a notification channel and tick "Default enabled" so
   new monitors use it straight away.

## Rollback

Roll the image tag back in `compose.yml` (and in `.upstream-ref` / `.authentik-ref`, or
the next scheduled run will undo it) and redeploy. Holding a single deployment back
without touching the repo works too: set `UPTIME_KUMA_TAG` or `AUTHENTIK_TAG` in the
platform's env editor, which overrides the default in `compose.yml`.

The database is a separate resource and is left untouched, so the data is safe — but note
that Uptime Kuma runs forward-only schema migrations, so rolling back *across* a release
that migrated the schema needs a database restore too.
