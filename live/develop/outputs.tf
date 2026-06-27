output "alb_dns_name"        { value = aws_lb.this.dns_name }
output "ecs_cluster_name"    { value = module.ecs_cluster.cluster_name }
output "ecs_api_service"     { value = module.api.service_name }
output "ecs_worker_service"  { value = module.worker.service_name }
output "ecs_migrator_task_def" {
  value       = aws_ecs_task_definition.migrator.family
  description = "Migrator task definition family name — use with aws ecs run-task"
}
output "rds_endpoint"        { value = module.rds.endpoint }
output "rds_master_secret_arn" { value = module.rds.master_secret_arn }
output "cache_endpoint"      { value = module.cache.endpoint }
output "secret_arns"         { value = module.secrets.secret_arns }
output "attachments_bucket"  { value = aws_s3_bucket.attachments.bucket }

# Networking — needed for ECS run-task (migrator) and GitHub env vars
output "private_subnet_ids"  { value = module.network.private_subnet_ids }
output "sg_app_id"           { value = module.network.sg_app_id }

# Messaging — useful for verifying queue setup
output "sqs_queue_urls"      { value = module.messaging.queue_urls }
output "sns_topic_arns"      { value = module.messaging.topic_arns }

# CDN outputs — copy these values into GitHub environment vars for rally-web CI
output "web_s3_bucket"       { value = module.cdn.bucket_name }
output "web_cloudfront_id"   { value = module.cdn.cloudfront_id }
output "web_cloudfront_url"  { value = "https://${module.cdn.cloudfront_domain}" }
