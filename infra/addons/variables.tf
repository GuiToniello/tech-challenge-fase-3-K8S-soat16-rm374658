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

# Liga/desliga o Datadog inteiro (Agent e recursos SaaS). No CI vem da variable DD_ENABLED.
variable "datadog_enabled" {
  type    = bool
  default = true
}

# Chaves via TF_VAR_datadog_api_key/TF_VAR_datadog_app_key (secrets DD_API_KEY/DD_APP_KEY no CI), nunca no tfvars.
variable "datadog_api_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "datadog_app_key" {
  type      = string
  default   = ""
  sensitive = true
}

# So o host do site da conta (ex.: datadoghq.com, us5.datadoghq.com), sem https:// e sem o prefixo app.
variable "datadog_site" {
  type    = string
  default = "datadoghq.com"

  validation {
    condition     = !var.datadog_enabled || contains(["datadoghq.com", "us3.datadoghq.com", "us5.datadoghq.com", "datadoghq.eu", "ap1.datadoghq.com", "ap2.datadoghq.com"], var.datadog_site)
    error_message = "O datadog_site deve ser um destes sites: datadoghq.com, us3.datadoghq.com, us5.datadoghq.com, datadoghq.eu, ap1.datadoghq.com ou ap2.datadoghq.com."
  }
}

# Tag env no Datadog: igual ao environment da foundation.
variable "datadog_env" {
  type    = string
  default = "study"
}

variable "datadog_chart_version" {
  type    = string
  default = "3.255.0"
}

# Handles no fim das mensagens dos alertas (ex.: "@nome@dominio.com"). Sensitive: o repo e publico e o plan imprime as mensagens.
variable "datadog_alert_recipients" {
  type      = string
  default   = ""
  sensitive = true
}

variable "datadog_synthetics_status" {
  type    = string
  default = "live"

  validation {
    condition     = contains(["live", "paused"], var.datadog_synthetics_status)
    error_message = "O datadog_synthetics_status deve ser live ou paused."
  }
}