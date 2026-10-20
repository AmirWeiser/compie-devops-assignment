# Offline unit test (mock provider, nothing is called or created).

mock_provider "aws" {}

# Mocked ids/arns are only known at plan time for explicitly overridden resources.
# Distinct values per resource also stop a cross-reference check from passing by accident.

override_resource {
  target          = aws_iam_openid_connect_provider.github
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
}

variables {
  name                    = "compie-app-dev"
  github_repository       = "AmirWeiser@123477471/compie-devops-assignment@1424430511"
  ecr_repository_arn      = "arn:aws:ecr:us-east-1:123456789012:repository/compie-app"
  image_tag_parameter_arn = "arn:aws:ssm:us-east-1:123456789012:parameter/compie-app/dev/image_tag"
  asg_arn                 = "arn:aws:autoscaling:us-east-1:123456789012:autoScalingGroup:uuid:autoScalingGroupName/compie-app-dev"
}

run "only_main_branch_of_this_repo_can_assume" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role.ci.assume_role_policy).Statement[0].Condition.StringEquals == {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
      "token.actions.githubusercontent.com:sub" = "repo:AmirWeiser@123477471/compie-devops-assignment@1424430511:ref:refs/heads/main"
    }
    error_message = "Trust policy must pin the audience and the main branch of this repo (immutable IDs)."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ci.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn
    error_message = "Trust policy must federate through the GitHub OIDC provider."
  }
}

run "deploy_policy_is_scoped" {
  command = plan

  assert {
    condition = {
      for s in jsondecode(aws_iam_role_policy.ci.policy).Statement : s.Sid => s.Resource
      if contains(["EcrPush", "SetImageTag", "Rollout"], s.Sid)
      } == {
      EcrPush     = var.ecr_repository_arn
      SetImageTag = var.image_tag_parameter_arn
      Rollout     = var.asg_arn
    }
    error_message = "Write actions must be limited to this repo's ECR repository, image_tag parameter and ASG."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.ci.policy).Statement : !contains(flatten([s.Action]), "*")
    ])
    error_message = "No wildcard actions."
  }
}
