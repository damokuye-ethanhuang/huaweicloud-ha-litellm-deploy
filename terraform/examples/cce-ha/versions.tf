terraform {
  required_version = ">= 1.6.0"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.99"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credentials come from the environment:
#   export HW_ACCESS_KEY=...  HW_SECRET_KEY=...
# Never put AK/SK in tfvars - they would end up in state and shell history.
provider "huaweicloud" {
  region = var.region
}
