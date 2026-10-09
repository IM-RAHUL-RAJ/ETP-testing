# What this `deploy/` adds to CD2026-files/deploy

`deploy/` is `CD2026-files/deploy` with sixteen changes, found while fitting
thirty capstone repositories (six classes, five teams each) to it. A project that uses none of the new options
gets the same result as before, except the frontend reverse proxy, which is off
unless `proxy: true` is set.

Each change was built and run with Podman against real repositories on
9 October 2026. `examples/` holds a verified config to copy from.

## 1. The runnable jar is picked, not guessed (`docker/java.Dockerfile`)

Before: `COPY target/*.jar /app/app.jar`. With two jars in `target/` (a plain
jar plus `*-exec.jar`, or `*-plain.jar` from Gradle-style setups), Docker
BuildKit stops the build; Podman/Buildah copies one of them. For one
order-service it copied the 443 KB library jar and the container exited with
`no main manifest attribute, in /app/app.jar`.

After: the build stage copies the jar that contains `BOOT-INF/`.

## 2. A service can compile against another one (`java.Dockerfile`, `apply.py`, compose, Jenkinsfile)

Before: every service was built from its own folder, so a service whose
`pom.xml` depends on another service of the same repository could not compile.

After: two optional keys per folder in `project.yaml`:

```yaml
  executor:
    path: services/executor-service
    type: java
    build_from: services          # build context, relative to the project
    prebuild: [order-service]     # folders in it to `mvn install` first
```

`apply.py` writes `<ROLE>_CONTEXT`, `<ROLE>_MODULE` and `<ROLE>_PREBUILD`;
docker-compose and the Jenkinsfile pass them to the build. Without the keys,
context is the service's folder and nothing is installed first, as before.
Maven's download cache is a BuildKit cache mount, so repeated builds stay fast.

Seen in: an executor-service that depends on the order-service jar.

## 3. SQL with a schema, and psql variables (`docker/postgres-init.sh`, `apply.py`, compose)

Before: every file ran with the default search_path and no psql variables.

After, in `project.yaml`:

```yaml
sql:
  - {path: Databases/Postgres/migrations, schema: trade}   # SET search_path TO trade, public
  - Databases/Postgres/we_trade_creds/migrations           # unchanged form still works
sql_vars:                                                  # :name in the SQL
  db_api_user: trade_api_user
  db_api_password: $POSTGRES_API_PASSWORD                  # read from a secret in .env
```

Seen in: trade migrations that name no schema (a project script set it per file), and
migrations that use `:db_api_user` and similar variables.

## 4. The frontend can proxy the APIs (`docker/angular.Dockerfile`, `apply.py`)

Before: the browser called the auth service and the trade API on their own
ports. That needs three open ports, a CORS list in every service that matches
the page's address, and a frontend that learns the API addresses at runtime
(the `app-config.js` edit). Three of five repositories had CORS origins
fixed to `localhost:4200` in code.

After: `proxy: true` in `project.yaml`. nginx in the frontend container sends
each path in `kubernetes.routes` to its service (`PROXY_ROUTES`, written by
`apply.py`), WebSockets included, and `AUTH_URL`/`BACKEND_URL` are left empty.
The page calls its own address, exactly as it does behind the EKS load
balancer, so:

- only the frontend's port is opened on EC2;
- requests are same-origin, so CORS lists in the services no longer matter;
- an app that calls relative paths (`/auth/login`, `/api/v1/orders`) works
  with no frontend edit at all.

The proxy forwards `Host` with its port (`$http_host`), so Spring sees the same
origin the browser sent and does not reject the request as cross-origin.

## 5. Jenkinsfile builds from the same context

The image build passes `--build-arg MODULE`/`PREBUILD` and uses
`<ROLE>_CONTEXT` as the build context, matching docker-compose.

## 6. The Java image's folder is writable (`java.Dockerfile`)

Before: `/app` belonged to root and the service ran as `app`, so a service that
logs to a relative `logs/` folder (Logback `RollingFileAppender`) stopped at
start: `Failed to create parent directories for [/app/logs/trade-api.log]`.

