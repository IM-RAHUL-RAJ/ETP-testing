# deploy/: one folder that builds and runs any capstone-shaped project

A frontend, an auth service, a trade API and an executor, with Postgres and
Kafka. You copy this folder into the project, write two small files, and run
one command. Nothing is edited by hand in `.env`: `apply.py` writes it and makes
up the passwords and secrets.

```bash
cp -r deploy <your-project>/deploy
cd <your-project>/deploy
# edit config/project.yaml (what your code needs) and config/application.yaml (addresses)
python3 config/apply.py                 # writes .env, build.env and the per-service env files
docker-compose up -d --build            # Postgres, Kafka, Mailpit and the four services
```

Only API keys you must type yourself (for example `FAUXNANCE_API_KEY`) are left
empty in `.env`; everything else is generated.

| File | What it is |
|---|---|
| `config/project.yaml` | Folders, types, health paths, SQL to load, the settings your code reads, the names of the secrets. Written once per project. |
| `config/application.yaml` | Addresses and ports for the current phase (`local`, `docker`, `eks`). |
| `config/apply.py` | Turns the two files above into `.env` for docker-compose or `k8s/` for Kubernetes. |
| `docker/*.Dockerfile` | Java (Maven), Node, Angular (served by nginx) and Python images. |
| `docker/postgres-init.sh` | Loads the SQL listed under `sql:` in version order. |
| `k8s-templates/`, `Jenkinsfile` | The Kubernetes files and the pipeline. |
| `examples/` | A working config to copy from. |
| `CHANGES.md` | What this folder adds to `CD2026-files/deploy`, and why. |

With `proxy: true` the frontend container forwards `/auth` and `/api` to the
services, so the page calls its own address and needs no API URL baked into the
build. This is the most portable setup: the same image works on a laptop, an EC2
box and EKS.

See `examples/README.md` to choose a starting point.
