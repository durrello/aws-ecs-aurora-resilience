variable "name" {
  description = "Cluster identifier and name prefix."
  type        = string
}

variable "is_primary" {
  description = "True for the writer cluster. False for a secondary cluster in a global database."
  type        = bool
}

variable "global_cluster_identifier" {
  description = "Aurora global database to join. Null for a single-region cluster."
  type        = string
  default     = null
}

variable "engine_version" {
  description = "Aurora PostgreSQL version, for example 16.6."
  type        = string
}

variable "parameter_group_major" {
  description = "Major version used for the parameter group family, for example 16."
  type        = string
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "master_username" {
  type    = string
  default = null
}

variable "master_password" {
  type      = string
  default   = null
  sensitive = true
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 5432."
  type        = list(string)
}

variable "instance_count" {
  description = "Writer plus readers. Two gives a reader in a second AZ to fail over to."
  type        = number
  default     = 2
}

variable "min_acu" {
  type    = number
  default = 0.5
}

variable "max_acu" {
  type    = number
  default = 4
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = false
}
