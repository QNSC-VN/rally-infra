output "vpc_id"               { value = aws_vpc.this.id }
output "public_subnet_ids"   { value = [for s in aws_subnet.public  : s.id] }
output "private_subnet_ids"  { value = [for s in aws_subnet.private : s.id] }
output "data_subnet_ids"     { value = [for s in aws_subnet.data    : s.id] }
output "sg_alb_id"           { value = aws_security_group.alb.id }
output "sg_app_id"           { value = aws_security_group.app.id }
output "sg_rds_id"           { value = aws_security_group.rds.id }
output "sg_cache_id"         { value = aws_security_group.cache.id }
