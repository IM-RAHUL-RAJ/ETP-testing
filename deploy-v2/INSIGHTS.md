# What running all 30 capstone repos taught us

Two runs over the latest code of every SE1 to SE6 team, on one machine:

- **10 October: docker-compose** (Podman) with this kit. Each stack was built, started with the team's SQL,
  and checked through the page: `/` must be 200, and `/auth/me` and `/api/v1/accounts/1` must be answered by
  the services (401 or 403 without a login), not by the page.
- **11 October: Kubernetes** (local k3s) with the kit's own `apply.py eks` output. Only the AWS parts were
  swapped: a local registry for ECR, nginx ingress for the ALB, local-path for gp3, a postgres:17 pod with SSL
  (loaded with the team's SQL) for RDS. Same checks, through the ingress, as the Jenkins smoke test does.

Scripts: `testing/` (see `testing/README.md`).

## Results

| | Teams |
|---|---|
| Compose: run with no change to the team's code | 9 |
| Compose: run after a small hands-on fix (settings, one file, a merge conflict) | 21 |
| Kubernetes: run as generated | 26 |
| Kubernetes: run once their config files are mounted from a ConfigMap | 4 (SE1-team1, SE2-team1, SE2-team2, SE4-team5) |
| Committed secrets (flagged, will be rotated; does not change the status) | 2 (SE4-team3, SE6-team3) |

No team is blocked. Every stack runs; what is left is hands-on work the teams do themselves.

ETP-testing's own `k8s-tester/` and `k8s-ingress/` (reference app, `origin/main` 459c34f) also work on the
local cluster: phase 1 with four Services (page 200, auth 200, trade API `/health` 200, API 401) and phase 2
behind one Ingress (page 200, `/auth/me` 401, `/api/v1/accounts/1` 401). The `k8s-tester` README is out of
date: it asks for a JFrog repository key and pull secret, but the manifests use ECR and need neither, and it
mentions a 5 GiB analytics volume that no manifest creates.

## Insights

1. **Configuration, not code, is what breaks.** About half the teams read a setting only from a file
   (`Config/application.yml`, `config/services.json`, `services.env`, `.env.example`) with no environment
   fallback. Inside a container the file is not there and the service stops at start. The one habit to teach:
   environment first, file second, and a default for every placeholder.

2. **Compose hides gaps that Kubernetes exposes.** Three kinds of problem passed compose and failed on
   Kubernetes:
   - Settings that only worked by accident: the kit's compose hands every service its whole `.env`, so code
     that read `FRONTEND_PORT` or `KAFKA_PORT` found them; on Kubernetes only declared settings reach the pod
     (SE2-team1, SE3-Team1, SE3-team5, SE5-team2, SE6-team3).
   - Health checks: a service with no page that answers 200 was restarted forever by HTTP probes (kit fixed:
     TCP probes for `health: ''`).
   - Background workers with no web server: no probe can pass (kit fixed: `health: none`).
   Test on Kubernetes before the session, not only with compose.

3. **"Running" is not "up".** A container in a restart loop shows as running between restarts, and the browser
   checks never reach the executor. Three executors (SE4-team3, SE5-team1, SE6-team3) were restarting through a
   compose run that looked green. The check now also fails on restart counts, Spring start failures and missing
   SQL paths. On Kubernetes the same problems show at once as CrashLoopBackOff.

4. **A silent skip is a failure.** SE5-team1's SQL folder had been renamed (`database/` to `databases/`); the
   loader printed "SQL path not found" and the run carried on as if the services made their own tables.
   Anything that is configured but not found should stop the run.

5. **The teams' own samples are not always right.** SE4-team3's `.env.example` sets a poll delay of 5s, which
   its own code rejects (minimum 44 s for its 8 symbols); SE5-team1's database URL needs
   `?currentSchema=trade,public`, which only its own compose file shows. Read the team's compose and samples,
   then check them against the code.

6. **External registries are a dependency.** Docker Hub rate limits and refusals broke builds and pod starts
   several times over the two nights. Pin image versions (mailpit was `:latest`), pull once into ECR, and
   expect the network to fail: the test workers now retry network failures automatically.

7. **One Ingress per stack, unique hosts for shared clusters.** Running two teams at once on one ingress
   controller needs a host name per team; on EKS each team's own ALB avoids this.

8. **Security findings come out of deployment tests too.** SE3-team5's API returns account data with no login
   (`anyRequest().permitAll()`). It is on their list; status is not affected.

## What the session should cover

- Environment variables with defaults, and the ConfigMap/Secret split on EKS.
- Health endpoints: what to probe, and what to do when there is nothing to probe.
- Reading logs for the first `Caused by` / `Could not resolve placeholder`.
- `kubectl get pods` restarts and CrashLoopBackOff, not just "Running".
