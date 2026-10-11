# deploy-v2: what changed from deploy/, and why

`deploy-v2/` is `deploy/` plus the fixes found on 10 October 2026, when every one of the 30
capstone repositories (SE1 to SE6) was built and started with this kit (docker-compose on
Podman) and checked through the page. `deploy/` is left as it was. Each fix below was hit by
at least one team; each would have stopped teams in the hands-on session.

| What went wrong | Fix in deploy-v2 | Found on |
|---|---|---|
| Angular 21 builds waited forever for an answer to the CLI's usage-data question | `angular.Dockerfile` sets `CI=true` and `NG_CLI_ANALYTICS=false` | SE4-team2 |
| Older Angular builders write `dist/<app>`, not `dist/<app>/browser`; the image found no page | `angular.Dockerfile` serves `dist/*/browser` when it exists, else the folder holding `index.html` | SE1-team1 |
| Health checks called `localhost`, which resolves to IPv6 `::1` first; a service listening on `0.0.0.0` looked unhealthy and held up the stack | Every Dockerfile health check calls `127.0.0.1` | SE6-team1 |
| A Java service with a native library (ONNX Runtime) could not load it on Alpine (no glibc) | `java.Dockerfile` runtime is `eclipse-temurin:<version>-jre` (Ubuntu), not `-jre-alpine` | SE6-team4 |
| Encryption keys were made up as 48 hex characters; services expecting base64 of 32 bytes refused them | `apply.py` makes up `*_KEY` secrets as base64 of 32 bytes (`openssl rand -base64 32`) | SE2-team1 |
| `EMAIL_ENCRYPTION_KEY` was treated as a mail login to type in, because the name contains MAIL | Names with ENCRYPTION, LOOKUP, SIGNING or CIPHER are always generated | SE1-team5 |
| The frontend generates its API client with `openapi-generator` during the build, which needs Java | `angular.Dockerfile` adds Java when `package.json` uses openapi-generator | SE4-team3 |
| A bundle check compared the build against secret values a container build never has | `angular.Dockerfile` sets `ALLOW_MISSING_SECRET_VALUES=1` | SE5-team1 |
| Native Node modules (argon2) could not download their binary and had no compiler to fall back on | `node.Dockerfile` has python3, make and g++ in the build stage, prunes dev dependencies and copies `node_modules` into the runtime instead of installing twice | SE5-team1 |
| Spring's mail health check failed `/actuator/health` when mail was not set up, so the service looked down | `java.Dockerfile` sets `MANAGEMENT_HEALTH_MAIL_ENABLED=false` | SE3-Team2, SE6-team1 |
| Services that require SSL (as on RDS) could not connect to the local Postgres | Local Postgres is `postgres:17` (Debian) with SSL on, using its built-in certificate | SE5-team1 |
| On EKS every pod reads the Secret `app-secrets`, but nothing created it (CreateContainerConfigError) | `apply.py eks` writes `deploy/secrets.env` (git-ignored) and prints the `kubectl create secret` command; the Jenkinsfile stops with a clear message when the Secret is missing | kit review |

## Patterns in the teams' own code (not kit changes; fixed by the teams in the hands-on)

- A value read only from a file (`Config/application.yaml`, `config/services.json`, `.env.example`) with no
  environment fallback. Inside a container the file is not there. Read the environment first, the file second.
- The frontend build needs a file from the repository root (`Config/`, `Contracts/`, `.env`). Set
  `build_from: .` (or the folder that holds it) for the frontend in `project.yaml`.
- `/actuator/health` behind Spring Security: permit it, or the Docker health check and Kubernetes probes fail.
- Database SSL tied to `NODE_ENV=production`: right for RDS, wrong for the local Postgres container. Make it a setting.

## Found on Kubernetes (11 October 2026, local k3s)

Every team was then deployed with `apply.py eks` on a local k3s cluster, with only the AWS parts swapped
(local registry for ECR, nginx ingress for the ALB, local-path for gp3, a postgres:17 pod with SSL for RDS),
and checked through the ingress. Compose could not show these:

| What went wrong | Fix in deploy-v2 | Found on |
|---|---|---|
| `health: ''` (no page that answers 200) produced HTTP probes with an empty path; Kubernetes probed `/`, got 404 or 401 and restarted the pod forever | Those services get TCP probes (port open), and the ALB counts any HTTP answer (200-499) as healthy | SE1-team3 |
| Four executors are background workers with no web server, so no probe can ever pass | `health: none` writes no probes; the Docker health check is skipped, as for `health: ''` | SE2-team4, SE4-team4, SE5-team1, SE5-team4 |
| `axllent/mailpit:latest` is pulled again on every pod start; Docker Hub refused pulls during the run | Mailpit pinned to `v1.31.4` | SE4-team4, SE5-team3 |

Still open (not changed, because it changes the compose result for every team): the compose file hands every
service the kit's whole `.env`. A service that reads `FRONTEND_PORT` or `KAFKA_PORT` finds it under compose
but not on Kubernetes, where only the declared settings reach the pod (SE2-team1, SE3-Team1, SE3-team5,
SE5-team2, SE6-team3). Passing each service only its own settings would make compose fail the same way.

`testing/` holds the scripts used for both runs; see `INSIGHTS.md` for the results.
