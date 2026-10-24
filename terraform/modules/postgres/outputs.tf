output "instance_id" {
  description = "RDS instance ID."
  value       = huaweicloud_rds_instance.this.id
}

output "host" {
  description = "Private IP of the RDS instance."
  value       = try(huaweicloud_rds_instance.this.private_ips[0], null)
}

output "port" {
  description = "PostgreSQL port."
  value       = try(huaweicloud_rds_instance.this.db[0].port, 5432)
}

output "database_name" {
  description = "Database created for LiteLLM."
  value       = huaweicloud_rds_pg_database.litellm.name
}

output "username" {
  description = "Administrator user name reported by RDS."
  value       = try(huaweicloud_rds_instance.this.db[0].user_name, "root")
}

output "connection_url" {
  description = "Prisma-compatible DATABASE_URL for LiteLLM."
  value       = "postgresql://${try(huaweicloud_rds_instance.this.db[0].user_name, "root")}:${urlencode(var.password)}@${try(huaweicloud_rds_instance.this.private_ips[0], "localhost")}:${try(huaweicloud_rds_instance.this.db[0].port, 5432)}/${var.database_name}?schema=public"
  sensitive   = true
}

output "backup_keep_days" {
  description = "Configured backup retention."
  value       = var.backup_keep_days
}
