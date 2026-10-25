output "vpc_id" {
  description = "VPC ID."
  value       = huaweicloud_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = huaweicloud_vpc.this.cidr
}

output "subnet_ids" {
  description = "Subnet IDs keyed access/app/data/ops."
  value       = { for k, s in huaweicloud_vpc_subnet.this : k => s.id }
}

output "access_subnet_id" {
  description = "Ingress subnet: internal ELB VIP."
  value       = huaweicloud_vpc_subnet.this["access"].id
}

output "ops_subnet_id" {
  description = "Operations subnet: where the in-VPC bastion lives."
  value       = huaweicloud_vpc_subnet.this["ops"].id
}

output "ops_subnet_cidr" {
  description = "CIDR of the operations subnet."
  value       = huaweicloud_vpc_subnet.this["ops"].cidr
}

output "app_subnet_id" {
  description = "Application subnet: CCE workers."
  value       = huaweicloud_vpc_subnet.this["app"].id
}

output "data_subnet_id" {
  description = "Data subnet: RDS, DCS and other stateful components."
  value       = huaweicloud_vpc_subnet.this["data"].id
}

output "vpce_subnet_id" {
  description = "Dedicated ModelArts VPCEP subnet ID. Null when create_vpce_subnet is false."
  value       = var.create_vpce_subnet ? huaweicloud_vpc_subnet.vpce[0].id : null
}

output "elb_security_group_id" {
  description = "Security group for the internal load balancer."
  value       = huaweicloud_networking_secgroup.elb.id
}

output "data_security_group_id" {
  description = "Security group for RDS and DCS."
  value       = huaweicloud_networking_secgroup.data.id
}

output "bastion_security_group_id" {
  description = "Security group for the operator bastion."
  value       = huaweicloud_networking_secgroup.bastion.id
}

output "nat_gateway_id" {
  description = "NAT gateway ID, null when disabled."
  value       = var.enable_nat_gateway ? huaweicloud_nat_gateway.this[0].id : null
}

output "nat_public_ip" {
  description = "NAT public IP, null when disabled."
  value       = var.enable_nat_gateway ? huaweicloud_vpc_eip.nat[0].address : null
}
