# Offline unit test (mock provider, nothing is called or created).

mock_provider "aws" {}

# Mocked ids/arns are only known at plan time for explicitly overridden resources.
# Distinct values per resource also stop a cross-reference check from passing by accident.

override_resource {
  target          = aws_security_group.alb
  override_during = plan
  values          = { id = "sg-alb" }
}

override_resource {
  target          = aws_security_group.app
  override_during = plan
  values          = { id = "sg-app" }
}

variables {
  name     = "compie-app-dev"
  vpc_id   = "vpc-0123456789abcdef0"
  app_port = 8000
}

run "traffic_path_internet_alb_app" {
  command = plan

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.alb_http.cidr_ipv4 == "0.0.0.0/0" &&
      aws_vpc_security_group_ingress_rule.alb_http.from_port == 80 &&
      aws_vpc_security_group_ingress_rule.alb_http.to_port == 80
    )
    error_message = "The ALB must accept HTTP :80 from the internet, and nothing else."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.alb_to_app.referenced_security_group_id == aws_security_group.app.id &&
      aws_vpc_security_group_egress_rule.alb_to_app.from_port == 8000
    )
    error_message = "The ALB may only send traffic to the app security group on the app port."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.app_from_alb.referenced_security_group_id == aws_security_group.alb.id &&
      aws_vpc_security_group_ingress_rule.app_from_alb.from_port == 8000 &&
      aws_vpc_security_group_ingress_rule.app_from_alb.to_port == 8000
    )
    error_message = "Instances must accept the app port from the ALB security group only."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.app_https.from_port == 443 &&
      aws_vpc_security_group_egress_rule.app_https.to_port == 443
    )
    error_message = "Instance egress must be HTTPS only."
  }

  assert {
    condition     = aws_security_group.alb.name == "compie-app-dev-alb" && aws_security_group.app.name == "compie-app-dev-app"
    error_message = "Naming convention changed."
  }
}
