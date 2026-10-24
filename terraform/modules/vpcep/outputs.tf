output "endpoint_id" {
  description = "VPC endpoint ID."
  value       = huaweicloud_vpcep_endpoint.this.id
}

output "ip_address" {
  description = "Private IP of the endpoint ENI."
  value       = huaweicloud_vpcep_endpoint.this.ip_address
}

output "private_domain_name" {
  description = "Private DNS name of the endpoint, when DNS is enabled."
  value       = huaweicloud_vpcep_endpoint.this.private_domain_name
}
