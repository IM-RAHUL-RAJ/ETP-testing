# team3 deploy kit

Deployment files for `Neueda-Learning/chennai-capstone-SE1-team3/Application`, written to be generic for the other capstone projects with the same shape (Angular frontend, Node auth/BFF, Spring order service, Spring executor, Kafka, Postgres).

`Application/` mirrors the project's folder: copy it over the project's `Application/` folder.

- New generic Dockerfiles in each component folder. The project's originals are kept as `Dockerfile.999`.
- `docker-compose.yaml` is new. The original is kept as `docker-compose.9999.yml`.
- `k8s/` holds the EKS cluster file, a kustomize base and three overlays: four ELBs, one ALB with an Ingress, and S3 with CloudFront.
- `deploy/` holds the helper scripts and **`deploy/GUIDE.html`**, the step-by-step guide. It covers EC2, Docker, RDS, ECR, EKS, the ELBs or the Ingress, S3, CloudFront, Route 53 and ACM, plus what to change for another project.
- `Frontend/` contains the small code change that lets one image use any API address.

`k8s/base/secrets.env` and `.env` hold secrets and are never committed. Copy them from `secrets.env.example` and `.env.example`.
