output "cluster_id" {
  description = "CCE cluster ID."
  value       = huaweicloud_cce_cluster.this.id
}

output "cluster_name" {
  description = "CCE cluster name."
  value       = huaweicloud_cce_cluster.this.name
}

output "api_server" {
  description = "Kubernetes API server endpoint."
  value       = try(huaweicloud_cce_cluster.this.certificate_clusters[0].server, null)
}

output "kube_config_raw" {
  description = "Raw kubeconfig for the cluster. Contains cluster-admin credentials."
  value       = huaweicloud_cce_cluster.this.kube_config_raw
  sensitive   = true
}

output "node_security_group_id" {
  description = "Security group CCE created for the worker nodes."
  value       = huaweicloud_cce_cluster.this.security_group_id
}

output "node_ids" {
  description = "Worker node IDs, in creation order (round-robin across AZs)."
  value       = huaweicloud_cce_node.workers[*].id
}

output "node_count" {
  description = "Total worker nodes."
  value       = length(huaweicloud_cce_node.workers)
}
