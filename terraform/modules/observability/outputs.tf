output "log_group_id" {
  description = "LTS log group ID for ELB access logs."
  value       = var.enable_lts ? huaweicloud_lts_group.this[0].id : null
}

output "log_stream_id" {
  description = "LTS log stream ID for ELB access logs."
  value       = var.enable_lts ? huaweicloud_lts_stream.elb[0].id : null
}

output "alarm_topic_urn" {
  description = "SMN topic URN used by Cloud Eye alarms."
  value       = var.enable_smn ? huaweicloud_smn_topic.this[0].topic_urn : null
}
