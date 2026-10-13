# Terraform: provisionamento do cluster

Camada de infraestrutura do `k8s-gitops-platform`. O Terraform cria e destroi o
cluster k3d a partir de `clusters/local/k3d-config.yaml`. A entrega dos workloads
continua no Argo CD, que e a fonte de verdade dos manifests.

## Onde ele para

O Terraform cuida so do cluster. Ele nao aplica a app nem a stack de
observabilidade, porque esses manifests vivem no Git e o Argo CD os reconcilia.
Duplicar os mesmos manifests aqui criaria uma segunda fonte de verdade e a
pergunta "qual venceu?".

O `bootstrap.sh` continua sendo a entrada unica para subir tudo: ele instala o
Argo CD, resolve os secrets e espera as Applications ficarem Synced/Healthy.

## Uso

```bash
cd k8s-gitops-platform/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Depois do apply:

```bash
export KUBECONFIG=~/.kube/local-k3d.kubeconfig
cd .. && ./bootstrap.sh
```

Teardown do cluster pelo Terraform:

```bash
terraform destroy
```

## Decisoes

- O cluster e gerado pelo binario `k3d` via `local-exec`, com um guard de
  idempotencia (cria so se o cluster nao existe). Nao existe provider oficial
  do k3d, e reaproveitar o `k3d-config.yaml` mantem uma fonte unica da topologia.
- `filesha256` do k3d-config entra nos triggers do recurso. Mudar portas, nodes
  ou a imagem do k3s recria o cluster, em vez de deixar um ambiente divergente.
- Estado local por padrao. O bloco de backend remoto (S3 + DynamoDB) esta
  comentado em `versions.tf` para quando houver mais de um operador.
