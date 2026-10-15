resource "helm_release" "datadog" {
  count = var.datadog_enabled ? 1 : 0

  name             = "datadog"
  repository       = "https://helm.datadoghq.com"
  chart            = "datadog"
  namespace        = "datadog"
  create_namespace = true
  version          = var.datadog_chart_version
  wait             = true
  timeout          = 600

  values = [
    templatefile("${path.module}/datadog-agent-values.yaml", {
      site         = var.datadog_site
      cluster_name = var.cluster_name
      env          = var.datadog_env
    })
  ]

  # A API key fica fora dos values: entra so por set_sensitive, mascarada no plan.
  set_sensitive {
    name  = "datadog.apiKey"
    value = var.datadog_api_key
  }
}