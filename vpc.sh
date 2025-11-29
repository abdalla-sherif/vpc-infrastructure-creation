#!/bin/bash
set -e

REGION="eu-north-1"
TAG_PREFIX="devops90"
VPC_CIDR="10.0.0.0/16"

# -----------------------------
# Helper: extract JSON ID safely
# -----------------------------
extract_id() {
    echo "$1" | grep "$2" | awk -F'"' '{print $4}'
}

log() { echo -e "\n[INFO] $1\n"; }

# -----------------------------
# VPC
# -----------------------------
log "Checking VPC..."

check_vpc=$(aws ec2 describe-vpcs --region $REGION \
    --filters Name=tag:Name,Values=$TAG_PREFIX-vpc \
    --output json | grep '"VpcId"' | awk -F'"' '{print $4}')

if [ -z "$check_vpc" ]; then
    log "Creating VPC..."
    vpc_json=$(aws ec2 create-vpc \
        --region $REGION \
        --cidr-block $VPC_CIDR \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$TAG_PREFIX-vpc}]" \
        --output json)
    vpc_id=$(extract_id "$vpc_json" "VpcId")
else
    log "VPC already exists."
    vpc_id=$check_vpc
fi

echo "VPC ID = $vpc_id"

# Enable DNS
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $vpc_id --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $vpc_id --enable-dns-hostnames "{\"Value\":true}"

# -----------------------------
# Subnets
# -----------------------------
create_subnet() {
    NUM=$1
    AZ=$2
    TYPE=$3
    NAME="sub-$TYPE-$NUM-$TAG_PREFIX"

    check_sub=$(aws ec2 describe-subnets --region $REGION \
        --filters Name=tag:Name,Values=$NAME \
        --output json | grep '"SubnetId"' | awk -F'"' '{print $4}')

    if [ -z "$check_sub" ]; then
        log "Creating subnet $NAME..."
        subnet_json=$(aws ec2 create-subnet \
            --region $REGION \
            --vpc-id $vpc_id \
            --availability-zone "$REGION$AZ" \
            --cidr-block 10.0.$NUM.0/24 \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$NAME}]" \
            --output json)
        subnet_id=$(extract_id "$subnet_json" "SubnetId")
    else
        subnet_id=$check_sub
    fi

    echo "$subnet_id"
}

sub1=$(create_subnet 1 a public)
sub2=$(create_subnet 2 b public)
sub3=$(create_subnet 3 a private)
sub4=$(create_subnet 4 b private)

echo "Public Subnets:  $sub1, $sub2"
echo "Private Subnets: $sub3, $sub4"

# -----------------------------
# Internet Gateway
# -----------------------------
log "Checking Internet Gateway..."
igw_check=$(aws ec2 describe-internet-gateways --region $REGION \
    --filters Name=tag:Name,Values=$TAG_PREFIX-igw \
    --output json | grep '"InternetGatewayId"' | awk -F'"' '{print $4}')

if [ -z "$igw_check" ]; then
    log "Creating IGW..."
    igw_json=$(aws ec2 create-internet-gateway --region $REGION \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$TAG_PREFIX-igw}]" \
        --output json)
    igw_id=$(extract_id "$igw_json" "InternetGatewayId")
else
    log "IGW already exists."
    igw_id=$igw_check
fi

echo "IGW ID = $igw_id"

# Attach IGW
attached=$(aws ec2 describe-internet-gateways --region $REGION --internet-gateway-ids $igw_id \
    --output json | grep '"VpcId"' | awk -F'"' '{print $4}' || true)

if [ "$attached" != "$vpc_id" ]; then
    log "Attaching IGW..."
    aws ec2 attach-internet-gateway --region $REGION --internet-gateway-id $igw_id --vpc-id $vpc_id || true
else
    log "IGW already attached."
fi

# -----------------------------
# Elastic IP for NAT
# -----------------------------
log "Checking EIP..."
eip=$(aws ec2 describe-addresses --region $REGION \
    --filters Name=tag:Name,Values=$TAG_PREFIX-eip \
    --output json | grep '"AllocationId"' | awk -F'"' '{print $4}')

if [ -z "$eip" ]; then
    log "Allocating EIP..."
    eip_json=$(aws ec2 allocate-address --region $REGION --domain vpc --output json)
    eip=$(extract_id "$eip_json" "AllocationId")
    aws ec2 create-tags --region $REGION --resources $eip --tags Key=Name,Value=$TAG_PREFIX-eip
fi

echo "EIP = $eip"

# -----------------------------
# NAT Gateway
# -----------------------------
log "Checking NAT Gateway..."
nat=$(aws ec2 describe-nat-gateways --region $REGION \
    --filter Name=tag:Name,Values=$TAG_PREFIX-nat \
    --output json | grep '"NatGatewayId"' | awk -F'"' '{print $4}')

if [ -z "$nat" ]; then
    log "Creating NAT Gateway..."
    nat_json=$(aws ec2 create-nat-gateway --region $REGION \
        --subnet-id $sub1 \
        --allocation-id $eip \
        --output json)
    nat=$(extract_id "$nat_json" "NatGatewayId")
    aws ec2 create-tags --region $REGION --resources $nat --tags Key=Name,Value=$TAG_PREFIX-nat
    log "Waiting for NAT to become available..."
    aws ec2 wait nat-gateway-available --region $REGION --nat-gateway-ids $nat
fi

echo "NAT = $nat"

# -----------------------------
# Route Tables
# -----------------------------
# Public RTB
log "Checking public RTB..."
pub_rtb=$(aws ec2 describe-route-tables --region $REGION \
    --filters Name=tag:Name,Values=public-$TAG_PREFIX-rtb \
    --output json | grep '"RouteTableId"' | awk -F'"' '{print $4}')

if [ -z "$pub_rtb" ]; then
    log "Creating public RTB..."
    pub_json=$(aws ec2 create-route-table --region $REGION --vpc-id $vpc_id --output json)
    pub_rtb=$(extract_id "$pub_json" "RouteTableId")
    aws ec2 create-tags --region $REGION --resources $pub_rtb --tags Key=Name,Value=public-$TAG_PREFIX-rtb
    aws ec2 create-route --region $REGION --route-table-id $pub_rtb --destination-cidr-block 0.0.0.0/0 --gateway-id $igw_id
fi

aws ec2 associate-route-table --region $REGION --route-table-id $pub_rtb --subnet-id $sub1
aws ec2 associate-route-table --region $REGION --route-table-id $pub_rtb --subnet-id $sub2

# Private RTB
log "Checking private RTB..."
priv_rtb=$(aws ec2 describe-route-tables --region $REGION \
    --filters Name=tag:Name,Values=private-$TAG_PREFIX-rtb \
    --output json | grep '"RouteTableId"' | awk -F'"' '{print $4}')

if [ -z "$priv_rtb" ]; then
    log "Creating private RTB..."
    priv_json=$(aws ec2 create-route-table --region $REGION --vpc-id $vpc_id --output json)
    priv_rtb=$(extract_id "$priv_json" "RouteTableId")
    aws ec2 create-tags --region $REGION --resources $priv_rtb --tags Key=Name,Value=private-$TAG_PREFIX-rtb
    aws ec2 create-route --region $REGION --route-table-id $priv_rtb --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $nat
fi

aws ec2 associate-route-table --region $REGION --route-table-id $priv_rtb --subnet-id $sub3
aws ec2 associate-route-table --region $REGION --route-table-id $priv_rtb --subnet-id $sub4

log "VPC Infrastructure Created Successfully!"
