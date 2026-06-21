output "ecr_urls"              { value = module.ecr.repository_urls }
output "ecr_push_role_arn"     { value = module.iam_oidc.ecr_push_role_arn }
output "deploy_role_arns"      { value = module.iam_oidc.deploy_role_arns }
output "infra_plan_role_arn"   { value = module.iam_oidc.infra_plan_role_arn }
output "infra_apply_role_arn"  { value = module.iam_oidc.infra_apply_role_arn }
