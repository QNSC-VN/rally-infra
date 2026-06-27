variable "prefix" {
  type = string
  description = "Namespace prefix (e.g. rally/staging)"
}
variable "recovery_window_days" {
  type = number
  default = 7
}
variable "kms_key_arn" {
  type = string
  default = ""
}

variable "secret_names" {
  type        = map(string)
  description = "Map of secret key → description. Values must be set out-of-band."
  default = {
    "db-url"       = "PostgreSQL connection URL for the app"
    "jwt-private"  = "Ed25519 private key (PEM, base64-encoded)"
    "jwt-public"   = "Ed25519 public key (PEM, base64-encoded)"
    "csrf-secret"  = "CSRF token signing secret"
    "redis-url"    = "Redis/Valkey connection URL"
  }
}

variable "ssm_parameters" {
  type = map(object({
    value       = string
    description = string
  }))
  default     = {}
  description = "Non-sensitive config to store in SSM Parameter Store"
}

variable "tags" {
  type = map(string)
  default = {}
}
