# iron-control API

`iron-control` exposes a JSON API under `/api/v1`. Every resource endpoint requires API key authentication. The single exception is `POST /api/v1/proxy/sync`, which `iron-proxy` instances call with a proxy bearer token.

- [Authentication](#authentication)
- [Conventions](#conventions)
- [Errors](#errors)
- [Shared building blocks](#shared-building-blocks)
  - [Secret sources](#secret-sources)
  - [Request rules](#request-rules)
- [Static secrets](#static-secrets)
- [GCP auth secrets](#gcp-auth-secrets)
- [OAuth token secrets](#oauth-token-secrets)
- [PG DSN secrets](#pg-dsn-secrets)
- [Principals](#principals)
- [Roles](#roles)
- [Grants](#grants)
- [API keys](#api-keys)
- [Proxies](#proxies)
- [Proxy sync](#proxy-sync)

## Authentication

Send your API key as a bearer token:

```
Authorization: Bearer iak_<64 lowercase hex chars>
```

API keys have the form `iak_` followed by 64 lowercase hex characters (a 32-byte hex string). The plaintext token is shown only once: when the key is created (or, for the bootstrap key, logged once at startup). Tokens are stored as SHA-256 hashes and cannot be recovered.

A missing or invalid token returns `401`:

```json
{ "error": { "message": "invalid or missing API key" } }
```

`iron-proxy` instances authenticate to [`POST /api/v1/proxy/sync`](#proxy-sync) with their own token (`iprx_` followed by 64 lowercase hex characters), issued once when the proxy is created. An invalid proxy token returns `401` with `"invalid or missing proxy token"`.

## Conventions

- **Request bodies** wrap attributes in a top-level `data` object. A missing `data` key returns `400`.
- **Single-resource responses** wrap the resource in `data`.
- **List responses** include `data` (an array) and `meta` (pagination):

  ```json
  {
    "data": [ /* ... */ ],
    "meta": { "page": 1, "limit": 50, "total": 100, "total_pages": 2 }
  }
  ```

- **Pagination** uses the `page` (default `1`) and `limit` (default `50`, max `200`) query parameters. Values are clamped into range; a non-integer value returns `400`.
- **Namespaced list filtering** (static secrets, GCP auth secrets, OAuth token secrets, principals, roles) requires a `namespace` query parameter and accepts an optional `labels[key]=value` filter that matches by JSONB containment (all supplied pairs must be present). Label values must be scalars.
- **Object IDs** are prefixed by type: `ssr_` (static secret), `gas_` (GCP auth secret), `ots_` (OAuth token secret), `prn_` (principal), `role_` (role), `grant_` (grant), `ak_` (API key), `prx_` (proxy).
- **`namespace`** defaults to `"default"` when omitted on create. Once set, `namespace` and `foreign_id` are immutable.
- **`namespace` and `foreign_id`** must be URL-safe: only `A-Z a-z 0-9 - . _ ~`. `foreign_id` is optional and, when set, must be unique within its namespace. A `foreign_id` may not start with the resource's opaque-id prefix (e.g. `ssr_`), so it can never be mistaken for an OID.

### Upsert (`PUT` / `PATCH`)

For the resources with a `foreign_id` (static secrets, GCP auth secrets, OAuth token secrets, principals, roles), `PUT`/`PATCH /api/v1/<resource>/:id` is an **upsert**, and `:id` may be either an OID or a `foreign_id`:

- **`:id` is an OID** (it starts with the resource's prefix, e.g. `ssr_…`): updates that record. `404` if it does not exist — an OID is server-assigned, so it can't be created at a chosen value.
- **`:id` is anything else**: it is treated as a `foreign_id` within the body `namespace` (default `"default"`). The record is **updated if it exists, created if it does not**. Creation responds `201`; update responds `200`.

This makes provisioning idempotent: `PUT /api/v1/roles/infra` with `{"data":{"namespace":"acme", …}}` converges the `acme/infra` role whether or not it already exists, in one call. On the foreign-id form the namespace and foreign_id come from the URL/body, so omitting `foreign_id` from the body does not clear it.
- **`labels`** is an arbitrary string-keyed object (defaults to `{}`).
- **Timestamps** are ISO 8601 UTC.

## Errors

Errors return an `error` object with a `message` and, for validation failures, a `details` map of field name to messages:

```json
{
  "error": {
    "message": "validation failed",
    "details": {
      "base": ["must define one of inject_config or replace_config"],
      "name": ["can't be blank"]
    }
  }
}
```

| Status | Meaning                                                  |
| ------ | -------------------------------------------------------- |
| `200`  | OK                                                       |
| `201`  | Created                                                  |
| `204`  | No Content (successful `DELETE`)                         |
| `400`  | Bad Request (missing `data`, bad pagination/label query) |
| `401`  | Unauthorized (missing or invalid token)                 |
| `404`  | Not Found                                               |
| `422`  | Unprocessable Entity (validation failed)                |

## Shared building blocks

### Secret sources

A secret source describes where a credential value is resolved from. It appears as the `source` of a static secret, the `keyfile` of a GCP auth secret, and each entry in an OAuth token secret's `credentials` and `token_endpoint_headers` maps.

Shape:

```json
{
  "source_type": "env",
  "config": { "var": "GITHUB_TOKEN" }
}
```

`source_type` is required and immutable. `config` is an object whose allowed keys depend on the type. Unknown keys are rejected. Every type additionally accepts the optional keys `json_key` (extract one field from a JSON value) and `ttl` (cache lifetime).

| `source_type`         | Required `config` keys | Type-specific optional keys | Notes |
| --------------------- | ---------------------- | --------------------------- | ----- |
| `env`                 | `var`                  | —                           | Reads a process environment variable. |
| `aws_sm`              | `secret_id`            | `region`                    | AWS Secrets Manager. |
| `aws_ssm`             | `name`                 | `region`, `with_decryption` | AWS SSM Parameter Store. |
| `1password`           | `secret_ref`           | `token_env`                 | 1Password CLI / service account. |
| `1password_connect`   | `secret_ref`           | `host_env`, `token_env`     | 1Password Connect server. |
| `control_plane`       | — (no config keys)     | —                           | Value is supplied inline; see below. |
| `token_broker`        | `credential_id`        | `failure_ttl`               | External token broker. |

`control_plane` is special: the value is stored in iron-control itself. Supply it as a top-level `secret` field on the source (not inside `config`), and leave `config` empty:

```json
{
  "source_type": "control_plane",
  "secret": "the-actual-secret-value",
  "config": {}
}
```

The `secret` field is encrypted at rest, is write-only, and is never returned in any response. It is only permitted for `control_plane` sources; supplying it for any other type is a validation error, and omitting it for `control_plane` is also an error.

### Request rules

A rule scopes a credential to matching outbound requests. Rules appear as the `rules` array of static, GCP, and OAuth secrets.

```json
{
  "host": "api.github.com",
  "http_methods": ["GET", "POST"],
  "paths": ["/repos/*"]
}
```

| Field          | Type             | Notes |
| -------------- | ---------------- | ----- |
| `host`         | string           | Hostname to match. Exactly one of `host` or `cidr` is required. |
| `cidr`         | string           | CIDR block to match (e.g. `10.0.0.0/8`). Must be a valid CIDR. |
| `http_methods` | array of strings | Each must be one of `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `CONNECT`, or `*`. |
| `paths`        | array of strings | Each must start with `/`. Glob patterns such as `/repos/*` are allowed. |

Rules are positional: a `position` (0-based, assigned from array order) is returned in responses but is not part of the request. On update, the supplied `rules` array fully replaces the existing rules.

## Static secrets

A static secret injects or replaces a fixed credential value on matching requests. It has a single secret [source](#secret-sources) and a list of [rules](#request-rules), and defines exactly one of `inject_config` or `replace_config`.

### Attributes

| Field            | In requests | Notes |
| ---------------- | ----------- | ----- |
| `namespace`      | optional    | Defaults to `"default"`. Immutable after create. |
| `foreign_id`     | optional    | Unique per namespace. Immutable after create. |
| `name`           | optional    | |
| `description`    | optional    | |
| `labels`         | optional    | Object; defaults to `{}`. |
| `inject_config`  | conditional | Define exactly one of `inject_config` / `replace_config`. |
| `replace_config` | conditional | |
| `source`         | optional    | A [secret source](#secret-sources). Replaced wholesale on update. |
| `rules`          | optional    | Array of [rules](#request-rules). Replaced wholesale on update. |

`inject_config` — inject the value into a request header or query parameter:

```json
{
  "header": "Authorization",       // exactly one of header / query_param
  "query_param": "api_key",
  "formatter": "Bearer {{ .Value }}"  // optional template
}
```

`replace_config` — replace an occurrence of a known placeholder in proxied traffic:

```json
{
  "proxy_value": "__GITHUB_TOKEN__",   // required, non-empty
  "match_headers": ["X-Token"],         // optional array of strings
  "match_body": true,                    // optional booleans
  "match_path": false,
  "match_query": false,
  "require": true
}
```

Both config objects reject unknown keys.

### Create

`POST /api/v1/static_secrets`

```json
{
  "data": {
    "namespace": "default",
    "foreign_id": "github-token",
    "name": "GitHub Token",
    "description": "Repo access",
    "labels": { "team": "platform" },
    "inject_config": { "header": "Authorization", "formatter": "Bearer {{ .Value }}" },
    "source": { "source_type": "env", "config": { "var": "GITHUB_TOKEN" } },
    "rules": [
      { "host": "api.github.com", "http_methods": ["GET", "POST"], "paths": ["/repos/*"] }
    ]
  }
}
```

Returns `201` with the created resource. Response shape:

```json
{
  "data": {
    "id": "ssr_...",
    "namespace": "default",
    "foreign_id": "github-token",
    "name": "GitHub Token",
    "description": "Repo access",
    "labels": { "team": "platform" },
    "inject_config": { "header": "Authorization", "formatter": "Bearer {{ .Value }}" },
    "replace_config": null,
    "source": { "source_type": "env", "config": { "var": "GITHUB_TOKEN" } },
    "rules": [
      { "host": "api.github.com", "cidr": null, "position": 0, "http_methods": ["GET", "POST"], "paths": ["/repos/*"] }
    ],
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

The `source` in responses never includes a `control_plane` `secret` value.

### Other operations

| Method | Path | Notes |
| ------ | ---- | ----- |
| `GET`  | `/api/v1/static_secrets?namespace=default` | List. `namespace` required; `labels[k]=v` and pagination optional. |
| `GET`  | `/api/v1/static_secrets/:id` | Fetch one. `404` if missing. |
| `GET`  | `/api/v1/static_secrets/lookup/:namespace/:foreign_id` | Fetch by namespace + foreign id. `404` if missing. |
| `PUT`/`PATCH` | `/api/v1/static_secrets/:id` | [Upsert](#upsert-put--patch) by OID or `foreign_id`; same body as create. `source` and `rules` are replaced wholesale. |

## GCP auth secrets

A GCP auth secret mints short-lived GCP OAuth2 access tokens and injects them as `Authorization: Bearer`. It defines exactly one credential mechanism: either a `keyfile` [secret source](#secret-sources) (the service account JSON) or a `credentials_provider` (Application Default Credentials).

### Attributes

| Field                  | In requests | Notes |
| ---------------------- | ----------- | ----- |
| `namespace`            | optional    | Defaults to `"default"`. Immutable. |
| `foreign_id`           | optional    | Unique per namespace. Immutable. |
| `name`, `description`  | optional    | |
| `labels`               | optional    | |
| `scopes`               | required    | Non-empty array of non-empty strings (GCP OAuth scopes). |
| `keyfile`              | conditional | A [secret source](#secret-sources). Define exactly one of `keyfile` / `credentials_provider`. |
| `credentials_provider` | conditional | Object `{ "type": "workload_identity" }`. Only `workload_identity` is accepted. |
| `subject`              | optional    | Email for domain-wide delegation. Only allowed with `keyfile`, not `credentials_provider`. |
| `rules`               | optional    | Array of [rules](#request-rules). |

### Create

`POST /api/v1/gcp_auth_secrets`

```json
{
  "data": {
    "namespace": "default",
    "foreign_id": "sa-prod",
    "name": "Production Service Account",
    "scopes": ["https://www.googleapis.com/auth/cloud-platform"],
    "subject": "user@example.com",
    "keyfile": {
      "source_type": "aws_sm",
      "config": { "secret_id": "gcp-sa-keyfile", "region": "us-west-2" }
    },
    "rules": [ { "host": "googleapis.com", "http_methods": ["*"], "paths": ["/v1/*"] } ]
  }
}
```

Or with workload identity instead of a keyfile:

```json
{
  "data": {
    "namespace": "default",
    "scopes": ["https://www.googleapis.com/auth/cloud-platform"],
    "credentials_provider": { "type": "workload_identity" },
    "rules": [ { "host": "googleapis.com", "http_methods": ["*"], "paths": ["/v1/*"] } ]
  }
}
```

Returns `201`. Response shape:

```json
{
  "data": {
    "id": "gas_...",
    "namespace": "default",
    "foreign_id": "sa-prod",
    "name": "Production Service Account",
    "description": null,
    "labels": {},
    "credentials_provider": null,
    "subject": "user@example.com",
    "scopes": ["https://www.googleapis.com/auth/cloud-platform"],
    "keyfile": { "source_type": "aws_sm", "config": { "secret_id": "gcp-sa-keyfile", "region": "us-west-2" } },
    "rules": [ { "host": "googleapis.com", "cidr": null, "position": 0, "http_methods": ["*"], "paths": ["/v1/*"] } ],
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

### Other operations

| Method | Path | Notes |
| ------ | ---- | ----- |
| `GET`  | `/api/v1/gcp_auth_secrets?namespace=default` | List. |
| `GET`  | `/api/v1/gcp_auth_secrets/:id` | Fetch one. |
| `GET`  | `/api/v1/gcp_auth_secrets/lookup/:namespace/:foreign_id` | Fetch by namespace + foreign id. `404` if missing. |
| `PUT`/`PATCH` | `/api/v1/gcp_auth_secrets/:id` | [Upsert](#upsert-put--patch) by OID or `foreign_id`; same body as create. |

## OAuth token secrets

An OAuth token secret mints OAuth2 access tokens for a single grant and injects them as a bearer header. Each credential field and each token-endpoint header is its own [secret source](#secret-sources). At least one [rule](#request-rules) is required.

### Attributes

| Field                    | In requests | Notes |
| ------------------------ | ----------- | ----- |
| `namespace`              | optional    | Defaults to `"default"`. Immutable. |
| `foreign_id`             | optional    | Unique per namespace. Immutable. |
| `name`, `description`    | optional    | |
| `labels`                 | optional    | |
| `grant`                  | required    | One of `refresh_token`, `client_credentials`, `password`, `jwt_bearer`. |
| `token_endpoint`         | required    | Token endpoint URL. |
| `audience`               | conditional | Required when `grant` is `jwt_bearer`; otherwise optional. |
| `scopes`                 | optional    | Array of strings. |
| `header`                 | optional    | Header to inject the token into. |
| `value_prefix`           | optional    | Prefix for the injected value (e.g. `Bearer`). |
| `credentials`            | required    | Object mapping credential field → [secret source](#secret-sources). Required/allowed fields depend on `grant` (see below). |
| `token_endpoint_headers` | optional    | Object mapping header name → [secret source](#secret-sources). |
| `rules`                  | required    | At least one [rule](#request-rules). |

Credential fields per grant:

| `grant`              | Required credential fields           | Optional credential fields |
| -------------------- | ------------------------------------ | -------------------------- |
| `refresh_token`      | `refresh_token`, `client_id`         | `client_secret`            |
| `client_credentials` | `client_id`, `client_secret`         | —                          |
| `password`           | `username`, `password`, `client_id`  | `client_secret`            |
| `jwt_bearer`         | `issuer`, `subject`, `private_key`   | `private_key_id`           |

Supplying a credential field that the chosen grant does not use, or omitting a required one, is a validation error.

### Create

`POST /api/v1/oauth_token_secrets`

```json
{
  "data": {
    "namespace": "default",
    "foreign_id": "slack-app",
    "name": "Slack App OAuth",
    "grant": "refresh_token",
    "token_endpoint": "https://slack.com/api/oauth.v2.access",
    "scopes": ["chat:write"],
    "header": "Authorization",
    "value_prefix": "Bearer",
    "credentials": {
      "client_id": { "source_type": "aws_ssm", "config": { "name": "/slack/client_id" } },
      "client_secret": { "source_type": "aws_ssm", "config": { "name": "/slack/client_secret", "with_decryption": true } },
      "refresh_token": { "source_type": "control_plane", "secret": "xoxe-1-...", "config": {} }
    },
    "token_endpoint_headers": {
      "X-Auth": { "source_type": "env", "config": { "var": "SLACK_AUTH_HEADER" } }
    },
    "rules": [ { "host": "slack.com", "http_methods": ["POST"], "paths": ["/api/*"] } ]
  }
}
```

Returns `201`. Response shape (note that `credentials` and `token_endpoint_headers` echo each source as `{ source_type, config }`, never the underlying `secret`):

```json
{
  "data": {
    "id": "ots_...",
    "namespace": "default",
    "foreign_id": "slack-app",
    "name": "Slack App OAuth",
    "description": null,
    "labels": {},
    "grant": "refresh_token",
    "token_endpoint": "https://slack.com/api/oauth.v2.access",
    "audience": null,
    "scopes": ["chat:write"],
    "header": "Authorization",
    "value_prefix": "Bearer",
    "credentials": {
      "client_id": { "source_type": "aws_ssm", "config": { "name": "/slack/client_id" } },
      "client_secret": { "source_type": "aws_ssm", "config": { "name": "/slack/client_secret", "with_decryption": true } },
      "refresh_token": { "source_type": "control_plane", "config": {} }
    },
    "token_endpoint_headers": {
      "X-Auth": { "source_type": "env", "config": { "var": "SLACK_AUTH_HEADER" } }
    },
    "rules": [ { "host": "slack.com", "cidr": null, "position": 0, "http_methods": ["POST"], "paths": ["/api/*"] } ],
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

### Other operations

| Method | Path | Notes |
| ------ | ---- | ----- |
| `GET`  | `/api/v1/oauth_token_secrets?namespace=default` | List. |
| `GET`  | `/api/v1/oauth_token_secrets/:id` | Fetch one. |
| `GET`  | `/api/v1/oauth_token_secrets/lookup/:namespace/:foreign_id` | Fetch by namespace + foreign id. `404` if missing. |
| `PUT`/`PATCH` | `/api/v1/oauth_token_secrets/:id` | [Upsert](#upsert-put--patch) by OID or `foreign_id`; same body as create. |

## PG DSN secrets

A PG DSN secret is a Postgres upstream credential: a connection string (DSN) resolved from a single secret [source](#secret-sources), plus an optional `SET ROLE` for the upstream session. It is delivered to `iron-proxy` keyed by `foreign_id`, and a proxy-local listener binds to it by that key. Because the binding key must exist, `foreign_id` is **required** here (unlike the other secret types).

Listener and client knobs (bind address, client auth) are deliberately not modeled: they are proxy-host deployment concerns. There are no [request rules](#request-rules) either: a Postgres listener matches by port, not by request.

### Attributes

| Field         | In requests | Notes |
| ------------- | ----------- | ----- |
| `namespace`   | optional    | Defaults to `"default"`. Immutable after create. |
| `foreign_id`  | required    | Unique per namespace. Immutable after create. |
| `name`        | optional    | |
| `description` | optional    | |
| `labels`      | optional    | Object; defaults to `{}`. |
| `role`        | optional    | Upstream `SET ROLE` applied to the session. |
| `dsn`         | required    | A [secret source](#secret-sources) resolving to the connection string. Replaced wholesale on update. |

### Create

`POST /api/v1/pg_dsn_secrets`

```json
{
  "data": {
    "namespace": "default",
    "foreign_id": "analytics-pg",
    "name": "Analytics DB",
    "description": "Read-only reporting",
    "labels": { "team": "data" },
    "role": "readonly",
    "dsn": { "source_type": "env", "config": { "var": "PG_ANALYTICS_DSN" } }
  }
}
```

Returns `201` with the created resource. Response shape:

```json
{
  "data": {
    "id": "pgs_...",
    "namespace": "default",
    "foreign_id": "analytics-pg",
    "name": "Analytics DB",
    "description": "Read-only reporting",
    "labels": { "team": "data" },
    "role": "readonly",
    "dsn": { "source_type": "env", "config": { "var": "PG_ANALYTICS_DSN" } },
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

The `dsn` in responses never includes a `control_plane` `secret` value.

### Other operations

| Method | Path | Notes |
| ------ | ---- | ----- |
| `GET`  | `/api/v1/pg_dsn_secrets?namespace=default` | List. `namespace` required; `labels[k]=v` and pagination optional. |
| `GET`  | `/api/v1/pg_dsn_secrets/:id` | Fetch one. `404` if missing. |
| `GET`  | `/api/v1/pg_dsn_secrets/lookup/:namespace/:foreign_id` | Fetch by namespace + foreign id. `404` if missing. |
| `PUT`/`PATCH` | `/api/v1/pg_dsn_secrets/:id` | [Upsert](#upsert-put--patch) by OID or `foreign_id`; same body as create. `dsn` is replaced wholesale. |

## Principals

A principal is an identity (an application, service, or proxy owner) that can be granted secrets.

### Attributes

| Field        | In requests | Notes |
| ------------ | ----------- | ----- |
| `namespace`  | optional    | Defaults to `"default"`. Immutable. |
| `foreign_id` | optional    | Unique per namespace. Immutable. |
| `name`       | optional    | |
| `labels`     | optional    | |

### Operations

`POST /api/v1/principals`

```json
{ "data": { "namespace": "default", "foreign_id": "api-service", "name": "API Service", "labels": { "tier": "backend" } } }
```

Returns `201`:

```json
{
  "data": {
    "id": "prn_...",
    "namespace": "default",
    "foreign_id": "api-service",
    "name": "API Service",
    "labels": { "tier": "backend" },
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

| Method | Path | Notes |
| ------ | ---- | ----- |
| `GET`  | `/api/v1/principals?namespace=default` | List. |
| `GET`  | `/api/v1/principals/:id` | Fetch one by OID. To fetch by `foreign_id`, use the lookup route below. |
| `GET`  | `/api/v1/principals/lookup/:namespace/:foreign_id` | Fetch by namespace + foreign id. `404` if missing. |
| `GET`  | `/api/v1/principals/:id/effective_config` | [Effective config](#effective-config) the principal resolves to. `:id` is an OID. |
| `GET`  | `/api/v1/principals/lookup/:namespace/:foreign_id/effective_config` | [Effective config](#effective-config) by namespace + foreign id. `404` if missing. |
| `GET`  | `/api/v1/principals/:principal_id/grants` | [List the grants](#list-by-grantee) granted directly to the principal. |
| `PUT`/`PATCH` | `/api/v1/principals/:id` | [Upsert](#upsert-put--patch) by OID or `foreign_id`. Only `name` and `labels` are mutable on an existing record; `namespace`/`foreign_id` apply only when creating. |

See [Role assignments](#role-assignments) for attaching roles to a principal.

### Effective config

`GET /api/v1/principals/:id/effective_config`
`GET /api/v1/principals/lookup/:namespace/:foreign_id/effective_config`

The config a principal resolves to, in the same shape `iron-proxy` receives on [proxy sync](#proxy-sync), for operator inspection. The principal is addressed by OID (`:id`) or by an explicit namespace + `foreign_id` via the lookup route.

Unlike proxy sync, this endpoint never reveals live secrets and does no config-hash negotiation:

- Inline `control_plane` source values are redacted to `"[redacted]"`. Every other source type carries only a reference (an env var name, a `secret_id`, ...), so it passes through unchanged.
- There is no `config_hash`, `status`, or `principal_id` field, and no hash request param.
- The response carries a content-derived `ETag` for change detection and `Cache-Control: no-store`, so it is never served from a cache.

Returns `200`:

```json
{
  "data": {
    "id": "prn_...",
    "secrets": [
      {
        "source": { "type": "env", "var": "GITHUB_TOKEN" },
        "inject": { "header": "Authorization", "formatter": "Bearer {{ .Value }}" },
        "rules": [ { "host": "api.github.com", "methods": ["GET", "POST"], "paths": ["/repos/*"] } ]
      },
      {
        "source": { "type": "control_plane", "value": "[redacted]" },
        "replace": { "proxy_value": "__DB_PASSWORD__" },
        "rules": [ { "host": "db.internal", "methods": ["*"] } ]
      }
    ],
    "transforms": [],
    "postgres": []
  }
}
```

The `secrets`, `transforms`, and `postgres` arrays are assembled exactly as in [proxy sync](#proxy-sync), covering the principal's effective grants (direct plus any held via a [role](#roles)). See that section for the per-field details.

## Roles

A role is a reusable bundle of [grants](#grants). Principals are assigned roles, and a principal's effective secrets are the union of its own direct grants and the grants of every role it holds. Use a role to apply a common set of secrets (for example, shared infrastructure credentials) to many principals without re-granting each one.

Roles are namespaced. A principal may only be assigned roles in its own namespace.

### Attributes

| Field        | In requests | Notes |
| ------------ | ----------- | ----- |
| `namespace`  | optional    | Defaults to `"default"`. Immutable. |
| `foreign_id` | optional    | Unique per namespace. Immutable. Handy for idempotent provisioning. |
| `name`       | optional    | |
| `labels`     | optional    | |

### Operations

`POST /api/v1/roles`

```json
{ "data": { "namespace": "default", "foreign_id": "infra", "name": "Infra", "labels": { "kind": "shared" } } }
```

Returns `201`:

```json
{
  "data": {
    "id": "role_...",
    "namespace": "default",
    "foreign_id": "infra",
    "name": "Infra",
    "labels": { "kind": "shared" },
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

| Method   | Path | Notes |
| -------- | ---- | ----- |
| `GET`    | `/api/v1/roles?namespace=default` | List. `namespace` required; `labels[k]=v` and pagination optional. |
| `GET`    | `/api/v1/roles/:id` | Fetch one. |
| `GET`    | `/api/v1/roles/lookup/:namespace/:foreign_id` | Fetch by namespace + foreign id. `404` if missing. |
| `GET`    | `/api/v1/roles/:role_id/grants` | [List the grants](#list-by-grantee) attached to the role. |
| `PUT`/`PATCH` | `/api/v1/roles/:id` | [Upsert](#upsert-put--patch) by OID or `foreign_id`. Only `name` and `labels` are mutable on an existing record; `namespace`/`foreign_id` apply only when creating. |
| `DELETE` | `/api/v1/roles/:id` | Delete. Returns `204`. Cascades: the role's grants and its assignments are removed. |

### Role assignments

Assign and unassign roles on a principal. The assignment endpoints are nested under the principal; the role is identified by its OID.

`POST /api/v1/principals/:principal_id/roles`

```json
{ "data": { "role_id": "role_..." } }
```

Returns `201` with the assigned role's representation. Assigning a role from a different namespace, or one already assigned, returns `422`. An unknown principal or role returns `404`.

| Method   | Path | Notes |
| -------- | ---- | ----- |
| `GET`    | `/api/v1/principals/:principal_id/roles` | List the roles assigned to the principal. |
| `POST`   | `/api/v1/principals/:principal_id/roles` | Assign a role (`data: { role_id }`). |
| `DELETE` | `/api/v1/principals/:principal_id/roles/:id` | Unassign the role with OID `:id`. Returns `204`; `404` if not assigned. |

## Grants

A grant attaches exactly one secret to a **grantee** — either a principal or a [role](#roles). A principal receives a secret if it is granted directly or through any role the principal holds; its proxies then receive that secret through [proxy sync](#proxy-sync).

### Create

`POST /api/v1/grants` — supply exactly one grantee (`principal_id` **or** `role_id`) plus exactly one of `static_secret_id`, `gcp_auth_secret_id`, or `oauth_token_secret_id`:

```json
{ "data": { "principal_id": "prn_...", "static_secret_id": "ssr_..." } }
```

Or grant to a role:

```json
{ "data": { "role_id": "role_...", "static_secret_id": "ssr_..." } }
```

Returns `201`. The response includes the one grantee key and the one secret-type key that were set:

```json
{
  "data": {
    "id": "grant_...",
    "principal_id": "prn_...",
    "static_secret_id": "ssr_...",
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

Referencing a missing grantee or secret returns `404`. Supplying no grantee returns `422` with `"must reference one of principal_id, role_id"`; supplying no secret returns `422` with `"must reference one of static_secret_id, gcp_auth_secret_id, oauth_token_secret_id"`.

### List by grantee

List the grants attached to a single grantee. The endpoints are nested under the grantee, which is identified by its OID. The grantee is resolved first, so an unknown principal or role returns `404` rather than an empty list; a grantee with no grants returns `200` with an empty `data` array.

`GET /api/v1/principals/:principal_id/grants`

Returns `200`. Results use the standard [paginated](#conventions) envelope, and each entry has the same shape as `GET /api/v1/grants/:id`:

```json
{
  "data": [
    {
      "id": "grant_...",
      "principal_id": "prn_...",
      "static_secret_id": "ssr_...",
      "created_at": "2026-06-01T10:00:00Z",
      "updated_at": "2026-06-01T10:00:00Z"
    }
  ],
  "meta": { "page": 1, "limit": 50, "total": 1, "total_pages": 1 }
}
```

| Method | Path | Notes |
| ------ | ---- | ----- |
| `GET`  | `/api/v1/principals/:principal_id/grants` | List the grants granted directly to the principal. Paginated; `404` if the principal is unknown. |
| `GET`  | `/api/v1/roles/:role_id/grants` | List the grants attached to the role. Paginated; `404` if the role is unknown. |

The principal endpoint lists only the principal's **direct** grants, not those it resolves through roles. For everything a principal resolves to, see [effective config](#effective-config).

### Other operations

| Method   | Path | Notes |
| -------- | ---- | ----- |
| `GET`    | `/api/v1/grants/:id` | Fetch one. Response carries `principal_id` or `role_id` depending on the grantee. |
| `DELETE` | `/api/v1/grants/:id` | Revoke. Returns `204`. |

## API keys

API keys belong to the authenticated user and authenticate API requests. They are scoped to the current user: listing and fetching only ever return your own keys.

### Create

`POST /api/v1/api_keys`

```json
{ "data": { "name": "CI Runner" } }
```

Returns `201`. The plaintext `token` is included **only** in this create response: save it immediately.

```json
{
  "data": {
    "id": "ak_...",
    "name": "CI Runner",
    "token": "iak_0a1b2c3d...",
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

`name` is required; omitting it returns `422`.

### Other operations

| Method   | Path | Notes |
| -------- | ---- | ----- |
| `GET`    | `/api/v1/api_keys` | List your keys (paginated; no `namespace`). Tokens are never returned. |
| `GET`    | `/api/v1/api_keys/:id` | Fetch one (no token). |
| `DELETE` | `/api/v1/api_keys/:id` | Revoke (soft delete). Returns `204`. Revoking the key used for the current request returns `422` with `"cannot revoke the API key used for this request"`. |

## Proxies

A proxy represents an `iron-proxy` instance. It may be assigned a principal, in which case it receives config for the secrets granted to that principal. A proxy can also boot **unassigned**: it authenticates and syncs normally but receives an empty config until a principal is assigned. The principal can be assigned, swapped, or cleared at any time without reissuing the token.

A proxy's `status` is `assigned` when it currently holds a principal and `unassigned` otherwise. `principal_assigned_at` records when the current assignment was made (`null` while unassigned).

### Create

`POST /api/v1/proxies`

```json
{ "data": { "name": "Edge Proxy - US", "principal_id": "prn_..." } }
```

Returns `201`. The plaintext proxy `token` (`iprx_...`) is included **only** in this create response: save it immediately. The proxy uses it to authenticate to [proxy sync](#proxy-sync).

```json
{
  "data": {
    "id": "prx_...",
    "name": "Edge Proxy - US",
    "principal_id": "prn_...",
    "status": "assigned",
    "principal_assigned_at": "2026-06-01T10:00:00Z",
    "created_at": "2026-06-01T10:00:00Z",
    "updated_at": "2026-06-01T10:00:00Z"
  }
}
```

`name` is required. `principal_id` is optional: omit it to create an unassigned proxy (`status` is then `unassigned`, `principal_id` and `principal_assigned_at` are `null`). When supplied, a missing principal returns `404`.

### Assign, swap, or clear the principal

`PATCH /api/v1/proxies/:id` (or `PUT`)

```json
{ "data": { "principal_id": "prn_..." } }
```

Assigns the principal when the proxy is unassigned, or swaps it when already assigned. The token is unchanged; the proxy picks up the new config on its next [sync](#proxy-sync). Send `"principal_id": null` to unassign. Omitting `principal_id` leaves the assignment unchanged; `name` may also be updated. A missing principal returns `404`. Returns `200` with the updated proxy.

### Other operations

| Method   | Path | Notes |
| -------- | ---- | ----- |
| `GET`    | `/api/v1/proxies` | List. Optional `principal_id` filter; paginated. Tokens are never returned. |
| `GET`    | `/api/v1/proxies/:id` | Fetch one (no token). |
| `DELETE` | `/api/v1/proxies/:id` | Deregister. Returns `204`. |

Deleting a principal does not delete its proxies: they become unassigned and can be reassigned.

## Proxy sync

`POST /api/v1/proxy/sync`

Called by `iron-proxy` instances to fetch their configuration. **Authentication is the proxy bearer token** (`Authorization: Bearer iprx_...`), not an API key.

The proxy sends the config hash it currently holds. If it matches the freshly computed hash, the server returns only the hash so the proxy skips re-applying. Otherwise the full payload is returned.

Request:

```json
{ "config_hash": "sha256:0a1b2c3d..." }
```

`config_hash` is optional. It is an opaque, deterministic fingerprint of the config (the literal string `sha256:` followed by a hex digest); the proxy treats it as an ETag.

Response when the hash matches (no payload):

```json
{ "config_hash": "sha256:..." }
```

Response when the hash differs (full payload):

```json
{
  "config_hash": "sha256:...",
  "status": "assigned",
  "principal_id": "prn_...",
  "secrets": [
    {
      "source": { "type": "env", "var": "GITHUB_TOKEN" },
      "inject": { "header": "Authorization", "formatter": "Bearer {{ .Value }}" },
      "rules": [ { "host": "api.github.com", "methods": ["GET", "POST"], "paths": ["/repos/*"] } ]
    },
    {
      "source": { "type": "control_plane", "value": "s3cr3t" },
      "replace": { "proxy_value": "__DB_PASSWORD__" },
      "rules": [ { "host": "db.internal", "methods": ["*"] } ]
    }
  ],
  "transforms": [
    {
      "name": "gcp_auth",
      "config": {
        "keyfile": { "type": "aws_sm", "secret_id": "gcp-sa-keyfile", "region": "us-west-2" },
        "subject": "user@example.com",
        "scopes": ["https://www.googleapis.com/auth/cloud-platform"],
        "rules": [ { "host": "googleapis.com", "methods": ["*"], "paths": ["/v1/*"] } ]
      }
    },
    {
      "name": "oauth_token",
      "config": {
        "tokens": [
          {
            "grant": "refresh_token",
            "token_endpoint": "https://slack.com/api/oauth.v2.access",
            "client_id": { "type": "env", "var": "SLACK_CLIENT_ID" },
            "refresh_token": { "type": "control_plane", "value": "xoxe-1-..." },
            "scopes": ["chat:write"],
            "header": "Authorization",
            "value_prefix": "Bearer",
            "rules": [ { "host": "slack.com", "methods": ["POST"], "paths": ["/api/*"] } ]
          }
        ]
      }
    }
  ]
}
```

Notes on the proxy-sync payload, which differs from the REST representation:

- `status` is `assigned` or `unassigned`, and `principal_id` is the assigned principal (or `null`). An unassigned proxy gets a valid response with `status: "unassigned"` and empty `secrets`/`transforms`, which is distinct from an assigned proxy whose config is genuinely empty. These fields appear only in the full payload (not the hash-only response).
- The config hash incorporates the principal assignment, so assigning, swapping, or clearing the principal always changes the hash and the proxy refetches. A swap is a full replacement: the proxy should drop the previously delivered config rather than merge.
- The delivered config covers the proxy's principal's **effective grants**: secrets granted to the principal directly plus those granted to any [role](#roles) it holds. A secret reachable through more than one path appears once.
- `secrets` carries one entry per granted static secret that has a source (sourceless static secrets are skipped). `transforms` carries one `gcp_auth` transform per granted GCP auth secret and a single bundled `oauth_token` transform whose `config.tokens` lists every granted OAuth token secret.
- Each source is flattened: its `config` keys are merged up and tagged with `type` (the `source_type`). A `control_plane` source delivers its decrypted value inline as `value`.
- Rules use `methods` here, versus `http_methods` in the REST API. Blank rule fields are omitted.
- The top-level `rules`, `mcp`, and `ingest_token` fields the proxy also understands are intentionally omitted; iron-control has no models for them. Rules are carried per secret instead.
