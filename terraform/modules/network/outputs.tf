output "vpc_id" {
  description = "ID of the VPC."
  value       = huaweicloud_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = huaweicloud_vpc.this.cidr
}

output "subnet_ids" {
  description = "Map of subnet name to subnet ID."
  value       = { for key, subnet in huaweicloud_vpc_subnet.this : key => subnet.id }
}

output "app_subnet_id" {
  description = "Subnet hosting CCE nodes and the ELB VIP."
  value       = huaweicloud_vpc_subnet.this["app"].id
}

output "data_subnet_id" {
  description = "Subnet hosting RDS and DCS."
  value       = huaweicloud_vpc_subnet.this["data"].id
}

output "vpce_subnet_id" {
  description = "Subnet used for VPC endpoints."
  value       = huaweicloud_vpc_subnet.this["vpce"].id
}

output "eni_subnet_ids" {
  description = "Subnet IDs for CCE Turbo ENI networking, in availability zone order."
  value       = [for index, _ in var.eni_subnet_cidrs : huaweicloud_vpc_subnet.this["eni-${index}"].id]
}

output "elb_security_group_id" {
  description = "Security group attached to the load balancer."
  value       = huaweicloud_networking_secgroup.elb.id
}

output "data_security_group_id" {
  description = "Security group attached to RDS and DCS."
  value       = huaweicloud_networking_secgroup.data.id
}

output "nat_gateway_id" {
  description = "ID of the NAT gateway, empty when disabled."
  value       = var.enable_nat_gateway ? huaweicloud_nat_gateway.this[0].id : null
}

output "nat_public_ip" {
  description = "Public IP of the NAT gateway, empty when disabled."
  value       = var.enable_nat_gateway ? huaweicloud_vpc_eip.nat[0].address : null
}
