output "alb_dns_name"        { value = aws_lb.this.dns_name }
output "ecs_cluster_name"    { value = module.ecs_cluster.cluster_name }
output "ecs_api_service"     { value = module.api.service_name }
output "ecs_worker_service"  { value = module.worker.service_name }
output "rds_endpoint"        { value = module.rds.endpoint }
output "cache_endpoint"      { value = module.cache.endpoint }
output "secret_arns"         { value = module.secrets.secret_arns }
