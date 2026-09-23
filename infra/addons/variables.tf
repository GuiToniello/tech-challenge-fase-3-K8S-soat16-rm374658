variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "techchallenge-oficina-eks"
}

variable "metrics_server_chart_version" {
  type    = string
  default = "3.12.2"
}