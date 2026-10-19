variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "compie-app"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
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
