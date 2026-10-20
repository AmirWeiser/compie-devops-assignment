# Offline unit test (mock provider, nothing is called or created).

mock_provider "aws" {}

# Mocked ids/arns are only known at plan time for explicitly overridden resources.
# Distinct values per resource also stop a cross-reference check from passing by accident.

override_resource {
  target          = aws_lb_target_group.app
  override_during = plan
  values          = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/compie-app-dev/tg" }
}

variables {
  name              = "compie-app-dev"
  vpc_id            = "vpc-0123456789abcdef0"
  public_subnet_ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  security_group_id = "sg-0aaaaaaaaaaaaaaaa"
  app_port          = 8000
}

run "public_alb_forwards_to_app" {
  command = plan

  assert {
    condition     = aws_lb.app.internal == false && aws_lb.app.subnets == toset(var.public_subnet_ids)
    error_message = "The ALB must be internet-facing, in the public subnets."
  }

  assert {
    condition     = aws_lb.app.drop_invalid_header_fields == true
    error_message = "drop_invalid_header_fields must stay enabled."
  }

  assert {
    condition = (
      aws_lb_listener.http.port == 80 &&
      aws_lb_listener.http.default_action[0].type == "forward" &&
      aws_lb_listener.http.default_action[0].target_group_arn == aws_lb_target_group.app.arn
    )
    error_message = "Listener :80 must forward to the app target group."
  }

  assert {
    condition     = aws_lb_target_group.app.port == 8000 && aws_lb_target_group.app.deregistration_delay == "30"
    error_message = "Target group must target the app port with a 30s deregistration delay."
  }
}

run "health_check_is_liveness" {
  command = plan

  assert {
    condition = (
      aws_lb_target_group.app.health_check[0].path == "/health" &&
      aws_lb_target_group.app.health_check[0].matcher == "200" &&
      aws_lb_target_group.app.health_check[0].interval == 15 &&
      aws_lb_target_group.app.health_check[0].healthy_threshold == 2 &&
      aws_lb_target_group.app.health_check[0].unhealthy_threshold == 3
    )
    error_message = "Health check must stay GET /health -> 200, every 15s, 2 healthy / 3 unhealthy."
  }
}
