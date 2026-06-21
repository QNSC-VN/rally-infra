variable "name"                { type = string; description = "Resource name prefix" }
variable "region"              { type = string; description = "AWS region" }
variable "vpc_cidr"            { type = string; default = "10.0.0.0/16" }
variable "azs"                 { type = list(string) }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs"{ type = list(string) }
variable "data_subnet_cidrs"   { type = list(string) }
variable "app_port"            { type = number; default = 3000 }
variable "multi_az_nat"        { type = bool; default = false; description = "true = one NAT per AZ (prod); false = single NAT (staging/dev)" }
variable "tags"                { type = map(string); default = {} }
