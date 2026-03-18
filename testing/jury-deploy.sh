#!/usr/bin/env bash
# ============================================================
#  testing/jury-deploy.sh
#  LKS 2026 — Jury Full Deployment (Proof of Concept)
#
#  Script ini men-deploy SELURUH infrastruktur LKS 2026 dari nol,
#  identik dengan apa yang diharapkan dari siswa, digunakan juri
#  untuk memverifikasi soal bisa dikerjakan sebelum kompetisi.
#
#  Cara pakai:
#    cd /path/to/infralks26
#    chmod +x testing/jury-deploy.sh
#    ./testing/jury-deploy.sh
#
#  Prasyarat:
#    - AWS CLI dengan credentials aktif (us-east-1)
#    - terraform >= 1.8
#    - docker (untuk build image)
#    - jq, curl
#    - GitHub repo sudah dibuat dan code sudah di-push
#    - GitHub Secrets sudah dikonfigurasi (lihat .github/SETUP.md)
#    - S3 state bucket sudah dibuat
# ============================================================
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/tmp/jury-deploy-$(date +%Y%m%d-%H%M%S).log"

log()   { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"   | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}[ERR]${NC} $1"   | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
die()   { err "$1"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}━━━ STEP $1: $2 ━━━${NC}\n" | tee -a "$LOG_FILE"; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"

# ── Banner ──────────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     LKS 2026 — JURY FULL DEPLOYMENT SCRIPT     ║${NC}"
echo -e "${BOLD}║     Deploying complete LKS 2026 architecture    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  Log: ${CYAN}$LOG_FILE${NC}\n"

# ── Preflight checks ────────────────────────────────────────
step "0" "Preflight Checks"

for cmd in aws terraform docker jq curl git; do
  command -v "$cmd" &>/dev/null \
    && ok "$cmd tersedia" \
    || die "$cmd tidak terinstal — install dulu"
done

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) \
  || die "AWS credentials tidak valid atau expired"
ok "AWS credentials valid — Account: $ACCOUNT_ID"

REGION=$(aws configure get region 2>/dev/null || echo "")
[ "$REGION" = "us-east-1" ] \
  || warn "Default region '$REGION' — pastikan us-east-1 aktif"

# Minta input dari juri
echo ""
read -rp "  Masukkan nama Anda (untuk S3 bucket naming): " STUDENT_NAME
[ -z "$STUDENT_NAME" ] && die "Nama tidak boleh kosong"

TF_STATE_BUCKET="lks-tfstate-${STUDENT_NAME// /-}-2026"
log "S3 state bucket: $TF_STATE_BUCKET"

# ── Step 1: S3 State Bucket ──────────────────────────────────
step "1" "Buat S3 State Bucket"

BUCKET_EXISTS=$(aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null && echo "yes" || echo "no")
if [ "$BUCKET_EXISTS" = "yes" ]; then
  ok "S3 bucket '$TF_STATE_BUCKET' sudah ada"
else
  log "Membuat S3 bucket $TF_STATE_BUCKET ..."
  aws s3 mb "s3://$TF_STATE_BUCKET" --region us-east-1
  aws s3api put-bucket-versioning \
    --bucket "$TF_STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption \
    --bucket "$TF_STATE_BUCKET" \
    --server-side-encryption-configuration '{
      "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
    }'
  ok "S3 bucket dibuat: $TF_STATE_BUCKET"
fi

# ── Step 2: ECR Repositories (Manual — buat via CLI) ────────
step "2" "Buat ECR Repositories (Manual)"

log "Membuat ECR repositories..."
for REPO in lks-fe-app lks-api-app; do
  EXISTS=$(aws ecr describe-repositories --repository-names "$REPO" \
    --region us-east-1 --query 'repositories[0].repositoryUri' \
    --output text 2>/dev/null || echo "")
  if [ -n "$EXISTS" ] && [ "$EXISTS" != "None" ]; then
    ok "ECR $REPO (us-east-1): sudah ada"
  else
    aws ecr create-repository \
      --repository-name "$REPO" \
      --region us-east-1 \
      --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --output json | jq -r '.repository.repositoryUri' | xargs -I{} echo "Created: {}"
    ok "ECR $REPO dibuat di us-east-1"
  fi
