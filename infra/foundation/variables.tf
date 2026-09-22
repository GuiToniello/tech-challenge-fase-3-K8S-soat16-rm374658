variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "techchallenge-oficina"
}

variable "environment" {
  type    = string
  default = "study"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "cluster_name" {
  type    = string
  default = "techchallenge-oficina-eks"
}

variable "eks_version" {
  type    = string
  default = "1.32"
}

variable "node_instance_type" {
  type    = string
  default = "t3.small"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_disk_size" {
  type    = number
  default = 30
}

variable "cluster_admin_user_name" {
  type    = string
  default = "cluster_admin"
}