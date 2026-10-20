output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.app.name
}

output "asg_arn" {
  description = "CI/CD starts instance refreshes on this ASG"
  value       = aws_autoscaling_group.app.arn
}

output "log_group_name" {
  description = "CloudWatch log group with the container logs"
  value       = aws_cloudwatch_log_group.app.name
}
