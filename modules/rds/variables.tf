variable "identifier"              { type = string; description = "RDS instance identifier" }
variable "database_name"           { type = string; default = "rally" }
variable "master_username"         { type = string; default = "rallyadmin" }
variable "instance_class"          { type = string; default = "db.t4g.medium" }
variable "allocated_storage_gb"    { type = number; default = 20 }
variable "max_allocated_storage_gb"{ type = number; default = 100 }
variable "multi_az"                { type = bool; default = false }
variable "deletion_protection"     { type = bool; default = true }
variable "backup_retention_days"   { type = number; default = 7 }
variable "log_min_duration_ms"     { type = number; default = 1000; description = "Log queries slower than N ms (1000 = 1s)" }
variable "secret_recovery_days"    { type = number; default = 7 }
variable "subnet_ids"              { type = list(string) }
variable "security_group_id"       { type = string }
variable "kms_key_arn"             { type = string; default = "" }
variable "tags"                    { type = map(string); default = {} }
