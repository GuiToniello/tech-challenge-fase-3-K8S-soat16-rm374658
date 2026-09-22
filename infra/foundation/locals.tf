locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
}