output "cluster_name" {
  value = data.aws_eks_cluster.this.name
}

output "datadog_dashboard_url" {
  value = try(module.datadog[0].dashboard_url, null)
}