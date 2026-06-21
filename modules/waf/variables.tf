variable "name"                { type = string }
variable "alb_arn"             { type = string; default = "" }
variable "rate_limit_per_5min" { type = number; default = 2000; description = "Max requests per IP per 5 minutes before blocking" }
variable "log_retention_days"  { type = number; default = 30 }
variable "tags"                { type = map(string); default = {} }
