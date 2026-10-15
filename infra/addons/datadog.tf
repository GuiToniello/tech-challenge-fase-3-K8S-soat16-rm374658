# Recursos SaaS do Datadog (metricas de log, monitores, synthetics, SLO e dashboard), em modulo local.
# O modulo nao pode ficar em ./datadog: o Helm procura primeiro uma pasta local com o nome do chart
# ("datadog") e o helm_release.datadog falha com "Chart.yaml file is missing".
module "datadog" {
  source = "./modules/datadog"
  count  = var.datadog_enabled ? 1 : 0

  env               = var.datadog_env
  site              = var.datadog_site
  alert_recipients  = var.datadog_alert_recipients
  synthetics_status = var.datadog_synthetics_status
}