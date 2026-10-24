locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/vpcep"
    },
    var.tags,
  )
}

resource "huaweicloud_vpcep_endpoint" "this" {
  service_id  = var.service_id
  vpc_id      = var.vpc_id
  network_id  = var.subnet_id
  enable_dns  = var.enable_dns
  description = "${var.names["vpce"]} private endpoint"
  tags        = local.tags
}
