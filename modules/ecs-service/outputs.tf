output "service_name"      { value = aws_ecs_service.this.name }
output "service_arn"       { value = aws_ecs_service.this.id }
output "task_role_arn"     { value = aws_iam_role.task.arn }
output "execution_role_arn"{ value = aws_iam_role.execution.arn }
output "task_definition_arn" { value = aws_ecs_task_definition.this.arn }
output "log_group_name"    { value = aws_cloudwatch_log_group.this.name }
output "target_group_arn"  {
  value = var.attach_alb ? aws_lb_target_group.this[0].arn : null
}
