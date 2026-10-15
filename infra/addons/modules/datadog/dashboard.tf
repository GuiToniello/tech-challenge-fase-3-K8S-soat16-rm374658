# R7: dashboard unico. Negocio (OS) no topo, depois APIs (R1), Kubernetes (R2), disponibilidade (R3)
# e os logs de erro. As queries de metrica usam a template variable $env.
resource "datadog_dashboard" "this" {
  title       = "[oficina] Observabilidade das APIs"
  description = "Ordens de servico, APIs, Kubernetes e disponibilidade das 5 APIs da oficina. Gerenciado pelo Terraform (repo K8S, infra/addons/modules/datadog): alteracoes feitas na UI sao sobrescritas."
  layout_type = "ordered"
  reflow_type = "auto"

  template_variable {
    name     = "env"
    prefix   = "env"
    defaults = [var.env]
  }

  # (a) Ordens de Servico: metricas de log (logs-metrics.tf) e 5xx do APM.
  widget {
    group_definition {
      title       = "Ordens de Servico"
      layout_type = "ordered"

      widget {
        note_definition {
          content          = "Metricas geradas dos eventos de log das APIs: sem backfill, so contam o que chegou depois da criacao. OS encerrada = OS entregue. Falhas de negocio sao respostas 4xx (regra de negocio ou nao encontrado); os 5xx vem do APM."
          background_color = "gray"
          font_size        = "14"
          text_align       = "left"
        }
      }

      widget {
        timeseries_definition {
          title     = "OS criadas por dia"
          live_span = "1w"

          request {
            q            = "sum:oficina.os.criadas{$env}.as_count().rollup(sum, daily, 12am, 'America/Sao_Paulo')"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title     = "OS encerradas (entregues) por dia"
          live_span = "1w"

          request {
            q            = "sum:oficina.os.encerradas{$env}.as_count().rollup(sum, daily, 12am, 'America/Sao_Paulo')"
            display_type = "bars"
          }
        }
      }

      widget {
        toplist_definition {
          title = "Tempo medio em cada status (min)"

          request {
            formula {
              formula_expression = "query1 / 60"
              alias              = "minutos"
            }

            query {
              metric_query {
                name       = "query1"
                query      = "avg:oficina.os.tempo_no_status{$env} by {status_anterior}"
                aggregator = "avg"
              }
            }
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Falhas de negocio por etapa"

          request {
            q            = "sum:oficina.os.falhas{$env} by {etapa,tipo_falha}.as_count()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Erros 5xx por rota"

          request {
            q            = "sum:trace.aspnet_core.request.errors{$env} by {resource_name}.as_count()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Erros de integracao"

          request {
            q            = "sum:oficina.integracao.erros{$env} by {integracao}.as_count()"
            display_type = "bars"
          }
        }
      }
    }
  }

  # (b) APIs: APM por service.
  widget {
    group_definition {
      title       = "APIs"
      layout_type = "ordered"

      widget {
        timeseries_definition {
          title = "Latencia p95 por servico (s)"

          request {
            q            = "p95:trace.aspnet_core.request{$env} by {service}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Requisicoes por servico"

          request {
            q            = "sum:trace.aspnet_core.request.hits{$env} by {service}.as_count()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Erros por servico"

          request {
            q            = "sum:trace.aspnet_core.request.errors{$env} by {service}.as_count()"
            display_type = "bars"
          }
        }
      }
    }
  }

  # (c) Kubernetes: pods das APIs (namespace oficina) e nodes.
  widget {
    group_definition {
      title       = "Kubernetes"
      layout_type = "ordered"

      widget {
        timeseries_definition {
          title = "CPU (% do limit) por deployment"

          request {
            q            = "( sum:kubernetes.cpu.usage.total{$env,${local.namespace_scope}} by {kube_deployment} / 1000000000 ) / sum:kubernetes.cpu.limits{$env,${local.namespace_scope}} by {kube_deployment} * 100"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Memoria (% do limit) por deployment"

          request {
            q            = "sum:kubernetes.memory.working_set{$env,${local.namespace_scope}} by {kube_deployment} / sum:kubernetes.memory.limits{$env,${local.namespace_scope}} by {kube_deployment} * 100"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Restarts de container por deployment (acumulado)"

          request {
            q            = "sum:kubernetes_state.container.restarts{$env,${local.namespace_scope}} by {kube_deployment}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Replicas indisponiveis por deployment"

          request {
            q            = "max:kubernetes_state.deployment.replicas_unavailable{$env,${local.namespace_scope}} by {kube_deployment}"
            display_type = "bars"
          }
        }
      }

      widget {
        query_value_definition {
          title     = "Nodes Ready"
          autoscale = false
          precision = 0

          request {
            q          = "sum:kubernetes_state.node.by_condition{$env,condition:ready,status:true}"
            aggregator = "last"

            conditional_formats {
              comparator = "<"
              value      = 2
              palette    = "white_on_red"
            }

            conditional_formats {
              comparator = ">="
              value      = 2
              palette    = "white_on_green"
            }
          }
        }
      }
    }
  }

  # (d) Disponibilidade: uptime externo (SLO dos synthetics) e health interno (http_check do Agent).
  widget {
    group_definition {
      title       = "Disponibilidade"
      layout_type = "ordered"

      widget {
        service_level_objective_definition {
          title             = "Uptime externo (synthetics em GET /<api>/health)"
          slo_id            = datadog_service_level_objective.uptime.id
          view_type         = "detail"
          view_mode         = "overall"
          time_windows      = ["7d"]
          show_error_budget = true
        }
      }

      widget {
        check_status_definition {
          title    = "Health interno (/health/ready, com banco) por servico"
          check    = "http.can_connect"
          grouping = "cluster"
          group_by = ["service"]
          tags     = ["env:${var.env}"]
        }
      }
    }
  }

  # (e) Logs de erro recentes das APIs. Inclui emergency: o LogCritical (ex.: app.migracao_falhou) sai como
  # Fatal no JSON, e o Datadog mapeia Fatal para emergency.
  widget {
    group_definition {
      title       = "Logs de erro recentes"
      layout_type = "ordered"

      widget {
        list_stream_definition {
          title = "Logs com status error ou emergency"

          request {
            response_format = "event_list"

            query {
              data_source  = "logs_stream"
              query_string = "env:${var.env} status:(error OR emergency)"
            }

            columns {
              field = "status_line"
              width = "auto"
            }

            columns {
              field = "timestamp"
              width = "auto"
            }

            columns {
              field = "service"
              width = "auto"
            }

            columns {
              field = "content"
              width = "compact"
            }
          }
        }
      }
    }
  }
}