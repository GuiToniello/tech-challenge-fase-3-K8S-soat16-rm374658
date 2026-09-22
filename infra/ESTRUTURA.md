# Infraestrutura AWS com Terraform

## Objetivo

Provisionar a rede e o Amazon EKS onde rodam as cinco APIs e expô-las por HTTP usando o hostname DNS público gerado pela AWS para o Load Balancer do `ingress-nginx`.

O Terraform gerencia a infraestrutura AWS (state `foundation`) e, num state separado (`addons`), instala `ingress-nginx` e Metrics Server via Helm. Os manifests das APIs ([k8s/](../k8s/kustomization.yaml)) são aplicados pelo GitHub Actions com `kubectl apply -k k8s` (seção [Aplicação dos manifests](#aplicação-dos-manifests)).

O banco de dados (RDS PostgreSQL) não é criado aqui: ele fica no [repositório DB](https://github.com/GuiToniello/tech-challenge-fase-3-DB-soat16-rm374658). O build das imagens e o push para o ECR ficam no [repositório APP](https://github.com/GuiToniello/tech-challenge-fase-3-APP-soat16-rm374658).

## Decisões consolidadas

- Região: `us-east-1`.
- Bucket de state externo: `terraform-state-soat16`, com lock nativo (`use_lockfile`).
- States:
  - `techchallenge-oficina/k8s-foundation.tfstate`.
  - `techchallenge-oficina/k8s-addons.tfstate`.
- Os arquivos `.terraform.lock.hcl` são versionados: provider AWS `6.66.0` nas duas pastas e Helm `2.17.0` no addons.
- Sem Route 53, domínio próprio, certificado ou HTTPS nesta etapa.
- O Ingress das APIs não possui campo `host`.
- Os repositórios ECR e as imagens pertencem ao repo APP. Aqui, os nodes só leem do ECR pela role IAM com `AmazonEC2ContainerRegistryReadOnly`; não existe Secret Kubernetes para pull.
- `apply` e `destroy` rodam pelo GitHub Actions e só a partir da `main` (detalhes em [.github/workflows/README.md](../.github/workflows/README.md)).
- O ambiente é acadêmico e descartável; todos os recursos podem ser destruídos ao final.

## Pré-requisitos manuais

Antes do primeiro Bootstrap, devem existir:

1. Bucket S3 `terraform-state-soat16`, em `us-east-1`, com versionamento, criptografia, bloqueio público e leitura/escrita nas keys `techchallenge-oficina/k8s-*.tfstate*` para o usuário `terraform`.
2. Usuário IAM `terraform`, cujas access keys vão para os secrets do GitHub. Precisa de permissões para criar a foundation (VPC, IAM, EKS), consultar o usuário `cluster_admin`, criar Access Entries no EKS e, no K8s Apply e no Destroy, executar `eks:DescribeCluster` e `rds:DescribeDBInstances`.
3. Usuário IAM `cluster_admin`. **Obrigatório**: a foundation o consulta por data source, e o `plan` falha se ele não existir.
4. Secrets, Variables e o Environment `destroy` no GitHub, descritos em [.github/workflows/README.md](../.github/workflows/README.md).

O Terraform não cria esses usuários nem o bucket. Access keys, secrets, `terraform.tfvars` real e `k8s/.env` nunca devem ser versionados.

## Arquitetura

```text
Internet
   |
   | HTTP :80
   v
Load Balancer público do Service ingress-nginx
   |
   v
Ingress Controller no EKS (Ingress oficina-apis, namespace oficina)
   |
   +--> /monolith  --> monolith-api:80 --> container:8080
   +--> /approval  --> approval-api:80 --> container:8080
   +--> /createos  --> createos-api:80 --> container:8080
   +--> /getos     --> getos-api:80    --> container:8080
   +--> /status    --> status-api:80   --> container:8080

VPC 10.0.0.0/16 (tag Project = techchallenge-oficina)
  Subnets públicas techchallenge-oficina-public-{1,2}   (10.0.0.0/20, 10.0.16.0/20)
    -> EKS, nodes e Load Balancer; rota 0.0.0.0/0 pelo Internet Gateway
  Subnets privadas techchallenge-oficina-private-{1,2}  (10.0.128.0/20, 10.0.144.0/20)
    -> reservadas para o RDS do repo DB; sem NAT e sem rota para a Internet
```

Não há NAT Gateway. Os nodes usam saída pelas subnets públicas para acessar ECR e demais serviços AWS.

### Security Groups

| Security Group | Regras |
|---|---|
| `techchallenge-oficina-cluster-sg` | SG adicional do control plane; sem entrada, saída liberada |
| `techchallenge-oficina-nodes-sg` | Entrada total entre os próprios nodes e a partir do SG do cluster; saída liberada |

O launch template anexa aos nodes o SG do cluster, o `techchallenge-oficina-nodes-sg` e o SG gerenciado pelo EKS. O SG do banco não é criado aqui. O repo DB cria o próprio SG (`techchallenge-oficina-rds-sg`), com entrada `5432` a partir do `techchallenge-oficina-nodes-sg`, e o repo LAMBDA adiciona a própria regra nesse SG.

As regras garantem:

- Nenhuma entrada pública nas portas `8080` ou dos Services.
- Nenhum SSH aberto para a Internet.
- Nenhum NodePort configurado manualmente pelo Terraform.
- O Service `LoadBalancer` e a integração Kubernetes/AWS gerenciam NodePorts e regras do Load Balancer.

## Foundation

Localização: `infra/foundation/`

Responsabilidades:

- VPC `10.0.0.0/16` com DNS habilitado.
- Duas subnets públicas para EKS, nodes e Load Balancer, com a tag `kubernetes.io/role/elb`.
- Duas subnets privadas, em duas AZs, para o DB subnet group do RDS do repo DB. A route table privada não tem rotas além da local.
- Internet Gateway e rotas públicas.
- Security Groups do cluster e dos nodes.
- IAM roles do EKS e dos nodes, com `AmazonEC2ContainerRegistryReadOnly` na role dos nodes.
- EKS `techchallenge-oficina-eks`, versão `1.32`, `authentication_mode = "API"`, endpoint público e privado.
- Managed node group:
  - Instância `t3.small`, elegível ao Free Tier nesta conta.
  - `min_size = 2`.
  - `desired_size = 2`.
  - `max_size = 2`.
  - Disco EBS `gp3` de `30 GiB`, criptografado, e IMDSv2 obrigatório no launch template.
- Access Entry com `AmazonEKSClusterAdminPolicy` para o usuário `cluster_admin` (obrigatório).
- Access Entry com `AmazonEKSClusterAdminPolicy` para quem executa o Terraform (`aws_caller_identity`).

O usuário `terraform` é o acesso principal: executa foundation, addons e `kubectl`, no CI e localmente. Rode sempre com esse mesmo usuário. Com outra identidade, a Access Entry do executor anterior é substituída, e o CI pode perder o acesso ao cluster.

Outputs: `cluster_name`, `cluster_endpoint` e `cluster_region`.

## Addons

Localização: `infra/addons/`

Responsabilidades:

- Usar as mesmas credenciais do usuário `terraform`.
- Consultar o cluster pelo nome, sem ler o state remoto da foundation. Por isso, o `plan` do addons exige o cluster EKS de pé.
- Instalar `ingress-nginx` (chart `4.12.1`) via Helm com os valores padrão.
- Instalar Metrics Server (chart `3.12.2`) via Helm, usado pelos HPAs.

O hostname do Load Balancer é consultado com:

```powershell
kubectl get svc ingress-nginx-controller -n ingress-nginx
kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

## Contrato com o repo DB

O [repo DB](https://github.com/GuiToniello/tech-challenge-fase-3-DB-soat16-rm374658) encontra a rede por tag e nome, sem ler o state deste repositório. Estes nomes **não podem mudar**:

| O que | Valor |
|---|---|
| VPC | Tag `Project = techchallenge-oficina`, aplicada pelo `default_tags` do provider. Deve existir **exatamente uma** VPC com essa tag |
| Subnets privadas | `Name = techchallenge-oficina-private-1` e `techchallenge-oficina-private-2`, em AZs diferentes |
| SG dos nodes | `techchallenge-oficina-nodes-sg`, anexado aos nodes pelo launch template |

Alterar `project_name` ou o nome/descrição do SG dos nodes recria esses recursos e quebra o repo DB. No sentido inverso, este repositório consome do DB:
- o identifier do RDS `techchallenge-oficina-postgres`, usado pelo K8s Apply para descobrir o endpoint e pelo Destroy para conferir que o RDS já foi removido;
- o nome do SG `techchallenge-oficina-rds-sg`, que o Destroy também confere antes de começar.

## Aplicação dos manifests

Os manifests são aplicados com Kustomize ([k8s/kustomization.yaml](../k8s/kustomization.yaml)), nunca com `kubectl apply -f` por pasta: o Secret `oficina-api-secrets` é gerado pelo `secretGenerator` a partir de `k8s/.env`, que não é versionado. O modelo é [k8s/.env.example](../k8s/.env.example).

Ordem entre repositórios no deploy:

1. **K8S**: Bootstrap (foundation → addons).
2. **DB**: Bootstrap (RDS).
3. **APP**: imagens no ECR.
4. **K8S**: [K8s Apply](../.github/workflows/k8s-apply.yml), disparado automaticamente pelo repo APP depois do push das imagens.

O K8s Apply (disparado pelo repo APP ou manual, `restart-pods` com padrão `true`) descobre o endpoint do RDS, monta o `k8s/.env` com a connection string e o `ResendSettings__ApiKey` a partir dos secrets do GitHub, roda `kubectl apply -k k8s` e, se pedido, faz o `rollout restart` das cinco APIs. O restart é necessário quando o Secret muda (`disableNameSuffixHash` mantém o mesmo nome) ou quando há imagem nova, já que os Deployments usam a tag `latest` com `imagePullPolicy: Always`. O Deploy também aplica os manifests, com restart, em push na `main` que altere `k8s/**`.

O arquivo [k8s/infra/ingress.yml](../k8s/infra/ingress.yml) contém somente o recurso `Ingress` das APIs.

## Validação

Sem acessar a AWS, em `infra/foundation/` e em `infra/addons/`:

```powershell
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
```

Manifests, a partir da raiz do repositório (o `.env` gerado só tem placeholders e não deve ser aplicado):

```powershell
Copy-Item k8s\.env.example k8s\.env
kubectl kustomize k8s
```

São as mesmas verificações obrigatórias dos PRs (`validate-foundation`, `validate-addons` e `validate-k8s`). O `plan` com AWS roda no PR como informativo. O `apply` não é manual: roda pelo Bootstrap ou pelo push na `main`, primeiro na foundation e depois nos addons.

O CI não usa `terraform.tfvars` e aplica os defaults de `variables.tf`. Se criar um localmente a partir do `terraform.tfvars.example`, mantenha os mesmos valores, pois o state é o mesmo do CI. Para atualizar os providers, rode `terraform init -upgrade` e depois `terraform providers lock -platform=linux_amd64 -platform=windows_amd64`.

## Destruição e custos

EKS (control plane cobrado por hora), os dois nodes com seus discos EBS e o Load Balancer do `ingress-nginx` geram custos enquanto existem.

Ordem entre repositórios: **LAMBDA** → **DB** → **K8S**. O APP não tem recursos a destruir, porque o ECR é manual. O RDS usa as subnets privadas e o SG dele referencia o SG dos nodes; se ainda existir, o destroy da VPC falha com `DependencyViolation`.

Neste repositório, rode o workflow [Destroy](../.github/workflows/destroy.yml) com `confirm = destroy` e aprove no Environment `destroy`. A sequência é:
1. `db-check`: falha se o RDS `techchallenge-oficina-postgres` ou o SG `techchallenge-oficina-rds-sg` ainda existirem.
2. `gate`: aprovação manual.
3. `delete-load-balancer`: remove o Service `ingress-nginx-controller` e espera o finalizer. O ELB é criado pelo Kubernetes, e não pelo Terraform. Esperar que ele saia antes do cluster evita ELB órfão e VPC travada.
4. Addons.
5. Foundation. O bucket S3 do state e o ECR do repo APP ficam fora do `destroy`.
