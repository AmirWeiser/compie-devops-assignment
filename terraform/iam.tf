# --- EC2 instance role: pull from ECR, read app config, write logs, use SSM, read DynamoDB ---

resource "aws_iam_role" "app" {
  name = "${local.name}-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-instance"
  role = aws_iam_role.app.name
}

# AWS-managed policy for the SSM agent (Session Manager access, no SSH needed).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "app"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # this action does not support resource-level permissions
      },
      {
        Sid      = "EcrPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = data.aws_ecr_repository.app.arn
      },
      {
        Sid      = "ReadAppConfig"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.param_path}/*"
      },
      {
        Sid      = "WriteAppLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      },
      {
        Sid      = "ReadinessProbe"
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = aws_dynamodb_table.app.arn
        # Only via our VPC gateway endpoint: leaked credentials can't read the table from outside the VPC.
        Condition = { StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.dynamodb.id } }
      },
    ]
  })
}
