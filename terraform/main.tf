terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# VPC for EKS
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "observability-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "observability"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "observability-cluster"
  cluster_version = "1.27"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    observability = {
      instance_types = ["m5.large"]
      min_size       = 3
      max_size       = 6
      desired_size   = 3
    }
  }

  # Enable OIDC provider
  enable_irsa = true

  tags = {
    Terraform   = "true"
    Environment = "observability"
  }
}

# AMP Workspace
resource "aws_prometheus_workspace" "observability" {
  alias = "observability-workspace"

  tags = {
    Environment = "observability"
  }
}

# S3 buckets for Loki
resource "aws_s3_bucket" "loki_chunks" {
  bucket = "observability-loki-chunks"

  tags = {
    Environment = "observability"
    Purpose     = "loki-storage"
  }
}

resource "aws_s3_bucket" "loki_ruler" {
  bucket = "observability-loki-ruler"

  tags = {
    Environment = "observability"
    Purpose     = "loki-storage"
  }
}

resource "aws_s3_bucket" "loki_admin" {
  bucket = "observability-loki-admin"

  tags = {
    Environment = "observability"
    Purpose     = "loki-storage"
  }
}

# SNS Topics
resource "aws_sns_topic" "devops_guru" {
  name = "DevOpsGuruNotifications"
}

resource "aws_sns_topic" "incident_manager" {
  name = "IncidentManagerNotifications"
}

resource "aws_sns_topic" "chatops" {
  name = "ChatOpsIncidents"
}

# Outputs
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus workspace ID"
  value       = aws_prometheus_workspace.observability.id
}

output "amp_endpoint" {
  description = "Amazon Managed Prometheus endpoint"
  value       = aws_prometheus_workspace.observability.prometheus_endpoint
}