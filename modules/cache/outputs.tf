output "endpoint"         { value = aws_elasticache_serverless_cache.this.endpoint[0].address }
output "port"             { value = aws_elasticache_serverless_cache.this.endpoint[0].port }
output "reader_endpoint"  { value = aws_elasticache_serverless_cache.this.reader_endpoint[0].address }
