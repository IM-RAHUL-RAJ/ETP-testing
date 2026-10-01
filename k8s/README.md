# EKS deployment for 140 associates

This structure follows the prior `leapCloudDeployment/k8s` convention: one
single-replica Deployment and one internal Service per app, JFrog-hosted versioned
images, and a pull secret. The Helm chart packages those per-service files so
multiple associates can deploy into the same group namespace without resource
name/selector collisions.

## Layout and model

- `cluster.yaml` creates one shared EKS cluster with a small, scalable managed
  node group. It does not create any RDS databases.
- `create-namespaces.sh` creates `team-01` through `team-30`, each with a quota
  intended for up to five associates.
- `associate-stack/templates/` has a separate Deployment and Service for the
  frontend, auth service, order service, and trade executor. The Kafka
  StatefulSet and headless Service are separate because Kafka needs stable
  identity and storage.
- Each associate installs the chart once using a unique ID, such as `a001`.
  Their five pods and Services are isolated by unique labels and names, even
  though they share a team namespace.
- Each team group shares one RDS instance. Give each associate a separate
  database and DB user on that instance; do not point all five releases at the
  same database. This keeps their orders/users separated without adding RDS
  instances per associate.

## Capacity reality

One associate requests about 375 millicores and 1.2 GiB across the five pods.
At 140 simultaneous users that is about 52.5 vCPU and 166 GiB of requested
memory, before Kubernetes system overhead and real workload spikes. A `t3.micro`
has only 1 GiB RAM, so even one complete associate stack cannot fit reliably.
The cluster config uses `t3.large` (2 vCPU, 8 GiB) workers as a modest starting
point, with 2 initially and a cap of 50. Expect to scale to roughly 30-40 nodes
for a fully concurrent class; validate using actual JVM/ETL usage before class.
The 2-node initial size is for setup/testing, not 140 simultaneous stacks.

The node group's maximum is not automatic autoscaling by itself. Install and
configure Cluster Autoscaler/Karpenter before relying on pending pods to add
workers, or scale the node group ahead of class. Confirm AWS account EC2/EBS
quotas permit the required nodes and 140 Kafka volumes.

## Prerequisites

Install AWS CLI, `eksctl`, `kubectl`, Helm 3, and the AWS Load Balancer
Controller. Configure AWS credentials and permissions for EKS, IAM, VPC,
Route 53, ACM, EC2, and EBS CSI. Have a DNS domain and an ACM wildcard
certificate for `*.apps.example.com` (substitute your domain).

Create the cluster and gp3 storage class:

```sh
eksctl create cluster -f k8s/cluster.yaml
kubectl apply -f k8s/storageclass.yaml
```

Install the AWS Load Balancer Controller and ensure it has IAM permissions.
The chart's Ingresses share one ALB using the `trading-platform` ingress group;
configure wildcard DNS for `*.apps.example.com` to that ALB. Set a certificate
ARN valid for the wildcard hostnames.

Create the 30 group namespaces and resource quotas:

```sh
sh k8s/create-namespaces.sh
```

## JFrog images

The reference uses the pattern `<jfrog-host>/<docker-repository>/<image>:<tag>`.
The registry host provided for this deployment is `trialzww0tc.jfrog.io`; the
Docker repository key still needs to be supplied by the JFrog administrator.
Build the four existing images from the repository root and push immutable
version `1.0` (or a later version) to that repository:

```sh
docker build -t trading-frontend:1.0 -f sprint8/front-end/Dockerfile sprint8/front-end
docker build -t trading-auth-service:1.0 -f sprint8-auth-service/Dockerfile sprint8-auth-service
docker build -t trading-trade-api:1.0 -f sprint8/Dockerfile sprint8
docker build -t trading-executor:1.0 -f executor/Dockerfile executor
```

Push as `trialzww0tc.jfrog.io/<docker-repository-key>/<image>:1.0`. In
`associate-stack/values.yaml`, replace `REPLACE_WITH_DOCKER_REPOSITORY_KEY`.
Create the `artifactory-pull-secret` image pull secret once in each team
namespace, using a JFrog access token. Never commit the token. Example command
(run once per namespace; enter credentials in your own terminal):

```sh
kubectl -n team-01 create secret docker-registry artifactory-pull-secret \
  --docker-server=trialzww0tc.jfrog.io \
  --docker-username='<JFROG_USER>' \
  --docker-password='<JFROG_ACCESS_TOKEN>'
```

## RDS and per-associate credentials

Provision one RDS instance for each team namespace group, then create a
separate database, database user, and strong password for each associate on
that group's instance. Run `sprint8/db/schema.sql` and `seed-data.sql` against
each associate database. In the schema script, omit the `ALTER ROLE postgres
IN DATABASE trading_system_db ...` statement when using a different database
name; both Java services already specify `currentSchema=trading` in their JDBC
URLs. Give each chart install its own `database.name`, `database.user`, and
runtime secret. The endpoint is shared by the group; database and credentials
are unique per associate.

Create one runtime secret per associate in the team namespace. It must contain
`password`, `jwt-secret`, and `fauxnance-api-key` keys. Do not reuse JWT secrets
or DB passwords between associates.

## Deploy one associate

Example for associate `a001` in `team-01`; replace the RDS endpoint, database
name/user, JFrog repository key, domain, and ACM certificate ARN:

```sh
helm upgrade --install a001 k8s/associate-stack \
  --namespace team-01 \
  --set associateId=a001 \
  --set image.registry=trialzww0tc.jfrog.io/<docker-repository-key> \
  --set image.tag=1.0 \
  --set database.host='<team-01-rds-endpoint>' \
  --set database.name=a001_trading \
  --set database.user=a001_app \
  --set jwt.secretName=a001-runtime-secret \
  --set frontend.baseDomain=apps.example.com \
  --set frontend.certificateArn='<acm-certificate-arn>'
```

Repeat for each associate with a unique ID and one of `team-01` to `team-30`.
The release creates one replica each for frontend, auth, order service,
executor, and Kafka, plus the services, Kafka topic Job, and Ingress. The
associate URL is `https://a001.apps.example.com`.

## Kafka storage

Kafka is one KRaft broker/controller per associate, with replication factor 1
and a 2 GiB encrypted gp3 EBS volume. Messages survive pod deletion/restart
while the PVC remains. This matches the low message volume while avoiding data
loss on ordinary pod replacement. A single broker cannot survive loss of its
EBS volume or availability zone; keep backups if messages are important.
Storage is allocated only for Kafka; app pods and RDS do not use Kubernetes
volumes. Analytics ETL is disabled by default to avoid a shared DuckDB volume.

## Check status

```sh
kubectl -n team-01 get pods,pvc,services,ingress
kubectl -n team-01 rollout status deployment/a001-frontend
kubectl -n team-01 rollout status deployment/a001-auth-service
kubectl -n team-01 rollout status deployment/a001-order-service
kubectl -n team-01 rollout status deployment/a001-trade-executor
kubectl -n team-01 rollout status statefulset/a001-kafka
```