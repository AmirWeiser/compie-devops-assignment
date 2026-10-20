output "alb_security_group_id" {
  description = "Security group for the ALB"
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group for the app instances"
  value       = aws_security_group.app.id
}
