# iron-control

## First Boot

`iron-control` requires an authenticated user and API key before any API endpoint will respond. To bootstrap a fresh deployment without a console, set the following environment variables on startup:

| Variable                          | Required | Description                                                                                              |
| --------------------------------- | -------- | -------------------------------------------------------------------------------------------------------- |
| `IRON_CONTROL_INITIAL_USER_EMAIL`    | yes      | Email for the initial user.                                                                              |
| `IRON_CONTROL_INITIAL_USER_PASSWORD` | yes      | Password for the initial user (minimum 12 characters).                                                   |
| `IRON_CONTROL_INITIAL_API_KEY`       | no       | Plaintext API key for the initial user. Must match `iak_` followed by 64 lowercase hex characters (a 32-byte hex string). If omitted, a token is generated and logged once at startup. |

Behavior:

- Bootstrap runs after Rails initialization on every boot, but is a no-op if any user already exists. It is safe to leave the env vars set across rolling restarts.
- If `IRON_CONTROL_INITIAL_USER_EMAIL` is set without `IRON_CONTROL_INITIAL_USER_PASSWORD`, the process exits with a clear error.
- Concurrent pods racing the first boot are serialized with a Postgres advisory lock; exactly one user is created.

When deploying to Kubernetes, source these values from a `Secret`, not from a `ConfigMap`.

## Encryption Keys

`iron-control` uses ActiveRecord encryption to protect secrets stored in the control plane (for example, the `control_plane` secret source type). The following environment variables configure the encryption keys:

| Variable                                 | Required           | Description                                  |
| ---------------------------------------- | ------------------ | -------------------------------------------- |
| `IRON_CONTROL_AR_ENCRYPTION_PRIMARY_KEY`         | yes (in production) | Primary key used for non-deterministic encryption. |
| `IRON_CONTROL_AR_ENCRYPTION_DETERMINISTIC_KEY`   | yes (in production) | Key used for deterministic encryption.       |
| `IRON_CONTROL_AR_ENCRYPTION_KEY_DERIVATION_SALT` | yes (in production) | Salt used to derive per-attribute keys.      |

Generate suitable values with `bin/rails db:encryption:init` and store them in your secret manager. In production, the process refuses to boot if any of the three are missing. In `development` and `test`, fixed fallback values are used so the suite runs without configuration.

Rotating any of these keys makes previously encrypted data unreadable. Treat them as long-lived secrets and back them up alongside other production credentials.

## API

`iron-control` exposes a JSON API under `/api/v1`. All resource endpoints authenticate with an API key sent as a bearer token (`Authorization: Bearer iak_...`); the one exception is `POST /api/v1/proxy/sync`, which `iron-proxy` instances call with a proxy bearer token.

See [docs/API.md](docs/API.md) for the full reference: authentication, request/response conventions, pagination, error formats, the shared secret-source and request-rule shapes, and detailed payloads for every endpoint (static secrets, GCP auth secrets, OAuth token secrets, principals, grants, API keys, proxies, and proxy sync).