After: `/app` belongs to `app`. Seen in an order-service that writes under `/app`.

## 7. SQL files in version order (`docker/postgres-init.sh`)

Before: `sort`, so `V10_multi_exchange.sql` ran before `V2_add_settlement_columns.sql`.
After: `sort -V` (version order). Same result for zero-padded names like `001_`.

## 8. Settings for one service only (`apply.py`, compose, `k8s-templates/app.yaml`)

Before: every service got the same settings. Two services that read the same
name in different formats (a JDBC `DATABASE_URL` for Java, a `postgresql://`
one for Node) could not both be served.

After: `folders.<role>.settings` in `project.yaml`. docker-compose reads
`deploy/<service>.env` after `.env`; on EKS each Deployment reads the
ConfigMap `<service>-config` after the shared ones, so the service's own value wins.

## 9. Proxy routes that drop a prefix (`angular.Dockerfile`, `apply.py`)

Some pages call `/trade-api/...` and expect the server in front to drop the
prefix. `strip_routes: {/trade-api: order}` sends `/trade-api/x` to the order
service as `/x`. On EKS these paths reach the frontend pod (the Ingress sends
everything else there), whose nginx forwards them the same way.

## 10. Angular SSR builds (`angular.Dockerfile`)

An SSR project's browser output has `index.csr.html` and no `index.html`; the
image now serves the former as the latter.

## 11. Secrets made up by `apply.py` (`apply.py`)

Passwords, signing keys and internal tokens left empty in `.env` are filled
with random values on the first run and kept. `derived_secrets` builds values
such as `DATABASE_URL` from the others on every run. Only keys for outside
services (Fauxnance, Gemini, mail logins) are typed in, and the application
runs without them, with those features off.

## 12. Start command per service (`folders.<role>.start`)

The Node image always ran `node dist/main.js`; a project whose build writes
`dist/src/main.js` (a `tsconfig` that includes `test/`) did not start.
`start: node dist/src/main.js` is passed as `START_CMD` (Node) or `APP_ENTRY` (Python).

## 13. Plain Java services (`folders.<role>.main_class`)

A service with no Spring Boot builds a jar with no `Main-Class` and no
dependencies inside. With `main_class: org.example.Main` the image keeps that
jar plus its runtime dependencies (`mvn dependency:copy-dependencies`) and
starts `java -cp app.jar:lib/* org.example.Main`.
Seen in: a plain-Java executor-service.

## 14. Flyway-named SQL runs in one transaction (`docker/postgres-init.sh`)

Files named like Flyway migrations (`V4__instrument_prices.sql`) were written
for Flyway, which runs each in a transaction; `LOCK TABLE` outside one fails.
The loader now runs those files with `--single-transaction`.

## 15. Kafka on any port (`kafka.port`; `docker-compose.yml`, `apply.py`, `k8s-templates/kafka.yaml`)

Before: the broker's in-network listener was fixed at 29092 and the host listener at 9092,
so `kafka.port: 9092` made every service dial `kafka:9092`, which advertises `localhost`.

After: `apply.py` writes `KAFKA_PORT` (the port on the network, from `kafka.port`) and
`KAFKA_HOST_PORT` (9092, or 19092 when `kafka.port` is 9092 so the two do not clash).
Compose and the Kubernetes Kafka file use them. With the default 29092 nothing changes.
Checked with `kafka.port: 9092`: topics created, both Java services connect.

## 16. Java services keep off port 8080 (`java.Dockerfile`)

Jenkins listens on 8080 on the build box. The Java image's default `APP_PORT` is now
8081 (compose always passes the configured port, so this only matters when none is given).
Configs that put the trade API on 8080 now use 8081 for it and 8082 for the executor.

## Not changed

- The Kubernetes templates. With `proxy: true` the ConfigMap also carries
  `PROXY_ROUTES`; on EKS the Ingress already routes those paths, so the proxy
  in the frontend pod is simply unused there.
