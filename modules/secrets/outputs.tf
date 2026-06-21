output "secret_arns" {
  value       = { for k, v in aws_secretsmanager_secret.app : k => v.arn }
  description = "Map of secret key → ARN (pass to ECS task definitions)"
}
output "ssm_parameter_arns" {
  value = { for k, v in aws_ssm_parameter.config : k => v.arn }
}