done

PROM_EXISTS=$(aws ecr describe-repositories --repository-names lks-prometheus \
  --region us-west-2 --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null || echo "")
if [ -n "$PROM_EXISTS" ] && [ "$PROM_EXISTS" != "None" ]; then
  ok "ECR lks-prometheus (us-west-2): sudah ada"
else
  aws ecr create-repository \
    --repository-name lks-prometheus \
    --region us-west-2 \
    --image-tag-mutability MUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --output json | jq -r '.repository.repositoryUri' | xargs -I{} echo "Created: {}"
  ok "ECR lks-prometheus dibuat di us-west-2"
fi

# ── Step 3: Build & Push Docker Images ──────────────────────
step "3" "Build & Push Docker Images ke ECR"

ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"
ECR_OREGON="$ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com"
IMAGE_TAG=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "latest")

log "Login ke ECR us-east-1..."
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

log "Login ke ECR us-west-2..."
aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS --password-stdin "$ECR_OREGON"

log "Build & push Frontend..."
docker build -t "$ECR_REGISTRY/lks-fe-app:$IMAGE_TAG" \
             -t "$ECR_REGISTRY/lks-fe-app:latest" \
             "$ROOT_DIR/frontend"
docker push "$ECR_REGISTRY/lks-fe-app:$IMAGE_TAG"
docker push "$ECR_REGISTRY/lks-fe-app:latest"
ok "Frontend image pushed: $IMAGE_TAG"

log "Build & push API..."
docker build -t "$ECR_REGISTRY/lks-api-app:$IMAGE_TAG" \
             -t "$ECR_REGISTRY/lks-api-app:latest" \
             "$ROOT_DIR/api"
docker push "$ECR_REGISTRY/lks-api-app:$IMAGE_TAG"
docker push "$ECR_REGISTRY/lks-api-app:latest"
ok "API image pushed: $IMAGE_TAG"

log "Build & push Prometheus config image..."
docker build -t "$ECR_OREGON/lks-prometheus:$IMAGE_TAG" \
             -t "$ECR_OREGON/lks-prometheus:latest" \
             "$ROOT_DIR/monitoring"
docker push "$ECR_OREGON/lks-prometheus:$IMAGE_TAG"
docker push "$ECR_OREGON/lks-prometheus:latest"
ok "Prometheus image pushed ke us-west-2: $IMAGE_TAG"

# ── Step 4: Write terraform.tfvars ──────────────────────────
step "4" "Buat terraform.tfvars"

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

# ── Step 5: Terraform Apply ──────────────────────────────────
step "5" "Terraform Init, Plan & Apply"

cd "$TF_DIR"
log "terraform init..."
# -reconfigure: handles 'Backend configuration changed' error without prompting
# -upgrade: picks up any new provider version requirements from modules
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -reconfigure \
  -upgrade \
  -input=false 2>&1 | tee -a "$LOG_FILE"
ok "terraform init selesai"

log "terraform validate..."
terraform validate 2>&1 | tee -a "$LOG_FILE"
ok "terraform validate OK"

log "terraform plan..."
terraform plan -out=tfplan -input=false 2>&1 | tee -a "$LOG_FILE"
ok "terraform plan selesai"

log "terraform apply..."
terraform apply -auto-approve tfplan 2>&1 | tee -a "$LOG_FILE"
ok "terraform apply selesai"

