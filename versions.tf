terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27.0, < 7.0.0" # 6.27+ required for S3 Vectors-backed Knowledge Bases
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }

  # Remote state (recommended). Create the bucket once, then uncomment and run `terraform init -migrate-state`.
  backend "s3" {
    bucket       = "kredify-terraform-state-418059030617"
    key          = "kredify/copilot/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
