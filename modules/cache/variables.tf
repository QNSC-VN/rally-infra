variable "name"                  { type = string }
variable "engine_version" {
  type = string
  default = "7"
}
variable "max_data_storage_gb" {
  type = number
  default = 5
}
variable "max_ecpu_per_second" {
  type = number
  default = 5000
}
variable "snapshot_retention_days" {
  type = number
  default = 3
}
variable "subnet_ids"            { type = list(string) }
variable "security_group_id"     { type = string }
variable "kms_key_arn" {
  type = string
  default = ""
}
variable "tags" {
  type = map(string)
  default = {}
}
