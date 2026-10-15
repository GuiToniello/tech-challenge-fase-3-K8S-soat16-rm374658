# Recursos SaaS do Datadog (metricas de log, monitores, synthetics, SLO e dashboard), em modulo local.
module "datadog" {
  source = "./datadog"
  count  = var.datadog_enabled ? 1 : 0

  env               = var.datadog_env
  site              = var.datadog_site
  alert_recipients  = var.datadog_alert_recipients
  synthetics_status = var.datadog_synthetics_status
}