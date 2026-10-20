variable "name" {
  description = "Name prefix for the topic and alarms, e.g. compie-app-dev"
  type        = string
}

variable "alert_email" {
  description = "Email subscribed to the alerts topic (requires a confirmation click). Empty = no subscription."
  type        = string
  default     = ""
}

variable "lb_arn_suffix" {
  description = "ALB arn_suffix, the LoadBalancer dimension of its CloudWatch metrics"
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group arn_suffix, the TargetGroup dimension of its CloudWatch metrics"
  type        = string
}
