# One-time foundation resources that must exist before the main stack:
#   - S3 bucket for the main stack's Terraform state
#   - ECR repository, so an image can be pushed before the ASG first launches
# This stack uses local state (terraform.tfstate here, gitignored).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "compie-app"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

# --- Terraform state bucket ---

resource "aws_s3_bucket" "tfstate" {
  # Account ID keeps the globally-unique name predictable without hardcoding it.
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Protect state history: destroy fails while the bucket holds objects/versions.
  # To tear down, empty the bucket deliberately first (documented in the README).
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Container registry ---

resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # dev only: lets `destroy` remove the repo with images in it

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}
