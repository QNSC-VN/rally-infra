variable "acm_cert_arn" {
  type        = string
  description = "ACM certificate ARN for the production ALB HTTPS listener (ap-southeast-1)"
}

variable "web_acm_cert_arn" {
  type        = string
  description = "ACM certificate ARN for production CloudFront (MUST be in us-east-1)"
}
