#!/usr/bin/env bash
# ============================================================
#  testing/jury-deploy.sh
#  LKS 2026 — Jury Full Deployment (Idempotent)
#
#  Setiap step dicek dulu — kalau sudah ada, dilewati (skip).
#  Aman dijalankan berulang kali tanpa membuat ulang resource.
#
#  Cara pakai:
#    cd /path/to/infralks26
#    chmod +x testing/jury-deploy.sh
#    ./testing/jury-deploy.sh
#
#  Env var untuk kontrol eksekusi:
#    ONLY_ASSESS=1  -- langsung jury-assess saja (skip semua deploy)
#    SKIP_BUILD=1   -- skip docker build (pakai image yang ada)
#    SKIP_TF=1      -- skip terraform (pakai infra yang ada)
#    SKIP_ECS=1     -- skip ECS create/update (pakai service yang ada)
#    SKIP_ECS=force -- force update ECS meski sudah running
#
#  Idempotent — setiap resource dicek dulu, skip jika sudah ada:
#    Step 1: S3 bucket  → skip jika sudah ada
#    Step 2: ECR repos  → skip jika sudah ada
#    Step 3: Docker     → skip jika image tag sudah di ECR
#    Step 4: tfvars     → skip jika file sudah ada
#    Step 5: Terraform  → skip jika lks-vpc sudah ada di AWS
#    Step 6: ECS cluster/service → skip jika sudah ACTIVE/running
#    Step 9: Monitoring → skip jika sudah ACTIVE/running
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/tmp/jury-deploy-$(date +%Y%m%d-%H%M%S).log"
log()   { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"    | tee -a "$LOG_FILE"; }
skip()  { echo -e "${CYAN}[SKIP]${NC} $1"  | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
die()   { echo -e "${RED}[ERR]${NC} $1"    | tee -a "$LOG_FILE"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}━━━ STEP $1: $2 ━━━${NC}\n" | tee -a "$LOG_FILE"; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"

echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     LKS 2026 — JURY DEPLOYMENT SCRIPT          ║${NC}"
echo -e "${BOLD}║     Idempotent — aman dijalankan berulang kali  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  Log: ${CYAN}$LOG_FILE${NC}"
echo ""

# ── Shortcut: hanya assessment ──────────────────────────────
if [ "${ONLY_ASSESS:-0}" = "1" ]; then
  log "ONLY_ASSESS=1 — langsung jalankan jury-assess.sh"
  bash "$ROOT_DIR/testing/jury-assess.sh" "JURY-VERIFICATION"
  exit $?
fi

# ── Step 0: Preflight ────────────────────────────────────────
step "0" "Preflight Checks"
for cmd in aws terraform docker jq curl git; do
  command -v "$cmd" &>/dev/null \
    && ok "$cmd tersedia" \
    || die "$cmd tidak terinstal"
done

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) \
  || die "AWS credentials tidak valid atau expired"
ok "AWS credentials — Account: $ACCOUNT_ID"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"
ECR_OREGON="$ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com"
IMAGE_TAG=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "latest")
LAB_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/LabRole"

# Get student name for S3 bucket
if [ -f "$TF_DIR/terraform.tfvars" ]; then
  STUDENT_NAME=$(grep "student_name" "$TF_DIR/terraform.tfvars" \
    | head -1 | sed 's/.*= *"\(.*\)".*/\1/' || echo "")
fi
if [ -z "${STUDENT_NAME:-}" ]; then
  read -rp "  Masukkan nama Anda (untuk S3 bucket): " STUDENT_NAME
  [ -z "$STUDENT_NAME" ] && die "Nama tidak boleh kosong"
fi
TF_STATE_BUCKET="lks-tfstate-${STUDENT_NAME// /-}-2026"
ok "Student: $STUDENT_NAME | Bucket: $TF_STATE_BUCKET"

# ── Step 1: S3 State Bucket ──────────────────────────────────
step "1" "S3 State Bucket"
if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
  skip "S3 '$TF_STATE_BUCKET' sudah ada"
else
  log "Membuat S3 bucket..."
  aws s3 mb "s3://$TF_STATE_BUCKET" --region us-east-1
  aws s3api put-bucket-versioning \
    --bucket "$TF_STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  ok "S3 bucket dibuat"
fi

