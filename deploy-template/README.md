# Deploy your capstone: Docker, ECR, EKS, RDS and Jenkins

A starting point for deploying a capstone trading platform (an Angular page, a NestJS
auth-service, Spring Boot order-service and executor-service, PostgreSQL and Kafka).
Copy this folder into your repository as `deploy/`, change the lines marked
**CHANGE ME**, and work through the steps. Every file is plain and short on purpose:
read each one before you use it, because the session is about understanding how the
pieces fit, not just getting a green light.

```
deploy/
├── .env.example            your project: name, folders, SQL files, topics   (copy to .env, commit)
├── env/                    settings the services read
│   ├── common.env            shared by every service (database, Kafka, service addresses)
│   ├── auth-service.env      order-service.env      executor-service.env
│   └── secrets.env.example   passwords and keys       (copy to secrets.env, NEVER commit)
├── docker/
│   ├── frontend.Dockerfile   Angular build, served by nginx
│   ├── frontend-nginx.conf   the page + forwards /auth and /api to the services
│   ├── node.Dockerfile       NestJS / Node service (auth-service)
│   ├── java.Dockerfile       Spring Boot service (order-service, executor-service)
│   └── load-sql.sh           loads your SQL into an empty database (local or RDS)
├── docker-compose.yml      the whole stack on one machine
├── k8s/                    one folder per service
│   ├── common/               namespace.yaml  storageclass.yaml
│   ├── kafka/                statefulset.yaml  service.yaml  topics-job.yaml
│   ├── auth-service/         deployment.yaml  service.yaml  service-internal.yaml
│   ├── order-service/        deployment.yaml  service.yaml  service-internal.yaml
│   ├── executor-service/     deployment.yaml  service.yaml  service-internal.yaml
│   ├── frontend/             deployment.yaml  service.yaml  service-internal.yaml
│   └── ingress/              ingress.yaml   (phase 2: one load balancer)
└── jenkins/Jenkinsfile     every push to main: build, push to ECR, deploy, smoke test
```

## How the pieces talk

| Service | Port | Reached by |
|---|---|---|
| frontend (Angular + nginx) | 80 in the container, **4200** on the box | the browser |
| auth-service (NestJS) | 3000 | the page, through nginx or the Ingress (`/auth`) |
| order-service (Spring Boot) | 8081 | the page, through nginx or the Ingress (`/api`) |
| executor-service (Spring Boot) | 8082 | Kafka only (no public route in phase 2) |
| PostgreSQL | 5432 | the services (`postgres` on the box, RDS on EKS) |
| Kafka | 9092 | the services (`kafka:9092`) |
| Jenkins | **8080** | you, on the box; that is why the Java services avoid 8080 |

**The browser only talks to the page's own address.** nginx in the frontend image
forwards `/auth/...` and `/api/...` to the services, so your Angular code should call
relative paths (`/auth/login`, `/api/v1/orders`), never `http://localhost:3000`. Then the
same image works on a laptop, on the box and on EKS.

## What you change

| File | What | How to find the value |
|---|---|---|
| `.env` | `PROJECT`, the four folders, `AUTH_ENTRY`, `SQL_DIR`, `SQL_FILES`, `KAFKA_TOPICS` | Your repository layout; `ls dist/` after building auth-service |
| `env/common.env`, `env/<service>.env` | The setting **names** your code reads | Search your code: `${NAME}` in `application.yml` / `.properties`, `process.env.NAME` or `configService.get('NAME')` in NestJS |
| `env/secrets.env` | Passwords, JWT secret, API keys, mail login | `openssl rand -hex 32` for anything you make up |
| `docker/frontend-nginx.conf` and `k8s/ingress/ingress.yaml` | Only if your API paths are not `/auth` and `/api` | Your Angular services' URLs |
| `k8s/kafka/topics-job.yaml` | The topic list, same as `KAFKA_TOPICS` | Your `@KafkaListener` / producer topics |
| your Angular code | API addresses must be relative (empty base URL) | `environment.prod.ts`, any `http://localhost:` in `src/` |

Everything else should work as it is. If you find you must change a Dockerfile, write
down why: it is usually a sign of something in your code worth fixing instead (see
step 12).

---

## Steps at a glance

