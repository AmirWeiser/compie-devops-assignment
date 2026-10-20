# --- App servers: EC2 Auto Scaling Group in private subnets, registered with the ALB target group ---
# Everything an instance needs lives here: its log group, its IAM role, its launch template.

data "aws_caller_identity" "current" {}

# Latest Amazon Linux 2023 AMI, published by AWS as a public SSM parameter.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = var.log_group_name
  retention_in_days = 7
}

# --- EC2 instance role: pull from ECR, read app config, write logs, use SSM, read DynamoDB ---

resource "aws_iam_role" "app" {
  name = "${var.name}-instance"

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
  name = "${var.name}-instance"
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
        Resource = var.ecr_repository_arn
      },
      {
        Sid      = "ReadAppConfig"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.param_path}/*"
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
        Resource = var.dynamodb_table_arn
        # Only via our VPC gateway endpoint: leaked credentials can't read the table from outside the VPC.
        Condition = { StringEquals = { "aws:SourceVpce" = var.dynamodb_endpoint_id } }
      },
    ]
  })
}

# --- Launch template and Auto Scaling Group ---

resource "aws_launch_template" "app" {
  name_prefix            = "${var.name}-"
  image_id               = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  vpc_security_group_ids = [var.security_group_id]
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # IMDSv2 only. Hop limit 2 lets the app inside the Docker container reach the
  # metadata service for the instance role's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type = "gp3"
      encrypted   = true # AWS-managed key aws/ebs
    }
  }

  # path.module is this module's directory, so the template is found wherever the module is called from.
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region     = var.region
    param_path = var.param_path
    image_repo = var.ecr_repository_url
    log_group  = aws_cloudwatch_log_group.app.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = var.name }
  }
}

resource "aws_autoscaling_group" "app" {
  name                = var.name
  vpc_zone_identifier = var.private_subnet_ids # one subnet per AZ; the ASG balances across them
  target_group_arns   = [var.target_group_arn]

  min_size         = var.min_size
  desired_capacity = var.desired_capacity
  max_size         = var.max_size

  # Replace instances the ALB reports unhealthy; give new ones time to install Docker and pull.
  # A normal boot takes ~80s, but on a fresh apply a just-created NAT Gateway made the first
  # boot take ~240s, so 300s leaves headroom without hiding genuinely broken instances for long.
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # user_data needs these permissions at boot, but the launch template does not reference
  # the policy, so make sure it exists before the first instance launches.
  # (The SSM parameters are waited for through var.param_path, see the data module's output.)
  depends_on = [aws_iam_role_policy.app]
}
