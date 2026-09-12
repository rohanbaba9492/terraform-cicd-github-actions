variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "github_org" {
  description = "GitHub org or username that owns the repo."
  type        = string
  default     = "rohanbaba9492"
}

variable "github_repo" {
  description = "Repository name the roles are scoped to."
  type        = string
}

variable "role_name_prefix" {
  type    = string
  default = "gha-terraform"
}

variable "create_oidc_provider" {
  description = "false if token.actions.githubusercontent.com already exists in this account."
  type        = bool
  default     = true
}

variable "state_bucket" {
  description = "Terraform state bucket the roles need access to."
  type        = string
}

variable "lock_table" {
  description = "DynamoDB lock table name."
  type        = string
}
