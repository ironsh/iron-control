# iron-control

## First Boot

`iron-control` requires an authenticated user and API key before any API endpoint will respond. To bootstrap a fresh deployment without a console, set the following environment variables on startup:

| Variable                          | Required | Description                                                                                              |
| --------------------------------- | -------- | -------------------------------------------------------------------------------------------------------- |
| `IRON_BOOT_INITIAL_USER_EMAIL`    | yes      | Email for the initial user.                                                                              |
| `IRON_BOOT_INITIAL_USER_PASSWORD` | yes      | Password for the initial user (minimum 12 characters).                                                   |
| `IRON_BOOT_INITIAL_API_KEY`       | no       | Plaintext API key for the initial user. Must match `iak_` followed by 64 lowercase hex characters (a 32-byte hex string). If omitted, a token is generated and logged once at startup. |

Behavior:

- Bootstrap runs after Rails initialization on every boot, but is a no-op if any user already exists. It is safe to leave the env vars set across rolling restarts.
- If `IRON_BOOT_INITIAL_USER_EMAIL` is set without `IRON_BOOT_INITIAL_USER_PASSWORD`, the process exits with a clear error.
- Concurrent pods racing the first boot are serialized with a Postgres advisory lock; exactly one user is created.

When deploying to Kubernetes, source these values from a `Secret`, not from a `ConfigMap`.
