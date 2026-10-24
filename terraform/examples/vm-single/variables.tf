variable "region" {
  description = "Huawei Cloud region."
  type        = string
  default     = "cn-north-4"
}

variable "project_name" {
  description = "Short lowercase project name used as a resource prefix."
  type        = string
  default     = "litellm"
}

variable "environment" {
  description = "Environment suffix."
  type        = string
  default     = "dev"
}

variable "availability_zone" {
  description = "AZ for the instance. Empty means: use the first AZ returned by the API."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR."
  type        = string
  default     = "10.0.1.0/24"
}

variable "image_id" {
  description = "IMS image ID. Empty means: look up image_name instead."
  type        = string
  default     = ""
}

variable "image_name" {
  description = "IMS image name used when image_id is empty."
  type        = string
  default     = "Ubuntu 24.04 server 64bit"
}

variable "flavor_id" {
  description = "ECS flavor. Flavor codes are region specific."
  type        = string
  default     = "c7.xlarge.4"
}

variable "system_disk_size" {
  description = "System disk size in GB."
  type        = number
  default     = 100
}

variable "eip_bandwidth_size" {
  description = "Public bandwidth in Mbit/s."
  type        = number
  default     = 100
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to call the gateway on 4000. Restrict this - the lab stack terminates plain HTTP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed to SSH into the instance."
  type        = list(string)
  default     = []
}

variable "key_pair" {
  description = "Existing key pair name for SSH. Empty means password-less console access only."
  type        = string
  default     = ""
}

variable "model_base_url" {
  description = "OpenAI-compatible base URL both preset models talk to (placeholder default; replace before use)."
  type        = string
  default     = "http://127.0.0.1:9/v1"
}

variable "glm_api_key" {
  description = "API key for glm-5.3. Leave empty when the endpoint does not authenticate."
  type        = string
  default     = "sk-not-configured"
  sensitive   = true
}

variable "deepseek_api_key" {
  description = "API key for deepseek-v4.1-flash. Leave empty when the endpoint does not authenticate."
  type        = string
  default     = "sk-not-configured"
  sensitive   = true
}

variable "litellm_version" {
  description = "LiteLLM image tag."
  type        = string
  default     = "1.106.3"
}

variable "litellm_image_repository" {
  description = "Image repository."
  type        = string
  default     = "ghcr.io/berriai/litellm"
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
