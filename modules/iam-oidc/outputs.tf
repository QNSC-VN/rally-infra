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
