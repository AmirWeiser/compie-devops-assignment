output "table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.app.name
}

output "table_arn" {
  description = "DynamoDB table ARN, for IAM policies"
  value       = aws_dynamodb_table.app.arn
}

# Instances read these parameters at boot, but nothing else in their configuration
# references them. depends_on makes anything that uses this path wait until all
# parameters exist, so the first instance never boots before its config is there.
output "param_path" {
  description = "SSM path of the app parameters; waits until all of them exist"
  value       = var.param_path

  depends_on = [
    aws_ssm_parameter.welcome_message,
    aws_ssm_parameter.table_name,
    aws_ssm_parameter.image_tag,
  ]
}

output "image_tag_parameter_arn" {
  description = "CI/CD writes new release tags here"
  value       = aws_ssm_parameter.image_tag.arn
}
