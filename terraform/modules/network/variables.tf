variable "name" {
  description = "Name prefix for all resources, e.g. compie-app-dev"
  type        = string
}

variable "region" {
  description = "AWS region, used for the gateway endpoint service names"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Subnets are /24s carved from it: public at offset 0, private at offset 10."
  type        = string
}

variable "az_count" {
  description = "Number of AZs, with one public and one private subnet in each"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "An ALB needs subnets in at least 2 AZs."
  }
}
