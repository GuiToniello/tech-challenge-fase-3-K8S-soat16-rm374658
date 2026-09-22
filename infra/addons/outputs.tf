output "cluster_name" {
  value = data.aws_eks_cluster.this.name
}

output "ingress_service_command" {
  value = "kubectl get svc ingress-nginx-controller -n ingress-nginx"
}

output "ingress_hostname_command" {
  value = "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath=\"{.status.loadBalancer.ingress[0].hostname}\""
}