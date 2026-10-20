# Offline unit test (mock provider, nothing is called or created).

mock_provider "aws" {}

# Mocked ids/arns are only known at plan time for explicitly overridden resources.
# Distinct values per resource also stop a cross-reference check from passing by accident.

override_resource {
  target          = aws_ssm_parameter.image_tag
  override_during = plan
  values          = { arn = "arn:aws:ssm:us-east-1:123456789012:parameter/compie-app/dev/image_tag" }
}

variables {
  name            = "compie-app-dev"
  param_path      = "/compie-app/dev"
  welcome_message = "Hello"
  image_tag       = "abc1234"
}

run "encrypted_table_and_config" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.app.server_side_encryption[0].enabled == true && aws_dynamodb_table.app.billing_mode == "PAY_PER_REQUEST"
    error_message = "Table must be on-demand and encrypted at rest."
  }

  assert {
    condition = (
      aws_ssm_parameter.welcome_message.name == "/compie-app/dev/welcome_message" &&
      aws_ssm_parameter.welcome_message.type == "SecureString" &&
      aws_ssm_parameter.table_name.name == "/compie-app/dev/table_name" &&
      aws_ssm_parameter.table_name.type == "SecureString" &&
      aws_ssm_parameter.image_tag.name == "/compie-app/dev/image_tag"
    )
    error_message = "Parameter names or SecureString types changed (the instances and CI/CD read these exact names)."
  }

  assert {
    condition     = output.param_path == "/compie-app/dev"
    error_message = "param_path output must pass the path through unchanged."
  }

  assert {
    condition     = output.image_tag_parameter_arn == aws_ssm_parameter.image_tag.arn
    error_message = "CI/CD must be granted the image_tag parameter."
  }
}
