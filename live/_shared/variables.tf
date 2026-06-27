variable "github_org" {
  type        = string
  description = "GitHub organisation or username that owns rally-api, rally-web, rally-infra repos"
  default     = "nghiavt1802"
}

variable "create_oidc_provider" {
  type        = bool
  description = <<-EOT
    Set true  → create the GitHub OIDC provider in this AWS account (first-time / standalone setup).
    Set false → reuse an existing provider; supply existing_oidc_provider_arn.
  EOT
  default     = true
}

variable "existing_oidc_provider_arn" {
  type        = string
  description = "ARN of an existing GitHub OIDC provider. Only used when create_oidc_provider = false."
  default     = ""
}
