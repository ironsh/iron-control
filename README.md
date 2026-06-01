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

`iron-control` exposes a JSON API under `/api/v1`. All resource endpoints require API key authentication; the single exception is `POST /api/v1/proxy/sync`, which is called by `iron-proxy` instances using a proxy bearer token.

### Authentication

Send your API key as a bearer token:

```
Authorization: Bearer iak_<64 hex chars>
```

API keys have the form `iak_` followed by 64 lowercase hex characters. The plaintext token is shown only once: when the key is created (or, for the bootstrap key, logged once at startup). Tokens are stored as SHA-256 hashes and cannot be recovered.

`iron-proxy` instances authenticate to `POST /api/v1/proxy/sync` with their own token (`iprx_` followed by 64 hex characters), issued once when the proxy is created.

A missing or invalid token returns `401`:

```json
{ "error": { "message": "invalid or missing API key" } }
```

### Conventions

- **Request bodies** wrap attributes in a top-level `data` object.
- **Single-resource responses** wrap the resource in `data`.
- **List responses** include `data` (an array) and `meta` (pagination):

  ```json
  {
    "data": [ /* ... */ ],
    "meta": { "page": 1, "limit": 50, "total": 100, "total_pages": 2 }
  }
  ```

- **Pagination** is controlled by `page` (default `1`) and `limit` (default `50`, max `200`) query parameters.
- **List filtering** for namespaced resources uses a required `namespace` query parameter and an optional `labels[key]=value` filter (JSONB containment).
- **Object IDs** are prefixed by type, e.g. `ssr_` (static secret), `gas_` (GCP auth secret), `ots_` (OAuth token secret), `prn_` (principal), `grant_` (grant), `ak_` (API key), `prx_` (proxy).
- **Timestamps** are ISO 8601 UTC.

### Errors

Errors return an `error` object with a `message` and, for validation failures, a `details` map:

```json
{
  "error": {
    "message": "validation failed",
    "details": { "name": ["can't be blank"] }
  }
}
```

| Status | Meaning                                             |
| ------ | --------------------------------------------------- |
| `200`  | OK                                                  |
| `201`  | Created                                             |
| `204`  | No Content (successful `DELETE`)                    |
| `400`  | Bad Request (invalid query params or malformed JSON)|
| `401`  | Unauthorized (missing or invalid token)             |
| `404`  | Not Found                                           |
| `422`  | Unprocessable Entity (validation failed)            |

### Endpoints

| Method   | Path                                          | Description                                             |
| -------- | --------------------------------------------- | ------------------------------------------------------ |
| `GET`    | `/api/v1/static_secrets`                      | List static secrets (`namespace` required).            |
| `GET`    | `/api/v1/static_secrets/:id`                  | Fetch a static secret.                                 |
| `POST`   | `/api/v1/static_secrets`                      | Create a static secret.                                |
| `PUT`    | `/api/v1/static_secrets/:id`                  | Update a static secret.                                |
| `GET`    | `/api/v1/gcp_auth_secrets`                    | List GCP auth secrets (`namespace` required).          |
| `GET`    | `/api/v1/gcp_auth_secrets/:id`                | Fetch a GCP auth secret.                               |
| `POST`   | `/api/v1/gcp_auth_secrets`                    | Create a GCP auth secret.                              |
| `PUT`    | `/api/v1/gcp_auth_secrets/:id`                | Update a GCP auth secret.                              |
| `GET`    | `/api/v1/oauth_token_secrets`                 | List OAuth token secrets (`namespace` required).       |
| `GET`    | `/api/v1/oauth_token_secrets/:id`             | Fetch an OAuth token secret.                           |
| `POST`   | `/api/v1/oauth_token_secrets`                 | Create an OAuth token secret.                          |
| `PUT`    | `/api/v1/oauth_token_secrets/:id`             | Update an OAuth token secret.                          |
| `GET`    | `/api/v1/principals`                          | List principals (`namespace` required).                |
| `GET`    | `/api/v1/principals/:id`                      | Fetch a principal.                                     |
| `GET`    | `/api/v1/principals/lookup/:namespace/:foreign_id` | Look up a principal by namespace and foreign id.  |
| `POST`   | `/api/v1/principals`                          | Create a principal.                                    |
| `PUT`    | `/api/v1/principals/:id`                      | Update a principal (`name`, `labels`).                 |
| `GET`    | `/api/v1/grants/:id`                          | Fetch a grant.                                         |
| `POST`   | `/api/v1/grants`                              | Grant a secret to a principal.                         |
| `DELETE` | `/api/v1/grants/:id`                          | Revoke a grant.                                        |
| `GET`    | `/api/v1/api_keys`                            | List the current user's API keys.                      |
| `GET`    | `/api/v1/api_keys/:id`                        | Fetch an API key (without token).                      |
| `POST`   | `/api/v1/api_keys`                            | Create an API key (returns the plaintext token once).  |
| `DELETE` | `/api/v1/api_keys/:id`                        | Revoke an API key.                                     |
| `GET`    | `/api/v1/proxies`                             | List proxies (filterable by `principal_id`).           |
| `GET`    | `/api/v1/proxies/:id`                         | Fetch a proxy (without token).                         |
| `POST`   | `/api/v1/proxies`                             | Register a proxy (returns the plaintext token once).   |
| `DELETE` | `/api/v1/proxies/:id`                         | Deregister a proxy.                                    |
| `POST`   | `/api/v1/proxy/sync`                          | Proxy config sync (proxy token auth, not API key).     |

