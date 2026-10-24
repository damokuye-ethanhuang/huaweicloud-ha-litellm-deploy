output "instance_id" {
  description = "DCS instance ID."
  value       = huaweicloud_dcs_instance.this.id
}

output "host" {
  description = "Private endpoint of the DCS instance."
  value       = huaweicloud_dcs_instance.this.private_ip
}

output "port" {
  description = "Redis port."
  value       = try(huaweicloud_dcs_instance.this.port, 6379)
}

output "flavor" {
  description = "Flavor actually used by the instance."
  value       = huaweicloud_dcs_instance.this.flavor
}

output "ssl_enabled" {
  description = "Whether TLS is enabled."
  value       = var.ssl_enable
}
