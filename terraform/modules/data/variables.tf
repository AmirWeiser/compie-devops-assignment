variable "name" {
  description = "DynamoDB table name"
  type        = string
}

variable "param_path" {
  description = "SSM path prefix for the app's parameters, e.g. /compie-app/dev"
  type        = string
}

variable "welcome_message" {
  description = "Returned by GET /"
  type        = string
}

variable "image_tag" {
  description = "Initial image tag. Only used on first apply; CI/CD owns it afterwards."
  type        = string
}
