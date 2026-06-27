variable "name"                { type = string }
variable "enabled" {
  type = bool
  default = true
  description = "Set false in develop to skip WAF (saves $5+/month per WebACL)"
}
variable "alb_arn" {
  type = string
  default = ""
}
variable "rate_limit_per_5min" {
  type = number
  default = 2000
  description = "Max requests per IP per 5 minutes before blocking"
}
variable "log_retention_days" {
  type = number
  default = 30
}
variable "tags" {
  type = map(string)
  default = {}
}
