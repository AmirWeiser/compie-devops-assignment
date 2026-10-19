output "alb_url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "dynamodb_table" {
  value = aws_dynamodb_table.app.name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
