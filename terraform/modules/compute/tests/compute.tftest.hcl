# Offline unit test (mock provider, nothing is called or created).

mock_provider "aws" {}

# Mocked ids/arns are only known at plan time for explicitly overridden resources.
# Distinct values per resource also stop a cross-reference check from passing by accident.

override_resource {
  target          = aws_cloudwatch_log_group.app
  override_during = plan
  values          = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/compie-app/dev" }
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

variables {
  name               = "compie-app-dev"
  region             = "us-east-1"
  private_subnet_ids = ["subnet-0ccccccccccccccc0", "subnet-0ddddddddddddddd0"]
  security_group_id  = "sg-0bbbbbbbbbbbbbbbb"
  target_group_arn   = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/compie-app-dev/0123456789abcdef"

  ecr_repository_url   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/compie-app"
  ecr_repository_arn   = "arn:aws:ecr:us-east-1:123456789012:repository/compie-app"
  param_path           = "/compie-app/dev"
  log_group_name       = "/compie-app/dev"
  dynamodb_table_arn   = "arn:aws:dynamodb:us-east-1:123456789012:table/compie-app-dev"
  dynamodb_endpoint_id = "vpce-0123456789abcdef0"
}

run "instance_hardening" {
  command = plan

  assert {
    condition = (
      aws_launch_template.app.metadata_options[0].http_tokens == "required" &&
      aws_launch_template.app.metadata_options[0].http_put_response_hop_limit == 2
    )
    error_message = "IMDSv2 must be required, with hop limit 2 for the container."
  }

  assert {
    condition = (
      aws_launch_template.app.block_device_mappings[0].ebs[0].encrypted == "true" &&
      aws_launch_template.app.block_device_mappings[0].ebs[0].volume_type == "gp3"
    )
    error_message = "Root volume must be encrypted gp3."
  }

  assert {
    condition     = aws_launch_template.app.vpc_security_group_ids == toset([var.security_group_id])
    error_message = "Instances must use only the app security group."
  }
}

run "user_data_template_renders_from_module_path" {
  command = plan

  assert {
    condition = alltrue([
      for s in [
        "--region us-east-1",
        "--name \"/compie-app/dev/$1\"",
        "docker pull \"123456789012.dkr.ecr.us-east-1.amazonaws.com/compie-app:$IMAGE_TAG\"",
        "awslogs-group=/compie-app/dev",
      ] : strcontains(base64decode(aws_launch_template.app.user_data), s)
    ])
    error_message = "user_data is missing a rendered value."
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.app.user_data), "$${")
    error_message = "user_data contains an unrendered template expression."
  }
}

run "asg_behind_alb" {
  command = plan

  assert {
    condition = (
      aws_autoscaling_group.app.min_size == 2 &&
      aws_autoscaling_group.app.desired_capacity == 2 &&
      aws_autoscaling_group.app.max_size == 4
    )
    error_message = "Default capacity must stay 2/2/4."
  }

  assert {
    condition = (
      aws_autoscaling_group.app.health_check_type == "ELB" &&
      aws_autoscaling_group.app.health_check_grace_period == 300 &&
      aws_autoscaling_group.app.target_group_arns == toset([var.target_group_arn]) &&
      aws_autoscaling_group.app.vpc_zone_identifier == toset(var.private_subnet_ids)
    )
    error_message = "ASG must run in the private subnets, register with the target group, and use ELB health checks (grace 300s)."
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/compie-app/dev" && aws_cloudwatch_log_group.app.retention_in_days == 7
    error_message = "Log group name or 7-day retention changed."
  }
}

run "instance_role_least_privilege" {
  command = plan

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.app.policy).Statement : s if s.Sid == "ReadinessProbe"
    ]).Condition.StringEquals["aws:SourceVpce"] == "vpce-0123456789abcdef0"
    error_message = "DynamoDB reads must be restricted to the VPC gateway endpoint."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.app.policy).Statement : s if s.Sid == "ReadAppConfig"
    ]).Resource == "arn:aws:ssm:us-east-1:123456789012:parameter/compie-app/dev/*"
    error_message = "SSM read access must be limited to this app's parameter path."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.app.policy).Statement : s if s.Sid == "WriteAppLogs"
    ]).Resource == "${aws_cloudwatch_log_group.app.arn}:*"
    error_message = "Log writes must be limited to this app's log group."
  }

  assert {
    condition     = aws_iam_role.app.name == "compie-app-dev-instance" && aws_iam_instance_profile.app.name == "compie-app-dev-instance"
    error_message = "Naming convention changed."
  }
}
