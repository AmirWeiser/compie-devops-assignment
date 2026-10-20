output "dns_name" {
  description = "Public DNS name of the ALB"
  value       = aws_lb.app.dns_name
}

output "target_group_arn" {
  description = "The ASG registers its instances here"
  value       = aws_lb_target_group.app.arn
}

# CloudWatch ALB metrics are keyed by these suffixes, not by full ARNs.
output "lb_arn_suffix" {
  description = "ALB arn_suffix (LoadBalancer dimension of its CloudWatch metrics)"
  value       = aws_lb.app.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group arn_suffix (TargetGroup dimension of its CloudWatch metrics)"
  value       = aws_lb_target_group.app.arn_suffix
}
