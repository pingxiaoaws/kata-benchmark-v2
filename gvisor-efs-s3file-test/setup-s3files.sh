#!/usr/bin/env bash
# setup-s3files.sh — 创建 S3 Files 文件系统 & Mount Target
# 用法: ./setup-s3files.sh <cluster-name> <s3-bucket-name> <s3files-role-arn>
set -euo pipefail

CLUSTER_NAME="${1:-test-s4}"
S3_BUCKET="${2:-}"         # 需要用户提供
S3FILES_ROLE_ARN="${3:-}"  # S3 Files 访问 S3 bucket 的 IAM Role ARN
REGION="${AWS_DEFAULT_REGION:-us-west-2}"
SG_NAME="gvisor-s3files-sg"

if [ -z "$S3_BUCKET" ] || [ -z "$S3FILES_ROLE_ARN" ]; then
  echo "Usage: $0 <cluster-name> <s3-bucket-name> <s3files-role-arn>"
  echo ""
  echo "Prerequisites:"
  echo "  1. An S3 bucket in the same region"
  echo "  2. An IAM role that allows S3 Files to access the bucket"
  echo "     (trust policy: s3files.amazonaws.com; policy: s3:GetObject, s3:PutObject, s3:ListBucket, etc.)"
  echo ""
  echo "Example:"
  echo "  $0 test-s4 my-s3files-bucket arn:aws:iam::123456789012:role/S3FilesAccessRole"
  exit 1
fi

echo "=== S3 Files Setup ==="
echo "Cluster: $CLUSTER_NAME"
echo "Bucket:  $S3_BUCKET"
echo "Role:    $S3FILES_ROLE_ARN"
echo "Region:  $REGION"
echo ""

# Step 1: Get VPC ID
echo "[1/5] Getting VPC ID..."
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text \
  --region "$REGION")
echo "  VPC: $VPC_ID"

# Step 2: Get VPC CIDR
echo "[2/5] Getting VPC CIDR..."
CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query "Vpcs[].CidrBlock" \
  --output text \
  --region "$REGION")
echo "  CIDR: $CIDR"

# Step 3: Create Security Group
echo "[3/5] Creating Security Group..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "S3 Files mount target SG for gVisor test" \
  --vpc-id "$VPC_ID" \
  --output text \
  --region "$REGION" 2>/dev/null) || \
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region "$REGION")
echo "  SG: $SG_ID"

# Allow NFS inbound
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 2049 \
  --cidr "$CIDR" \
  --region "$REGION" 2>/dev/null || echo "  (NFS rule already exists)"

# Step 4: Create S3 Files file system
echo "[4/5] Creating S3 Files file system..."
FS_ID=$(aws s3files create-file-system \
  --region "$REGION" \
  --bucket "arn:aws:s3:::${S3_BUCKET}" \
  --client-token "${CLUSTER_NAME}-gvisor-test" \
  --role-arn "$S3FILES_ROLE_ARN" \
  --query 'FileSystemId' \
  --output text)
echo "  FileSystem: $FS_ID"

# Wait for file system to become available
echo "  Waiting for file system to be available..."
for i in $(seq 1 30); do
  STATUS=$(aws s3files describe-file-system \
    --file-system-id "$FS_ID" \
    --query 'LifeCycleState' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "creating")
  [ "$STATUS" = "available" ] && break
  sleep 10
done
echo "  Status: $STATUS"

# Step 5: Create mount targets
echo "[5/5] Creating mount targets..."
# Get subnet for our test node
NODE_SUBNET=$(kubectl get node ip-172-31-9-46.us-west-2.compute.internal \
  -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "")

# Get all subnets in VPC
SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].SubnetId' \
  --output text \
  --region "$REGION")

for SUBNET in $SUBNETS; do
  echo "  Creating mount target in $SUBNET..."
  aws s3files create-mount-target \
    --file-system-id "$FS_ID" \
    --subnet-id "$SUBNET" \
    --security-groups "$SG_ID" \
    --region "$REGION" 2>/dev/null || echo "    (already exists or failed)"
done

echo ""
echo "=== Done ==="
echo ""
echo "S3 Files FileSystem ID: $FS_ID"
echo ""
echo "Next steps:"
echo "  1. Update manifests/s3files-static-pv.yaml with volumeHandle: s3files:${FS_ID}"
echo "  2. kubectl apply -f manifests/"
echo "  3. Run: ./s3files-fio-benchmark.sh"