### Resources

**Secrets** (`static_secrets`, `gcp_auth_secrets`, `oauth_token_secrets`) describe a credential, where its value comes from (a *secret source*), and the requests it applies to (a list of *rules*). They share these attributes: `namespace` (required, URL-safe), `foreign_id` (optional, URL-safe, unique per namespace), `name`, `description`, `labels`, and `rules`.

- A **secret source** is `{ "source_type": "...", "config": { ... } }`. Supported `source_type` values: `env`, `aws_sm`, `aws_ssm`, `1password`, `1password_connect`, `control_plane`, `token_broker`. Each accepts optional `json_key` and `ttl`.
- A **rule** is `{ "host": "...", "cidr": null, "http_methods": ["GET"], "paths": ["/repos/*"] }`. Exactly one of `host` or `cidr` is required; `http_methods` accepts standard methods or `*`; `paths` must start with `/` and may use globs.
- A **static secret** defines exactly one of `inject_config` (inject the value into a request `header` or `query_param`, with an optional `formatter`) or `replace_config` (replace a `proxy_value` found in traffic).
- A **GCP auth secret** defines exactly one of `keyfile` (a secret source for the service account JSON, with an optional `subject` for domain-wide delegation) or `credentials_provider` (`{ "type": "workload_identity" }`), plus a non-empty `scopes` array.
- An **OAuth token secret** sets a `grant` (`refresh_token`, `client_credentials`, `password`, or `jwt_bearer`), a `token_endpoint`, a `credentials` map (field name to secret source, with required fields per grant), and optional `scopes`, `audience`, `header`, `value_prefix`, and `token_endpoint_headers`.

**Principals** (`prn_`) are identities that can be granted secrets. Attributes: `namespace`, `foreign_id`, `name`, `labels`.

**Grants** (`grant_`) attach exactly one secret to a principal. Create with `principal_id` plus exactly one of `static_secret_id`, `gcp_auth_secret_id`, or `oauth_token_secret_id`.

**API keys** (`ak_`) belong to the current user. Creating one requires a `name` and returns the plaintext `token` once. You cannot revoke the key used to make the request.

**Proxies** (`prx_`) represent `iron-proxy` instances. Creating one requires a `name` and a `principal_id` and returns the plaintext proxy `token` once.

### Example

```bash
curl -s https://control.example.com/api/v1/principals \
  -H "Authorization: Bearer iak_..." \
  -H "Content-Type: application/json" \
  -d '{ "data": { "namespace": "default", "foreign_id": "api-service", "name": "API Service" } }'
```
