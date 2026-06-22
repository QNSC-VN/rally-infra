variable "name" {
  type        = string
  description = "Unique name prefix for all resources (e.g. rally-web-develop)"
}

variable "acm_cert_arn" {
  type        = string
  description = <<-EOT
    ACM certificate ARN for the CloudFront distribution.
    IMPORTANT: must be created in us-east-1 (CloudFront global requirement),
    regardless of the AWS region used for the rest of the stack.
  EOT
}

variable "aliases" {
  type        = list(string)
  default     = []
  description = "Custom domain aliases (e.g. [\"app.rally.example.com\"])"
}

variable "price_class" {
  type        = string
  default     = "PriceClass_200"
  description = "CloudFront price class. PriceClass_200 covers US/EU/Asia (good default). PriceClass_All for global."

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
