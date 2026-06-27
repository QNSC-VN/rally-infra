variable "acm_cert_arn" {
  type        = string
  description = "ACM certificate ARN for the ALB HTTPS listener (ap-southeast-1)"
}

variable "web_acm_cert_arn" {
  type        = string
  description = "ACM certificate ARN for CloudFront (MUST be in us-east-1)"
}

variable "entra_tenant_id" {
  type        = string
  description = "Microsoft Entra (Azure AD) tenant ID — leave empty to disable SSO"
  default     = ""
}

variable "entra_client_id" {
  type        = string
  description = "Microsoft Entra (Azure AD) app client ID — leave empty to disable SSO"
  default     = ""
}
