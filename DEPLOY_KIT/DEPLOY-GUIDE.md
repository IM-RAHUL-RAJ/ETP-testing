# ETP Trading Platform Deployment Guide

Written for `chennai-capstone-SE1-team3/Application`. Every step is a command you type yourself, followed by **Why:**, which explains the reason for it. There are no helper scripts. The kit holds only Dockerfiles, `docker-compose.yaml`, `.env.example` and the YAML in `k8s/`.

**No application code changes are needed for team3.** Everything is set through `.env` (EC2) or `k8s/base/config.env`, `k8s/secrets.env` and `k8s/overlays/*/urls.env` (Kubernetes).

The order of the work: EC2 build box, then Docker Compose, then RDS, then ECR, then EKS with four load balancers, then EKS with one ALB, then S3 + CloudFront, then Route 53 + ACM.

---

## 0. What is in the kit

| Path | What it is |
|---|---|
| `Frontend/Dockerfile` | Builds Angular, serves it with nginx. The API URLs are written into the page when the container **starts**, so one image works everywhere. |
| `Services/auth-service/Dockerfile` | Node/Nest image. Runs as non-root user 1000. |
| `Services/order-service/Dockerfile` | Spring Boot image (Maven or Gradle). Runs as non-root user 10001. |
| `Services/executor-service/Dockerfile` | Identical to the order-service one. |
| `ETL Layer/Dockerfile` | Python worker (optional). |
| `docker-variants/java-python.Dockerfile` | For a Java service that also runs Python (the older ETP executor). |
| `*/Dockerfile.999`, `docker-compose.9999.yml`, `.env.example.999` | The team's original files, renamed so nothing picks them up. |
| `docker-compose.yaml` + `.env.example` | The whole stack on one EC2 box. |
| `k8s/base/` | Kafka, the topics Job, the four apps, `config.env`, `secrets.env.example`. |
| `k8s/overlays/four-lb/` | Stage 1: a load balancer per public service. |
| `k8s/overlays/ingress/` | Stage 2: one ALB with an Ingress. |
| `k8s/optional/postgres/` | Postgres inside the cluster, for when there is no RDS. |
| `k8s/cluster.example.yaml` | eksctl cluster definition. |

Ports: frontend 4200 on EC2 (80 inside the container), auth 3000, order 8081, executor 8082 (internal), Postgres 5432, Kafka 29092 (internal).

API paths: auth `/auth/*` (health check `/docs/json`); order `/api/v1/*` (health check `/health`); the executor has no HTTP API, so it is checked by TCP port.

---

## 1. Before you start

1. Choose one region, for example `ap-south-1`, and use it everywhere. The one exception is the CloudFront certificate, which must be in `us-east-1`.
2. Get an IAM user with AdministratorAccess (lab account) and create an access key.
   **Why:** eksctl creates VPCs, IAM roles and CloudFormation stacks. Narrow permissions fail halfway through.
3. Collect the secrets:
   - DB password
   - JWT secret: `openssl rand -base64 48` (it must be at least 32 bytes, or the auth and order services refuse to start)
   - `FAUXNANCE_API_KEY`: required, because the executor won't start without it
   - optional: `GROQ_API_KEY`, SMTP user and app password

---

## 2. EC2 build box (t3.xlarge, 30 GB)

### 2.1 Launch the instance (console)

EC2 > Launch instance:
- **Amazon Linux 2023**, x86_64, **t3.xlarge**, **30 GiB gp3** root disk, your key pair.
- New security group `etp-ec2-sg`:

| Port | Source | Why |
|---|---|---|
| 22 | My IP | SSH |
| 4200 | 0.0.0.0/0 | The UI |
| 3000 | 0.0.0.0/0 | The browser calls the auth API directly |
| 8081 | 0.0.0.0/0 | The browser calls the order API directly |

**Why not 5432, 9092 or 8082?** The database, Kafka and the executor are only used by the other containers on the same box. Compose binds Postgres and Kafka to 127.0.0.1, so they stay private.

**Why t3.xlarge?** The Angular and Maven builds plus two JVMs, Kafka and Postgres need about 8 GB of RAM at peak. 16 GB gives headroom.

### 2.2 Install Docker, Compose and Buildx
```bash
ssh -i key.pem ec2-user@<EC2_PUBLIC_IP>
sudo dnf install -y docker git jq unzip
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user && newgrp docker
```
**Why:** `usermod` lets you run `docker` without sudo. `newgrp` applies that in the current shell.

```bash
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -sSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo curl -sSL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
sudo chmod +x /usr/local/lib/docker/cli-plugins/*
docker compose version && docker buildx version
```
**Why:** The Dockerfiles use BuildKit features (`COPY <<EOF` heredocs and `--mount=type=cache` for the Maven/npm caches). Those need Buildx. The compose file uses `required: false` dependencies, which need Compose 2.20 or newer.

