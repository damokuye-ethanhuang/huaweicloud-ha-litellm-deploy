variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the load balancer VIP."
  type        = string
}

variable "availability_zones" {
  description = "Two availability zones for the load balancer."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "A highly available load balancer needs at least two availability zones."
  }
}

variable "l7_flavor_id" {
  description = "Explicit L7 flavor ID. Leave empty to use the elastic L7 flavor (billed per LCU), which is the recommended default."
  type        = string
  default     = ""
}

variable "eip_bandwidth_size" {
  description = "Public bandwidth in Mbit/s for the gateway EIP."
  type        = number
  default     = 300
}

variable "eip_charge_mode" {
  description = "EIP billing mode: traffic or bandwidth."
  type        = string
  default     = "traffic"
}

variable "certificate_id" {
  description = "Existing ELB/SCM certificate ID. Used when no PEM pair is supplied."
  type        = string
  default     = ""
}

variable "enable_https" {
  description = "Require a certificate for TLS termination. When false the module can be used for a plain HTTP lab deployment."
  type        = bool
  default     = true
}

variable "certificate_pem" {
  description = "PEM encoded server certificate. When set together with private_key_pem, the module creates an ELB certificate."
  type        = string
  default     = ""
  sensitive   = true
}

variable "private_key_pem" {
  description = "PEM encoded private key matching certificate_pem."
  type        = string
  default     = ""
  sensitive   = true
}

variable "deletion_protection" {
  description = "Block accidental deletion of the load balancer."
  type        = bool
  default     = true
}

variable "charging_mode" {
  description = "postPaid or prePaid."
  type        = string
  default     = "postPaid"

  validation {
    condition     = contains(["postPaid", "prePaid"], var.charging_mode)
    error_message = "charging_mode must be postPaid or prePaid."
  }
}

variable "enterprise_project_id" {
  description = "Enterprise project ID."
  type        = string
  default     = "0"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
