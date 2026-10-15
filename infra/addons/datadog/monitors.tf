# Monitores R1-R4. So o de nodes notifica falta de dados: sem trafego, as metricas de APM e de log
# ficam vazias e isso nao e falha (por isso require_full_window = false nelas). As falhas de regra
# de negocio (os.falha) ficam so no dashboard: o e2e gera 400s propositais.

# R1: latencia das APIs (APM).
resource "datadog_monitor" "latencia_p95" {
  name  = "[oficina] Latencia p95 alta"
  type  = "metric alert"
  query = "percentile(last_5m):p95:trace.aspnet_core.request{env:${var.env}} by {service} > 1"

  message = <<-EOT
    p95 de {{service.name}} em {{value}} s (aviso acima de 0,5 s, alerta acima de 1 s).
    Veja as rotas mais lentas no APM. Logo apos um restart dos pods (Deploy ou K8s Apply), o primeiro request
    de cada pod e lento e, com pouco trafego, pode disparar este alerta sozinho.
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 1
    warning  = 0.5
  }

  require_full_window = false
  tags                = local.common_tags
}

# R2: recursos do Kubernetes. CPU e memoria em % do limit de cada deployment.
resource "datadog_monitor" "cpu_limit" {
  name  = "[oficina] CPU acima de 80% do limit"
  type  = "metric alert"
  query = "avg(last_10m):( sum:kubernetes.cpu.usage.total{${local.namespace_scope}} by {kube_deployment} / 1000000000 ) / sum:kubernetes.cpu.limits{${local.namespace_scope}} by {kube_deployment} * 100 > 80"

  message = <<-EOT
    CPU de {{kube_deployment.name}} em {{value}}% do limit. Confira o HPA e o consumo dos pods no namespace oficina.
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 80
  }

  tags = local.common_tags
}

resource "datadog_monitor" "memoria_limit" {
  name  = "[oficina] Memoria acima de 85% do limit"
  type  = "metric alert"
  query = "avg(last_10m):sum:kubernetes.memory.working_set{${local.namespace_scope}} by {kube_deployment} / sum:kubernetes.memory.limits{${local.namespace_scope}} by {kube_deployment} * 100 > 85"

  message = <<-EOT
    Memoria (working set) de {{kube_deployment.name}} em {{value}}% do limit. Em 100% o pod e morto por OOM.
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 85
  }

  tags = local.common_tags
}

resource "datadog_monitor" "crashloop" {
  name  = "[oficina] Container em CrashLoopBackOff"
  type  = "metric alert"
  query = "max(last_10m):default_zero(max:kubernetes_state.container.status_report.count.waiting{${local.namespace_scope},reason:crashloopbackoff} by {kube_deployment}) >= 1"

  message = <<-EOT
    {{kube_deployment.name}} tem container em CrashLoopBackOff.
    Veja os logs de erro do service (ex.: evento app.migracao_falhou) e os eventos do pod.
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 1
  }

  require_full_window = false
  tags                = local.common_tags
}

resource "datadog_monitor" "restarts" {
  name  = "[oficina] Restarts de container"
  type  = "metric alert"
  query = "change(max(last_15m),last_15m):max:kubernetes_state.container.restarts{${local.namespace_scope}} by {kube_deployment} > 2"

  message = <<-EOT
    {{kube_deployment.name}} teve mais de 2 restarts de container em 15 min.
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 2
  }

  tags = local.common_tags
}

# Unico com notify_no_data: sem dados dos nodes por 30 min, o Agent ou o cluster caiu.
resource "datadog_monitor" "nodes_ready" {
  name  = "[oficina] Nodes Ready abaixo de 2"
  type  = "metric alert"
  query = "max(last_10m):sum:kubernetes_state.node.by_condition{env:${var.env},condition:ready,status:true} < 2"

  message = <<-EOT
    Menos de 2 nodes Ready no cluster, ou sem dados dos nodes ha 30 min (Agent ou cluster fora do ar).
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 2
  }

  notify_no_data    = true
  no_data_timeframe = 30
  tags              = local.common_tags
}

# R3: healthchecks. O uptime externo (synthetics e SLO) fica em synthetics.tf.
# min(last_15m): so alerta com replica indisponivel nos 15 min inteiros. Um pod subindo num scale-out
# do HPA ou num restart nao dispara (restarts e CrashLoopBackOff tem monitores proprios).
resource "datadog_monitor" "replicas_indisponiveis" {
  name  = "[oficina] Replicas indisponiveis"
  type  = "metric alert"
  query = "min(last_15m):max:kubernetes_state.deployment.replicas_unavailable{${local.namespace_scope}} by {kube_deployment} >= 1"

  message = <<-EOT
    {{kube_deployment.name}} com replica indisponivel ha 15 min (ex.: pod Pending por falta de espaco nos nodes).
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 1
  }

  tags = local.common_tags
}

# http_check do Agent em /health/ready (API e banco), por service.
resource "datadog_monitor" "health_ready" {
  name  = "[oficina] Health interno (/health/ready) falhando"
  type  = "service check"
  query = "\"http.can_connect\".over(\"env:${var.env}\").by(\"service\").last(3).count_by_status()"

  message = <<-EOT
    /health/ready de {{service.name}} falhou em 2 checagens seguidas: API fora do ar ou sem acesso ao banco.
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    ok       = 1
    warning  = 1
    critical = 2
  }

  tags = local.common_tags
}

# R4: falhas no processamento de OS. 5xx por rota (APM) e erros de integracao (metrica de log).
resource "datadog_monitor" "erros_5xx" {
  name  = "[oficina] Respostas 5xx por rota"
  type  = "metric alert"
  query = "sum(last_10m):sum:trace.aspnet_core.request.errors{env:${var.env}} by {service,resource_name}.as_count() > 0"

  message = <<-EOT
    Respostas 5xx em {{service.name}} na rota {{resource_name.name}} nos ultimos 10 min.
    Veja os traces com erro no APM e os logs com status:error do service.
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 0
  }

  require_full_window = false
  tags                = local.common_tags
}

resource "datadog_monitor" "integracao_erros" {
  name  = "[oficina] Erros de integracao"
  type  = "metric alert"
  query = "sum(last_15m):sum:${datadog_logs_metric.integracao_erros.name}{env:${var.env}} by {integracao}.as_count() > 0"

  message = <<-EOT
    Falha de integracao {{integracao.name}} nos ultimos 15 min (resend: envio de e-mail; postgres: banco indisponivel).
    ${var.alert_recipients}
  EOT

  monitor_thresholds {
    critical = 0
  }

  require_full_window = false
  tags                = local.common_tags
}