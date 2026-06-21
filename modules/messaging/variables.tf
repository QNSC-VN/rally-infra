variable "prefix"               { type = string; description = "Name prefix for all queues/topics (e.g. rally-staging)" }
variable "dlq_max_receive_count" { type = number; default = 5; description = "Messages received this many times move to DLQ" }
variable "sns_topic_names"      { type = list(string); default = ["domain-events"] }
variable "kms_key_arn"          { type = string; default = "" }
variable "tags"                 { type = map(string); default = {} }