# ── Step 2: ECR Repositories ────────────────────────────────
step "2" "ECR Repositories"
for REPO in lks-fe-app lks-api-app; do
  URI=$(aws ecr describe-repositories --repository-names "$REPO" \
    --region us-east-1 --query 'repositories[0].repositoryUri' \
    --output text 2>/dev/null || echo "")
  if [ -n "$URI" ] && [ "$URI" != "None" ]; then
    skip "ECR $REPO (us-east-1): sudah ada"
  else
    aws ecr create-repository --repository-name "$REPO" \
      --region us-east-1 --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --output json >/dev/null
    ok "ECR $REPO dibuat"
  fi
done

PURI=$(aws ecr describe-repositories --repository-names lks-prometheus \
  --region us-west-2 --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null || echo "")
if [ -n "$PURI" ] && [ "$PURI" != "None" ]; then
  skip "ECR lks-prometheus (us-west-2): sudah ada"
else
  aws ecr create-repository --repository-name lks-prometheus \
    --region us-west-2 --image-tag-mutability MUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --output json >/dev/null
  ok "ECR lks-prometheus dibuat"
fi

# ── Step 3: Docker Build & Push ──────────────────────────────
step "3" "Docker Build & Push"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
  skip "SKIP_BUILD=1 — melewati docker build"
else
  # Check if current git SHA already pushed
  FE_TAG_EXISTS=$(aws ecr list-images --repository-name lks-fe-app \
    --region us-east-1 \
    --query "imageIds[?imageTag=='$IMAGE_TAG'] | length(@)" \
    --output text 2>/dev/null || echo "0")

  if [ "${FE_TAG_EXISTS:-0}" -gt 0 ]; then
    skip "Docker image tag $IMAGE_TAG sudah ada di ECR — skip build"
  else
    log "Login ke ECR..."
    aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    aws ecr get-login-password --region us-west-2 \
      | docker login --username AWS --password-stdin "$ECR_OREGON"

    log "Build & push Frontend..."
    docker build -t "$ECR_REGISTRY/lks-fe-app:$IMAGE_TAG" \
                 -t "$ECR_REGISTRY/lks-fe-app:latest" \
                 "$ROOT_DIR/frontend"
    docker push "$ECR_REGISTRY/lks-fe-app:$IMAGE_TAG"
    docker push "$ECR_REGISTRY/lks-fe-app:latest"
    ok "Frontend pushed: $IMAGE_TAG"

    log "Build & push API..."
    docker build -t "$ECR_REGISTRY/lks-api-app:$IMAGE_TAG" \
                 -t "$ECR_REGISTRY/lks-api-app:latest" \
                 "$ROOT_DIR/api"
    docker push "$ECR_REGISTRY/lks-api-app:$IMAGE_TAG"
    docker push "$ECR_REGISTRY/lks-api-app:latest"
    ok "API pushed: $IMAGE_TAG"

    log "Build & push Prometheus..."
    aws ecr get-login-password --region us-west-2 \
      | docker login --username AWS --password-stdin "$ECR_OREGON"
    docker build -t "$ECR_OREGON/lks-prometheus:$IMAGE_TAG" \
                 -t "$ECR_OREGON/lks-prometheus:latest" \
                 "$ROOT_DIR/monitoring"
    docker push "$ECR_OREGON/lks-prometheus:$IMAGE_TAG"
    docker push "$ECR_OREGON/lks-prometheus:latest"
    ok "Prometheus pushed: $IMAGE_TAG"
  fi
fi

# ── Step 4: terraform.tfvars ─────────────────────────────────
step "4" "terraform.tfvars"
if [ -f "$TF_DIR/terraform.tfvars" ]; then
  skip "terraform.tfvars sudah ada"
  # Show current values
  grep -E "student_name|aws_account_id" "$TF_DIR/terraform.tfvars" \
    | while read -r l; do log "  $l"; done
else
  cat > "$TF_DIR/terraform.tfvars" << TFVARS
aws_region        = "us-east-1"
monitoring_region = "us-west-2"
aws_account_id    = "$ACCOUNT_ID"
student_name      = "$STUDENT_NAME"
vpc_cidr                      = "10.0.0.0/16"
monitoring_vpc_cidr           = "10.1.0.0/16"
public_subnet_cidrs           = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs          = ["10.0.3.0/24", "10.0.4.0/24"]
isolated_subnet_cidrs         = ["10.0.5.0/24", "10.0.6.0/24"]
availability_zones            = ["us-east-1a", "us-east-1b"]
monitoring_subnet_cidrs       = ["10.1.1.0/24", "10.1.2.0/24"]
monitoring_availability_zones = ["us-west-2a", "us-west-2b"]
db_name           = "lksdb"
db_username       = "lksadmin"
db_password       = "LKSSecure2026!"
TFVARS
  ok "terraform.tfvars dibuat"
