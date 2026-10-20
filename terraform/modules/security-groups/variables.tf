variable "name" {
  description = "Name prefix, e.g. compie-app-dev"
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to"
  type        = string
}

variable "app_port" {
  description = "Port the application container listens on"
  type        = number
}
