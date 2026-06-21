output "endpoint"              { value = aws_db_instance.this.endpoint }
output "port"                  { value = aws_db_instance.this.port }
output "database_name"         { value = aws_db_instance.this.db_name }
output "master_secret_arn"     { value = aws_secretsmanager_secret.db_master.arn }
output "instance_id"           { value = aws_db_instance.this.id }
output "instance_arn"          { value = aws_db_instance.this.arn }
