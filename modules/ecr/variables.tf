variable "repository_names"      { type = list(string); description = "ECR repository names to create" }
variable "kms_key_arn"           { type = string; default = ""; description = "KMS key ARN for ECR encryption (empty = AWS managed)" }
variable "allowed_principal_arns"{ type = list(string); default = []; description = "IAM role ARNs allowed to push/pull" }
variable "tags"                  { type = map(string); default = {} }
