# Offline unit test (mock provider, nothing is called or created).

mock_provider "aws" {}

# Mocked ids/arns are only known at plan time for explicitly overridden resources.
# Distinct values per resource also stop a cross-reference check from passing by accident.

override_resource {
  target          = aws_sns_topic.alerts
  override_during = plan
  values          = { arn = "arn:aws:sns:us-east-1:123456789012:compie-app-dev-alerts" }
}

variables {
  name                    = "compie-app-dev"
  lb_arn_suffix           = "app/compie-app-dev/0123456789abcdef"
  target_group_arn_suffix = "targetgroup/compie-app-dev/0123456789abcdef"
}

run "alarms_watch_the_alb_and_notify_sns" {
  command = plan

  variables {
    alert_email = "ops@example.com"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "An alert_email must create one email subscription."
  }

  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.unhealthy_hosts, aws_cloudwatch_metric_alarm.no_healthy_hosts, aws_cloudwatch_metric_alarm.target_5xx] :
      a.dimensions == tomap({ LoadBalancer = var.lb_arn_suffix, TargetGroup = var.target_group_arn_suffix }) &&
      a.alarm_actions == toset([aws_sns_topic.alerts.arn]) &&
      a.ok_actions == toset([aws_sns_topic.alerts.arn])
    ])
    error_message = "Every alarm must watch this ALB/target group and notify the topic on ALARM and OK."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.no_healthy_hosts.treat_missing_data == "breaching"
    error_message = "Missing HealthyHostCount data must count as an outage."
  }
}

run "no_email_no_subscription" {
  command = plan

  variables {
    alert_email = ""
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "An empty alert_email must skip the subscription."
  }
}
