variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
}

variable "enable_lts" {
  description = "Create an LTS log group and stream for load balancer access logs."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "LTS retention in days."
  type        = number
  default     = 30
}

variable "enable_smn" {
  description = "Create an SMN topic for alarm notifications."
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "Email address subscribed to the alarm topic. SMN sends a confirmation mail that must be accepted."
  type        = string
  default     = ""
}

variable "alarms" {
  description = "Cloud Eye alarm definitions. Every alarm is optional and opt-in: verify the metric name and dimension for your region before enabling."
  type = list(object({
    name                = string
    namespace           = string
    metric_name         = string
    dimension_name      = string
    dimension_value     = string
    comparison_operator = string
    value               = number
    count               = number
    period              = number
    filter              = string
    level               = number
    description         = string
  }))
  default = []
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
