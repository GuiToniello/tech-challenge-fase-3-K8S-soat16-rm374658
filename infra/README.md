# Terraform AWS

Tutorial resumido para criar a infraestrutura deste repositório a partir da sua máquina. Existem duas configurações Terraform independentes:

- `foundation/`: VPC, subnets públicas e privadas, security groups, IAM, EKS, node group, access entries e o acesso externo às APIs (API Gateway, VPC Link e NLB interno).
- `addons/`: Metrics Server e Datadog Agent via Helm, e os recursos do Datadog no módulo local `addons/datadog/` (métricas de log, monitores, synthetics, SLO e dashboard). Detalhes em [DATADOG.md](DATADOG.md).

O state usa o bucket S3 externo `terraform-state-soat16`, com lock nativo (`use_lockfile`) e estas chaves:

- `techchallenge-oficina/k8s-foundation.tfstate`
- `techchallenge-oficina/k8s-addons.tfstate`

No dia a dia, esses passos são automatizados pelos workflows **Bootstrap**, **Deploy** e **Destroy** (veja [.github/workflows/README.md](../.github/workflows/README.md)). Use este tutorial para execução local ou diagnóstico. O state é o mesmo do CI: um apply local altera o mesmo ambiente, então aplique a partir do código da `main`.

O banco de dados (RDS) não fica aqui. Ele é criado pelo repositório [DB](https://github.com/GuiToniello/tech-challenge-fase-3-DB-soat16-rm374658), dentro da rede criada pela foundation. Detalhes da arquitetura estão em [ESTRUTURA.md](ESTRUTURA.md).

## 1. Pré-requisitos

Crie/configure manualmente na AWS:

- Bucket S3 `terraform-state-soat16` em `us-east-1`, com versionamento, criptografia, bloqueio público e acesso de leitura/escrita.
- Usuário IAM `terraform`, usado para executar Terraform, Helm e `kubectl`. É **o mesmo usuário do CI**: a foundation cria uma access entry de administrador para quem executa o Terraform (`aws_caller_identity`). Com outro usuário, essa access entry é substituída e o usuário anterior (o do CI) perde o acesso ao cluster.
- Usuário IAM `cluster_admin`, acesso alternativo ao EKS. É **obrigatório**: a foundation consulta esse usuário (`data "aws_iam_user"`), e o `plan` falha se ele não existir.
- AWS CLI configurada com o profile do usuário `terraform` (se não for o profile padrão, use `$env:AWS_PROFILE = "<profile>"`).
- Terraform `>= 1.10.0` (o CI usa 1.15.8) e `kubectl`.
- Conta Datadog (trial) com API Key e Application Key, se o Datadog estiver ligado, que é o padrão. Veja [DATADOG.md](DATADOG.md#2-configuração).

O Terraform não cria esses usuários, o bucket nem a conta do Datadog.

**O ambiente da fase 2 precisa estar destruído.** Este repositório usa os mesmos nomes (VPC com tag `Project=techchallenge-oficina`, EKS `techchallenge-oficina-eks`, IAM roles `techchallenge-oficina-cluster-role`/`-node-role`), mas states diferentes (`k8s-*.tfstate`). Se a fase 2 ainda existir, o apply falha com nomes duplicados, e o repositório DB passa a encontrar duas VPCs.

## 2. Crie os arquivos de variáveis

É necessário criar um `terraform.tfvars` em cada pasta Terraform. A partir da pasta `infra/`, execute:

```powershell
Copy-Item foundation/terraform.tfvars.example foundation/terraform.tfvars
Copy-Item addons/terraform.tfvars.example addons/terraform.tfvars
```

Os exemplos já trazem os valores padrão do projeto (região, nomes, `t3.small` com 2/2/2 nodes e as opções do Datadog) e não têm segredos. Não versione esses arquivos. Eles já estão ignorados pelo `.gitignore`. As chaves do Datadog não ficam no `terraform.tfvars`: passe-as por variáveis de ambiente (seção 4).

## 3. Crie a foundation

A partir da pasta `infra/`:

```powershell
Push-Location foundation
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
Pop-Location
```

Revise o `plan` antes de confirmar o `apply`.

Ao final, o output `api_gateway_endpoint` mostra a URL pública das APIs (`https://<id>.execute-api.us-east-1.amazonaws.com`). Para consultá-la depois, rode `terraform output -raw api_gateway_endpoint` em `foundation/`. As rotas estão em [k8s/README.md](../k8s/README.md#8-acesso-externo-api-gateway).

A foundation também cria o que o repositório DB usa: a tag `Project = techchallenge-oficina` na VPC, as subnets privadas `techchallenge-oficina-private-1` e `-2` e o SG `techchallenge-oficina-nodes-sg`. Não renomeie esses itens (contrato em [README.md](../README.md)).

## 4. Instale os addons

Depois que os nodes do EKS estiverem `Ready`, prepare o Datadog com os mesmos valores do GitHub, porque o state é o mesmo do CI (chaves de outra org ou outro site fariam o apply recriar os recursos lá):
- No `addons/terraform.tfvars`, `datadog_enabled`, `datadog_site` e `datadog_synthetics_status` precisam ser iguais às variables `DD_ENABLED`, `DD_SITE` e `DD_SYNTHETICS_STATUS`. Os valores do `terraform.tfvars` têm precedência sobre as `TF_VAR_*`.
- As chaves não ficam no arquivo: defina-as na mesma sessão do PowerShell, com os valores dos secrets. Com `datadog_enabled = false`, elas só são necessárias enquanto o state tiver recursos do Datadog: o apply que desliga o Datadog apaga esses recursos e, para isso, precisa das chaves e do site da conta.

```powershell
$env:TF_VAR_datadog_api_key = "<API Key>"
$env:TF_VAR_datadog_app_key = "<Application Key>"
# Opcional, como o secret DD_ALERT_RECIPIENTS:
$env:TF_VAR_datadog_alert_recipients = "@seu-email@dominio.com"
```

Depois, execute a partir de `infra/`:

```powershell
Push-Location addons
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
Pop-Location
```

Isso instala o Metrics Server (chart 3.12.2) e o Datadog Agent (chart 3.255.0) e cria os recursos do Datadog. O output `datadog_dashboard_url` mostra a URL do dashboard. Os addons encontram o cluster pelo nome, sem ler o state da foundation, então o `plan` só funciona com o cluster já criado. Os synthetics do Datadog também leem a URL do API Gateway da foundation. O mesmo usuário/profile `terraform` é usado nos dois estados.

## 5. Configure o kubectl

```powershell
aws eks update-kubeconfig --region us-east-1 --name techchallenge-oficina-eks
kubectl get nodes
kubectl get pods -A
```

## 6. Aplique os manifests

Os manifests das APIs ficam em [k8s/](../k8s), e o passo a passo está em [k8s/README.md](../k8s/README.md). Antes de aplicá-los, é preciso ter o RDS criado pelo repositório [DB](https://github.com/GuiToniello/tech-challenge-fase-3-DB-soat16-rm374658) e as imagens publicadas no ECR pelo repositório [APP](https://github.com/GuiToniello/tech-challenge-fase-3-APP-soat16-rm374658).

O caminho recomendado é o workflow **K8s Apply**, que descobre o endpoint do RDS, gera o `k8s/.env` a partir dos secrets do GitHub e roda `kubectl apply -k k8s`. Aplique sempre com `-k` (e não `-f` por pasta), porque o Secret `oficina-api-secrets` é gerado pelo Kustomize a partir do `k8s/.env`.

Valide:

```powershell
kubectl get pods,svc,hpa -n oficina
kubectl top pods -n oficina
```

## 7. Valide sem acessar a AWS

Em `infra/foundation` e em `infra/addons`:

```powershell
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
```

É o mesmo que os checks obrigatórios dos Pull Requests fazem, e não precisa das chaves do Datadog. Os `.terraform.lock.hcl` **são** versionados e fixam as versões dos providers (aws 6.66.0 e, nos addons, helm 2.17.0 e DataDog/datadog 4.25.0).

Ao adicionar um provider (como o `DataDog/datadog`, no addons), regenere o lock com os hashes de Linux (CI) e de Windows. Para atualizar as versões dos providers já existentes, acrescente `-upgrade` ao `init`:

```powershell
terraform init -backend=false
terraform providers lock -platform=linux_amd64 -platform=windows_amd64
```

## 8. Destrua o ambiente

Antes, destrua o LAMBDA e o repositório DB. O APP não tem recursos a destruir, porque o ECR é manual. O RDS usa as subnets privadas e referencia o SG dos nodes: com ele de pé, o destroy da foundation falha com `DependencyViolation`.

Depois, para evitar custos:
1. Destrua os addons. Isso remove o Datadog Agent e os recursos do Datadog, então defina antes as chaves do Datadog, como na seção 4.
2. Destrua a foundation, que leva junto o API Gateway, o VPC Link e o NLB.

Os comandos rodam a partir de `infra/`:

```powershell
Push-Location addons
terraform destroy -var-file="terraform.tfvars"
Pop-Location

Push-Location foundation
terraform destroy -var-file="terraform.tfvars"
Pop-Location
```

No CI, o workflow **Destroy** faz o mesmo. Antes, ele confere se o RDS e o SG `techchallenge-oficina-rds-sg` (repo DB) já foram removidos. O destroy da foundation roda mesmo se o dos addons falhar (por exemplo, com chaves do Datadog revogadas), para o EKS não ficar ligado gerando custo; nesse caso, veja o troubleshooting do [DATADOG.md](DATADOG.md#8-troubleshooting). O bucket S3 do state e o ECR (usado pelo repositório APP) não são gerenciados por este Terraform e ficam fora do `destroy`.
