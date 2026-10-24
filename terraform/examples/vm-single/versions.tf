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

# Credentials from the environment: export HW_ACCESS_KEY / HW_SECRET_KEY.
provider "huaweicloud" {
  region = var.region
}
