# --- What the app reads at runtime: its DynamoDB table and its configuration in SSM ---

# DynamoDB table (encrypted at rest with the AWS-managed KMS key aws/dynamodb)
resource "aws_dynamodb_table" "app" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  server_side_encryption {
    enabled = true # no kms_key_arn = AWS-managed key aws/dynamodb
  }
}

# --- App configuration in SSM Parameter Store ---
# SecureString values are encrypted with the AWS-managed KMS key aws/ssm.
# The instance reads them at boot; nothing is baked into the image.

resource "aws_ssm_parameter" "welcome_message" {
  name  = "${var.param_path}/welcome_message"
  type  = "SecureString"
  value = var.welcome_message
}

resource "aws_ssm_parameter" "table_name" {
  name  = "${var.param_path}/table_name"
  type  = "SecureString"
  value = aws_dynamodb_table.app.name
}

# Which image version the instances run. Terraform sets the first value only;
# later releases update it outside Terraform (CI/CD), so value changes are ignored.
resource "aws_ssm_parameter" "image_tag" {
  name  = "${var.param_path}/image_tag"
  type  = "String"
  value = var.image_tag

  lifecycle {
    ignore_changes = [value]
  }
}
