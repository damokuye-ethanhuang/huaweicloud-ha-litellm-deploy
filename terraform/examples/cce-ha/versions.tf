terraform {
  # 1.17 is the floor because of a Terraform bug we hit and reproduced: under
  # `-target`, variable validation results are reported for variables outside
  # the targeted graph, which panics with
  #   "panic: checkable object status report for unexpected checkable object
  #    var.<name>"
  # in 1.9.x. scripts/apply-staged.sh relies on -target, so older versions crash
  # intermittently. Verified clean on 1.17.0.
  required_version = ">= 1.17.0"

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
