output "loadbalancer_id" {
  description = "ELB load balancer ID. The Helm chart uses it in the Service annotations."
  value       = huaweicloud_elb_loadbalancer.this.id
}

output "public_ip" {
  description = "Public IP when an EIP was attached (internal = false). Empty for the internal design."
  value       = var.internal ? "" : huaweicloud_vpc_eip.this[0].address
}

output "private_ip" {
  description = "Private VIP of the load balancer. This is the address clients in the VPC use."
  value       = huaweicloud_elb_loadbalancer.this.ipv4_address
}

output "internal" {
  description = "Whether the load balancer is private-only."
  value       = var.internal
}

output "certificate_id" {
  description = "Certificate ID available to the listener (empty when none was configured)."
  value       = local.certificate_id
}

output "l7_flavor_id" {
  description = "L7 flavor in use (elastic when not pinned)."
  value       = local.l7_flavor_id
}
