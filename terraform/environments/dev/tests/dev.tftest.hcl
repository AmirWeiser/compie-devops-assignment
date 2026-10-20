# Offline integration test: plans the whole dev composition (all 7 modules) with a mock provider.
# Nothing is called or created, and the S3 backend is not used. Proves the modules wire together;
# it does not prove the result behaves the same in AWS.

mock_provider "aws" {}

override_data {
  target = module.network.data.aws_availability_zones.available
  values = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
}

override_data {
  target = module.compute.data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

override_data {
  target = data.aws_ecr_repository.app
  values = {
    arn            = "arn:aws:ecr:us-east-1:123456789012:repository/compie-app"
    repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/compie-app"
  }
}

variables {
  image_tag = "abc1234"
}

run "dev_composes_with_original_names" {
  command = plan

  assert {
    condition = (
      output.asg_name == "compie-app-dev" &&
      output.dynamodb_table == "compie-app-dev" &&
      output.log_group == "/compie-app/dev"
    )
    error_message = "Resource names must match the original stack (the workflow uses them)."
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2 && length(output.private_subnet_ids) == 2
    error_message = "Expected 2 public and 2 private subnets."
  }

  assert {
    condition     = startswith(output.alb_url, "http://")
    error_message = "alb_url must be an http:// URL."
  }
}
