output "instance_id" {
  description = "Bastion ECS instance ID."
  value       = huaweicloud_compute_instance.bastion.id
}

output "public_ip" {
  description = "Pay-per-use EIP of the operator bastion. The only public IP in the stack; empty once sealed."
  value       = var.eip_enabled ? huaweicloud_vpc_eip.bastion[0].address : ""
}

output "private_ip" {
  description = "Private IP used to reach CCE and the internal load balancer."
  value       = try(huaweicloud_compute_instance.bastion.access_ip_v4, null)
}

output "ssh_command" {
  description = "SSH command for operators."
  value       = var.eip_enabled ? "ssh root@${huaweicloud_vpc_eip.bastion[0].address}" : "sealed: no public IP, reach the bastion from inside the VPC"
}
