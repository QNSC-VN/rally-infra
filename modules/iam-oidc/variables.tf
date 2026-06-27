variable "create_oidc_provider" {
  type        = bool
  default     = true
  description = "Create the GitHub OIDC provider. Set false if it already exists in this account."
}
variable "existing_oidc_provider_arn" {
  type        = string
  default     = ""
  description = "ARN of an existing OIDC provider (used when create_oidc_provider = false)"
}
variable "github_org" {
  type        = string
  description = "GitHub organisation name (e.g. my-org)"
}
variable "environments" {
  type = map(object({
    allowed_subjects = list(string)   # e.g. ["repo:my-org/rally-api:ref:refs/heads/main"]
  }))
  description = "Map of environment name → OIDC subject constraints"
}
variable "infra_repo_name" {
  type        = string
  default     = "rally-infra"
  description = "GitHub repo name for the infra repo (used to scope plan/apply OIDC roles)"
}
variable "app_repo_names" {
  type        = list(string)
  default     = ["rally-api", "rally-web"]
  description = "GitHub repo names allowed to assume the ECR push role"
}
variable "tags" {
  type = map(string)
  default = {}
}
