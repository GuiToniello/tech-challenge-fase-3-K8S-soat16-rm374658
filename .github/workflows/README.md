# Pipelines (GitHub Actions)

As pipelines deste repositório cuidam de dois roots do Terraform, [infra/foundation](../../infra/foundation) e [infra/addons](../../infra/addons), e dos manifests em [k8s/](../../k8s). A lógica técnica fica em dois **workflows reutilizáveis**:
- `_terraform.yml`
- `_k8s-apply.yml`

Os quatro workflows de entrada decidem só **quando** chamar cada um e com quais inputs:
- `bootstrap.yml`
- `deploy.yml`
- `k8s-apply.yml`
- `destroy.yml`

Build e push das imagens no ECR **não** ficam aqui: são do repositório APP.

## Visão geral

```mermaid
flowchart TD
  subgraph Reusable[Workflows reutilizaveis]
    T[_terraform.yml\nvalidate / plan / apply / destroy\npor working-directory]
    K[_k8s-apply.yml\nvalidate offline / apply no EKS]
  end

  B[bootstrap.yml\nmanual] -->|foundation apply| T
  B -->|addons apply| T

  subgraph Deploy[deploy.yml]
    PR[pull_request para main] --> VF[validate-foundation]
    PR --> VA[validate-addons]
    PR --> VK[validate-k8s]
    VF --> PF[plan-foundation\ninformativo]
    VA --> PA[plan-addons\ninformativo]
    PUSH[push na main] --> C{paths-filter}
    C -->|infra/**| AF[apply-foundation] --> AA[apply-addons]
    C -->|k8s/**| AK[apply-k8s]
    AA -.-> AK
  end

  KA[k8s-apply.yml\nmanual + restart-pods] --> K
  D[destroy.yml\nmanual + confirm] --> DC[db-check] --> G[gate\nenvironment destroy]
  G -->|addons destroy| T
  G -.->|depois foundation destroy, mesmo se o dos addons falhar| T
```

> Convenção: workflows que começam com `_` são internos, chamados com `uses: ./.github/workflows/_x.yml`.

## Arquivos

```
.github/workflows/
  _terraform.yml   (workflow_call)       - validate | plan | apply | destroy em infra/foundation ou infra/addons (com o Datadog)
  _k8s-apply.yml   (workflow_call)       - validate (kustomize offline) | apply (kubectl apply -k k8s)
  bootstrap.yml    (workflow_dispatch)   - foundation → addons
  deploy.yml       (pull_request, push)  - checks de PR; apply no merge conforme o que mudou
  k8s-apply.yml    (workflow_dispatch)   - apply dos manifests, com restart opcional
  destroy.yml      (workflow_dispatch)   - addons → foundation, com confirmação e aprovação
```

---

## 1. `_terraform.yml` (reusable)

Inputs:
- `working-directory`: `infra/foundation` ou `infra/addons`, que também gerencia o Datadog.
- `command`: `validate`, `plan`, `apply` ou `destroy`.

O workflow tem um único job, `terraform`.

| Step | validate | plan | apply / destroy |
|---|---|---|---|
| Bloqueio fora da `main` (falha com erro) | — | — | ✔ se `github.ref != refs/heads/main` |
| Conferir secrets e variables do Datadog, só em `infra/addons` (falha se `DD_API_KEY`, `DD_APP_KEY` ou `DD_SITE` estiver vazio; com `DD_ENABLED=false`, só avisa) | — | ✔ | ✔ |
| `actions/checkout@v7` | ✔ | ✔ | ✔ |
| `aws-actions/configure-aws-credentials@v6` | — | ✔ | ✔ |
| `hashicorp/setup-terraform@v4` (Terraform `1.15.8`, sem wrapper) | ✔ | ✔ | ✔ |
| `terraform init -input=false` | com `-backend=false` | ✔ | ✔ |
| `terraform fmt -check -recursive` | ✔ | ✔ | ✔ |
| `terraform validate` | ✔ | ✔ | ✔ |
| `terraform plan -input=false -lock=false`, com as `TF_VAR_datadog_*` | — | ✔ | — |
| `terraform <cmd> -auto-approve -input=false`, com as `TF_VAR_datadog_*` | — | — | ✔ |