# Read all terraform outputs immediately after apply
log "Membaca terraform outputs..."
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
MON_VPC_ID=$(terraform output -raw monitoring_vpc_id 2>/dev/null || echo "")
PEERING_ID=$(terraform output -raw peering_connection_id 2>/dev/null || echo "")
PEERING_STATUS=$(terraform output -raw peering_connection_status 2>/dev/null || echo "")
ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null || echo "")
SG_ECS=$(terraform output -raw sg_ecs_id 2>/dev/null || echo "")
SG_MON=$(terraform output -raw sg_monitoring_oregon_id 2>/dev/null || echo "")
TG_FE=$(terraform output -raw tg_fe_arn 2>/dev/null || echo "")
TG_API=$(terraform output -raw tg_api_arn 2>/dev/null || echo "")
PRIVATE_SUBNETS=$(terraform output -json private_subnet_ids 2>/dev/null | jq -r '[.[]] | join(",")' || echo "")
ALL_MON_SUBNETS=$(terraform output -json monitoring_subnet_ids 2>/dev/null | jq -r '[.[]] | join(",")' || echo "")
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null | cut -d: -f1 || echo "localhost")
[ -n "$VPC_ID" ]       && ok "VPC: $VPC_ID"          || warn "VPC output kosong"
[ -n "$ALB_DNS" ]      && ok "ALB: $ALB_DNS"          || warn "ALB output kosong"
[ -n "$PEERING_STATUS" ] && ok "Peering: $PEERING_STATUS" || warn "Peering output kosong"

# Ensure route 10.1.0.0/16 exists in lks-private-rt (Virginia)
log "Verifikasi route 10.1.0.0/16 di lks-private-rt..."
PRIV_RT=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=lks-private-rt" \
  --query 'RouteTables[0].RouteTableId' --output text --region us-east-1 2>/dev/null || echo "")
if [ -n "$PRIV_RT" ] && [ "$PRIV_RT" != "None" ]; then
  RT_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-ids "$PRIV_RT" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='10.1.0.0/16'] | length(@)" \
    --output text --region us-east-1 2>/dev/null || echo "0")
  if [ "${RT_ROUTE:-0}" -eq 0 ]; then
    warn "Route 10.1.0.0/16 tidak ada — menambahkan manual via peering connection..."
    PCX_ID=$(aws ec2 describe-vpc-peering-connections \
      --filters "Name=tag:Name,Values=pcx-lks-2026" "Name=status-code,Values=active" \
      --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' \
      --output text --region us-east-1 2>/dev/null || echo "")
    if [ -n "$PCX_ID" ] && [ "$PCX_ID" != "None" ]; then
      aws ec2 create-route \
        --route-table-id "$PRIV_RT" \
        --destination-cidr-block "10.1.0.0/16" \
        --vpc-peering-connection-id "$PCX_ID" \
        --region us-east-1 2>/dev/null \
        && ok "Route 10.1.0.0/16 ditambahkan ke lks-private-rt" \
        || warn "Gagal tambah route — mungkin sudah ada"
    else
      warn "Peering connection tidak aktif — cek VPC Peering di Console"
    fi
  else
    ok "Route 10.1.0.0/16 sudah ada di lks-private-rt"
  fi
fi

# Ensure TCP 9100 rule exists in lks-sg-ecs (sometimes missed if SG pre-existed)
log "Verifikasi rule TCP 9100 di lks-sg-ecs..."
if [ -n "$SG_ECS" ]; then
  RULE_EXISTS=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ECS" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`9100\`] | length(@)" \
    --output text --region us-east-1 2>/dev/null || echo "0")
  if [ "${RULE_EXISTS:-0}" -eq 0 ]; then
    warn "TCP 9100 rule tidak ada — menambahkan manual..."
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ECS" \
      --protocol tcp --port 9100 \
      --cidr "10.1.0.0/16" \
      --region us-east-1 2>/dev/null \
      && ok "TCP 9100 rule ditambahkan ke lks-sg-ecs" \
      || warn "Gagal tambah rule — cek manual di Console"
  else
    ok "lks-sg-ecs: TCP 9100 dari 10.1.0.0/16 sudah ada"
  fi
fi

# Read outputs
MON_SUBNETS=$(terraform output -json monitoring_subnet_ids 2>/dev/null | jq -r '.[]' | head -1 || echo "")
PEERING_STATUS=$(terraform output -raw peering_connection_status 2>/dev/null || echo "")
TG_FE=$(terraform output -raw tg_fe_arn 2>/dev/null || echo "")
TG_API=$(terraform output -raw tg_api_arn 2>/dev/null || echo "")
cd "$ROOT_DIR"

ok "VPC: $VPC_ID"
ok "ALB: $ALB_DNS"
ok "Peering: $PEERING_STATUS"

[ "$PEERING_STATUS" != "active" ] && \
  warn "Peering belum active — tunggu beberapa detik lalu cek kembali"

