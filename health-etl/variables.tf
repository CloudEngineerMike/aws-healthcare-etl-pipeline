# Variables for the infrastructure
# These can be customized before deployment
# to set names and regions for resources
# such as S3 buckets and Glue databases.

variable "project_name" {
  description = "Short name prefix"
  type        = string
  default     = "health-etl"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}
