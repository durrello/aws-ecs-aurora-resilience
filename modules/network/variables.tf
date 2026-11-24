variable "name" {
  description = "Name prefix for every resource in this VPC."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block. Use different ranges per region so the VPCs can be peered later."
  type        = string
}

variable "az_count" {
  description = "Number of availability zones (2 or 3)."
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "One NAT gateway for the whole VPC (cheaper) instead of one per AZ (more resilient)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 30
}