### 2.3 Install the AWS CLI, kubectl, eksctl and Helm
```bash
aws --version          # preinstalled on Amazon Linux 2023
aws configure          # access key, secret, region (ap-south-1), output json
curl -sSLO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl && sudo install kubectl /usr/local/bin/
curl -sSL https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz | tar xz && sudo mv eksctl /usr/local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
kubectl version --client; eksctl version; helm version
```
**Why:**
- `aws`: creates ECR, RDS and more, and logs Docker in to ECR.
- `eksctl`: creates the cluster.
- `kubectl`: applies the YAML.
- `helm`: installs the AWS Load Balancer Controller.

### 2.4 Get the code and the kit
```bash
git clone https://github.com/Neueda-Learning/chennai-capstone-SE1-team3.git
# from your laptop:  scp -i key.pem team3-deploy.zip ec2-user@<EC2_PUBLIC_IP>:~
unzip -o ~/team3-deploy.zip -d ~/chennai-capstone-SE1-team3/
cd ~/chennai-capstone-SE1-team3/Application
ls Frontend/Dockerfile Services/*/Dockerfile docker-compose.yaml k8s
```
**Why:** The kit's `Application/` folder lands on top of the repo's. It adds the new Dockerfiles, compose file and k8s folder, and leaves the team's code untouched.

---

## 3. Run everything on EC2 with Docker Compose

### 3.1 Create `.env`
```bash
cp .env.example .env
vi .env
```
Set:

| Variable | Value | Why |
|---|---|---|
| `PUBLIC_HOST` | the EC2 public IPv4 / DNS | The browser calls the APIs at this address. Compose builds every URL and the CORS origin from it. |
| `DB_PASSWORD` | your password | Used by Postgres and by all three services. |
| `JWT_SECRET` | 32+ random bytes | Auth signs tokens with it; the order service verifies them with the same key. |
| `FAUXNANCE_API_KEY` | your key | The executor's market-data poller needs it. |
| `GROQ_API_KEY`, `SMTP_USER`, `SMTP_PASS` | optional | Without SMTP, the sign-up OTP is printed in the auth log. |

The values compose builds from `PUBLIC_HOST`:
- frontend `http://<PUBLIC_HOST>:4200`
- auth `http://<PUBLIC_HOST>:3000`
- order `http://<PUBLIC_HOST>:8081`
- `CORS_ALLOWED_ORIGINS` = the frontend URL

`COOKIE_SECURE=false` stays false until you have https, because browsers silently drop `Secure` cookies over plain http and login would break.

### 3.2 Check the config, then build and start
```bash
docker compose config -q && echo config-ok
```
**Why:** This expands every `${VAR}` and stops with a clear message (`set DB_PASSWORD in .env`) before anything is built.

```bash
docker compose up -d --build
docker compose ps
```
**Why:** `--build` builds the five images from the Dockerfiles. The first build takes about 5-10 minutes; later builds reuse the cache. `-d` runs everything in the background.

What happens, in order:
1. **postgres** starts on an empty volume. Its official image runs `schema.sql`, then `seed_data.sql`, from `/docker-entrypoint-initdb.d`. This happens once, on first start only.
2. **kafka** starts.
3. **kafka-init** creates the six topics, then exits with code 0. Those topics are `orders`, `trade-events` and `market-data`, plus a `.DLT` dead-letter topic for each.
4. **auth**, **order** and **executor** start once their dependencies are healthy.
5. **frontend** swaps the placeholder URLs for the real ones and starts nginx.

Wait until every service shows `healthy` and kafka-init shows `Exited (0)`.

### 3.3 Check it works
```bash
curl -s localhost:3000/docs/json | head -c 80; echo        # auth answers
curl -s localhost:8081/health; echo                        # order answers
docker compose logs frontend | grep 'frontend:'            # "AUTH_SERVICE_URL = http://<IP>:3000 (placeholder replaced in N file(s))"
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --list
```
Open `http://<EC2_PUBLIC_IP>:4200`, register (without SMTP, the OTP is in `docker compose logs auth-service`), log in and place an order.

### 3.4 Day-to-day commands
```bash
docker compose logs -f order-service           # follow a log
docker compose restart frontend                # picks up a changed URL in .env (no rebuild needed)
docker compose up -d --build order-service     # rebuild one service after a code change
docker compose down                            # stop, keep data
docker compose down -v                         # stop and DELETE the DB/Kafka volumes (schema + seed run again)
docker system df && docker builder prune -f    # keep the 30 GB disk free
```

---

## 4. Move the database to RDS

### 4.1 Create the RDS instance (console)

RDS > Create database > Standard create:
- **PostgreSQL 16**, template **Free tier** or Dev/Test, `db.t3.micro`
- DB identifier `etp-db`, master user `postgres`, password = your `DB_PASSWORD`
- VPC: **the same VPC as the EC2 box**. Public access: **No**. New security group: `etp-rds-sg`.
- Additional configuration > **Initial database name: `trading_system_db`**

Wait for **Available**, then copy the **Endpoint**.

**Why the same VPC and no public access?** The database is reached over the private network only. Nothing on the internet can try the password.

**Why the initial DB name?** RDS creates only the `postgres` database unless you name one. `schema.sql` expects `trading_system_db` to exist.

