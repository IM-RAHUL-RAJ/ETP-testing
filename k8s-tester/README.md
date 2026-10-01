# Individual EKS test stack

This folder is separate from `k8s/`, which is for the 30 shared team
namespaces. It creates one test EKS cluster, one `tester` namespace, and one
instance of each service. PostgreSQL is not deployed in Kubernetes; configure
an RDS database for this test.

## Create the test cluster

Requirements: AWS credentials with EKS/VPC/IAM permissions, `eksctl`,
`kubectl`, and Helm is not required for this static test bundle.

```sh
eksctl create cluster -f k8s-tester/cluster.yaml
kubectl apply -f k8s-tester/namespace.yaml
```

The single worker is a `t3.medium`, not a `t3.micro`: the five application
pods request about 1.2 GiB RAM before EKS system pods. It is sized for one
person testing, not a class. The EBS CSI add-on provisions encrypted gp3 disks.

## Configure external services and image pulls

1. In `configmap.yaml`, set `DB_HOST`, `DB_NAME`, and `DB_USER` for your test
   database in RDS. Apply the existing schema and seed files once to that RDS
   database: `sprint8/db/schema.sql` and `sprint8/db/seed-data.sql`.
2. Replace `REPLACE_WITH_DOCKER_REPOSITORY_KEY` in the four deployment files
   with the JFrog Docker repository key. The image paths use
   `trialzww0tc.jfrog.io/<repository>/<image>:1.0`.
3. Create the JFrog pull secret in your terminal; use a JFrog access token and
   do not put it in a manifest:

```sh
kubectl -n tester create secret docker-registry artifactory-pull-secret \
  --docker-server=trialzww0tc.jfrog.io \
  --docker-username='<JFROG_USER>' \
  --docker-password='<JFROG_ACCESS_TOKEN>'
```

4. Create the runtime secret. Use a strong unique JWT secret, the RDS user's
   password, and your Fauxnance API key:

```sh
kubectl -n tester create secret generic trading-secrets \
  --from-literal=db-password='<RDS_PASSWORD>' \
  --from-literal=jwt-secret='<LONG_RANDOM_JWT_SECRET>' \
  --from-literal=fauxnance-api-key='<FAUXNANCE_API_KEY>'
```

## Deploy and test

Apply the test stack (the EKS cluster config is intentionally not part of the
Kustomize bundle):

```sh
kubectl apply -k k8s-tester/
kubectl -n tester get pods,pvc,services,jobs
kubectl -n tester wait --for=condition=complete job/kafka-topics --timeout=10m
```

Wait for all four Deployments and Kafka to become ready, then open three
terminals and keep these port-forwards running:

```sh
kubectl -n tester port-forward service/frontend 4200:4200
kubectl -n tester port-forward service/auth-service 3000:3000
kubectl -n tester port-forward service/order-service 8085:8085
```

Open `http://localhost:4200`. Frontend API URLs are set to the matching local
ports. The executor, auth service, and trade API connect to RDS; the executor
and frontend share the 5 GiB analytics PVC. Kafka has one replica and its own
2 GiB EBS claim, retained across pod replacement.

## Kafka durability and cleanup

The persisted Kafka volume protects against ordinary pod termination. With a
single broker, it cannot protect messages if the EBS volume or its availability
zone is lost. Back up the volume if test messages matter.

To remove the test cluster and its workloads:

```sh
eksctl delete cluster -f k8s-tester/cluster.yaml
```

Review AWS EBS volumes and RDS separately before deleting them; cluster
deletion and retained-volume behavior depend on the storage reclaim policy.