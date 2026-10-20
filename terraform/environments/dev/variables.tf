variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name: prefix of every resource name, ECR repository name"
  type        = string
  default     = "compie-app"
}

variable "environment" {
  description = "Environment name: suffix of every resource name, SSM path segment"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type for the app servers"
  type        = string
  default     = "t3.micro"
}

variable "welcome_message" {
  description = "Returned by GET /. Stored in SSM Parameter Store, not in the image."
  type        = string
  default     = "Hello from the Compie DevOps assignment (dev)"
}

variable "alert_email" {
  description = "Email subscribed to the alerts SNS topic (requires a confirmation click). Empty = no subscription."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Initial image tag (git SHA) already pushed to ECR. Only used on first apply; CI/CD owns it afterwards."
  type        = string
}

variable "github_repository" {
  # GitHub's OIDC "sub" claim uses immutable IDs (owner@<owner-id>/repo@<repo-id>), see the github-oidc module.
  description = "GitHub repo as it appears in the OIDC sub claim (owner@id/name@id)"
  type        = string
  default     = "AmirWeiser@123477471/compie-devops-assignment@1424430511"
}