### 4.2 Allow EC2 to reach RDS
In `etp-rds-sg`, add an inbound rule: **PostgreSQL, 5432, source = security group `etp-ec2-sg`**.

**Why a security-group source and not an IP?** It keeps working if the EC2 IP changes, and it lets in only instances that carry that group.

If RDS and the box are in different VPCs, set up VPC peering:
1. VPC > Peering connections > Create, then Accept.
2. Add a route to each VPC's route table for the other VPC's CIDR through the peering connection.
3. Use the EC2 VPC CIDR as the source in `etp-rds-sg`.

### 4.3 Load the schema and seed data into RDS (manually with psql)
Install the psql client on the box:
```bash
sudo dnf install -y postgresql16
psql --version
```
**Why:** You need a Postgres client to run the SQL files against RDS. Postgres itself is not installed.

Set the connection details once for this shell:
```bash
export PGHOST=<rds-endpoint>        # e.g. etp-db.abc123.ap-south-1.rds.amazonaws.com
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD='<DB_PASSWORD>'
export PGSSLMODE=require
```
**Why:** `psql` reads these `PG*` variables, so every command below stays short. `PGSSLMODE=require` is needed because RDS for PostgreSQL 15+ refuses unencrypted connections (`rds.force_ssl=1`).

Test the connection and check that the database exists:
```bash
psql -d postgres -c 'select version();'
psql -d postgres -c '\l' | grep trading_system_db
```
If `trading_system_db` is missing (you skipped the initial DB name), create it:
```bash
psql -d postgres -c 'CREATE DATABASE trading_system_db;'
```

Run the schema, then the seed data:
```bash
cd ~/chennai-capstone-SE1-team3/Application
psql -d trading_system_db -v ON_ERROR_STOP=1 -f Databases/PostgreSQL/schema.sql
psql -d trading_system_db -v ON_ERROR_STOP=1 -f Databases/PostgreSQL/seed_data.sql
```
**Why this order:**
- `schema.sql` creates the `trading` and `auth` schemas, the tables, constraints and indexes. It also sets `search_path` for the user.
- `seed_data.sql` inserts the starting rows (instruments, demo accounts), which need the tables to exist first.
- `ON_ERROR_STOP=1` stops at the first error instead of carrying on and leaving the database half-built.

Check:
```bash
psql -d trading_system_db -c '\dn'                     # schemas: auth, trading
psql -d trading_system_db -c '\dt trading.*'           # tables
psql -d trading_system_db -c '\dt auth.*'
psql -d trading_system_db -c 'select count(*) from trading.instrument;'   # seeded rows
```

Starting over (deletes all data):
```bash
psql -d trading_system_db -f Databases/PostgreSQL/reset.sql
```
Then run the two files again. `schema.sql` never drops anything; `reset.sql` is kept separate on purpose so a wipe is always a deliberate step.

Upgrading an existing database instead of starting fresh: apply the numbered migration files in order.
```bash
for f in Databases/PostgreSQL/migrations/*.sql; do echo "$f"; psql -d trading_system_db -v ON_ERROR_STOP=1 -f "$f"; done
```

### 4.4 Point the compose stack at RDS
```bash
vi .env
```
Set these four:

| Setting | Why |
|---|---|
| `DB_HOST=<rds-endpoint>` | The services now connect to RDS. |
| `COMPOSE_PROFILES=` (empty) | Stops compose from starting the local postgres container. |
| `JDBC_EXTRA=&sslmode=require` | Spring connects over TLS. It is appended to the JDBC URL. |
| `PGSSLMODE=no-verify` | Node's `pg` driver uses TLS without checking the AWS certificate chain. |

```bash
docker compose down
docker compose up -d
docker compose logs order-service | grep -i -m3 'hikari\|started'
```

---

## 5. Push the images to ECR

### 5.1 Variables for this shell
```bash
export AWS_REGION=ap-south-1
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY=$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
export TAG=v1
echo $REGISTRY
```
**Why:** Every image name below is `<registry>/<repo>:<tag>`. Use a new tag (`v2`, `v3` ...) for each release, so Kubernetes can tell versions apart and you can roll back.

### 5.2 Create the four repositories (once per account)
```bash
aws ecr create-repository --repository-name etp/etp-auth-service     --region $AWS_REGION --image-scanning-configuration scanOnPush=true
aws ecr create-repository --repository-name etp/etp-order-service    --region $AWS_REGION --image-scanning-configuration scanOnPush=true
aws ecr create-repository --repository-name etp/etp-executor-service --region $AWS_REGION --image-scanning-configuration scanOnPush=true
aws ecr create-repository --repository-name etp/etp-frontend         --region $AWS_REGION --image-scanning-configuration scanOnPush=true
aws ecr describe-repositories --region $AWS_REGION --query 'repositories[].repositoryUri' --output table
```
**Why:** ECR is a private registry in the student's own account. EKS nodes can pull from it without passwords, because the node role has ECR read access.

### 5.3 Log Docker in to ECR
```bash
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY
```
**Why:** `docker push` needs credentials. This token lasts 12 hours, so run it again the next day.

