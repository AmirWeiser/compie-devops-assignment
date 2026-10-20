variable "name" {
  description = "Name of the load balancer and target group (max 32 characters)"
  type        = string
}

variable "vpc_id" {
  description = "VPC of the target group"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets in at least 2 AZs"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group attached to the ALB"
  type        = string
}

variable "app_port" {
  description = "Port the targets listen on"
  type        = number
}

variable "health_check_path" {
  description = "Target group health check path (liveness)"
  type        = string
  default     = "/health"
}
