output "oidc_provider_arn" {
  value       = local.oidc_provider_arn
  description = "GitHub OIDC provider ARN"
}
output "ecr_push_role_arn" {
  value       = aws_iam_role.ecr_push.arn
  description = "Role ARN assumed by CI build jobs to push images"
}
output "deploy_role_arns" {
  value       = { for k, v in aws_iam_role.deploy : k => v.arn }
  description = "Map of environment → deploy role ARN"
}
output "infra_plan_role_arn" {
  value       = aws_iam_role.infra_plan.arn
  description = "Role ARN for tofu plan (read-only)"
}
output "infra_apply_role_arn" {
  value       = aws_iam_role.infra_apply.arn
  description = "Role ARN for tofu apply (main branch only)"
}