| # | Step | Result |
|---|---|---|
| 1 | Launch the EC2 box | A box to work from |
| 2 | Connect the terminal to AWS | `aws sts get-caller-identity` works |
| 3 | Install the tools | git, Docker, compose, eksctl, kubectl, helm, psql |
| 4 | Clone your repository and add `deploy/` | The template in your repo |
| 5 | Fill in the settings and run with Docker | The platform on `http://<ip>:4200` |
| 6 | Create RDS and load your SQL | The database in RDS |
| 7 | Create the EKS cluster, disks, and VPC peering | A cluster that can reach RDS |
| 8 | Push the images to ECR | Images in ECR |
| 9 | Deploy to EKS, phase 1 (four load balancers) | The platform on EKS |
| 10 | Phase 2: one load balancer with an Ingress | One address for everything |
| 11 | Jenkins | Every push to `main` deploys |
| 12 | When something is wrong | Fixes for what we saw in testing |
| 13 | Clean up | No more charges |

Set these once per terminal session (steps 6 to 13 use them):

```bash
export AWS_REGION=ap-south-1
export CLUSTER_NAME=capstone
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
set -a; . deploy/.env; set +a          # PROJECT and the folders, from your .env
```

## 1. The EC2 box

AWS console, EC2, **Launch instance**:

- **AMI**: Amazon Linux 2023. **Type**: `t3.large` (2 vCPU, 8 GB). Building four images
  needs the memory; a `t2.micro` or `t3.small` freezes.
- **Storage**: 30 GB gp3.
- **IAM instance profile**: a role with the permissions your trainer gives you (EKS, ECR,
  EC2, RDS, IAM, CloudFormation). eksctl creates roles and stacks; a narrow role fails half way.
- **Security group**, inbound: 22 (SSH, your IP), **8080** (Jenkins), 4200 (the page),
  3000, 8081, 8082 (testing only). Keep 5432 and 9092 closed.

## 2. Connect the terminal to AWS

SSH (`ssh -i key.pem ec2-user@<public-ip>`) or the console: the instance, **Connect**,
**Session Manager**, then `sudo su - ec2-user`. The instance role is your login:

```bash
aws sts get-caller-identity          # shows the account and the role
```

## 3. Install the tools

```bash
sudo dnf install -y git docker postgresql16 gettext jq      # gettext gives envsubst
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user && newgrp docker

sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -sSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo curl -sSL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
sudo chmod +x /usr/local/lib/docker/cli-plugins/* && docker compose version

curl -sSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/ && eksctl version
curl -sSLO "https://dl.k8s.io/release/$(curl -sSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl && kubectl version --client
curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Docker Hub limits anonymous image pulls per address. If a build stops with
`toomanyrequests`, run `docker login` with a free Docker Hub account.

## 4. Your repository and this template

```bash
git clone https://github.com/<org>/<your-repo>.git && cd <your-repo>
git switch -c cloud-deployment
cp -r <path-to>/deploy-template deploy
```

A private repository asks for your GitHub user name and a **personal access token**
(GitHub, Settings, Developer settings, Tokens (classic), scope `repo`; **Configure SSO**
for the organisation) as the password.

## 5. Fill in the settings and run with Docker

```bash
cd deploy
cp .env.example .env && vi .env                         # CHANGE ME lines
cp env/secrets.env.example env/secrets.env && vi env/secrets.env
vi env/common.env env/auth-service.env env/order-service.env env/executor-service.env
docker compose up -d --build
docker compose ps
```

The first start loads your SQL into the local Postgres, creates the Kafka topics, then
starts the services. Check through the page, as a browser would:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4200/                    # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4200/auth/me             # 401 (no token)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4200/api/v1/accounts/1   # 401 or 403
docker compose logs -f auth-service          # Ctrl-C to stop following
```

A service that keeps restarting tells you why in its log: almost always a setting it
could not find (step 12). Add it to its `env/*.env` file and run `docker compose up -d`
again. `docker compose down -v` starts over with an empty database.

When it works, commit `deploy/` (without `env/secrets.env`, which `.gitignore` keeps out).

## 6. Move the database to RDS

