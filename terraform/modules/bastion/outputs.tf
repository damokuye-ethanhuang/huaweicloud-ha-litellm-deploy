output "instance_id" {
  description = "Bastion ECS instance ID."
  value       = huaweicloud_compute_instance.bastion.id
}

output "public_ip" {
  description = "Pay-per-use EIP of the operator bastion. The only public IP in the stack."
  value       = huaweicloud_vpc_eip.bastion.address
}

output "private_ip" {
  description = "Private IP used to reach CCE and the internal load balancer."
  value       = try(huaweicloud_compute_instance.bastion.access_ip_v4, null)
}

output "ssh_command" {
  description = "SSH command for operators."
  value       = "ssh root@${huaweicloud_vpc_eip.bastion.address}"
}
