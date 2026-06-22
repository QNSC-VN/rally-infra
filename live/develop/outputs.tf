output "alb_dns_name"        { value = aws_lb.this.dns_name }
output "ecs_cluster_name"    { value = module.ecs_cluster.cluster_name }
output "ecs_api_service"     { value = module.api.service_name }
output "ecs_worker_service"  { value = module.worker.service_name }
output "rds_endpoint"        { value = module.rds.endpoint }
output "cache_endpoint"      { value = module.cache.endpoint }
output "secret_arns"         { value = module.secrets.secret_arns }

# CDN outputs — copy these values into GitHub environment vars for rally-web CI
output "web_s3_bucket"       { value = module.cdn.bucket_name }
output "web_cloudfront_id"   { value = module.cdn.cloudfront_id }
output "web_cloudfront_url"  { value = "https://${module.cdn.cloudfront_domain}" }
