# Iron Control Helm Chart

Deploys Iron Control on Kubernetes with two workloads:

- **web**: the Puma web server (fronted by Thruster), with a Service, optional Ingress, and `/up` health probes.
- **jobs**: the Solid Queue supervisor (`bin/jobs`), which runs background workers and the recurring-job scheduler from `config/recurring.yml`.

Database migrations run as a Helm pre-install/pre-upgrade hook Job (`rails db:prepare`). Web pods bypass the image entrypoint's migration step, so rollouts do not race migrations.

The app uses Solid Queue, Solid Cache, and Solid Cable, so the only external dependency is PostgreSQL. No Redis is required.

## Prerequisites

- An external PostgreSQL server reachable from the cluster, with four databases owned by the `iron_control` role: `iron_control_production`, `iron_control_production_cache`, `iron_control_production_queue`, `iron_control_production_cable`. The migration Job creates them if the role has `CREATEDB`.
- The Iron Control container image in a registry the cluster can pull from.

## Installing

```sh
helm install iron-control charts/iron-control \
  --set image.repository=ghcr.io/ironsh/iron-control \
  --set image.tag=v1.2.3 \
  --set database.host=postgres.example.internal \
  --set secrets.existingSecret=iron-control-secrets
```

### Secrets

The app requires five secret environment variables. Provide them either via a pre-created Secret (recommended) or inline values.

With `secrets.existingSecret`, the named Secret must contain these keys:

| Key | Purpose |
|-----|---------|
| `RAILS_MASTER_KEY` | Rails credentials encryption |
| `IRON_CONTROL_DATABASE_PASSWORD` | Password for the `iron_control` Postgres role |
| `IRON_CONTROL_AR_ENCRYPTION_PRIMARY_KEY` | ActiveRecord encryption |
| `IRON_CONTROL_AR_ENCRYPTION_DETERMINISTIC_KEY` | ActiveRecord encryption |
| `IRON_CONTROL_AR_ENCRYPTION_KEY_DERIVATION_SALT` | ActiveRecord encryption |

Optional bootstrap keys (`IRON_CONTROL_INITIAL_USER_EMAIL`, `IRON_CONTROL_INITIAL_USER_PASSWORD`, `IRON_CONTROL_INITIAL_API_KEY`) can be added to the same Secret to create the first user on boot.

Without `existingSecret`, set all five `secrets.values.*` entries and the chart renders its own Secret. That Secret is hook-annotated so the migration Job can read it on first install. Two caveats: `helm uninstall` does not delete hook resources, and the secret values live in Helm release history. Prefer `existingSecret` in production (it also works with external-secrets operators).

## Values

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `""` (required) | Container image repository |
| `image.tag` | chart `appVersion` | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |
| `imagePullSecrets` | `[]` | Pull secrets for private registries |
| `database.host` | `""` (required) | Postgres hostname (`IRON_CONTROL_DB_HOST`) |
| `database.port` | `5432` | Postgres port (`IRON_CONTROL_DB_PORT`) |
| `secrets.existingSecret` | `""` | Name of a pre-created Secret (see above) |
| `secrets.values.*` | `""` | Inline secret values, used when `existingSecret` is unset |
| `bootstrap.*` | `""` | Optional first-boot user/API key (chart-managed Secret only) |
| `config.logLevel` | `info` | `RAILS_LOG_LEVEL` |
| `config.webConcurrency` | `1` | Puma worker processes (`WEB_CONCURRENCY`) |
| `config.railsMaxThreads` | `3` | Puma threads / AR pool (`RAILS_MAX_THREADS`) |
| `config.jobConcurrency` | `1` | Solid Queue worker processes (`IRON_CONTROL_JOB_CONCURRENCY`) |
| `extraEnv` / `extraEnvFrom` | `[]` | Extra env / envFrom for all workloads |
| `web.replicas` | `2` | Web pod count |
| `web.containerPort` | `8080` | Thruster listen port (`HTTP_PORT`); kept above 1024 because the image runs as a non-root user |
| `web.resources` | requests 250m/512Mi, limit 1Gi | Web resources |
| `web.{startup,readiness,liveness}Probe` | enabled | `/up` probes |
| `web.extraEnv` | `[]` | Extra env for web pods |
| `jobs.replicas` | `1` | Jobs pod count (Solid Queue locks; >1 is safe but rarely needed) |
| `jobs.resources` | requests 250m/512Mi, limit 1Gi | Jobs resources |
| `jobs.extraEnv` | `[]` | Extra env for jobs pods |
| `migrations.enabled` | `true` | Run `rails db:prepare` as a hook Job |
| `migrations.backoffLimit` | `1` | Job retries |
| `migrations.activeDeadlineSeconds` | `600` | Job timeout |
| `service.type` / `service.port` | `ClusterIP` / `80` | Web Service |
| `ingress.*` | disabled | Standard Ingress options |
| `serviceAccount.*` | created | ServiceAccount for web and jobs pods |
| `podSecurityContext` / `containerSecurityContext` | non-root, no caps | Security defaults |
| `web.podAnnotations`, `nodeSelector`, `tolerations`, `affinity` (also under `jobs`) | empty | Scheduling knobs |

## Design Notes

- **Migrations**: the image entrypoint runs `db:prepare` when started with the default server command. The web Deployment overrides `command` to skip that, so migrations only run in the hook Job. The migration Job runs before the release's regular resources exist, so it uses the namespace default ServiceAccount.
- **Jobs rollout strategy** is `Recreate` to avoid doubled recurring-job scheduler capacity during a rollout. Solid Queue's locking makes overlap safe, so this is for predictability, not correctness.
- **Do not set `IRON_CONTROL_SOLID_QUEUE_IN_PUMA`** via `extraEnv`. It would run the job supervisor inside every web pod in addition to the jobs Deployment.
- **No probes on jobs pods**: the Solid Queue supervisor restarts crashed workers, and if the supervisor itself exits the container dies and Kubernetes restarts it. Add an exec probe via your own tooling if needed.
- **Not included** (bring your own if needed): HorizontalPodAutoscaler (target the web Deployment; autoscaling jobs is rarely useful since the scheduler runs there), PodDisruptionBudget, NetworkPolicy, persistent storage (Active Storage local-disk uploads are not supported by this chart).

## Verifying a Render

```sh
helm lint charts/iron-control
helm template iron-control charts/iron-control \
  --set image.repository=ghcr.io/ironsh/iron-control \
  --set database.host=pg \
  --set secrets.existingSecret=iron-control-secrets
```
