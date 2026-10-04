# Shared settings for the pipeline scripts. Sourced, not run.
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export CLUSTER="${CLUSTER:-capstone}"
export NS="${NS:-tester}"
# name -> build context
IMAGES=(
  "trading-auth-service:sprint8-auth-service"
  "trading-trade-api:sprint8"
  "trading-executor:executor"
  "trading-frontend:sprint8/front-end"
)
registry() {
  echo "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
}
