data "aws_caller_identity" "current" {}

# Created by the bootstrap stack.
data "aws_ecr_repository" "app" {
  name = var.project
}

# Latest Amazon Linux 2023 AMI, published by AWS as a public SSM parameter.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}"
  retention_in_days = 7
}

resource "aws_launch_template" "app" {
  name_prefix            = "${local.name}-"
  image_id               = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]
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

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region     = var.region
    param_path = local.param_path
    image_repo = data.aws_ecr_repository.app.repository_url
    log_group  = aws_cloudwatch_log_group.app.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = local.name }
  }
}

resource "aws_autoscaling_group" "app" {
  name                = local.name
  vpc_zone_identifier = aws_subnet.private[*].id # one subnet per AZ; the ASG balances across them
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = 2
  desired_capacity = 2
  max_size         = 4

  # Replace instances the ALB reports unhealthy; give new ones time to install Docker and pull.
  # A normal boot takes ~80s, but on a fresh apply a just-created NAT Gateway made the first
  # boot take ~240s, so 300s leaves headroom without hiding genuinely broken instances for long.
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # user_data reads these at boot, but the launch template does not reference them,
  # so make sure they exist before the first instance launches.
  depends_on = [
    aws_iam_role_policy.app,
    aws_ssm_parameter.welcome_message,
    aws_ssm_parameter.table_name,
    aws_ssm_parameter.image_tag,
  ]
}