# ── Step 6: ECS Application Cluster ─────────────────────────
step "6" "Buat ECS Application Cluster (us-east-1)"

LAB_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/LabRole"

# Create cluster
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters lks-ecs-cluster \
  --query 'clusters[0].status' --output text --region us-east-1 2>/dev/null || echo "")
if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
  ok "lks-ecs-cluster sudah ada"
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
ok "CloudWatch Log Groups dibuat"

# Task Definition: Frontend
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

# Task Definition: API
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

# Get all private subnet IDs for ECS services
ALL_PRIVATE_SUBNETS=$(cd "$TF_DIR" && terraform output -json private_subnet_ids 2>/dev/null \
  | jq -r '[.[]] | join(",")' || echo "")

# ECS Service: Frontend
FE_SVC_STATUS=$(aws ecs describe-services --cluster lks-ecs-cluster \
  --services lks-fe-service --query 'services[0].status' \
  --output text --region us-east-1 2>/dev/null || echo "")
if [ "$FE_SVC_STATUS" = "ACTIVE" ]; then
  log "lks-fe-service sudah ada, update task definition..."
  aws ecs update-service \
    --cluster lks-ecs-cluster \
    --service lks-fe-service \
    --task-definition lks-fe-task \
    --force-new-deployment \
    --region us-east-1 --output json >/dev/null
else
  aws ecs create-service \
    --cluster lks-ecs-cluster \
    --service-name lks-fe-service \
    --task-definition lks-fe-task \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
      subnets=[$ALL_PRIVATE_SUBNETS],
      securityGroups=[$SG_ECS],
      assignPublicIp=DISABLED
    }" \
    --load-balancers "targetGroupArn=$TG_FE,containerName=lks-fe-app,containerPort=3000" \
    --region us-east-1 --output json >/dev/null
fi
ok "ECS Service lks-fe-service: dibuat/diupdate"

# ECS Service: API
API_SVC_STATUS=$(aws ecs describe-services --cluster lks-ecs-cluster \
  --services lks-api-service --query 'services[0].status' \
  --output text --region us-east-1 2>/dev/null || echo "")
if [ "$API_SVC_STATUS" = "ACTIVE" ]; then
  log "lks-api-service sudah ada, update task definition..."
  aws ecs update-service \
    --cluster lks-ecs-cluster \
    --service lks-api-service \
    --task-definition lks-api-task \
    --force-new-deployment \
    --region us-east-1 --output json >/dev/null
else
  aws ecs create-service \
    --cluster lks-ecs-cluster \
    --service-name lks-api-service \
    --task-definition lks-api-task \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
      subnets=[$ALL_PRIVATE_SUBNETS],
      securityGroups=[$SG_ECS],
      assignPublicIp=DISABLED
    }" \
    --load-balancers "targetGroupArn=$TG_API,containerName=lks-api-app,containerPort=8080" \
    --region us-east-1 --output json >/dev/null
fi
ok "ECS Service lks-api-service: dibuat/diupdate"

# ── Step 7: Tunggu ECS healthy ───────────────────────────────
step "7" "Tunggu ECS Services Healthy"

log "Tunggu lks-api-service healthy (maks 5 menit)..."
for i in $(seq 1 30); do
  RUNNING=$(aws ecs describe-services \
    --cluster lks-ecs-cluster --services lks-api-service \
    --query 'services[0].runningCount' --output text --region us-east-1 2>/dev/null || echo 0)
  if [ "${RUNNING:-0}" -gt 0 ]; then
    ok "lks-api-service running ($RUNNING tasks)"
    break
  fi
  log "Menunggu... ($i/30) running=$RUNNING"
  sleep 10
done

log "Tunggu lks-fe-service healthy..."
for i in $(seq 1 30); do
  RUNNING=$(aws ecs describe-services \
    --cluster lks-ecs-cluster --services lks-fe-service \
    --query 'services[0].runningCount' --output text --region us-east-1 2>/dev/null || echo 0)
  if [ "${RUNNING:-0}" -gt 0 ]; then
    ok "lks-fe-service running ($RUNNING tasks)"
    break
  fi
  log "Menunggu... ($i/30) running=$RUNNING"
  sleep 10