### 5.4 Build, tag and push
```bash
docker build -t $REGISTRY/etp/etp-auth-service:$TAG     Services/auth-service
docker push     $REGISTRY/etp/etp-auth-service:$TAG
docker build -t $REGISTRY/etp/etp-order-service:$TAG    Services/order-service
docker push     $REGISTRY/etp/etp-order-service:$TAG
docker build -t $REGISTRY/etp/etp-executor-service:$TAG Services/executor-service
docker push     $REGISTRY/etp/etp-executor-service:$TAG
docker build -t $REGISTRY/etp/etp-frontend:$TAG         Frontend
docker push     $REGISTRY/etp/etp-frontend:$TAG
```
**Why the folder at the end:** That folder is the build context, meaning the files the Dockerfile can see. Each component has its own folder.

**Why no URL is given to the frontend build:** The frontend image is built with placeholder URLs. Kubernetes supplies the real ones when the pod starts (step 7.5), so this one image works for EC2, four load balancers, the ALB and S3.

Already built the images with compose? Re-tag them instead of rebuilding:
```bash
docker images | grep '^etp-'
docker tag etp-auth-service:latest     $REGISTRY/etp/etp-auth-service:$TAG     && docker push $REGISTRY/etp/etp-auth-service:$TAG
docker tag etp-order-service:latest    $REGISTRY/etp/etp-order-service:$TAG    && docker push $REGISTRY/etp/etp-order-service:$TAG
docker tag etp-executor-service:latest $REGISTRY/etp/etp-executor-service:$TAG && docker push $REGISTRY/etp/etp-executor-service:$TAG
docker tag etp-frontend:latest         $REGISTRY/etp/etp-frontend:$TAG         && docker push $REGISTRY/etp/etp-frontend:$TAG
```
A project that differs from the defaults takes `--build-arg`s, for example `--build-arg JAVA_VERSION=17`. Each Dockerfile lists its build args at the top.

### 5.5 Check, then free the disk
```bash
aws ecr list-images --repository-name etp/etp-frontend --region $AWS_REGION
docker image prune -af && docker builder prune -f --keep-storage 4GB
df -h /
```
**Why:** The images are safe in ECR now. Local copies only fill the 30 GB disk. Keeping 4 GB of build cache makes the next build fast.

---

## 6. Create the EKS cluster

### 6.1 Create it
```bash
vi k8s/cluster.example.yaml          # metadata.name and region
eksctl create cluster -f k8s/cluster.example.yaml          # 15-20 min
kubectl get nodes
```
**Why each part of the file:**
- 2 x t3.large: about 16 GB in total, enough for Kafka, two JVMs, auth and the frontend.
- `privateNetworking`: the nodes have no public IPs.
- `withOIDC`: lets pods use IAM roles.
- `aws-ebs-csi-driver`: Kafka's disk is an EBS volume, and without this driver the volume claim stays `Pending`.

eksctl also writes `~/.kube/config`, so `kubectl` points at the new cluster.

### 6.2 Fill in the secrets and settings
```bash
cp k8s/base/secrets.env.example k8s/secrets.env
vi k8s/secrets.env            # DB_PASSWORD, JWT_SECRET, FAUXNANCE_API_KEY, GROQ_API_KEY, SMTP_USER, SMTP_PASS
vi k8s/base/config.env        # non-secret settings
```
**Why two files:**
- `secrets.env` becomes a Kubernetes **Secret**, kept out of git.
- `config.env` becomes a **ConfigMap**.

Both are handed to the pods as environment variables. Their names get a content hash, so when either file changes the pods restart and pick up the new values.

For RDS, set these in `config.env`:
```
DB_HOST=<rds-endpoint>
PGSSLMODE=no-verify
SPRING_DATASOURCE_URL=jdbc:postgresql://<rds-endpoint>:5432/trading_system_db?currentSchema=trading&sslmode=require
```
**Why `SPRING_DATASOURCE_URL`:** It replaces Spring's JDBC URL whole, which is how TLS gets switched on without touching the team's `application.yml`.

For a quick test without RDS, keep `DB_HOST=postgres` and include `../optional/postgres` in step 7.3.

### 6.3 Let the cluster reach RDS
eksctl creates its **own VPC**, so the cluster cannot see RDS in the default VPC. Pick one:
- **(a) Recommended:** create the RDS instance in the eksctl VPC (choose it in 4.1), and allow the cluster security group:
  ```bash
  CLUSTER_SG=$(aws eks describe-cluster --name etp-cluster --region $AWS_REGION \
               --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
  RDS_SG=<sg-id of etp-rds-sg>
  aws ec2 authorize-security-group-ingress --group-id $RDS_SG --protocol tcp --port 5432 --source-group $CLUSTER_SG
  ```
  Then load the SQL from the EC2 box (step 4.3). The box needs a path to that VPC: peering, or run psql from a pod as shown below.
- **(b)** Keep RDS where it is and peer the two VPCs (routes both ways + a CIDR rule on 5432).