Create it in the **default VPC** (the box's VPC), not public:

```bash
DEFAULT_VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
RDS_SG=$(aws ec2 create-security-group --group-name $PROJECT-rds --description "$PROJECT RDS" \
  --vpc-id $DEFAULT_VPC --query GroupId --output text)
BOX_SG=$(aws ec2 describe-instances --instance-ids $(ec2-metadata -i | awk '{print $2}') \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $RDS_SG --protocol tcp --port 5432 --source-group $BOX_SG

export DB_PASSWORD='ChooseAStrongPassword123'      # letters and digits only: it goes into URLs
aws rds create-db-instance --db-instance-identifier $PROJECT-db \
  --engine postgres --engine-version 17 --db-instance-class db.t3.micro --allocated-storage 20 \
  --master-username postgres --master-user-password "$DB_PASSWORD" \
  --db-name $DB_NAME --vpc-security-group-ids $RDS_SG \
  --no-publicly-accessible --backup-retention-period 0
aws rds wait db-instance-available --db-instance-identifier $PROJECT-db     # 5-10 minutes
export RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $PROJECT-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)

# Load your SQL with the same script the local container uses
PGHOST=$RDS_ENDPOINT PGUSER=postgres PGDATABASE=$DB_NAME PGPASSWORD="$DB_PASSWORD" PGSSLMODE=require \
  SQL_DIR=Databases/PostgreSQL SQL_FILES="$SQL_FILES" sh deploy/docker/load-sql.sh
```

Then point the settings at RDS: in `env/common.env` and each `SPRING_DATASOURCE_URL`, replace
`postgres` (the host) with `$RDS_ENDPOINT`; put `$DB_PASSWORD` in `env/secrets.env`. RDS
requires SSL: Spring with the PostgreSQL driver uses it by default; a NestJS service needs its
SSL option on (often `NODE_ENV=production` does that). To try Docker against RDS, set
`COMPOSE_PROFILES=` (empty) in `.env` and run `docker compose up -d`.

## 7. Create the EKS cluster

```bash
eksctl create cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --nodegroup-name workers --node-type t3.medium --nodes 2 --nodes-min 2 --nodes-max 2 \
  --managed --with-oidc                                   # 15-20 minutes
kubectl get nodes                                         # two nodes, Ready
```

Disks for Kafka (the EBS CSI driver add-on):

```bash
eksctl create iamserviceaccount --cluster $CLUSTER_NAME --region $AWS_REGION \
  --namespace kube-system --name ebs-csi-controller-sa \
  --role-name AmazonEKS_EBS_CSI_DriverRole_$CLUSTER_NAME --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy --approve
eksctl create addon --cluster $CLUSTER_NAME --region $AWS_REGION --name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole_$CLUSTER_NAME --force
```

**VPC peering** (required): eksctl puts the cluster in its own VPC (192.168.0.0/16), and
RDS is in the default VPC (172.31.0.0/16). Without peering every pod times out on RDS.

```bash
EKS_VPC=$(aws eks describe-cluster --name $CLUSTER_NAME --query cluster.resourcesVpcConfig.vpcId --output text)
EKS_CIDR=$(aws ec2 describe-vpcs --vpc-ids $EKS_VPC --query 'Vpcs[0].CidrBlock' --output text)
RDS_VPC=$DEFAULT_VPC
RDS_CIDR=$(aws ec2 describe-vpcs --vpc-ids $RDS_VPC --query 'Vpcs[0].CidrBlock' --output text)
PCX=$(aws ec2 create-vpc-peering-connection --vpc-id $EKS_VPC --peer-vpc-id $RDS_VPC \
  --query VpcPeeringConnection.VpcPeeringConnectionId --output text)
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id $PCX
aws ec2 modify-vpc-peering-connection-options --vpc-peering-connection-id $PCX \
  --requester-peering-connection-options AllowDnsResolutionFromRemoteVpc=true \
  --accepter-peering-connection-options AllowDnsResolutionFromRemoteVpc=true
for rt in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$EKS_VPC --query 'RouteTables[].RouteTableId' --output text); do
  aws ec2 create-route --route-table-id $rt --destination-cidr-block $RDS_CIDR --vpc-peering-connection-id $PCX; done
for rt in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$RDS_VPC --query 'RouteTables[].RouteTableId' --output text); do
  aws ec2 create-route --route-table-id $rt --destination-cidr-block $EKS_CIDR --vpc-peering-connection-id $PCX; done
aws ec2 authorize-security-group-ingress --group-id $RDS_SG --protocol tcp --port 5432 --cidr $EKS_CIDR
kubectl run pgcheck --rm -it --restart=Never --image=postgres:17 -- pg_isready -h $RDS_ENDPOINT   # accepting connections
```

## 8. Push the images to ECR

```bash
for s in frontend auth-service order-service executor-service; do
  aws ecr create-repository --repository-name $PROJECT/$s >/dev/null 2>&1 || true; done
aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY
export IMAGE_TAG=$(git rev-parse --short=12 HEAD)
docker build -f deploy/docker/frontend.Dockerfile --build-arg APP_DIR=$FRONTEND_DIR -t $ECR_REGISTRY/$PROJECT/frontend:$IMAGE_TAG .
docker build -f deploy/docker/node.Dockerfile --build-arg APP_DIR=$AUTH_DIR --build-arg ENTRY=$AUTH_ENTRY --build-arg PORT=3000 -t $ECR_REGISTRY/$PROJECT/auth-service:$IMAGE_TAG .
docker build -f deploy/docker/java.Dockerfile --build-arg APP_DIR=$ORDER_DIR --build-arg PORT=8081 -t $ECR_REGISTRY/$PROJECT/order-service:$IMAGE_TAG .
docker build -f deploy/docker/java.Dockerfile --build-arg APP_DIR=$EXECUTOR_DIR --build-arg PORT=8082 -t $ECR_REGISTRY/$PROJECT/executor-service:$IMAGE_TAG .
for s in frontend auth-service order-service executor-service; do docker push $ECR_REGISTRY/$PROJECT/$s:$IMAGE_TAG; done
```

## 9. Deploy to EKS, phase 1: four load balancers

`k` fills in `${PROJECT}`, `${ECR_REGISTRY}` and `${IMAGE_TAG}` in a file and applies it:

```bash
k() { envsubst '$PROJECT $ECR_REGISTRY $IMAGE_TAG' < "$1" | kubectl apply -f -; }
k deploy/k8s/common/namespace.yaml
k deploy/k8s/common/storageclass.yaml

# Settings and secrets: the SAME env files docker compose used (pointed at RDS in step 6).
for c in common auth-service order-service executor-service; do
  kubectl -n $PROJECT create configmap $c-config --from-env-file=deploy/env/$c.env
done
kubectl -n $PROJECT create secret generic app-secrets --from-env-file=deploy/env/secrets.env

# Kafka: broker with its disk, its Service, then the topics
k deploy/k8s/kafka/statefulset.yaml; k deploy/k8s/kafka/service.yaml
kubectl -n $PROJECT rollout status statefulset/kafka --timeout=5m
k deploy/k8s/kafka/topics-job.yaml
kubectl -n $PROJECT wait --for=condition=complete job/kafka-topics --timeout=5m

# The four services, each with its own load balancer
for s in auth-service order-service executor-service frontend; do
  k deploy/k8s/$s/deployment.yaml; k deploy/k8s/$s/service.yaml
done
kubectl -n $PROJECT get pods -w          # all 1/1 Running (Ctrl-C)
kubectl -n $PROJECT get svc              # four EXTERNAL-IP addresses (2-3 minutes)

FRONTEND=$(kubectl -n $PROJECT get svc frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w '%{http_code}\n' http://$FRONTEND/ http://$FRONTEND/auth/me    # 200 401
```

Put the page's address into the CORS settings (`env/auth-service.env`,
`env/order-service.env`), then update the ConfigMap and restart (pods read settings only
when they start):

