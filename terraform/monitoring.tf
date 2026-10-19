# --- Alerting: CloudWatch alarms -> SNS topic -> email (placeholder for a real paging tool) ---

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
  # Not KMS-encrypted: CloudWatch can only publish to an encrypted topic with a customer-managed
  # key policy, and alert messages contain no sensitive data.
}

# Email needs a one-time confirmation click. Leave alert_email empty to skip the subscription.
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alb_dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

# 1. An instance is failing /health (container down, boot failure, bad image).
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  alarm_description   = "At least one target is failing the ALB health check (/health)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.alb_dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3 # 3 minutes, so short blips during deploys do not page
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# 2. The service is down: no healthy target behind the ALB.
resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${local.name}-no-healthy-hosts"
  alarm_description   = "No healthy targets behind the ALB: the application is unavailable."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.alb_dimensions
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching" # no data from the target group is itself a problem
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# 3. The app is returning server errors (includes /ready 503s when DynamoDB is unreachable).
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name}-target-5xx"
  alarm_description   = "Application returned 5 or more 5xx responses in 5 minutes (incl. /ready 503 = DynamoDB unreachable)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.alb_dimensions
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching" # no requests = no errors
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
