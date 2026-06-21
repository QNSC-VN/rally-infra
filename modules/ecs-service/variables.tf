variable "service_name"      { type = string }
variable "cluster_name"      { type = string }
variable "cluster_arn"       { type = string }
variable "image_uri"         { type = string }
variable "cpu"               { type = number; default = 512 }
variable "memory"            { type = number; default = 1024 }
variable "container_port"    { type = number; default = 3000 }
variable "desired_count"     { type = number; default = 1 }
variable "min_count"         { type = number; default = 1 }
variable "max_count"         { type = number; default = 4 }
variable "cpu_target_pct"    { type = number; default = 70 }
variable "memory_target_pct" { type = number; default = 80 }
variable "log_retention_days"{ type = number; default = 30 }
variable "enable_ecs_exec"   { type = bool; default = false }

variable "vpc_id"            { type = string }
variable "subnet_ids"        { type = list(string) }
variable "security_group_id" { type = string }

variable "attach_alb"        { type = bool; default = true }
variable "alb_listener_arn"  { type = string; default = "" }
variable "alb_priority"      { type = number; default = 100 }
variable "alb_path_patterns" { type = list(string); default = ["/*"] }
variable "health_check_path" { type = string; default = "/v1/healthz" }
variable "health_check_command" { type = string; default = "curl -f http://localhost:3000/v1/healthz || exit 1" }

variable "environment_vars"  {
  type    = list(object({ name = string, value = string }))
  default = []
}
variable "secrets" {
  type    = list(object({ name = string, secret_arn = string }))
  default = []
}
variable "secret_arns"    { type = list(string); default = [] }
variable "sqs_queue_arns" { type = list(string); default = [] }
variable "sns_topic_arns" { type = list(string); default = [] }
variable "tags"           { type = map(string); default = {} }
