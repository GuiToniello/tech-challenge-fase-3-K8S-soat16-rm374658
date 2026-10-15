# tech-challenge-fase-3-K8S-soat16-rm374658

Infraestrutura de rede e Kubernetes do projeto **Tech Challenge Oficina** (SOAT16, fase 3). O Terraform deste repositório cria na AWS a VPC, o Amazon EKS, o Amazon API Gateway (acesso externo às APIs) e os addons do cluster, e configura a observabilidade no Datadog. Os manifests Kubernetes das cinco APIs também ficam aqui, e tudo é mantido por pipelines próprias no GitHub Actions.

O repositório não usa código nem state de outro repositório: tem os próprios Terraform states, a própria configuração e os próprios workflows. Ele se relaciona com outros três repositórios:
- **[DB](https://github.com/GuiToniello/tech-challenge-fase-3-DB-soat16-rm374658)**: cria o Amazon RDS dentro da rede deste repositório.
- **[APP](https://github.com/GuiToniello/tech-challenge-fase-3-APP-soat16-rm374658)**: builda e publica as imagens no Amazon ECR.
- **LAMBDA**.

## 1. O que é provisionado

Tudo fica na AWS, região `us-east-1`, em duas configurações Terraform independentes:

| Configuração | State | Recursos |
|---|---|---|
| [infra/foundation](infra/foundation) | `techchallenge-oficina/k8s-foundation.tfstate` | VPC `10.0.0.0/16`, subnets públicas e privadas (2 AZs), Internet Gateway e rotas, SGs do cluster e dos nodes, IAM roles, EKS `techchallenge-oficina-eks` (1.36), node group `t3.small` (2/2/2), access entries e o acesso externo: API Gateway (HTTP API, com o Lambda authorizer e a rota `/auth/token` do repo LAMBDA), VPC Link e NLB interno |
| [infra/addons](infra/addons) | `techchallenge-oficina/k8s-addons.tfstate` | Metrics Server e Datadog Agent, via Helm, e os recursos do Datadog no módulo [datadog/](infra/addons/datadog): métricas de log, monitores, synthetics, SLO e dashboard ([infra/DATADOG.md](infra/DATADOG.md)) |

Os manifests em [k8s/](k8s) criam o namespace `oficina` e, para cada uma das cinco APIs (monolith, approval, createos, getos, status), um ConfigMap, um Deployment, um Service `NodePort` e um HPA. Também criam o Secret `oficina-api-secrets`. Os Deployments levam os labels `tags.datadoghq.com/env` e `tags.datadoghq.com/service`, que dão ao Datadog o `env` e o `service` de cada API.

```mermaid
flowchart TD
  Internet[Internet]
  Datadog[Datadog - SaaS\nMetricas, logs, traces,\nmonitores e dashboard]

  subgraph AWS[AWS - us-east-1]
    APIGW[Amazon API Gateway\nHTTP API]
    ECR[Amazon ECR\nImagens - repo APP]

    subgraph VPC[VPC - este repo]
      subgraph PublicSubnets[Sub-redes publicas - duas AZs]
        EKS[Amazon EKS\nNodes gerenciados\nSG techchallenge-oficina-nodes-sg]
      end

      subgraph PrivateSubnets[Sub-redes privadas - duas AZs]
        VPCLink[VPC Link]
        NLB[NLB interno]
        RDS[Amazon RDS PostgreSQL\nrepo DB]
      end
    end
  end

  Internet -->|HTTPS| APIGW
  APIGW --> VPCLink
  VPCLink --> NLB
  NLB -->|NodePorts 30080-30084| EKS
  EKS -->|Le imagens| ECR
  EKS -->|PostgreSQL 5432| RDS
  EKS -->|Datadog Agent - HTTPS| Datadog
  Datadog -.->|Synthetics - health das APIs| APIGW
```

As subnets privadas não têm NAT nem rota para a Internet. Elas hospedam o banco do repositório DB e, deste repositório, o VPC Link e o NLB interno do API Gateway. Os detalhes da arquitetura estão em [infra/ESTRUTURA.md](infra/ESTRUTURA.md), e o passo a passo local em [infra/README.md](infra/README.md). A organização dos manifests está em [k8s/README.md](k8s/README.md), e a observabilidade com Datadog, em [infra/DATADOG.md](infra/DATADOG.md).

## 2. Dependências entre repositórios

### Ordem

| Operação | Ordem |
|---|---|
| Deploy | **K8S** Bootstrap (rede + EKS + addons) → **DB** Bootstrap (RDS) → **APP** Bootstrap (imagens no ECR) / **LAMBDA** → **K8S** K8s Apply (manifests), disparado automaticamente pelo APP |
| Destroy | **APP** (nada a destruir: o ECR é manual) / **LAMBDA** → **DB** → **K8S** |

- O Bootstrap deste repositório **não** aplica os manifests. Os pods precisam do RDS, para montar a connection string, e das imagens no ECR. Por isso o apply dos manifests é o workflow separado **K8s Apply**, que roda por último.
- Depois de publicar imagens no ECR, pelo Bootstrap ou pelo Deploy, o repo APP dispara o **K8s Apply** daqui com `restart-pods = true`. Para isso ele usa um token com permissão de Actions neste repositório. É assim que os pods passam a usar a nova `:latest`.
- O Destroy deste repositório **falha** se o RDS ainda existir. O RDS usa as subnets privadas, e o SG dele referencia o SG dos nodes, então apagar a rede antes travaria em `DependencyViolation`.

### Contrato produzido (usado pelo repo DB)

O repositório DB encontra a rede por tag e nome, sem ler o state deste repositório. **Estes nomes não podem mudar:**

| Item | Valor |
|---|---|
| VPC | Tag `Project = techchallenge-oficina`, aplicada pelo `default_tags` do provider em [providers.tf](infra/foundation/providers.tf). Precisa existir **uma única** VPC com essa tag |
| Subnets privadas | `techchallenge-oficina-private-1` e `-2`, em duas AZs ([vpc.tf](infra/foundation/vpc.tf)) |
| SG dos nodes | `techchallenge-oficina-nodes-sg`, anexado aos worker nodes pelo launch template ([eks-node-groups.tf](infra/foundation/eks-node-groups.tf)) |

O nome do cluster (`techchallenge-oficina-eks`) é usado só por este repositório: pelos addons e pela variable `EKS_CLUSTER_NAME`.

### Contrato consumido

| De | Item | Uso |
|---|---|---|
| DB | Identifier `techchallenge-oficina-postgres`, database `oficina`, usuário `sa`, porta `5432`, senha no secret `RDS_PASSWORD` | O K8s Apply descobre o endpoint e monta `DatabaseSettings__ConnectionString` no Secret das APIs |
| DB | SG `techchallenge-oficina-rds-sg` e o identifier do RDS | O Destroy (`db-check`) confere que os dois já foram removidos antes de destruir a rede |
| APP | Imagens `903936907231.dkr.ecr.us-east-1.amazonaws.com/techchallenge-oficina-<api>:latest`. Os 5 repositórios ECR já existem e não são gerenciados por este Terraform | Deployments com `imagePullPolicy: Always`. O pull usa a role IAM dos nodes (`AmazonEC2ContainerRegistryReadOnly`) |
| APP | `GET /health/ready`, anônimo, que checa o banco. O `/health` continua igual, sem banco | `http_check` do Datadog Agent (service check `http.can_connect`). As probes do Kubernetes continuam em `/health` |
| APP | Logs JSON no stdout com os atributos de [docs/observabilidade.md](https://github.com/GuiToniello/tech-challenge-fase-3-APP-soat16-rm374658/blob/main/docs/observabilidade.md) (`evento`, `dd.*`, `error.*` e as propriedades dos eventos), com o nível de log lido de `Serilog__MinimumLevel__*` | Métricas de log, monitores e dashboard do módulo `datadog/`, que filtram esses nomes (espelho em [infra/DATADOG.md](infra/DATADOG.md#5-contrato-com-o-repo-app-espelho)). Os ConfigMaps definem o nível de log |

## 3. Pré-requisitos (manuais, uma vez)

0. **Ambiente da fase 2 destruído.** Este repositório cria recursos com os mesmos nomes da fase 2 (EKS, IAM roles, VPC com tag `Project`), mas usa states novos (`k8s-*.tfstate`). Se a fase 2 ainda existir, o Bootstrap falha com nomes duplicados, e o repositório DB passa a encontrar duas VPCs. Desative também os workflows do repositório da fase 2, para que nada seja recriado por engano.
1. **Bucket S3 `terraform-state-soat16`** em `us-east-1`, com versionamento, criptografia e bloqueio de acesso público. É compartilhado entre os repositórios, cada um com as próprias keys. Este usa `techchallenge-oficina/k8s-foundation.tfstate` e `techchallenge-oficina/k8s-addons.tfstate`, com lock nativo (`use_lockfile`).
2. **Usuário IAM `terraform`**: suas access keys vão nos secrets do GitHub. Ele recebe uma access entry de administrador no EKS (`aws_caller_identity`). **Use sempre o mesmo usuário**, no CI e localmente. Com outro usuário, a access entry é substituída, e o usuário anterior perde o acesso ao cluster. Permissões necessárias, em linhas gerais:
   - `eks:*` no cluster, node group, access entries e access policies.
   - EC2: VPC, subnets, route tables, Internet Gateway, security groups, launch templates, tags e `ec2:Describe*`.
   - IAM:
     - `iam:CreateRole`, `iam:DeleteRole`, `iam:GetRole`, `iam:TagRole`, `iam:PassRole`.
     - `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:ListAttachedRolePolicies`, `iam:ListRolePolicies`, `iam:ListInstanceProfilesForRole`.
     - `iam:GetUser` (para `cluster_admin`) e `iam:CreateServiceLinkedRole` (EKS, node group, ELB e API Gateway: `ops.apigateway.amazonaws.com`, criada no primeiro VPC Link).
   - API Gateway: `apigateway:*` em `/apis*`, `/vpclinks*` e `/tags*` (HTTP API, rotas, integrações, authorizer, stage e VPC Link).
   - Elastic Load Balancing: criar, alterar e apagar o NLB, os target groups e os listeners, com `elasticloadbalancing:AddTags` e `elasticloadbalancing:Describe*`.
   - Auto Scaling: `autoscaling:AttachLoadBalancerTargetGroups`, `autoscaling:DetachLoadBalancerTargetGroups` e `autoscaling:Describe*` (anexa o ASG do node group aos target groups).
   - `rds:DescribeDBInstances` (K8s Apply e Destroy).
   - S3: `s3:GetObject`, `s3:PutObject` e `s3:DeleteObject` em `techchallenge-oficina/k8s-*.tfstate*`, mais `s3:ListBucket` no bucket.
3. **Usuário IAM `cluster_admin`**: acesso alternativo ao cluster. É **obrigatório**: a foundation consulta esse usuário (`data "aws_iam_user"`), e o plan falha se ele não existir.
4. **Secrets e Variables do GitHub**: veja a seção 4.
5. **Environment `destroy`** (Settings → Environments): crie **antes** do primeiro Destroy, com você como *Required reviewer* e *Deployment branches* restrito a `main`. Não dispare o Destroy com um Deploy ou Bootstrap em andamento (veja o Troubleshooting).
6. **Proteção da branch `main`** (Settings → Branches): exija Pull Request e os status checks abaixo. Eles só aparecem na lista depois que o primeiro PR roda a pipeline.
   - `validate-foundation / terraform`
   - `validate-addons / terraform`
   - `validate-k8s / kubectl`
7. **Conta Datadog (trial de 14 dias, sem cartão)**: crie só quando for subir o ambiente e demonstrar, porque os 14 dias contam do cadastro. Gere a API Key e a Application Key (não-escopada) e cadastre os secrets e variables `DD_*` (seção 4). Sem conta, defina a variable `DD_ENABLED=false`: o addons sobe só com o Metrics Server. Passo a passo em [infra/DATADOG.md](infra/DATADOG.md#2-configuração).

## 4. Secrets e Variables

| Nome | Tipo | Uso |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Secret | Credencial do usuário IAM `terraform` |
| `AWS_SECRET_ACCESS_KEY` | Secret | Idem |
| `RDS_PASSWORD` | Secret | Senha do RDS para a connection string. Deve ser **igual** à do repo DB |
| `RESEND_API_KEY` | Secret | Chave da API de e-mail (Resend) das APIs |
| `DD_API_KEY` | Secret | API Key do Datadog, usada pelo Agent e pelo provider do Terraform (addons). Obrigatória, exceto com `DD_ENABLED=false` **e** sem recursos do Datadog no state |
| `DD_APP_KEY` | Secret | Application Key do Datadog (não-escopada), usada pelo provider do Terraform. Obrigatória, exceto com `DD_ENABLED=false` **e** sem recursos do Datadog no state |
| `DD_ALERT_RECIPIENTS` | Secret (opcional) | Destinatários dos monitores, ex.: `@seu-email@dominio.com`. É secret porque o repositório é público e o plan imprime as mensagens dos monitores |
| `AWS_REGION` | Variable | `us-east-1` |
| `EKS_CLUSTER_NAME` | Variable | `techchallenge-oficina-eks` |
| `RDS_INSTANCE_IDENTIFIER` | Variable | `techchallenge-oficina-postgres` (contrato do repo DB) |
| `RDS_DATABASE` | Variable | `oficina` |
| `RDS_USERNAME` | Variable | `sa` |
| `DD_SITE` | Variable | Site do Datadog, só o host: `datadoghq.com` (US1, padrão do cadastro) ou o site escolhido. Obrigatória, exceto com `DD_ENABLED=false` **e** sem recursos do Datadog no state |
| `DD_ENABLED` | Variable (opcional) | `true` (padrão) / `false`: desliga o Datadog, e o próximo apply do addons remove o Agent e os recursos do Datadog |
| `DD_SYNTHETICS_STATUS` | Variable (opcional) | `live` (padrão) / `paused`: pausa os synthetics |

Todos ficam no nível do **repositório**, não de environment.

Ao desligar o Datadog (`DD_ENABLED` de `true` para `false`), mantenha `DD_API_KEY`, `DD_APP_KEY` e `DD_SITE` válidos até o apply que desliga o Datadog terminar: é ele que apaga os recursos do Datadog, e para isso o provider precisa das chaves e do site da conta.

Os segredos são passados ao `k8s/.env` por variáveis de ambiente, sem interpolação no script. Por isso `$` e backtick na senha não são interpretados. O `;` continua proibido, porque quebra a connection string.

As chaves do Datadog chegam ao Terraform do addons como `TF_VAR_datadog_*`, variáveis `sensitive` que não aparecem no plan nem nos logs. A API Key vai ao Agent por `set_sensitive` e fica no state do addons e num Secret do namespace `datadog`. Detalhes em [infra/DATADOG.md](infra/DATADOG.md#22-secrets-e-variables-do-github).

## 5. Pipelines (GitHub Actions)

| Workflow | Gatilho | O que faz |
|---|---|---|
| **Bootstrap** | Manual | `apply` da foundation → `apply` dos addons (Metrics Server e Datadog). Não aplica manifests |
| **Deploy** | Pull Request para `main` | `validate` offline de foundation, addons e manifests (checks obrigatórios) → `plan` informativo de foundation e addons |
| **Deploy** | Push na `main` | Mudança em `infra/**`, `deploy.yml` ou `_terraform.yml`: apply foundation → addons. Mudança em `k8s/**` ou `_k8s-apply.yml`: apply dos manifests com rollout restart |
| **K8s Apply** | Manual (input `restart-pods`, padrão `true`), ou disparado pelo repo APP depois de publicar imagens | Descobre o RDS, gera o Secret, `kubectl apply -k k8s` e, opcionalmente, `rollout restart` |
| **Destroy** | Manual, `confirm = destroy` + aprovação | Confere que as Lambdas do repo LAMBDA (SG `techchallenge-oficina-lambda-sg`), o RDS e o SG dele já foram destruídos → destroy dos addons (inclui o Datadog Agent e os recursos do Datadog) → destroy da foundation (inclui API Gateway, VPC Link e NLB), que roda mesmo se o dos addons falhar |

Apply, K8s Apply e Destroy só rodam a partir da `main`. Disparados em outra branch, **falham** com erro. Os detalhes estão em [.github/workflows/README.md](.github/workflows/README.md).

**Datadog nas pipelines:** no `infra/addons`, o plan, o apply e o destroy começam pelo passo **Conferir secrets e variables do Datadog**. Ele falha se faltar `DD_API_KEY`, `DD_APP_KEY` ou `DD_SITE` e, com `DD_ENABLED=false`, só avisa. Os valores entram no Terraform como `TF_VAR_datadog_*`. O addons instala o Datadog Agent antes do K8s Apply, e o restart dos pods faz o Datadog injetar neles o tracer .NET (APM). Trocar `DD_ENABLED` ou `DD_SYNTHETICS_STATUS` não dispara nada: rode o Bootstrap para aplicar. O Bootstrap não reinicia os pods: ao ligar o Datadog (`DD_ENABLED` de `false` para `true`), rode em seguida o **K8s Apply** com `restart-pods = true`, para os pods subirem com o tracer.

**Atenção ao custo: um merge em `infra/**` com o ambiente desligado recria o ambiente.** A foundation não depende de nada existente, então o push na `main` aplica a foundation e os addons do zero, subindo VPC, EKS, nodes, NLB e API Gateway. Isso inclui o **primeiro push** deste código. Como na fase 2, é o comportamento esperado; tenha isso em mente:
- **Com a infra destruída:**
  - O `plan-foundation` do PR mostra a criação completa.
  - Só o `plan-addons` falha, porque não há cluster.
  - Os `validate` continuam verdes.
- **Não faça merge de mudanças em `infra/**`, `deploy.yml` ou `_terraform.yml` enquanto quiser o ambiente desligado.** Se o merge acontecer, destrua de novo com o Destroy.
- **Primeiro push:**
  - Cria a infra e depois falha no `apply-k8s`, porque o RDS do repo DB ainda não existe. Isso é esperado.
  - Siga a ordem da seção 2: DB Bootstrap → APP Bootstrap, que publica as imagens e dispara o **K8s Apply**.
  - Se ainda não quiser subir nada, faça o primeiro push **antes** de configurar os secrets AWS. Os applies falham sem credenciais.
- **Merge só em `k8s/**` com o cluster ou o DB desligados:** falha no `apply-k8s`. Quando o ambiente estiver de pé, rode o **K8s Apply**.
- **Não use "Re-run" em um Deploy antigo:** ele reaplica o commit daquele run. Use o Bootstrap (infra) ou o K8s Apply (manifests), que aplicam a HEAD da `main`.

## 6. Uso local

O passo a passo com AWS CLI e Terraform está em [infra/README.md](infra/README.md).

Para validar sem acessar a AWS:

```powershell
# Terraform (em infra/foundation e em infra/addons)
terraform init -backend=false
terraform validate

# Manifests (a partir da raiz, com o template de .env)
Copy-Item k8s/.env.example k8s/.env
kubectl kustomize k8s
```

O `k8s/.env` e os `terraform.tfvars` são ignorados pelo Git. Os `.terraform.lock.hcl` **são** versionados e fixam as versões dos providers (aws 6.66.0, helm 2.17.0 e, no addons, DataDog/datadog 4.25.0). Os charts também são fixos: Metrics Server `3.12.2` e Datadog Agent `3.255.0` (`datadog_chart_version`).

O `validate` não precisa das chaves do Datadog. Para `plan` e `apply` locais do addons, passe as chaves por `TF_VAR_datadog_*` e mantenha as opções do Datadog no `terraform.tfvars` iguais às variables do GitHub ([infra/README.md](infra/README.md#4-instale-os-addons)).

## 7. Destruição e custos

EKS, nodes, NLB, API Gateway (cobrado por requisição) e o tráfego geram custo enquanto existem.

**Datadog:** sem custo durante o trial de 14 dias, sem cartão. Depois dele, APM, logs e synthetics param (plano Free). Antes do fim, defina `DD_ENABLED=false` e rode o Bootstrap, ou rode o Destroy. Nunca cadastre cartão ([infra/DATADOG.md](infra/DATADOG.md#4-trial-de-14-dias)).

**Atenção à versão do EKS:** `eks_version` é `1.36` ([variables.tf](infra/foundation/variables.tf)), no suporte padrão da AWS até 02/08/2027. Fora do suporte padrão, o control plane é cobrado na tarifa de *extended support*, várias vezes a tarifa padrão. O EKS só atualiza um cluster existente uma minor por vez: para trocar `eks_version`, destrua o ambiente antes do merge e deixe o Deploy recriá-lo na nova versão.

Para remover tudo:
1. Destrua o LAMBDA e o **DB**. O APP não tem recursos a destruir, porque o ECR é manual.
2. Rode o workflow **Destroy** deste repositório com `confirm = destroy` e aprove.

A ordem interna é addons → foundation:
- O destroy dos addons remove o Metrics Server, o Datadog Agent e os recursos do Datadog. A conta e as chaves continuam.
- O destroy da foundation roda **mesmo se o dos addons falhar** (por exemplo, com chaves do Datadog revogadas ou trial vencido), para o EKS não ficar ligado gerando custo, mas não se ele for cancelado. O run fica vermelho, e é preciso agir logo, mesmo sem planos de subir o ambiente de novo: os recursos do Datadog que sobraram continuam ativos (synthetics e monitores alertando), e sem o cluster o addons não roda mais. As saídas estão no troubleshooting do [infra/DATADOG.md](infra/DATADOG.md#8-troubleshooting).

O bucket S3 do state não é removido.

## 8. Troubleshooting

- **`no matching IAM User found` / erro em `aws_iam_user.cluster_admin`**: crie o usuário IAM `cluster_admin` (seção 3).
- **Addons ou K8s Apply sem acesso ao cluster (`Unauthorized`)**: a foundation foi aplicada por outro usuário IAM, e a access entry mudou. Reaplique a foundation com o usuário `terraform`.
- **K8s Apply falha em "Descobrir endpoint do RDS"**: o RDS do repo DB não existe ou ainda está sendo criado. Rode o Bootstrap do repo DB e aguarde.
- **Pods em `ImagePullBackOff`**: as imagens ainda não foram publicadas no ECR pelo repo APP.
- **Destroy falha em "Verificar se o RDS do repo DB já foi destruído"**: rode o Destroy do repo DB antes. O erro também aparece se a variable `RDS_INSTANCE_IDENTIFIER` não estiver configurada.
- **Destroy da foundation travado em `DependencyViolation` na VPC/subnets**: procure uma ENI órfã na VPC (por exemplo, do VPC Link do API Gateway). Espere alguns minutos ou apague-a e rode o Destroy de novo.
- **Destroy aparece como "cancelled"**: no padrão do GitHub (`queue: single`), um run mais novo no mesmo grupo de concorrência substituiu o que estava pendente. Rode o Destroy de novo, sem Deploy, Bootstrap ou K8s Apply em andamento.
- **`Error acquiring the state lock`**: há outro apply ou destroy rodando no mesmo root. Se o lock ficou preso depois de um run cancelado, rode `terraform force-unlock <LOCK_ID>` na pasta do root, ou apague o objeto `.tflock` correspondente no bucket.
- **Datadog** (passo "Conferir secrets e variables do Datadog" falhando, Agent ou pods `Pending`, synthetics vermelhos, chaves inválidas ou revogadas): veja o troubleshooting em [infra/DATADOG.md](infra/DATADOG.md#8-troubleshooting).
