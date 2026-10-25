output "gateway_url" {
  description = "Private endpoint of the LiteLLM gateway. Empty when elb_mode = ingress: the Ingress controller allocates the VIP after apply, read it with 'kubectl -n litellm get ingress'."
  value       = var.elb_mode == "standalone" ? (var.enable_https ? "https://${module.elb[0].private_ip}" : "http://${module.elb[0].private_ip}") : ""
}

output "gateway_private_ip" {
  description = "Private VIP of the internal load balancer (standalone mode only). Point your internal DNS at this address."
  value       = var.elb_mode == "standalone" ? module.elb[0].private_ip : null
}

output "elb_mode" {
  description = "Who owns the load balancer: ingress (CCE controller) or standalone (Terraform)."
  value       = var.elb_mode
}

output "ingress_elb" {
  description = "Parameters the Ingress annotation needs to create the internal ELB. Null in standalone mode."
  value = var.elb_mode == "ingress" ? {
    name               = local.names["elb"]
    class              = "performance"
    type               = "inner"
    l7_flavor_name     = var.elb_l7_flavor_name
    vip_subnet_cidr_id = module.network.access_subnet_neutron_id
    elb_virsubnet_ids  = [module.network.app_subnet_neutron_id]
    available_zone     = slice(local.azs, 0, 2)
  } : null
}

output "litellm_image" {
  description = "Container image reference used by the Helm release. With image_supply_chain = swr this is the same-region SWR path; nodes have no public egress, so anything else must already be reachable from the VPC."
  value = (
    var.image_supply_chain == "swr" ?
    "swr.${var.region}.myhuaweicloud.com/${var.swr_org}/litellm:${var.litellm_version}" :
    "${var.direct_image_repository}:${var.litellm_version}"
  )
}

output "loadbalancer_id" {
  description = "ELB ID of the Terraform-owned load balancer. Empty in ingress mode (CCE creates the ELB from the Ingress annotation)."
  value       = var.elb_mode == "standalone" ? module.elb[0].loadbalancer_id : ""
}

output "certificate_id" {
  description = "Certificate ID referenced by the HTTPS listener. Empty when TLS is disabled or the ELB is created by the Ingress controller."
  value       = var.elb_mode == "standalone" ? module.elb[0].certificate_id : ""
}

output "resource_names" {
  description = "Every generated resource name, keyed by component."
  value       = module.naming.all
}

output "bastion" {
  description = "Operator bastion (the only public IP in the stack)."
  value = var.bastion_enabled ? {
    instance_id = module.bastion[0].instance_id
    public_ip   = module.bastion[0].public_ip
    private_ip  = module.bastion[0].private_ip
    ssh         = module.bastion[0].ssh_command
    secret_name = huaweicloud_csms_secret.bastion[0].name
  } : null
}

output "cce_nodes" {
  description = "Worker node layout: one node pool per AZ."
  value = {
    nodes_per_az = var.cce_node_count_per_az
    az_count     = length(local.azs)
    total_nodes  = var.cce_node_count_per_az * length(local.azs)
    flavor       = var.cce_node_flavor
    masters      = length(local.azs) >= 3 ? 3 : 1
    azs          = local.azs
  }
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
    grafana_admin  = var.metric_backend == "aom" ? huaweicloud_csms_secret.grafana[0].name : null
  }
}

output "encryption" {
  description = "Which encryption branch is active and the key in use."
  value = {
    mode   = var.encryption_mode
    key_id = local.kms_key_id
  }
}

output "observability" {
  description = "Where logs and metrics are stored."
  value = {
    lts_log_group_id  = module.observability.log_group_id
    lts_log_stream_id = module.observability.log_stream_id
    aom_instance_name = var.metric_backend == "aom" ? local.names["aom"] : null
    aom_query_url     = var.metric_backend == "aom" ? try(huaweicloud_aom_prom_instance.this[0].prom_http_api_endpoint, null) : null
    aom_retention     = var.metric_backend == "aom" ? var.aom_retention : null
  }
}

output "modelarts_endpoint" {
  description = "Private endpoint IP for ModelArts inference when the VPC endpoint is enabled."
  value       = var.vpce_enabled ? try(module.vpcep[0].ip_address, null) : null
}

output "vpn" {
  description = "VPN gateway details when enabled."
  value = var.vpn_enabled ? {
    gateway_id = try(module.vpn[0].gateway_id, null)
    eip1       = try(module.vpn[0].eip1, null)
    eip2       = try(module.vpn[0].eip2, null)
  } : {}
}