- **Variáveis do Datadog por `TF_VAR_*`:** a foundation não tem variável sensível e usa só os defaults de `variables.tf`. O addons recebe, nos steps de plan e de apply/destroy, as `TF_VAR_datadog_*` (`enabled`, `api_key`, `app_key`, `site`, `alert_recipients` e `synthetics_status`), vindas dos secrets e variables do GitHub (tabela no fim). Sem a variable `DD_SITE`, o `TF_VAR_datadog_site` vai como `datadoghq.com`, o padrão do `variables.tf`: um valor vazio substituiria esse padrão e apontaria o provider para uma URL inválida (`https://api./`). As chaves e os destinatários são variáveis `sensitive` e não aparecem no plan. O env vale para os dois roots, e a foundation ignora essas `TF_VAR_*` porque não declara as variáveis. Nenhum root usa `terraform.tfvars` no CI.
- **Conferência do Datadog:** o step roda antes do checkout (por isso `working-directory: .`), só em `infra/addons` e fora do `validate`. Segue o padrão do `_k8s-apply.yml`: um `::error::` para cada nome vazio e falha no fim. Com `DD_ENABLED=false`, emite um `::notice::` e segue, e o Terraform remove (ou não cria) o Agent e os recursos do Datadog. Para apagar recursos do Datadog que já existem, `DD_API_KEY`, `DD_APP_KEY` e `DD_SITE` precisam continuar válidos até esse apply terminar. O `validate` dos PRs não precisa das chaves.
- **Versões fixas:** Terraform `1.15.8`. Os providers ficam fixados pelos `.terraform.lock.hcl` versionados em cada root.
- **Plan sem lock:** o plan do PR é especulativo e não grava state. Por isso não disputa lock com um apply e não deixa lock órfão se for cancelado.
- **Plan do addons:** o provider Helm e o data source `aws_eks_cluster` precisam do cluster de pé e, com o Datadog ligado, o provider do Datadog precisa de chaves válidas. Sem o cluster, esse plan falha, e por isso ele é só informativo.
- **Concorrência** (definida só no reusable):
  - `apply` e `destroy` usam um grupo fixo **por root** (`terraform-infra/foundation`, `terraform-infra/addons`), com `cancel-in-progress: false`.
  - `validate` e `plan` usam um grupo por root, comando e ref, com `cancel-in-progress: true`.
  - No padrão do GitHub (`queue: single`), cada grupo mantém no máximo um run pendente, e um run novo substitui o pendente anterior.

## 2. `_k8s-apply.yml` (reusable)

Inputs:
- `command`: `validate` ou `apply`.
- `restart-pods`: boolean, padrão `false`.

O workflow tem um único job, `kubectl`.

| Step | validate | apply |
|---|---|---|
| Bloqueio fora da `main` (falha com erro) | — | ✔ |
| `actions/checkout@v7`: commit do run no validate; **ponta da `main`** no apply, para um run antigo não sobrescrever manifests mais novos | ✔ | ✔ |
| `azure/setup-kubectl@v5` | ✔ | ✔ |
| Conferir se as secrets e variables estão configuradas (falha se alguma estiver vazia) | — | ✔ |
| `cp k8s/.env.example k8s/.env` + `kubectl kustomize k8s` (offline) | ✔ | — |
| Credenciais AWS + `aws eks update-kubeconfig` | — | ✔ |
| Descobrir o endpoint do RDS (`aws rds describe-db-instances`, pelo identifier do repo DB) | — | ✔ **falha** se não houver endpoint |
| Gerar `k8s/.env`: `DatabaseSettings__ConnectionString` e `ResendSettings__ApiKey` | — | ✔ |
| `kubectl apply -k k8s` | — | ✔ |
| `kubectl rollout restart deployment -n oficina -l app.kubernetes.io/part-of=techchallenge-oficina` | — | se `restart-pods` |

- **Secret sem hash no nome:** o `k8s/.env` só existe no runner, e o Kustomize (`secretGenerator`) gera o Secret `oficina-api-secrets` a partir dele. Como o Secret usa `disableNameSuffixHash`, alterá-lo **não** reinicia os pods; para isso existe o `restart-pods`.
- **Segredos por variável de ambiente:** os segredos entram no step de geração como variáveis de ambiente (`$env:RDS_PASSWORD`), sem interpolação `${{ }}` dentro do script PowerShell. Assim, `$` e backtick na senha não são interpretados.
- **Concorrência:**
  - `apply` usa o grupo fixo `k8s-apply` (`cancel-in-progress: false`).
  - `validate` usa um grupo por ref (`cancel-in-progress: true`).

## 3. `bootstrap.yml`

- **Gatilho:** `workflow_dispatch`.
- **Jobs:** `terraform-foundation` (apply) → `terraform-addons` (apply: Metrics Server e Datadog).