```bash
kubectl -n $PROJECT create configmap auth-service-config --from-env-file=deploy/env/auth-service.env \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $PROJECT rollout restart deployment/auth-service
```

## 10. Phase 2: one load balancer with an Ingress

Install the AWS Load Balancer Controller once per cluster:

```bash
curl -sSLo /tmp/alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.2/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy_$CLUSTER_NAME \
  --policy-document file:///tmp/alb-iam-policy.json
eksctl create iamserviceaccount --cluster $CLUSTER_NAME --region $AWS_REGION \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy_$CLUSTER_NAME \
  --override-existing-serviceaccounts --approve
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=$CLUSTER_NAME --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller --set region=$AWS_REGION --set vpcId=$EKS_VPC
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller
```

Swap each Service for its internal version and add the Ingress:

```bash
for s in auth-service order-service executor-service frontend; do
  kubectl -n $PROJECT delete svc $s                # removes its load balancer
  k deploy/k8s/$s/service-internal.yaml            # same name, inside the cluster only
done
k deploy/k8s/ingress/ingress.yaml
kubectl -n $PROJECT get ingress app -w             # ADDRESS in 2-4 minutes
ALB=$(kubectl -n $PROJECT get ingress app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/ http://$ALB/auth/me    # 200 401
```

## 11. Jenkins

