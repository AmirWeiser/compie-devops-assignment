output "alerts_topic_arn" {
  description = "SNS topic that receives the alarms"
  value       = aws_sns_topic.alerts.arn
}
