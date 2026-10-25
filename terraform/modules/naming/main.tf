terraform {
  required_version = ">= 1.6.0"
}

# Naming convention
#
# One input decides every name: `project_name`.
#
#   {project_name}-{component}
#
# Example with project_name = "litellmtest01":
#
#   litellmtest01-maas-vpc              VPC
#   litellmtest01-maas-access-subnet    front-end subnet (ELB VIP, bastion)
#   litellmtest01-maas-app-subnet       application subnet (CCE nodes)
#   litellmtest01-maas-data-subnet      data subnet (RDS, DCS)
#   litellmtest01-maas-sg-elb           security group for the internal load balancer
#   litellmtest01-maas-cce              CCE cluster
#   litellmtest01-maas-rds              RDS PostgreSQL
#   litellmtest01-maas-elb              internal load balancer
#   litellmtest01-litellm-master-key    CSMS secret
#
# Rules
#   - `project_name` is the only uniqueness anchor: two stacks in one account
#     differ by this prefix, so a console search for the project shows the whole
#     stack and nothing else.
#   - the prefix is lowercased and stripped to [a-z0-9-]; a value that does not
#     already look like that is rejected rather than silently rewritten.
#   - no region or environment suffix is appended. If you need several stacks in
#     one account, encode it in the name itself (`litellm-prod-01`,
#     `litellm-test-01`) - the prefix stays predictable.
#   - names are validated against the 64-character limit of the strictest
#     service used here.

variable "project_name" {
  description = "Prefix for every resource name, for example litellmtest01. The only naming input."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.project_name))
    error_message = "project_name must be 3-24 chars, lowercase letters/digits/hyphens, starting with a letter (for example litellmtest01)."
  }
}

variable "max_length" {
  description = "Strictest service name limit in the stack."
  type        = number
  default     = 64

  validation {
    condition     = var.max_length >= 24 && var.max_length <= 64
    error_message = "max_length must be between 24 and 64."
  }
}

locals {
  prefix = var.project_name

  names = {
    # --- network ---
    vpc = "${local.prefix}-maas-vpc"
    # three /24s inside the VPC, one per role, plus an ops /24 and a VPCE /26
    subnet_access = "${local.prefix}-maas-access-subnet"
    subnet_app    = "${local.prefix}-maas-app-subnet"
    subnet_data   = "${local.prefix}-maas-data-subnet"
    subnet_ops    = "${local.prefix}-maas-ops-subnet"
    subnet_vpce   = "${local.prefix}-maas-vpce-subnet"
    sg_elb        = "${local.prefix}-maas-sg-elb"
    sg_data       = "${local.prefix}-maas-sg-data"
    sg_admin      = "${local.prefix}-maas-sg-admin"
    sg_bastion    = "${local.prefix}-maas-sg-bastion"

    # --- egress ---
    nat = "${local.prefix}-maas-nat"

    # --- operator access ---
    bastion     = "${local.prefix}-maas-bastion"
    bastion_eip = "${local.prefix}-maas-bastion-eip"

    # --- compute ---
    cce      = "${local.prefix}-maas-cce"
    cce_pool = "${local.prefix}-maas-pool"

    # --- data ---
    rds = "${local.prefix}-maas-rds"
    dcs = "${local.prefix}-maas-dcs"

    # --- ingress ---
    elb  = "${local.prefix}-maas-elb"
    eip  = "${local.prefix}-maas-eip"
    cert = "${local.prefix}-maas-cert"

    # --- optional connectivity ---
    vpn  = "${local.prefix}-maas-vpn"
    vpce = "${local.prefix}-maas-vpce"

    # --- observability ---
    lts_group = "${local.prefix}-maas-lts"
    lts_elb   = "${local.prefix}-maas-lts-elb-access"
    lts_app   = "${local.prefix}-maas-lts-app"
    smn       = "${local.prefix}-maas-alarms"
    aom       = "${local.prefix}-maas-aom"

    # --- encryption ---
    kms = "${local.prefix}-maas-kms"

    # --- secrets (CSMS) ---
    secret_master_key = "${local.prefix}-litellm-master-key"
    secret_salt_key   = "${local.prefix}-litellm-salt-key"
    secret_db         = "${local.prefix}-litellm-db-password"
    secret_redis      = "${local.prefix}-litellm-redis-password"
    secret_grafana    = "${local.prefix}-grafana-admin"
    secret_bastion    = "${local.prefix}-bastion-password"
  }

  # Consumed by a precondition in the root module (check blocks are root-only).
  names_valid  = alltrue([for n in values(local.names) : can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", n))])
  names_fit    = alltrue([for n in values(local.names) : length(n) <= var.max_length])
  longest_name = max([for n in values(local.names) : length(n)]...)
}

output "prefix" {
  description = "Project name used as the prefix of every resource name."
  value       = local.prefix
}

output "all" {
  description = "Every named resource, keyed by component."
  value       = local.names
}

output "secrets" {
  description = "CSMS secret names (subset of `all`, convenience selector)."
  value = {
    master_key = local.names["secret_master_key"]
    salt_key   = local.names["secret_salt_key"]
    db         = local.names["secret_db"]
    redis      = local.names["secret_redis"]
    grafana    = local.names["secret_grafana"]
  }
}

output "valid" {
  description = "True when every generated name is syntactically valid and within length limits."
  value       = local.names_valid && local.names_fit
}

output "longest" {
  description = "Length of the longest generated name."
  value       = local.longest_name
}
