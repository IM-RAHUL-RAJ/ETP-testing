# Test scripts used for INSIGHTS.md

Written for one Linux machine with rootless Podman, docker-compose v2 pointed at the Podman socket, and
k3s. They expect this layout next to them: `teams.tsv` (id, branch, repo), `trees/<id>/` (an export of
each team's branch), the handover kit at `../handover/kit/deploy`, and each team's
`../handover/teams/<id>/project.yaml`. Adjust the paths at the top of each script for another layout.

| Script | What it does |
|---|---|
| `runall.sh <ids>` | Compose run per team: apply.py docker, build the four images, start, check through the page, collect logs, tear down. Fails on restarts, Spring start failures and missing SQL paths, not only on stopped containers. `SLOT=2` moves host ports so two can run at once. |
| `worker.sh <slot>` | Takes team ids from `queue.txt` and runs `runall.sh`; retries a team twice when a build fails on the network. |
| `k8s-setup.sh` | Once: a registry on NodePort 30500 and ingress-nginx on NodePort 30080 in k3s. |
| `k8s-test.sh <ids>` | Kubernetes run per team with `apply.py eks`, AWS parts swapped for local ones (see INSIGHTS.md), checked through the ingress. `K8SQUEUE=1` shares `k8squeue.txt` between workers; two teams use the cluster at a time, each with its own Ingress host. `K8SCONFIG=1` mounts the files from `overrides/<id>.yml` as ConfigMaps. |
| `k8s-configmount.py` | Turns a compose override (mounted config files) into ConfigMaps plus a kustomize patch. |
| `etp-k8s-test.sh` | ETP-testing's own `k8s-tester/` (phase 1) and `k8s-ingress/` (phase 2) on k3s, from `origin/main`. |

Test secrets are filled with throwaway values; no real key is used or stored.
