# --- dev environment: composes the child modules in ../../modules ---
# Values flow one way: network -> security-groups -> alb -> compute -> github-oidc,
# with data and monitoring alongside. No module reads another module's resources directly.

locals {
  name       = "${var.project}-${var.environment}"  # compie-app-dev
  param_path = "/${var.project}/${var.environment}" # SSM prefix, also the log group name
  app_port   = 8000                                 # the port uvicorn listens on (app/Dockerfile)
}

# Created by the bootstrap stack (terraform/bootstrap), so it is looked up, not managed here.
data "aws_ecr_repository" "app" {
  name = var.project
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  region   = var.region
  vpc_cidr = var.vpc_cidr
}

module "security_groups" {
  source = "../../modules/security-groups"

  name     = local.name
  vpc_id   = module.network.vpc_id
  app_port = local.app_port
}

module "alb" {
  source = "../../modules/alb"

  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  security_group_id = module.security_groups.alb_security_group_id
  app_port          = local.app_port
}

module "data" {
  source = "../../modules/data"

  name            = local.name
  param_path      = local.param_path
  welcome_message = var.welcome_message
  image_tag       = var.image_tag
}

module "compute" {
  source = "../../modules/compute"

  name          = local.name
  region        = var.region
  instance_type = var.instance_type

  private_subnet_ids = module.network.private_subnet_ids
  security_group_id  = module.security_groups.app_security_group_id
  target_group_arn   = module.alb.target_group_arn

  ecr_repository_url   = data.aws_ecr_repository.app.repository_url
  ecr_repository_arn   = data.aws_ecr_repository.app.arn
  param_path           = module.data.param_path # waits for the SSM parameters to exist
  log_group_name       = local.param_path
  dynamodb_table_arn   = module.data.table_arn
  dynamodb_endpoint_id = module.network.dynamodb_endpoint_id
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                    = local.name
  alert_email             = var.alert_email
  lb_arn_suffix           = module.alb.lb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  name                    = local.name
  github_repository       = var.github_repository
  ecr_repository_arn      = data.aws_ecr_repository.app.arn
  image_tag_parameter_arn = module.data.image_tag_parameter_arn
  asg_arn                 = module.compute.asg_arn
}
