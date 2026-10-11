
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "terraform-state-da5f85cbcc8e"
    key          = "terraform-aws-cicd/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-south-1"
}

data "aws_caller_identity" "current" {}


resource "aws_s3_bucket" "learning" {
  bucket = "terraform-learning-454015599516"

  lifecycle {
    prevent_destroy = true
  }
  
  tags = {
    Name        = "terraform-learning"
    Environment = "learning"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "learning" {
  bucket = aws_s3_bucket.learning.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "learning" {
  bucket = aws_s3_bucket.learning.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}