done

# ── Step 8: Get ECS Task IPs & Update Prometheus config ──────
step "8" "Ambil ECS Task IPs & Update Prometheus Config"

log "Ambil private IPs ECS tasks di us-east-1..."
sleep 10  # Give tasks a moment to register

TASK_ARNS=$(aws ecs list-tasks \
  --cluster lks-ecs-cluster \
  --region us-east-1 \
  --query 'taskArns[]' --output text 2>/dev/null || echo "")

declare -a TASK_IPS=()
if [ -n "$TASK_ARNS" ]; then
  while IFS= read -r ARN; do
    IP=$(aws ecs describe-tasks \
      --cluster lks-ecs-cluster --tasks "$ARN" \
      --region us-east-1 \
      --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value | [0]' \
      --output text 2>/dev/null || echo "")
    if [ -n "$IP" ] && [ "$IP" != "None" ]; then
      TASK_IPS+=("$IP")
      log "  Task IP: $IP"
    fi
  done <<< "$TASK_ARNS"
fi

if [ ${#TASK_IPS[@]} -ge 2 ]; then
  API_IP="${TASK_IPS[0]}"
  FE_IP="${TASK_IPS[1]}"
  
  log "Update prometheus.yml dengan IP nyata: API=$API_IP FE=$FE_IP"
  
  # Update prometheus.yml with real IPs
  sed -i "s|10.0.3.10:9100|$API_IP:9100|g" \
    "$ROOT_DIR/monitoring/prometheus/prometheus.yml"
  sed -i "s|10.0.3.11:9100|$FE_IP:9100|g" \
    "$ROOT_DIR/monitoring/prometheus/prometheus.yml"
  
  # Rebuild and push Prometheus image with updated config
  log "Rebuild Prometheus image dengan IP yang benar..."
  docker build -t "$ECR_OREGON/lks-prometheus:latest" \
               "$ROOT_DIR/monitoring"
  docker push "$ECR_OREGON/lks-prometheus:latest"
  ok "Prometheus image di-rebuild dengan IP nyata"
elif [ ${#TASK_IPS[@]} -eq 1 ]; then
  API_IP="${TASK_IPS[0]}"
  sed -i "s|10.0.3.10:9100|$API_IP:9100|g" \
    "$ROOT_DIR/monitoring/prometheus/prometheus.yml"
  docker build -t "$ECR_OREGON/lks-prometheus:latest" "$ROOT_DIR/monitoring"
  docker push "$ECR_OREGON/lks-prometheus:latest"
  warn "Hanya 1 task IP ditemukan ($API_IP) — pastikan kedua services running"
else
  warn "Belum ada task IPs — Prometheus akan menggunakan IP placeholder"
  warn "Update monitoring/prometheus/prometheus.yml secara manual setelah tasks running"
fi

# ── Step 9: ECS Monitoring Cluster (Oregon) ──────────────────
step "9" "Buat ECS Monitoring Cluster (us-west-2)"

MON_CLUSTER_STATUS=$(aws ecs describe-clusters --clusters lks-monitoring-cluster \
  --query 'clusters[0].status' --output text --region us-west-2 2>/dev/null || echo "")
if [ "$MON_CLUSTER_STATUS" = "ACTIVE" ]; then
  ok "lks-monitoring-cluster sudah ada"
else
  aws ecs create-cluster \
    --cluster-name lks-monitoring-cluster \
    --region us-west-2 --output json >/dev/null
  ok "lks-monitoring-cluster dibuat di us-west-2"
fi

aws logs create-log-group --log-group-name /ecs/lks-prometheus \
  --region us-west-2 2>/dev/null || true
aws logs put-retention-policy --log-group-name /ecs/lks-prometheus \
  --retention-in-days 7 --region us-west-2 2>/dev/null || true
ok "CloudWatch Log Group /ecs/lks-prometheus dibuat"

# Task Definition: Prometheus
ALL_MON_SUBNETS=$(cd "$TF_DIR" && terraform output -json monitoring_subnet_ids 2>/dev/null \
  | jq -r '[.[]] | join(",")' || echo "")

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

# ECS Service: Prometheus
PROM_SVC_STATUS=$(aws ecs describe-services --cluster lks-monitoring-cluster \
  --services lks-prometheus-service --query 'services[0].status' \
  --output text --region us-west-2 2>/dev/null || echo "")
if [ "$PROM_SVC_STATUS" = "ACTIVE" ]; then
  aws ecs update-service \
    --cluster lks-monitoring-cluster \
    --service lks-prometheus-service \
    --task-definition lks-prometheus-task \
    --force-new-deployment \
    --region us-west-2 --output json >/dev/null
  ok "lks-prometheus-service diupdate (force new deployment)"
else
  aws ecs create-service \
    --cluster lks-monitoring-cluster \
    --service-name lks-prometheus-service \
    --task-definition lks-prometheus-task \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
      subnets=[$ALL_MON_SUBNETS],
      securityGroups=[$SG_MON],
      assignPublicIp=DISABLED
    }" \
    --region us-west-2 --output json >/dev/null
  ok "lks-prometheus-service dibuat di us-west-2"
fi

# ── Step 10: Tunggu semua services healthy ────────────────────
step "10" "Tunggu Prometheus Healthy & Verifikasi"

log "Tunggu Prometheus task running (maks 5 menit)..."
for i in $(seq 1 30); do
  PR=$(aws ecs describe-services \
    --cluster lks-monitoring-cluster --services lks-prometheus-service \
    --query 'services[0].runningCount' --output text --region us-west-2 2>/dev/null || echo 0)
  if [ "${PR:-0}" -gt 0 ]; then
    ok "Prometheus running ($PR task)"
    break
  fi
  log "Menunggu Prometheus... ($i/30)"
  sleep 10
done

# Get Prometheus IP
PTASK=$(aws ecs list-tasks \
  --cluster lks-monitoring-cluster --service-name lks-prometheus-service \
  --query 'taskArns[0]' --output text --region us-west-2 2>/dev/null || echo "")
PROM_IP=""
if [ -n "$PTASK" ] && [ "$PTASK" != "None" ]; then
  PROM_IP=$(aws ecs describe-tasks \
    --cluster lks-monitoring-cluster --tasks "$PTASK" --region us-west-2 \
    --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value | [0]' \
    --output text 2>/dev/null || echo "")
  log "Prometheus private IP: $PROM_IP"
fi

# Wait for ALB to be ready
log "Tunggu ALB health check (maks 3 menit)..."
for i in $(seq 1 18); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://$ALB_DNS/api/health" 2>/dev/null || echo "000")
  if [ "$HTTP" = "200" ]; then
    ok "ALB → /api/health: HTTP 200"
    break
  fi
  log "Menunggu ALB... ($i/18) HTTP=$HTTP"
  sleep 10
done

# ── Step 11: Run assessment ───────────────────────────────────
step "11" "Jalankan Jury Assessment"

log "Menjalankan jury-assess.sh untuk verifikasi akhir..."
cd "$ROOT_DIR"
bash testing/jury-assess.sh "JURY-VERIFICATION" 2>&1 | tee -a "$LOG_FILE"

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     DEPLOYMENT SELESAI — RINGKASAN              ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  ALB URL    : http://$ALB_DNS"
echo -e "${BOLD}║${NC}  Prometheus : $PROM_IP:9090 (private, akses via VPN/bastion)"
echo -e "${BOLD}║${NC}  Image Tag  : $IMAGE_TAG"
echo -e "${BOLD}║${NC}  Log        : $LOG_FILE"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Langkah verifikasi Prometheus (manual):${NC}"
echo -e "  Buka http://$PROM_IP:9090/targets di browser"
echo -e "  Semua target harus berstatus UP"
echo ""
{
  echo "DEPLOYMENT SUMMARY"
  echo "ALB URL    : http://$ALB_DNS"
  echo "Prometheus : $PROM_IP:9090"
  echo "Image Tag  : $IMAGE_TAG"
  echo "Student    : $STUDENT_NAME"
  echo "Completed  : $(date)"
} >> "$LOG_FILE"

echo -e "${GREEN}${BOLD}Deployment juri selesai! Soal siap digunakan.${NC}"
