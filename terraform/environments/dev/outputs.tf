output "alb_url" {
  description = "Public URL of the application"
  value       = "http://${module.alb.dns_name}"
}

output "asg_name" {
  description = "Auto Scaling Group name (used by the CI/CD workflow)"
  value       = module.compute.asg_name
}

output "log_group" {
  description = "CloudWatch log group with the container logs"
  value       = module.compute.log_group_name
}

output "dynamodb_table" {
  description = "DynamoDB table name"
  value       = module.data.table_name
}

output "alerts_topic_arn" {
  description = "SNS topic that receives the CloudWatch alarms"
  value       = module.monitoring.alerts_topic_arn
}

output "vpc_id" {
  description = "VPC id"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet ids (ALB, NAT)"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet ids (EC2 instances)"
  value       = module.network.private_subnet_ids
}

output "ci_role_arn" {
  description = "Set as the AWS_ROLE_ARN variable in the GitHub repository"
  value       = module.github_oidc.role_arn
}
