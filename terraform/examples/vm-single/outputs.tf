output "public_ip" {
  description = "Public IP of the gateway instance."
  value       = huaweicloud_vpc_eip.this.address
}

output "gateway_url" {
  description = "Gateway endpoint. The lab stack serves plain HTTP - do not expose it to untrusted networks."
  value       = "http://${huaweicloud_vpc_eip.this.address}:4000"
}

output "instance_id" {
  description = "ECS instance ID."
  value       = huaweicloud_compute_instance.this.id
}

output "ssh_command" {
  description = "SSH command when a key pair was supplied."
  value       = var.key_pair == "" ? "" : "ssh -i <path-to-${var.key_pair}.pem> root@${huaweicloud_vpc_eip.this.address}"
}

output "master_key" {
  description = "LiteLLM master key (Admin UI login and admin API)."
  value       = local.master_key
  sensitive   = true
}

output "database_url" {
  description = "DATABASE_URL used by the lab stack."
  value       = "postgresql://litellm:${random_password.database.result}@litellm-pg:5432/litellm?schema=public"
  sensitive   = true
}

output "cloud_init_warning" {
  description = "Reminder about the lab tier."
  value       = "Secrets are delivered through cloud-init user_data in this tier. Use terraform/examples/cce-ha for production."
}
