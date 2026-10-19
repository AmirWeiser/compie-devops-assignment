# --- App configuration in SSM Parameter Store ---
# SecureString values are encrypted with the AWS-managed KMS key aws/ssm.
# The instance reads them at boot; nothing is baked into the image.

locals {
  param_path = "/${var.project}/${var.environment}"
}

resource "aws_ssm_parameter" "welcome_message" {
  name  = "${local.param_path}/welcome_message"
  type  = "SecureString"
  value = var.welcome_message
}

resource "aws_ssm_parameter" "table_name" {
  name  = "${local.param_path}/table_name"
  type  = "SecureString"
  value = aws_dynamodb_table.app.name
}

# Which image version the instances run. Terraform sets the first value only;
# later releases update it outside Terraform (CI/CD), so value changes are ignored.
resource "aws_ssm_parameter" "image_tag" {
  name  = "${local.param_path}/image_tag"
  type  = "String"
  value = var.image_tag

  lifecycle {
    ignore_changes = [value]
  }
}
