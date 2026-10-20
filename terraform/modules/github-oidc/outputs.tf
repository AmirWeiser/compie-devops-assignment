output "role_arn" {
  description = "Set as the AWS_ROLE_ARN variable in the GitHub repository"
  value       = aws_iam_role.ci.arn
}