Use-o na primeira criação, para recriar depois de um Destroy e para reaplicar a HEAD da `main` sem precisar de um push. É também o jeito de aplicar uma troca das variables `DD_ENABLED` ou `DD_SYNTHETICS_STATUS`. Com o Datadog ligado, o `terraform-addons` exige os secrets e variables do Datadog. Um push em `infra/**` também cria o ambiente do zero se ele estiver desligado, porque a foundation não depende de nada existente. Veja o aviso de custo no [README principal](../../README.md#5-pipelines-github-actions).

Ele **não** aplica os manifests. A ordem completa entre repositórios está no [README principal](../../README.md#2-dependências-entre-repositórios): K8S Bootstrap → DB Bootstrap → APP (imagens) → **K8s Apply**.

## 4. `deploy.yml`

É a pipeline de alteração. Os jobs são condicionados pelo evento (`github.event_name`):

| Evento | Job | Chama | Observação |
|---|---|---|---|
| `pull_request` → `main` (sem filtro de paths) | `validate-foundation` | `_terraform.yml` validate | **Check obrigatório** `validate-foundation / terraform`, sem AWS |
| | `validate-addons` | `_terraform.yml` validate | **Check obrigatório** `validate-addons / terraform`, sem AWS |
| | `validate-k8s` | `_k8s-apply.yml` validate | **Check obrigatório** `validate-k8s / kubectl`, sem AWS |
| | `plan-foundation` (`needs: validate-foundation`) | `_terraform.yml` plan | Informativo. Pulado em PR de fork (sem secrets) |
| | `plan-addons` (`needs: validate-addons`) | `_terraform.yml` plan | Informativo. Exige o cluster de pé e, com o Datadog ligado, os secrets e variables do Datadog. Pulado em PR de fork |
| `push` na `main` | `changes` | `dorny/paths-filter@v4` | Separa `infra` (`infra/**`, `_terraform.yml`, `deploy.yml`) de `k8s` (`k8s/**`, `_k8s-apply.yml`) |
| | `apply-foundation` → `apply-addons` | `_terraform.yml` apply | Se `infra` mudou |
| | `apply-k8s` | `_k8s-apply.yml` apply **com restart** (`restart-pods: true`) | Se `k8s` mudou. Espera a infra quando as duas mudam (`!failure() && !cancelled()`) |

- **PR sem filtro de paths:** o `pull_request` não usa filtro de paths de propósito. Se usasse, os checks obrigatórios ficariam *pending* em PRs que só mexem em documentação.
- **Não use "Re-run" em um Deploy antigo para infra:** ele reaplica o `github.sha` daquele run. Para aplicar a HEAD da infra, use o Bootstrap. O apply dos manifests sempre usa a ponta da `main`, então o re-run dele é seguro.

## 5. `k8s-apply.yml`

- **Gatilho:** `workflow_dispatch`, com o input `restart-pods` (padrão `true`).
- **Job:** `apply` → `_k8s-apply.yml` com `command: apply`.

O repo [APP](https://github.com/GuiToniello/tech-challenge-fase-3-APP-soat16-rm374658) dispara este workflow automaticamente, com `restart-pods = true`, depois de publicar imagens no ECR. Ele usa `gh workflow run` com um token *fine-grained* que tem **Actions: Read and write** neste repositório. Esse token fica no secret `K8S_REPO_TOKEN` do APP. Nada precisa ser configurado aqui.

Rode manualmente no primeiro deploy dos manifests, se as imagens já estiverem no ECR. Rode também, com `restart-pods = true`, nestes casos:
- imagem nova no ECR, se o dispatch do APP não tiver rodado;
- troca de `RDS_PASSWORD` ou `RESEND_API_KEY`;
- RDS recriado;
- Qualquer mudança que precise reiniciar os pods sem ter passado pelo Deploy. O Deploy de push em `k8s/**` já aplica **com** restart, porque ConfigMaps e Secret não têm hash no nome e esse run pode substituir, na fila, um K8s Apply pendente disparado pelo APP.

Mudanças no spec do Deployment (imagem, recursos, probes) já fazem rollout sozinhas.

## 6. `destroy.yml`

- **Gatilho:** `workflow_dispatch` com o input obrigatório `confirm`. A comparação do GitHub não diferencia maiúsculas.

| Job | Quando roda | O que faz |
|---|---|---|
| `reject` | `confirm` ≠ `destroy` ou branch ≠ `main` | **Falha** com erro, em vez de terminar verde sem ter destruído nada |
| `db-check` | `confirm` = `destroy` na `main` | **Falha** em quatro casos: o SG `techchallenge-oficina-lambda-sg` (Lambda do repo LAMBDA na VPC) ainda existe, a var `RDS_INSTANCE_IDENTIFIER` está vazia, o RDS ainda existe, ou o SG `techchallenge-oficina-rds-sg` ainda existe. Assim o destroy não remove os addons para depois travar no `DependencyViolation` da rede |
| `gate` | depois do `db-check` | `environment: destroy`: aprovação manual. É um job à parte porque um job com `uses:` não aceita `environment` |
| `terraform-destroy-addons` | depois do `gate` | `_terraform.yml` destroy do `infra/addons`: Metrics Server, Datadog Agent e recursos do Datadog |
| `terraform-destroy-foundation` | depois do `gate` e do destroy dos addons, **mesmo que ele falhe**, mas não se ele for cancelado (`needs: [gate, terraform-destroy-addons]` e `if: !cancelled() && needs.gate.result == 'success' && needs.terraform-destroy-addons.result != 'cancelled'`) | `_terraform.yml` destroy. A foundation leva junto o API Gateway, o VPC Link e o NLB; como nenhum Load Balancer é criado pelo Kubernetes, não há o que limpar antes |

A foundation é destruída mesmo com falha nos addons (por exemplo, chaves do Datadog revogadas ou trial vencido), para o EKS nunca ficar ligado gerando custo. O run continua vermelho, então a falha fica visível, e o state do addons fica com o que não foi destruído: veja o troubleshooting do [infra/DATADOG.md](../../infra/DATADOG.md#8-troubleshooting). Já se o destroy dos addons for cancelado (por exemplo, substituído na fila por outro run), a foundation **não** é destruída, para o EKS não sair com os addons intactos: rode o Destroy de novo.

Configure o environment `destroy` **antes** do primeiro uso, com *Required reviewers* e *Deployment branches* restrito a `main`. Se ele não existir, o GitHub o cria sem proteção.

**Não dispare o Destroy com Deploy, Bootstrap ou K8s Apply em andamento.** Os jobs de destroy dividem os grupos de concorrência com os applies, e um run novo pode substituir um destroy pendente. Se o Destroy terminar *cancelled* ou falhar no meio, rode-o de novo.

---

## Secrets e Variables

Configure em **Settings → Secrets and variables → Actions**:

| Nome | Tipo | Usado por |
|---|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Secret | Todos os jobs que acessam a AWS (usuário IAM `terraform`) |
| `RDS_PASSWORD` | Secret | `_k8s-apply.yml`: connection string. Igual à do repo DB |
| `RESEND_API_KEY` | Secret | `_k8s-apply.yml` |
| `DD_API_KEY` / `DD_APP_KEY` | Secret | `_terraform.yml`: conferência do Datadog (addons) e `TF_VAR_datadog_api_key` / `TF_VAR_datadog_app_key` |
| `DD_ALERT_RECIPIENTS` | Secret (opcional) | `_terraform.yml`: `TF_VAR_datadog_alert_recipients`, destinatários dos monitores (ex.: `@seu-email@dominio.com`). É secret porque o repositório é público e o plan imprime as mensagens |
| `AWS_REGION` | Variable | Todos (`us-east-1`) |
| `EKS_CLUSTER_NAME` | Variable | `_k8s-apply.yml` (`techchallenge-oficina-eks`) |
| `RDS_INSTANCE_IDENTIFIER` | Variable | `_k8s-apply.yml` e `destroy.yml` (`techchallenge-oficina-postgres`) |
| `RDS_DATABASE` / `RDS_USERNAME` | Variable | `_k8s-apply.yml` (`oficina` / `sa`) |
| `DD_SITE` | Variable | `_terraform.yml`: conferência do Datadog (addons) e `TF_VAR_datadog_site` (`datadoghq.com`) |
| `DD_ENABLED` | Variable (opcional) | `_terraform.yml`: conferência do Datadog (addons) e `TF_VAR_datadog_enabled`. Padrão `true`; `false` desliga o Datadog |
| `DD_SYNTHETICS_STATUS` | Variable (opcional) | `_terraform.yml`: `TF_VAR_datadog_synthetics_status`. Padrão `live`; `paused` pausa os synthetics |

Todos os callers usam `secrets: inherit`, e todos os workflows declaram `permissions: contents: read`. Os `DD_*` ficam no nível do repositório: os jobs do Terraform não usam environment. Conta, chaves e valores em [infra/DATADOG.md](../../infra/DATADOG.md#2-configuração).
