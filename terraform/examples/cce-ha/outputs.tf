output "gateway_url" {
  description = "Public endpoint of the LiteLLM gateway."
  value       = var.enable_https ? "https://${module.elb.public_ip}" : "http://${module.elb.public_ip}"
}

output "litellm_image" {
  description = "Container image reference used by the Helm release."
  value       = "${var.litellm_image_repository}:${var.litellm_version}"
}

output "elb_public_ip" {
  description = "Public IP of the gateway load balancer."
  value       = module.elb.public_ip
}

output "loadbalancer_id" {
  description = "ELB ID used by the Helm chart Service annotations."
  value       = module.elb.loadbalancer_id
}

output "certificate_id" {
  description = "Certificate ID referenced by the HTTPS listener. Empty when TLS is disabled."
  value       = module.elb.certificate_id
}

output "cluster_id" {
  description = "CCE cluster ID."
  value       = module.cce.cluster_id
}

output "cluster_name" {
  description = "CCE cluster name."
  value       = module.cce.cluster_name
}

output "kube_config_raw" {
  description = "Kubeconfig for the cluster. Treat as a cluster-admin credential."
  value       = module.cce.kube_config_raw
  sensitive   = true
}

output "database" {
  description = "PostgreSQL connection details."
  value = {
    host     = module.postgres.host
    port     = module.postgres.port
    name     = module.postgres.database_name
    username = module.postgres.username
    url      = module.postgres.connection_url
  }
  sensitive = true
}

output "redis" {
  description = "Redis connection details."
  value = {
    host = module.redis.host
    port = module.redis.port
    ssl  = module.redis.ssl_enabled
  }
  sensitive = true
}

output "app_env" {
  description = "Environment variables consumed by the Helm chart (sensitive)."
  value = {
    DATABASE_URL       = module.postgres.connection_url
    LITELLM_MASTER_KEY = local.master_key
    LITELLM_SALT_KEY   = local.salt_key
    REDIS_HOST         = module.redis.host
    REDIS_PORT         = tostring(module.redis.port)
    REDIS_PASSWORD     = random_password.redis.result
    REDIS_SSL          = module.redis.ssl_enabled ? "true" : "false"
  }
  sensitive = true
}

output "secret_names" {
  description = "CSMS secret names holding the application credentials."
  value = {
    master_key     = huaweicloud_csms_secret.master_key.name
    salt_key       = huaweicloud_csms_secret.salt_key.name
    db_password    = huaweicloud_csms_secret.database.name
    redis_password = huaweicloud_csms_secret.redis.name
  }
}

output "lts_log_group_id" {
  description = "LTS log group receiving ELB access logs."
  value       = module.observability.log_group_id
}

output "vpn_public_ips" {
  description = "Active/active public IPs of the VPN gateway when enabled."
  value = var.vpn_enabled ? {
    eip1 = try(module.vpn[0].eip1, null)
    eip2 = try(module.vpn[0].eip2, null)
  } : {}
}

output "modelarts_endpoint" {
  description = "Private endpoint IP for ModelArts inference when the VPC endpoint is enabled."
  value       = var.vpce_enabled ? try(module.vpcep[0].ip_address, null) : null
}
