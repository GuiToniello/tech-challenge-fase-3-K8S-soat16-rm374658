# Providers configurados no root (infra/addons) e herdados aqui. O source precisa ser declarado,
# senao o Terraform procura hashicorp/datadog.
terraform {
  required_providers {
    datadog = {
      source = "DataDog/datadog"
    }
    aws = {
      source = "hashicorp/aws"
    }
  }
}