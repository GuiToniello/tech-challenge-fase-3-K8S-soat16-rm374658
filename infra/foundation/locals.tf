locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)

  # NodePort de cada API (tambem porta do listener e do target group no NLB).
  # Precisa ser igual ao nodePort de k8s/features/<api>-api/service.yml.
  api_node_ports = {
    monolith = 30080
    approval = 30081
    createos = 30082
    getos    = 30083
    status   = 30084
  }
}