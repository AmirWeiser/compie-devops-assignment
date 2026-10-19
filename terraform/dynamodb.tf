# --- DynamoDB table (encrypted at rest with the AWS-managed KMS key aws/dynamodb) ---

resource "aws_dynamodb_table" "app" {
  name         = local.name
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
