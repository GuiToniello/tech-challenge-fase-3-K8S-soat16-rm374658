# Metricas geradas a partir dos eventos de log das APIs (contrato em docs/observabilidade.md do repo APP).
# Sem group_by a metrica nao tem tag nenhuma, entao todas agrupam por env. Ids (OrdemServicoId etc.)
# ficam so nos logs, nunca como tag. Nao ha backfill: so contam logs recebidos apos a criacao.

resource "datadog_logs_metric" "os_criadas" {
  name = "oficina.os.criadas"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "@evento:os.criada"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

resource "datadog_logs_metric" "os_encerradas" {
  name = "oficina.os.encerradas"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "@evento:os.encerrada"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

resource "datadog_logs_metric" "os_tempo_no_status" {
  name = "oficina.os.tempo_no_status"

  compute {
    aggregation_type = "distribution"
    path             = "@TempoNoStatusAnteriorSegundos"
  }

  filter {
    query = "@evento:os.status_alterado"
  }

  group_by {
    path     = "@StatusAnterior"
    tag_name = "status_anterior"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

resource "datadog_logs_metric" "os_falhas" {
  name = "oficina.os.falhas"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "@evento:os.falha"
  }

  group_by {
    path     = "@Etapa"
    tag_name = "etapa"
  }

  group_by {
    path     = "@TipoFalha"
    tag_name = "tipo_falha"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# integracao.falha (Resend) e http.erro_nao_tratado com banco indisponivel (Integracao=postgres).
resource "datadog_logs_metric" "integracao_erros" {
  name = "oficina.integracao.erros"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "@Integracao:*"
  }

  group_by {
    path     = "@Integracao"
    tag_name = "integracao"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}