```bash
sudo dnf install -y java-21-amazon-corretto
sudo curl -sSLo /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo dnf install -y jenkins && sudo usermod -aG docker jenkins
sudo systemctl enable --now jenkins
sudo -u jenkins aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
sudo systemctl restart jenkins
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

In `http://<public-ip>:8080`: install the suggested plugins and **GitHub**; add a
credential (*Username with password*: your GitHub user and token, ID `github-token`);
**New Item**, *Pipeline*, *Pipeline script from SCM*, your repository, branch `*/main`,
**Script Path** `deploy/jenkins/Jenkinsfile`, tick *GitHub hook trigger*. In GitHub,
**Settings, Webhooks**: `http://<public-ip>:8080/github-webhook/`, `application/json`,
push events. Every push to `main` now builds, pushes to ECR, deploys and smoke-tests.
The pipeline never touches `app-secrets`: you created it by hand in step 9.

## 12. When something is wrong

From running 30 capstone repositories through these steps: most failures are settings,
not broken code.

| Symptom | Cause and fix |
|---|---|
| A service restarts; its log says a setting is missing (`Could not resolve placeholder 'X'`, `X is not set`, port `NaN`) | Your code reads `X` and there is no default. Add `X=...` to that service's `env/*.env`. Look for every `${...}` without a `:default` at once, not one per restart. |
| `Cannot find config/services.json` / `Shared configuration file not found` / `application.yaml` | The service reads a file from your repository, which is not inside the image. Read the value from the environment first and the file second (the better fix), or copy the file into the image. |
| Frontend build: `Cannot find module`, missing `Config/` or `.env` | The build reads a file outside `FRONTEND_DIR`. The Dockerfile copies the whole repository, so check the relative path the script uses; generated API clients must be generated or committed. |
| Frontend build stops in `check-bundle-secrets`, or never ends | The image build has no secrets (`ALLOW_MISSING_SECRET_VALUES=1` is set for you); a build that never ends after "Output location" has a process left running: build locally and check. |
| Page loads but every API call fails | The page calls `http://localhost:...`. Make the base URLs empty or relative in `environment.prod.ts`. |
| `/actuator/health` 401 or 503; pod never Ready | Spring Security must permit `/actuator/health`; mail health is already off in `java.Dockerfile`. |
| `The server does not support SSL connections` | The service requires SSL; the local Postgres has it on. On RDS keep SSL; make it a setting rather than tied to `NODE_ENV`. |
| `secret must be at least 32 bytes` | Use `openssl rand -hex 32`. |
| SQL fails at `<<<<<<<` | A merge or stash conflict left in a `.sql` file: resolve it. |
| Pod `ImagePullBackOff` | The tag is not in ECR (`aws ecr list-images --repository-name $PROJECT/<svc>`). |
| Pod `CreateContainerConfigError` | `app-secrets` or a ConfigMap is missing in the namespace (step 9). |
| Pod times out connecting to RDS | VPC peering, routes or the RDS security group (step 7); test with the `pgcheck` pod. |
| Kafka `Pending` | No disk: the EBS CSI add-on is not ACTIVE, or `storageclass.yaml` not applied. |
| Ingress has no ADDRESS | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`. |
| Jenkins `permission denied ... docker.sock` / `Unauthorized` | `usermod -aG docker jenkins` and restart; re-run `update-kubeconfig` as jenkins. |

## 13. Clean up (stops the charges)

```bash
kubectl delete namespace $PROJECT                  # load balancers and the Kafka disk
helm uninstall aws-load-balancer-controller -n kube-system || true
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION
aws rds delete-db-instance --db-instance-identifier $PROJECT-db --skip-final-snapshot
aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $PCX
for s in frontend auth-service order-service executor-service; do
  aws ecr delete-repository --repository-name $PROJECT/$s --force; done
```
