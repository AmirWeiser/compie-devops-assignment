variable "name" {
  description = "Name prefix for the CI role, e.g. compie-app-dev"
  type        = string
}

variable "github_repository" {
  # GitHub's OIDC "sub" claim for this repo uses immutable IDs: owner@<owner-id>/repo@<repo-id>.
  # Binding to the IDs also blocks a deleted-and-recreated repo with the same name.
  # The exact claim is visible in CloudTrail (AssumeRoleWithWebIdentity events).
  description = "GitHub repo as it appears in the OIDC sub claim (owner@id/name@id)"
  type        = string
}

# --- The only resources the pipeline may change ---

variable "ecr_repository_arn" {
  description = "Repository the pipeline pushes images to"
  type        = string
}

variable "image_tag_parameter_arn" {
  description = "SSM parameter the pipeline writes the new release tag to"
  type        = string
}

variable "asg_arn" {
  description = "ASG the pipeline starts instance refreshes on"
  type        = string
}