fi

# ── Step 5: Terraform ────────────────────────────────────────
step "5" "Terraform Init & Apply"

# Check if infra already exists via AWS CLI (tidak butuh terraform state)
EXISTING_VPC=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=lks-vpc" "Name=state,Values=available" \
  --query 'Vpcs[0].VpcId' --output text --region us-east-1 2>/dev/null || echo "")

if [ "${SKIP_TF:-0}" = "1" ]; then
  skip "SKIP_TF=1 — melewati terraform"
elif [ -n "$EXISTING_VPC" ] && [ "$EXISTING_VPC" != "None" ]; then
  skip "Terraform sudah di-apply — lks-vpc: $EXISTING_VPC (skip re-apply)"
else
  log "VPC belum ada — jalankan terraform apply..."
  cd "$TF_DIR"
  terraform init \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=prod/terraform.tfstate" \
    -backend-config="region=us-east-1" \
    -reconfigure -upgrade -input=false 2>&1 | tee -a "$LOG_FILE"
  ok "terraform init selesai"

  terraform apply -auto-approve -input=false 2>&1 | tee -a "$LOG_FILE"
  ok "terraform apply selesai"
  cd "$ROOT_DIR"
fi

# Read outputs — prefer terraform output, fallback to AWS CLI
log "Membaca outputs..."
cd "$TF_DIR"
# Try terraform output first (works if .terraform/ exists and state is in S3)
if terraform output -raw vpc_id &>/dev/null 2>&1; then
  VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
  MON_VPC_ID=$(terraform output -raw monitoring_vpc_id 2>/dev/null || echo "")
  PEERING_STATUS=$(terraform output -raw peering_connection_status 2>/dev/null || echo "")
  ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null || echo "")
  SG_ECS=$(terraform output -raw sg_ecs_id 2>/dev/null || echo "")
  SG_MON=$(terraform output -raw sg_monitoring_oregon_id 2>/dev/null || echo "")
  TG_FE=$(terraform output -raw tg_fe_arn 2>/dev/null || echo "")
  TG_API=$(terraform output -raw tg_api_arn 2>/dev/null || echo "")
  PRIVATE_SUBNETS=$(terraform output -json private_subnet_ids 2>/dev/null \
    | jq -r '[.[]] | join(",")' || echo "")
  ALL_MON_SUBNETS=$(terraform output -json monitoring_subnet_ids 2>/dev/null \
    | jq -r '[.[]] | join(",")' || echo "")
  RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null \
    | cut -d: -f1 || echo "")
  ok "Outputs dari terraform state"
else
  # Fallback: AWS CLI — read directly from AWS
  warn "terraform output tidak tersedia — membaca langsung dari AWS CLI..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=lks-vpc" \
    --query 'Vpcs[0].VpcId' --output text --region us-east-1 2>/dev/null || echo "")
  MON_VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=lks-monitoring-vpc" \
    --query 'Vpcs[0].VpcId' --output text --region us-west-2 2>/dev/null || echo "")
  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --names lks-alb \
    --query 'LoadBalancers[0].DNSName' --output text --region us-east-1 2>/dev/null || echo "")
  SG_ECS=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=lks-sg-ecs" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text --region us-east-1 2>/dev/null || echo "")
  SG_MON=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=lks-sg-vpce" \
    --query 'SecurityGroups[0].GroupId' --output text --region us-west-2 2>/dev/null || echo "")
  TG_FE=$(aws elbv2 describe-target-groups \
    --names lks-tg-fe \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region us-east-1 2>/dev/null || echo "")
  TG_API=$(aws elbv2 describe-target-groups \
    --names lks-tg-api \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region us-east-1 2>/dev/null || echo "")
  PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=lks-private-subnet-*" \
    --query 'Subnets[*].SubnetId' --output text --region us-east-1 2>/dev/null \
    | tr '\t' ',' || echo "")
  ALL_MON_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$MON_VPC_ID" \
    --query 'Subnets[*].SubnetId' --output text --region us-west-2 2>/dev/null \
    | tr '\t' ',' || echo "")
  RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier lks-rds-postgres \
    --query 'DBInstances[0].Endpoint.Address' --output text --region us-east-1 2>/dev/null || echo "localhost")
  PEERING_STATUS=$(aws ec2 describe-vpc-peering-connections \
    --filters "Name=tag:Name,Values=pcx-lks-2026" \
    --query 'VpcPeeringConnections[0].Status.Code' --output text --region us-east-1 2>/dev/null || echo "")
  ok "Outputs dari AWS CLI"