Run psql from inside the cluster (no peering needed):
```bash
kubectl run psql --rm -it --image=postgres:16-alpine --env PGPASSWORD='<DB_PASSWORD>' --env PGSSLMODE=require -- \
  psql -h <rds-endpoint> -U postgres -d trading_system_db -c '\dt trading.*'
# to load files this way:  kubectl cp Databases/PostgreSQL/schema.sql <pod>:/tmp/  then  psql -f /tmp/schema.sql
```

---

## 7. Stage 1: four load balancers

### 7.1 Point kubectl at the cluster
```bash
aws eks update-kubeconfig --name etp-cluster --region $AWS_REGION
kubectl get nodes
```
**Why:** eksctl sets this up already on the same box. Run it again on any other machine, or if you have several clusters.

### 7.2 Copy the project files next to the manifests
```bash
cd ~/chennai-capstone-SE1-team3/Application
mkdir -p k8s/base/generated k8s/optional/postgres/generated
cp Config/application.yml k8s/base/generated/
cp k8s/secrets.env        k8s/base/secrets.env
cp Databases/PostgreSQL/schema.sql Databases/PostgreSQL/seed_data.sql k8s/optional/postgres/generated/
```
**Why:**
- Kustomize can only read files inside the folder it builds.
- `application.yml` is the team's shared config. It becomes a ConfigMap mounted at `/config/application.yml`, and the services find it through `SHARED_CONFIG`.
- The SQL files are only needed by the optional in-cluster Postgres, which runs them on first start just like compose does.

### 7.3 Write the top-level kustomization
```bash
mkdir -p k8s/.build
cat > k8s/.build/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: etp
resources:
  - ../overlays/four-lb
#  - ../optional/postgres          # uncomment ONLY when DB_HOST=postgres (no RDS)
images:
  - { name: etp-auth-service,     newName: $REGISTRY/etp/etp-auth-service,     newTag: "$TAG" }
  - { name: etp-order-service,    newName: $REGISTRY/etp/etp-order-service,    newTag: "$TAG" }
  - { name: etp-executor-service, newName: $REGISTRY/etp/etp-executor-service, newTag: "$TAG" }
  - { name: etp-frontend,         newName: $REGISTRY/etp/etp-frontend,         newTag: "$TAG" }
EOF
cat k8s/.build/kustomization.yaml
kubectl kustomize k8s/.build | less          # read what will be created
```
**Why:**
- The manifests use short image names (`etp-frontend`). The `images:` block swaps in your ECR address and tag, so the same YAML works in every student account without edits.
- `namespace:` puts everything in `etp`.
- The `resources:` line chooses the overlay.

### 7.4 Apply and wait
```bash
kubectl apply -k k8s/.build
```
**Why `-k`:** It runs kustomize (base + overlay + `images:`), then applies the result.

What gets created:
- the namespace, the gp3 StorageClass, Kafka (a StatefulSet with a 5 Gi EBS disk), the topics Job
- the four Deployments and their Services
- the ConfigMaps and the Secret
- `LoadBalancer` Services for frontend, auth and order

```bash
kubectl -n etp rollout status statefulset/kafka --timeout=10m
kubectl -n etp wait --for=condition=complete job/kafka-topics --timeout=10m
kubectl -n etp logs job/kafka-topics | tail -8
```
**Why wait for Kafka first:** order and executor connect to Kafka at start-up. The Job creates the six topics. Auto-creation is off, so a missing topic is an error rather than a silently wrong topic.

```bash
kubectl -n etp rollout status deploy/auth-service     --timeout=10m
kubectl -n etp rollout status deploy/order-service    --timeout=10m
kubectl -n etp rollout status deploy/executor-service --timeout=10m
kubectl -n etp rollout status deploy/frontend         --timeout=10m
kubectl -n etp get pods,svc
```
A pod shows Ready only when its probe passes:
- auth: `GET /docs/json`
- order: `GET /health`
- executor: its TCP port is open
- frontend: `GET /`

The Java pods have up to 5 minutes (a startup probe) before liveness checks can restart them.

### 7.5 Give the app the load-balancer addresses
```bash
kubectl -n etp get svc -w          # wait until EXTERNAL-IP shows a hostname for frontend, auth-service, order-service; Ctrl-C
F=$(kubectl -n etp get svc frontend      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
A=$(kubectl -n etp get svc auth-service  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
O=$(kubectl -n etp get svc order-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $F $A $O
```
**Why now:** AWS creates the ELBs and their DNS names only after the Services exist, so the URLs can't be known before step 7.4.

```bash
cat > k8s/overlays/four-lb/urls.env <<EOF
FRONTEND_URL=http://$F
AUTH_SERVICE_URL=http://$A:3000
ORDER_SERVICE_URL=http://$O:8081
CORS_ALLOWED_ORIGINS=http://$F
EOF
kubectl apply -k k8s/.build
kubectl -n etp rollout status deploy/frontend
kubectl -n etp logs deploy/frontend | grep 'frontend:'
echo "Open http://$F"
```
**Why:**
- `AUTH_SERVICE_URL` and `ORDER_SERVICE_URL` are what the browser calls, so the frontend writes them into the page when it starts.
- `CORS_ALLOWED_ORIGINS` tells auth and order to accept calls from the frontend's address. It must not be `*`, because the app sends cookies.
- A changed `urls.env` gives the ConfigMap a new hashed name, so `apply` restarts the frontend, auth and order pods by itself.

