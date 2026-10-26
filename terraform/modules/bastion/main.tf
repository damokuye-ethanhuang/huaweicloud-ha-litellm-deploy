locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/bastion"
      "purpose"    = "helm-operator"
    },
    var.tags,
  )

  # The bastion is the only instance with a public IP in this stack. It exists so
  # an operator can run helm from a laptop without giving CCE a public endpoint.
  user_data = var.install_tools ? templatefile("${path.module}/templates/bootstrap.sh.tpl", {
    kubectl_version = var.kubectl_version
    helm_version    = var.helm_version
    ssh_public_key  = var.ssh_public_key
  }) : null
}

# Seal step: once the deployment is verified, the EIP is what keeps the stack
# reachable from the internet. `bastion_eip_enabled = false` removes it and the
# association in one apply, leaving every other resource untouched.
resource "huaweicloud_vpc_eip" "bastion" {
  count = var.eip_enabled ? 1 : 0

  publicip {
    type = var.eip_type
  }

  bandwidth {
    name        = var.names["bastion_eip"]
    size        = var.eip_bandwidth_size
    share_type  = "PER"
    charge_mode = var.eip_charge_mode
  }

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_compute_instance" "bastion" {
  name               = var.names["bastion"]
  image_name         = var.image_name
  flavor_id          = var.flavor_id
  availability_zone  = var.availability_zone
  security_group_ids = [var.security_group_id]
  admin_pass         = var.admin_password
  key_pair           = var.key_pair == "" ? null : var.key_pair
  user_data          = local.user_data

  system_disk_type = var.system_disk_type
  system_disk_size = var.system_disk_size

  network {
    uuid = var.subnet_id
  }

  # The CCE cluster API is private; the bastion reaches it over the VPC.
  delete_eip_on_termination = var.auto_release_on_delete

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_compute_eip_associate" "bastion" {
  count       = var.eip_enabled ? 1 : 0
  public_ip   = huaweicloud_vpc_eip.bastion[0].address
  instance_id = huaweicloud_compute_instance.bastion.id
}
