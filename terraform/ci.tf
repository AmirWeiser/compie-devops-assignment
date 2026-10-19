# --- CI/CD identity for GitHub Actions (OIDC: no long-lived AWS keys in GitHub) ---
# Can push images, set the image tag, and start a rollout. Cannot read app config or decrypt anything.

variable "github_repository" {
  description = "GitHub repo (owner/name) allowed to assume the CI role"
  type        = string
  default     = "AmirWeiser/compie-devops-assignment"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "ci" {
  name = "${local.name}-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Only workflows running on the main branch of this repo.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci" {
  name = "deploy"
  role = aws_iam_role.ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
        ]
        Resource = data.aws_ecr_repository.app.arn
      },
      {
        Sid      = "SetImageTag"
        Effect   = "Allow"
        Action   = "ssm:PutParameter"
        Resource = aws_ssm_parameter.image_tag.arn
      },
      {
        Sid      = "Rollout"
        Effect   = "Allow"
        Action   = "autoscaling:StartInstanceRefresh"
        Resource = aws_autoscaling_group.app.arn
      },
      {
        Sid    = "ReadDeployStatus"
        Effect = "Allow"
        # Describe actions do not support resource-level permissions.
        Action   = ["autoscaling:DescribeInstanceRefreshes", "elasticloadbalancing:DescribeLoadBalancers"]
        Resource = "*"
      },
    ]
  })
}

output "ci_role_arn" {
  value = aws_iam_role.ci.arn
}