A new ELB name can take 2-5 minutes to resolve in DNS.

**Limit of stage 1.** The three hostnames are different sites, so the browser won't send the `SameSite=lax` refresh cookie to the API. Login works, but a session refresh can fail. Stage 2 removes the problem.

**The executor gets no load balancer** because nothing outside the cluster calls it.

---

## 8. Stage 2: one ALB with an Ingress

### 8.1 Install the AWS Load Balancer Controller (once per cluster)
```bash
export CLUSTER=etp-cluster
curl -fsSL -o alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://alb-iam-policy.json
```
**Why:** An Ingress object is only a request. The controller is the program that creates the real ALB, and it needs IAM permissions to do that.

```bash
NG=$(aws eks list-nodegroups --cluster-name $CLUSTER --region $AWS_REGION --query 'nodegroups[0]' --output text)
ROLE=$(aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NG --region $AWS_REGION \
       --query 'nodegroup.nodeRole' --output text | awk -F/ '{print $NF}')
aws iam attach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::$ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy
```
**Why the node role:** It's the simplest setup for a lab account, since the controller pod borrows the node's permissions. For production, use IRSA (`eksctl create iamserviceaccount`) instead.

```bash
VPC_ID=$(aws eks describe-cluster --name $CLUSTER --region $AWS_REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=$CLUSTER --set region=$AWS_REGION --set vpcId=$VPC_ID
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

### 8.2 Switch to the ingress overlay
```bash
sed -i 's#../overlays/four-lb#../overlays/ingress#' k8s/.build/kustomization.yaml
kubectl apply -k k8s/.build
kubectl -n etp get ingress etp -w          # ADDRESS appears after 2-4 min; Ctrl-C
```
**Why:**
- The ingress overlay leaves all Services as `ClusterIP`, so AWS deletes the three classic ELBs.
- It adds `ingress.yaml`, and the controller turns that into one ALB:
  - `/auth` and `/docs` go to auth
  - `/api/v1` and `/health` go to order
  - everything else goes to the frontend
- `target-type: ip` sends traffic straight to the pods.
- The `healthcheck-path` annotations on the Services tell the ALB how to check each target.

### 8.3 Give the app the ALB address
```bash
H=$(kubectl -n etp get ingress etp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
cat > k8s/overlays/ingress/urls.env <<EOF
FRONTEND_URL=http://$H
AUTH_SERVICE_URL=http://$H
ORDER_SERVICE_URL=http://$H
CORS_ALLOWED_ORIGINS=http://$H
EOF
kubectl apply -k k8s/.build
kubectl -n etp rollout status deploy/frontend
curl -s http://$H/health; echo
curl -s -o /dev/null -w '%{http_code}\n' http://$H/docs/json
echo "Open http://$H"
```
**Why the same URL four times:** The page and both APIs now sit behind one hostname, and the ALB routes by path. So the browser makes same-origin calls, CORS isn't really involved, and the refresh cookie works.

If a target is unhealthy, check EC2 > Target groups > Targets.

---

## 9. Frontend on S3 + CloudFront (optional)

The APIs stay on the ALB. Only the static files move to S3.

### 9.1 Create the bucket
```bash
export BUCKET=etp-frontend-$ACCOUNT
aws s3 mb s3://$BUCKET --region $AWS_REGION
```
**Why the account number:** Bucket names are global, and this makes the name unique.

### 9.2 Take the built site out of the frontend image, with the real URLs filled in
```bash
mkdir -p site
docker pull $REGISTRY/etp/etp-frontend:$TAG
docker run --rm --user 0 --entrypoint sh \
  -e AUTH_SERVICE_URL=https://app.example.com -e ORDER_SERVICE_URL=https://app.example.com \
  -e HTML_ROOT=/out -v "$PWD/site:/out" $REGISTRY/etp/etp-frontend:$TAG \
  -c '/docker-entrypoint.d/40-runtime-urls.sh && chmod -R a+rX /out'
ls site; grep -l placeholder.invalid -r site || echo "no placeholders left"
```
**Why:**
- S3 runs no code, so the URL swap the container normally does at start-up has to happen here.
- The image's own start-up step (`40-runtime-urls.sh` inside the image) writes the finished site into `./site`.
- Use the address the browser will call for the APIs: the ALB, or your https domain.

### 9.3 Upload
```bash
aws s3 sync site s3://$BUCKET --delete --exclude '*.html' --exclude '*.js' --exclude '*.css' --exclude '*.json' \
  --cache-control 'public,max-age=2592000'
aws s3 sync site s3://$BUCKET --exclude '*' --include '*.html' --include '*.js' --include '*.css' --include '*.json' \
  --cache-control 'no-cache'
```
**Why two passes:**
- Images and fonts never change, so browsers may cache them for 30 days.
- HTML, JS and CSS hold the API URLs, so browsers must re-check them on every visit.

### 9.4 CloudFront (console)
1. Create a distribution with origin = the bucket and **Origin access control**, then apply the bucket policy CloudFront offers.
   **Why:** The bucket stays private; only CloudFront can read it.
2. Set the default root object to `index.html`.
3. Error pages: map **403 and 404 to `/index.html` with code 200**.
   **Why:** Angular routes like `/blotter` are not real files, so the app has to handle them.
4. Add the CloudFront address to CORS in `k8s/overlays/ingress/urls.env`:
   ```
   FRONTEND_URL=https://dxxxx.cloudfront.net
   CORS_ALLOWED_ORIGINS=https://dxxxx.cloudfront.net
   ```
   Then run `kubectl apply -k k8s/.build`.
5. After each upload, run `aws cloudfront create-invalidation --distribution-id <ID> --paths '/*'`.

An https page can't call an http API (mixed content), so do step 10 first. The alternative is to add the ALB as a second CloudFront origin with behaviours `/auth/*`, `/docs/*`, `/api/v1/*` and `/health`. Then everything is one https origin, and all URLs equal the CloudFront URL.

---

## 10. Domain: Route 53 + ACM

1. **Route 53:** create a hosted zone for `example.com`, or buy a domain there. If it's registered elsewhere, point its name servers at the zone.
2. **ACM certificate** for `app.example.com`, using DNS validation (choose "Create records in Route 53"):
   - for the ALB, request it in **your cluster's region**
   - for CloudFront, request it in **us-east-1**

   **Why the two regions:** An ALB can only use certificates from its own region, and CloudFront only reads from us-east-1.
3. **ALB https:** in `k8s/overlays/ingress/ingress.yaml`, replace the `listen-ports` line with the three commented lines and paste the certificate ARN.
4. **Cookies:** in `k8s/base/config.env`, set `COOKIE_SECURE=true`. Cookies may now travel only over https.
5. **URLs:**
   ```bash
   sed -i 's#http://[^ ]*#https://app.example.com#' k8s/overlays/ingress/urls.env
   cat k8s/overlays/ingress/urls.env
   kubectl apply -k k8s/.build
   ```
6. **Route 53 record:** create an **A record, Alias = yes**, for `app.example.com`, pointing at the ALB (or the CloudFront distribution).
   **Why Alias:** It follows the AWS-managed address of the ALB or CloudFront, and Route 53 doesn't charge for alias queries.

---

## 11. Releasing a new version
```bash
export TAG=v2
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY
docker build -t $REGISTRY/etp/etp-order-service:$TAG Services/order-service && docker push $REGISTRY/etp/etp-order-service:$TAG
# ... the same for every changed component
sed -i "s/newTag: \"[^\"]*\"/newTag: \"$TAG\"/" k8s/.build/kustomization.yaml
kubectl apply -k k8s/.build
kubectl -n etp rollout status deploy/order-service
```
**Why:** Only the Deployments whose image tag changed are replaced, one pod at a time.

**Rolling back:** run `kubectl -n etp rollout undo deploy/order-service`, or set the old tag and apply again.

For a config-only change (`config.env`, `k8s/secrets.env`, `urls.env`, `Config/application.yml`):
1. Redo the copy in step 7.2.
2. Run `kubectl apply -k k8s/.build`.

The pods restart by themselves.

---

## 12. Where to change what

| What | EC2 (compose) | Kubernetes |
|---|---|---|
| Public address | `.env` `PUBLIC_HOST`, `PUBLIC_SCHEME` | `overlays/<mode>/urls.env` (steps 7.5 / 8.3) |
| Browser API URLs | derived, or `AUTH_PUBLIC_URL` / `ORDER_PUBLIC_URL` | `urls.env` `AUTH_SERVICE_URL`, `ORDER_SERVICE_URL` |
| CORS | derived from the frontend URL, or `.env` `CORS_ALLOWED_ORIGINS` | `urls.env` `CORS_ALLOWED_ORIGINS` (comma-separated, never `*`) |
| Secrets | `.env` | `k8s/secrets.env` (copy it into base, step 7.2) |
| Database / RDS TLS | `.env` `DB_HOST`, `COMPOSE_PROFILES`, `JDBC_EXTRA`, `PGSSLMODE` | `config.env` `DB_HOST`, `PGSSLMODE`, `SPRING_DATASOURCE_URL` |
| Ports | `.env` `*_SERVICE_PORT`, `FRONTEND_PORT` | `config.env` **and** the numbers in that service's YAML (`containerPort`, Service `port`, `SERVER_PORT`) and in `ingress.yaml` |
| Kafka topics | the `kafka-init` command in `docker-compose.yaml` | the command in `k8s/base/kafka-topics-job.yaml` |
| Node/Java version, start command | `build.args` in `docker-compose.yaml` | `--build-arg` on `docker build` (step 5.4) |
| Replicas, memory | n/a | `replicas:` / `resources:` in `k8s/base/*-service.yaml` (keep the executor at 1, since it polls the market API) |
| Other app settings | `.env` | `config.env`; anything unset falls back to `Config/application.yml` |

---

## 13. Using the kit for another capstone repo

Go through this list for each repo. Most of them need only YAML or build-arg changes, not code changes.

1. **Folder names:** fix the `build.context` paths in `docker-compose.yaml` and the folder at the end of each `docker build` command.
2. **Ports and health checks:** run `grep -rn "listen(\|server.port\|PORT" Services/` to find each port and health URL. Update the probes, `healthcheck` and `ingress.yaml` paths.
3. **How the frontend gets its API URLs** (look at `src/environments/*.ts` and `scripts/`):
   - **It reads env vars at build time** (as team3 does): list them in the `PLACEHOLDER_ENV` build arg, and set the same names at runtime.
   - **It hard-codes `http://localhost:3000`:** `--build-arg PLACEHOLDER_ENV="AUTH_SERVICE_URL=http://localhost:3000 ORDER_SERVICE_URL=http://localhost:8081"`. The literal acts as the placeholder, so no code change is needed.
   - **It uses relative URLs (`/api`):** `--build-arg PLACEHOLDER_ENV=""` and stage 2 only.
4. **Node service:**
   - plain JS: `--build-arg NEEDS_BUILD=false --build-arg START_CMD="node server.js"`
   - writes files at run time: `--build-arg WRITABLE_DIRS=/app/uploads`
5. **Java service:**
   - other Java version: `JAVA_VERSION=17`
   - multi-module Maven: `MODULE=<module>`
   - native libraries: `RUNTIME_IMAGE=eclipse-temurin:21-jre-jammy`
   - starts Python: build with `-f docker-variants/java-python.Dockerfile`
6. **Different env var names** (`SPRING_DATASOURCE_*`, `DATABASE_URL`, ...): add them to `.env` and `config.env`. Every key in those files reaches the containers.
7. **Different SQL file names:** fix the two compose mounts, `k8s/optional/postgres/kustomization.yaml`, and the `psql -f` lines in step 4.3.
8. **No `Config/application.yml`:** remove the `etp-shared-config` generator and its `volumeMounts`/`volumes`, and the `SHARED_CONFIG` env (compose: the `*config-volume` lines).
9. **No executor, or an extra service:** delete or copy a `k8s/base/*-service.yaml`, list it in `base/kustomization.yaml`, and do the same in compose and the ECR steps.

---

## 14. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Compose: `set X in .env` | That variable is empty in `.env`. |
| Frontend log: `X is not set; the page keeps the placeholder` | The runtime URL env is missing: check `environment:` (compose) or `urls.env` (k8s). |
| Browser: CORS error | `CORS_ALLOWED_ORIGINS` must match the page origin exactly: scheme, host and port, with no trailing slash. |
| Login then logged straight out | `COOKIE_SECURE=true` over http, or different hostnames (stage 1). |
| `no pg_hba.conf entry ... no encryption` | RDS needs TLS: set `PGSSLMODE` and `JDBC_EXTRA` / `SPRING_DATASOURCE_URL`. |
| `relation ... does not exist` | `schema.sql` was not loaded into **trading_system_db**. Check `psql -d trading_system_db -c '\dn'`. |
| Pod `CrashLoopBackOff` | `kubectl -n etp logs <pod> --previous`. Often a missing `FAUXNANCE_API_KEY`, or `JWT_SECRET` < 32 bytes. |
| `ImagePullBackOff` | Wrong registry or tag in `.build/kustomization.yaml`, or the image was never pushed. |
| Kafka PVC `Pending` | The EBS CSI addon is missing: `eksctl create addon --name aws-ebs-csi-driver --cluster etp-cluster --force`. |
| The topics Job can't be updated | A finished Job can't be changed: `kubectl -n etp delete job kafka-topics`, then apply again. |
| Ingress has no ADDRESS | Controller logs: `kubectl -n kube-system logs deploy/aws-load-balancer-controller`. |
| ALB target unhealthy | Wrong `healthcheck-path` annotation on that Service. |
| Java `OOMKilled` | Raise `limits.memory` in that YAML. The heap follows it (`MaxRAMPercentage`). |
| EC2 disk full | `docker system prune -af && docker builder prune -af`. |

---

## 15. Tear down (stop the bill)
```bash
kubectl -n etp delete ingress etp --ignore-not-found       # the controller deletes the ALB
kubectl delete namespace etp                               # removes the ELBs and EBS volumes too
eksctl delete cluster -f k8s/cluster.example.yaml
for r in etp-auth-service etp-order-service etp-executor-service etp-frontend; do
  aws ecr delete-repository --repository-name etp/$r --force --region $AWS_REGION; done
aws s3 rb s3://$BUCKET --force
```
**Why the Ingress first:** If the cluster goes before the controller removes the ALB, the ALB is orphaned and keeps billing.

Then, in the console:
- delete the RDS instance (skip the final snapshot for a lab)
- disable and delete the CloudFront distribution
- delete the Route 53 records and the ACM certificates
- terminate the EC2 box

---

## 16. Test status of these files

**Checked:**
- `docker compose config` with the local DB, with RDS and with the ETL profile.
- Kustomize builds of both overlays, including the in-cluster Postgres option.

**Not run here:** the image builds and the AWS steps. Do one full run on the first student's account before rolling out to all 30.