fi
cd "$ROOT_DIR"

[ -n "$VPC_ID" ]       && ok "VPC: $VPC_ID"           || warn "VPC output kosong"
[ -n "$ALB_DNS" ]      && ok "ALB: $ALB_DNS"           || warn "ALB output kosong"
[ "$PEERING_STATUS" = "active" ] \
  && ok "Peering: active" \
  || warn "Peering: $PEERING_STATUS"

# Ensure route 10.1.0.0/16 in lks-private-rt
if [ -n "$VPC_ID" ]; then
  PRIV_RT=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=lks-private-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region us-east-1 2>/dev/null || echo "")
  if [ -n "$PRIV_RT" ] && [ "$PRIV_RT" != "None" ]; then
    RT_ROUTE=$(aws ec2 describe-route-tables \
      --route-table-ids "$PRIV_RT" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='10.1.0.0/16'] | length(@)" \
      --output text --region us-east-1 2>/dev/null || echo "0")
    if [ "${RT_ROUTE:-0}" -eq 0 ]; then
      warn "Route 10.1.0.0/16 tidak ada — menambahkan..."
      PCX_ID=$(aws ec2 describe-vpc-peering-connections \
        --filters "Name=tag:Name,Values=pcx-lks-2026" "Name=status-code,Values=active" \
        --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' \
        --output text --region us-east-1 2>/dev/null || echo "")
      [ -n "$PCX_ID" ] && [ "$PCX_ID" != "None" ] && \
        aws ec2 create-route \
          --route-table-id "$PRIV_RT" \
          --destination-cidr-block "10.1.0.0/16" \
          --vpc-peering-connection-id "$PCX_ID" \
          --region us-east-1 2>/dev/null \
          && ok "Route 10.1.0.0/16 ditambahkan" \
          || warn "Gagal tambah route"
    else
      ok "Route 10.1.0.0/16 sudah ada"
    fi
  fi
fi

# Ensure TCP 9100 rule in lks-sg-ecs
if [ -n "$SG_ECS" ]; then
  RULE_EXISTS=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ECS" \
    --query "length(SecurityGroups[0].IpPermissions[?FromPort==\`9100\` && IpRanges[?CidrIp=='10.1.0.0/16']])" \
    --output text --region us-east-1 2>/dev/null || echo "0")
  if [ "${RULE_EXISTS:-0}" -eq 0 ]; then
    warn "TCP 9100 tidak ada — menambahkan..."
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ECS" --protocol tcp --port 9100 \
      --cidr "10.1.0.0/16" --region us-east-1 2>/dev/null \
      && ok "TCP 9100 ditambahkan" \
      || warn "Gagal tambah rule (mungkin sudah ada)"
  else
    ok "TCP 9100 sudah ada"
  fi
fi

# ── Step 6: ECS Application Cluster ─────────────────────────
step "6" "ECS Application Cluster (us-east-1)"

if [ "${SKIP_ECS:-0}" = "1" ]; then
  skip "SKIP_ECS=1 — melewati ECS"
else
  # Cluster
  CLUSTER_STATUS=$(aws ecs describe-clusters --clusters lks-ecs-cluster \
    --query 'clusters[0].status' --output text --region us-east-1 2>/dev/null || echo "")
  if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
    skip "lks-ecs-cluster sudah ada"
  else
    aws ecs create-cluster \
      --cluster-name lks-ecs-cluster \
      --settings name=containerInsights,value=enabled \
      --region us-east-1 --output json >/dev/null
    ok "lks-ecs-cluster dibuat"
  fi

  # CloudWatch Log Groups
  for LG in /ecs/lks-fe-app /ecs/lks-api-app; do
    aws logs create-log-group --log-group-name "$LG" \
      --region us-east-1 2>/dev/null || true
    aws logs put-retention-policy --log-group-name "$LG" \
      --retention-in-days 7 --region us-east-1 2>/dev/null || true
  done
  ok "CloudWatch Log Groups siap"

  # Task Definition: Frontend — skip jika service sudah running dengan task yang benar
  FE_RUNNING=$(aws ecs list-tasks \
    --cluster lks-ecs-cluster --service-name lks-fe-service \
    --desired-status RUNNING \
    --query 'length(taskArns)' --output text --region us-east-1 2>/dev/null || echo "0")

  if [ "${FE_RUNNING:-0}" -gt 0 ] && [ "${SKIP_ECS:-0}" != "force" ]; then
    skip "lks-fe-service sudah running ($FE_RUNNING task) — skip task definition update"
    FE_TD="(existing)"
  else
  FE_TD=$(aws ecs register-task-definition \
    --family lks-fe-task \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 256 --memory 512 \
    --execution-role-arn "$LAB_ROLE_ARN" \
    --task-role-arn "$LAB_ROLE_ARN" \
    --container-definitions "[{
      \"name\": \"lks-fe-app\",
      \"image\": \"$ECR_REGISTRY/lks-fe-app:latest\",
      \"portMappings\": [{\"containerPort\": 3000, \"protocol\": \"tcp\"}],
      \"essential\": true,
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/lks-fe-app\",
          \"awslogs-region\": \"us-east-1\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      },
      \"healthCheck\": {
        \"command\": [\"CMD-SHELL\",\"curl -f http://localhost:3000/health || exit 1\"],
        \"interval\": 30, \"timeout\": 5, \"retries\": 3
      }
    }]" \
    --region us-east-1 \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  ok "Task Definition lks-fe-task: $FE_TD"
  fi  # end FE running check

  # Task Definition: API — skip jika service sudah running
  API_RUNNING=$(aws ecs list-tasks \
    --cluster lks-ecs-cluster --service-name lks-api-service \
    --desired-status RUNNING \
    --query 'length(taskArns)' --output text --region us-east-1 2>/dev/null || echo "0")

  if [ "${API_RUNNING:-0}" -gt 0 ] && [ "${SKIP_ECS:-0}" != "force" ]; then
    skip "lks-api-service sudah running ($API_RUNNING task) — skip task definition update"
    API_TD="(existing)"
  else
  API_TD=$(aws ecs register-task-definition \
    --family lks-api-task \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 512 --memory 1024 \
    --execution-role-arn "$LAB_ROLE_ARN" \
    --task-role-arn "$LAB_ROLE_ARN" \
    --container-definitions "[{
      \"name\": \"lks-api-app\",
      \"image\": \"$ECR_REGISTRY/lks-api-app:latest\",
      \"portMappings\": [
        {\"containerPort\": 8080, \"protocol\": \"tcp\"},
        {\"containerPort\": 9100, \"protocol\": \"tcp\"}
      ],
      \"essential\": true,
      \"environment\": [
        {\"name\": \"PORT\",         \"value\": \"8080\"},
        {\"name\": \"METRICS_PORT\", \"value\": \"9100\"},
        {\"name\": \"DB_HOST\",      \"value\": \"$RDS_ENDPOINT\"},
        {\"name\": \"DB_PORT\",      \"value\": \"5432\"},
        {\"name\": \"DB_NAME\",      \"value\": \"lksdb\"},
        {\"name\": \"DB_USER\",      \"value\": \"lksadmin\"},
        {\"name\": \"DB_PASSWORD\",  \"value\": \"LKSSecure2026!\"},
        {\"name\": \"DB_SSL\",       \"value\": \"true\"},
        {\"name\": \"AWS_REGION\",   \"value\": \"us-east-1\"},
        {\"name\": \"NODE_ENV\",     \"value\": \"production\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/lks-api-app\",
          \"awslogs-region\": \"us-east-1\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      },
      \"healthCheck\": {
        \"command\": [\"CMD-SHELL\",\"curl -f http://localhost:8080/api/health || exit 1\"],
        \"interval\": 30, \"timeout\": 5, \"retries\": 3
      }
    }]" \
    --region us-east-1 \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  ok "Task Definition lks-api-task: $API_TD"
  fi  # end API running check

  # ECS Service: Frontend
  FE_SVC=$(aws ecs describe-services --cluster lks-ecs-cluster \
    --services lks-fe-service \
    --query 'services[0].status' --output text --region us-east-1 2>/dev/null || echo "")
  if [ "$FE_SVC" = "ACTIVE" ]; then
    log "lks-fe-service sudah ada — update image..."
    aws ecs update-service \
      --cluster lks-ecs-cluster --service lks-fe-service \
      --task-definition lks-fe-task \
      --force-new-deployment \
      --region us-east-1 --output json >/dev/null
    ok "lks-fe-service diupdate"
  else
    aws ecs create-service \
      --cluster lks-ecs-cluster \
      --service-name lks-fe-service \
      --task-definition lks-fe-task \
      --desired-count 1 \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={
        subnets=[$PRIVATE_SUBNETS],
        securityGroups=[$SG_ECS],
        assignPublicIp=DISABLED
      }" \
      --load-balancers "targetGroupArn=$TG_FE,containerName=lks-fe-app,containerPort=3000" \
      --region us-east-1 --output json >/dev/null
    ok "lks-fe-service dibuat"
  fi

  # ECS Service: API
  API_SVC=$(aws ecs describe-services --cluster lks-ecs-cluster \
    --services lks-api-service \
    --query 'services[0].status' --output text --region us-east-1 2>/dev/null || echo "")
  if [ "$API_SVC" = "ACTIVE" ]; then
    log "lks-api-service sudah ada — update image..."
    aws ecs update-service \
      --cluster lks-ecs-cluster --service lks-api-service \
      --task-definition lks-api-task \
      --force-new-deployment \
      --region us-east-1 --output json >/dev/null
    ok "lks-api-service diupdate"
  else
    aws ecs create-service \
      --cluster lks-ecs-cluster \
      --service-name lks-api-service \
      --task-definition lks-api-task \
      --desired-count 1 \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={
        subnets=[$PRIVATE_SUBNETS],
        securityGroups=[$SG_ECS],
        assignPublicIp=DISABLED
      }" \
      --load-balancers "targetGroupArn=$TG_API,containerName=lks-api-app,containerPort=8080" \
      --region us-east-1 --output json >/dev/null
    ok "lks-api-service dibuat"
  fi
fi # SKIP_ECS

# ── Step 7: Tunggu ECS Healthy ───────────────────────────────
step "7" "Tunggu ECS Services Healthy"

for SVC in lks-api-service lks-fe-service; do
  # Check if already running
  ALREADY=$(aws ecs list-tasks \
    --cluster lks-ecs-cluster --service-name "$SVC" \
    --desired-status RUNNING \
    --query 'length(taskArns)' --output text --region us-east-1 2>/dev/null || echo "0")
  if [ "${ALREADY:-0}" -gt 0 ]; then
    ok "$SVC: sudah running ($ALREADY task)"
    continue
  fi

  log "Menunggu $SVC healthy (maks 5 menit)..."
  for i in $(seq 1 30); do
    RC=$(aws ecs list-tasks \
      --cluster lks-ecs-cluster --service-name "$SVC" \
      --desired-status RUNNING \
      --query 'length(taskArns)' --output text --region us-east-1 2>/dev/null || echo "0")
    [ "${RC:-0}" -gt 0 ] && { ok "$SVC running ($RC tasks)"; break; }
    log "  Menunggu... ($i/30)"
    sleep 10
  done
done

# ── Step 8: Update Prometheus Config ─────────────────────────
step "8" "Ambil ECS Task IPs & Update Prometheus"

sleep 10  # brief pause for tasks to register IPs
TASK_ARNS=$(aws ecs list-tasks \
  --cluster lks-ecs-cluster \
  --region us-east-1 \
  --query 'taskArns[]' --output text 2>/dev/null || echo "")

TASK_IPS=()
if [ -n "$TASK_ARNS" ]; then
  while IFS= read -r ARN; do
    [ -z "$ARN" ] && continue
    IP=$(aws ecs describe-tasks \
      --cluster lks-ecs-cluster --tasks "$ARN" \
      --region us-east-1 \
      --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value | [0]' \
      --output text 2>/dev/null || echo "")
    [ -n "$IP" ] && [ "$IP" != "None" ] && TASK_IPS+=("$IP") && log "  Task IP: $IP"
  done <<< "$TASK_ARNS"
fi

PROM_YML="$ROOT_DIR/monitoring/prometheus/prometheus.yml"
if [ ${#TASK_IPS[@]} -ge 2 ]; then
  sed -i "s|10\.0\.3\.10:9100|${TASK_IPS[0]}:9100|g" "$PROM_YML"
  sed -i "s|10\.0\.3\.11:9100|${TASK_IPS[1]}:9100|g" "$PROM_YML"
  ok "prometheus.yml diupdate: API=${TASK_IPS[0]} FE=${TASK_IPS[1]}"

  # Rebuild Prometheus image with real IPs
  aws ecr get-login-password --region us-west-2 \
    | docker login --username AWS --password-stdin "$ECR_OREGON" 2>/dev/null
  docker build -t "$ECR_OREGON/lks-prometheus:latest" "$ROOT_DIR/monitoring" 2>/dev/null
  docker push "$ECR_OREGON/lks-prometheus:latest" 2>/dev/null
  ok "Prometheus image di-rebuild dengan IP nyata"
elif [ ${#TASK_IPS[@]} -eq 1 ]; then
  sed -i "s|10\.0\.3\.10:9100|${TASK_IPS[0]}:9100|g" "$PROM_YML"
  warn "Hanya 1 IP ditemukan (${TASK_IPS[0]}) — update baris kedua manual"
else
  warn "Belum ada task IPs — Prometheus pakai placeholder"
fi

# ── Step 9: ECS Monitoring Cluster ───────────────────────────
step "9" "ECS Monitoring Cluster (us-west-2)"

if [ "${SKIP_ECS:-0}" = "1" ]; then
  skip "SKIP_ECS=1 — melewati monitoring cluster"
else
  MON_STATUS=$(aws ecs describe-clusters --clusters lks-monitoring-cluster \
    --query 'clusters[0].status' --output text --region us-west-2 2>/dev/null || echo "")
  if [ "$MON_STATUS" = "ACTIVE" ]; then
    skip "lks-monitoring-cluster sudah ada"
  else
    aws ecs create-cluster \
      --cluster-name lks-monitoring-cluster \
      --region us-west-2 --output json >/dev/null
    ok "lks-monitoring-cluster dibuat"
  fi

  aws logs create-log-group --log-group-name /ecs/lks-prometheus \
    --region us-west-2 2>/dev/null || true
  aws logs put-retention-policy --log-group-name /ecs/lks-prometheus \
    --retention-in-days 7 --region us-west-2 2>/dev/null || true

  PROM_RUNNING=$(aws ecs list-tasks \
    --cluster lks-monitoring-cluster --service-name lks-prometheus-service \
    --desired-status RUNNING \
    --query 'length(taskArns)' --output text --region us-west-2 2>/dev/null || echo "0")

  if [ "${PROM_RUNNING:-0}" -gt 0 ] && [ "${SKIP_ECS:-0}" != "force" ]; then
    skip "lks-prometheus-service sudah running ($PROM_RUNNING task) — skip task definition"
    PROM_TD="(existing)"
  else
  PROM_TD=$(aws ecs register-task-definition \
    --family lks-prometheus-task \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 256 --memory 512 \
    --execution-role-arn "$LAB_ROLE_ARN" \
    --task-role-arn "$LAB_ROLE_ARN" \
    --container-definitions "[{
      \"name\": \"lks-prometheus\",
      \"image\": \"$ECR_OREGON/lks-prometheus:latest\",
      \"portMappings\": [{\"containerPort\": 9090, \"protocol\": \"tcp\"}],
      \"essential\": true,
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/lks-prometheus\",
          \"awslogs-region\": \"us-west-2\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }]" \
    --region us-west-2 \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  ok "Task Definition lks-prometheus-task: $PROM_TD"
  fi  # end PROM running check

  PROM_SVC=$(aws ecs describe-services \
    --cluster lks-monitoring-cluster --services lks-prometheus-service \
    --query 'services[0].status' --output text --region us-west-2 2>/dev/null || echo "")
  if [ "$PROM_SVC" = "ACTIVE" ]; then
    log "lks-prometheus-service sudah ada — force redeploy dengan image baru..."
    aws ecs update-service \
      --cluster lks-monitoring-cluster \
      --service lks-prometheus-service \
      --task-definition lks-prometheus-task \
      --force-new-deployment \
      --region us-west-2 --output json >/dev/null
    ok "lks-prometheus-service diupdate"
  else
    aws ecs create-service \
      --cluster lks-monitoring-cluster \
      --service-name lks-prometheus-service \
      --task-definition lks-prometheus-task \
      --desired-count 1 \
      --launch-type FARGATE \
      --enable-execute-command \
      --network-configuration "awsvpcConfiguration={
        subnets=[$ALL_MON_SUBNETS],
        securityGroups=[$SG_MON],
        assignPublicIp=DISABLED
      }" \
      --region us-west-2 --output json >/dev/null
    ok "lks-prometheus-service dibuat"
  fi
fi

# ── Step 10: Tunggu & Verifikasi ─────────────────────────────
step "10" "Tunggu Prometheus & ALB Healthy"

# Wait Prometheus — skip jika sudah running
PTASK=""
PROM_IP=""
PROM_OK=false

# Cek dulu apakah sudah running
PROM_ALREADY=$(aws ecs list-tasks \
  --cluster lks-monitoring-cluster --service-name lks-prometheus-service \
  --desired-status RUNNING \
  --query 'length(taskArns)' --output text --region us-west-2 2>/dev/null || echo "0")

if [ "${PROM_ALREADY:-0}" -gt 0 ]; then
  skip "Prometheus sudah running ($PROM_ALREADY task)"
  PTASK=$(aws ecs list-tasks \
    --cluster lks-monitoring-cluster --service-name lks-prometheus-service \
    --query 'taskArns[0]' --output text --region us-west-2 2>/dev/null || echo "")
  PROM_IP=$(aws ecs describe-tasks \
    --cluster lks-monitoring-cluster --tasks "$PTASK" --region us-west-2 \
    --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value | [0]' \
    --output text 2>/dev/null || echo "")
  [ -n "$PROM_IP" ] && ok "Prometheus IP: $PROM_IP"
  PROM_OK=true
else
  for i in $(seq 1 30); do
    PR=$(aws ecs list-tasks \
      --cluster lks-monitoring-cluster --service-name lks-prometheus-service \
      --desired-status RUNNING \
      --query 'length(taskArns)' --output text --region us-west-2 2>/dev/null || echo "0")
    if [ "${PR:-0}" -gt 0 ]; then
      ok "Prometheus running ($PR task)"
      PTASK=$(aws ecs list-tasks \
        --cluster lks-monitoring-cluster --service-name lks-prometheus-service \
        --query 'taskArns[0]' --output text --region us-west-2 2>/dev/null || echo "")
      PROM_IP=$(aws ecs describe-tasks \
        --cluster lks-monitoring-cluster --tasks "$PTASK" --region us-west-2 \
        --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value | [0]' \
        --output text 2>/dev/null || echo "")
      [ -n "$PROM_IP" ] && log "Prometheus IP: $PROM_IP"
      PROM_OK=true
      break
    fi
    log "  Menunggu Prometheus... ($i/30)"
    sleep 10
  done
fi

# Wait ALB — cek dulu apakah sudah healthy
ALB_OK=false
ALB_QUICK=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5   "http://$ALB_DNS/api/health" 2>/dev/null || echo "000")
if [ "$ALB_QUICK" = "200" ]; then
  skip "ALB sudah healthy (HTTP 200) — skip wait"
  ALB_OK=true
else
  log "Tunggu ALB healthy (maks 10 menit)..."
  for i in $(seq 1 60); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
    "http://$ALB_DNS/api/health" 2>/dev/null || echo "000")
  if [ "$HTTP" = "200" ]; then
    ok "ALB → /api/health: HTTP 200"
    ALB_OK=true
    break
  fi
  if [ $((i % 6)) -eq 0 ] && [ -n "$TG_API" ]; then
    TG_STATE=$(aws elbv2 describe-target-health \
      --target-group-arn "$TG_API" \
      --query 'TargetHealthDescriptions[*].TargetHealth.State' \
      --output text --region us-east-1 2>/dev/null || echo "unknown")
    log "  TG states: $TG_STATE | HTTP=$HTTP ($i/60)"
  else
    log "  Menunggu ALB... ($i/60) HTTP=$HTTP"
  fi
  sleep 10
done
[ "$ALB_OK" = "false" ] && warn "ALB belum healthy setelah 10 menit"

# ── Step 11: Jury Assessment ──────────────────────────────────
step "11" "Jalankan Jury Assessment"
bash "$ROOT_DIR/testing/jury-assess.sh" "JURY-VERIFICATION" 2>&1 | tee -a "$LOG_FILE"

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  RINGKASAN DEPLOYMENT                        ║${NC}"
echo -e "${BOLD}╠═══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  ALB     : http://$ALB_DNS"
echo -e "${BOLD}║${NC}  Prom IP : ${PROM_IP:-tidak tersedia} (private)"
echo -e "${BOLD}║${NC}  Tag     : $IMAGE_TAG"
echo -e "${BOLD}║${NC}  Log     : $LOG_FILE"
echo -e "${BOLD}╠═══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Shortcuts untuk run berikutnya:"
echo -e "${BOLD}║${NC}    ONLY_ASSESS=1 ./testing/jury-deploy.sh"
echo -e "${BOLD}║${NC}    SKIP_BUILD=1 SKIP_TF=1 ./testing/jury-deploy.sh"
echo -e "${BOLD}║${NC}    SKIP_ECS=1 ./testing/jury-deploy.sh"
echo -e "${BOLD}╚═══════════════════════════════════════════════╝${NC}"
