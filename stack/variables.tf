variable "name" {
  description = "Project name prefix."
  type        = string
  default     = "ecs-aurora"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "primary_region" {
  type    = string
  default = "eu-west-1"
}

variable "secondary_region" {
  description = "Standby region: holds the Aurora secondary cluster and a scaled-to-zero ECS service."
  type        = string
  default     = "eu-west-2"
}

variable "primary_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "secondary_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "container_image_primary" {
  description = "Image URI in the primary region's ECR."
  type        = string
}

variable "container_image_secondary" {
  description = "Image URI in the secondary region (ECR replication or a second push)."
  type        = string
}

variable "aurora_engine_version" {
  type    = string
  default = "16.6"
}

variable "aurora_parameter_group_major" {
  type    = string
  default = "16"
}

variable "standby_desired_count" {
  description = "Tasks in the standby region. 0 is pilot light; set to 2 or more for warm standby."
  type        = number
  default     = 0
}

variable "hosted_zone_id" {
  description = "Route 53 zone for failover DNS. Empty skips DNS failover."
  type        = string
  default     = ""
}

variable "app_hostname" {
  description = "Hostname for the failover record, a name inside the hosted zone (no scheme)."
  type        = string
  default     = ""
}

variable "deletion_protection" {
  description = "Turn on for anything that holds real data."
  type        = bool
  default     = false
}
