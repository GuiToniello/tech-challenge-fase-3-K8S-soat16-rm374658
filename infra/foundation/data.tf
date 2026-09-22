data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_iam_user" "cluster_admin" {
  user_name = var.cluster_admin_user_name
}