output "gateway_id" {
  description = "VPN gateway ID."
  value       = huaweicloud_vpn_gateway.this.id
}

output "eip1" {
  description = "First active/active public IP of the VPN gateway."
  value       = try(huaweicloud_vpn_gateway.this.eip1[0].id, null)
}

output "eip2" {
  description = "Second active/active public IP of the VPN gateway."
  value       = try(huaweicloud_vpn_gateway.this.eip2[0].id, null)
}

output "customer_gateway_id" {
  description = "Customer gateway ID when a peer IP was supplied."
  value       = local.create_customer_gateway ? huaweicloud_vpn_customer_gateway.this[0].id : null
}
