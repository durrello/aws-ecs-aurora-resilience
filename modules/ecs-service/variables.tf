variable "name" {
  description = "Service name; also used for the cluster, load balancer and log group."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC CIDR, used to scope security group egress."
  type        = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "container_image" {
  description = "Image URI, for example <account>.dkr.ecr.<region>.amazonaws.com/app:<git-sha>."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  description = "Tasks at first apply. Use 0 in the standby region (pilot light)."
  type        = number
  default     = 2
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 6
}

variable "cpu_target" {
  description = "Average CPU percentage the service scales to hold."
  type        = number
  default     = 60
}

variable "db_host" {
  description = "Aurora cluster (writer) endpoint for this region."
  type        = string
}

variable "db_name" {
  type = string
}

variable "db_secret_arn" {
  description = "Secrets Manager secret holding username and password, in this region."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. Empty means HTTP only (fine for a demo, not for production)."
  type        = string
  default     = ""
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}
