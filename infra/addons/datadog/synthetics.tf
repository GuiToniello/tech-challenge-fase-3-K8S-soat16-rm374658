# R3, uptime externo. A URL do API Gateway muda a cada bootstrap: e lida pelo nome da API,
# sem depender do state da foundation.
data "aws_apigatewayv2_apis" "this" {
  name          = var.api_gateway_name
  protocol_type = "HTTP"
}

data "aws_apigatewayv2_api" "this" {
  api_id = one(data.aws_apigatewayv2_apis.this.ids)
}

# GET /<api>/health pelo API Gateway: rota publica, sem authorizer, que chega ao pod pelo VPC Link e NLB.
resource "datadog_synthetics_test" "health" {
  for_each = local.services

  name      = "[oficina] ${each.value} GET /${each.key}/health"
  type      = "api"
  subtype   = "http"
  status    = var.synthetics_status
  locations = var.synthetics_locations
  tags      = concat(local.common_tags, ["service:${each.value}"])

  message = <<-EOT
    ${each.value} falhou em GET /${each.key}/health pelo API Gateway (status diferente de 200 ou resposta acima de 2 s).
    ${var.alert_recipients}
  EOT

  request_definition {
    method  = "GET"
    url     = "${data.aws_apigatewayv2_api.this.api_endpoint}/${each.key}/health"
    timeout = 10
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }

  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "2000"
  }

  # So alerta apos 5 min em falha (min_failure_duration), para nao acusar falhas isoladas.
  options_list {
    tick_every           = var.synthetics_tick_every
    min_failure_duration = 300
    min_location_failed  = 1

    retry {
      count    = 1
      interval = 1000
    }

    monitor_options {
      renotify_interval = 0
    }
  }
}

resource "datadog_service_level_objective" "uptime" {
  name        = "[oficina] Uptime das APIs"
  type        = "monitor"
  description = "Uptime externo das 5 APIs: synthetics em GET /<api>/health pelo API Gateway."
  monitor_ids = [for t in datadog_synthetics_test.health : t.monitor_id]
  tags        = local.common_tags

  thresholds {
    timeframe = "7d"
    target    = 99
    warning   = 99.5
  }
}