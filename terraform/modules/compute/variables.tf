variable "name" {
  description = "Name prefix, e.g. compie-app-dev"
  type        = string
}

variable "region" {
  description = "AWS region (used in user_data and IAM ARNs)"
  type        = string
}

# --- Placement and traffic ---

variable "private_subnet_ids" {
  description = "Private subnets for the instances, one per AZ"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group attached to the instances"
  type        = string
}

variable "target_group_arn" {
  description = "ALB target group the instances register with"
  type        = string
}

# --- Size ---

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "min_size" {
  description = "Minimum number of instances"
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Desired number of instances"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum number of instances (headroom for instance refresh)"
  type        = number
  default     = 4
}

# --- What the instances run and read ---

variable "ecr_repository_url" {
  description = "ECR repository the instances pull the app image from"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository ARN, for the pull permission"
  type        = string
}

variable "param_path" {
  description = "SSM path the instances read their config from at boot"
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group for the container logs"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "DynamoDB table the readiness probe reads"
  type        = string
}

variable "dynamodb_endpoint_id" {
  description = "DynamoDB gateway endpoint: table reads are allowed only through it"
  type        = string
}
