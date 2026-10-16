# k8s-gitops-platform

Manifests GitOps e bootstrap do cluster definido em codigo para uma plataforma
Kubernetes local que roda a todolist-app. O Argo CD reconcilia o Git no cluster;
o digest imutavel da imagem fica versionado aqui e o repo da app nao e segunda
fonte de verdade.

## O que a plataforma entrega

| Area | Como |
|---|---|
| Provisionamento | Cluster Talos em VMs libvirt pelo Terraform; Cilium, MetalLB, Traefik, Argo CD e secrets pela camada platform. O Terraform registra as Applications do Argo CD. |
| Deploy continuo | `git push` no repo da app -> CI (test + build GHCR) -> bump de digest no overlay -> Argo CD sincroniza. Sem passo manual. |
| Acesso externo | Ingress Traefik pelo IP LoadBalancer do MetalLB, por host local. |
| Escalabilidade e resiliencia | 2 replicas + HPA (2..5) + PDB + probes separadas (liveness `/livez`, readiness `/healthz`) + rolling update `maxUnavailable: 0` + requests/limits. |
| Documentacao | Este README, `DECISIONS.md` (escolhas e descartes) e `docs/` (logs e screenshots de execucoes). |

## Arquitetura

```
                 git push (staging|production)
  todolist-app ──────────────────────────────► GitHub Actions (test -> build GHCR)
   (codigo+CI)                                          │ bump de digest (kustomize)
                                                        ▼
  k8s-gitops-platform (GitOps)  ◄───────────────────────────┘
   k8s/base + overlays/ + clusters/
        │  Argo CD reconcilia
        ▼
   Talos em VMs libvirt ── Traefik (LoadBalancer do MetalLB)
        ├── todolist-staging      (auto-sync)
        ├── todolist-production   (sync manual = promocao)
        └── observability         (Prometheus/Grafana/Loki/Alloy)
```

## Ambientes e interfaces

| Env | Namespace | Cor | URL | Sync Argo |
|---|---|---|---|---|
| staging | `todolist-staging` | green | http://staging.local | automatico |
| production | `todolist-production` | blue | http://prod.local | manual (promocao) |
| Argo CD UI | argocd | — | http://argocd.local | — |
| Grafana | observability | — | http://grafana.local | — |
| Hubble UI | kube-system | — | http://hubble.local | — |

Trocar a cor de um env = 1 linha (`APP_COLOR`) no `configMapGenerator` do
overlay + push: o hash do ConfigMap muda, o kustomize reescreve o `envFrom` do
Deployment e o rollout acontece sozinho (sem restart manual).
Login app: `admin` + senha gerada no Terraform state. Login Grafana: `admin` + senha gerada no Terraform state.

Acesso **sem porta** (`http://<host>` e `https://<host>`): o LB publica 80 e 443.
O TLS é terminado no Ingress com o certificado self-signed padrão do Traefik
(browser avisa). Em produção o caminho é cert-manager + ACME/CA interna — ver
`DECISIONS.md`.

## Observabilidade (bonus)

Stack entregue via Argo CD (Helm charts pinados), tudo em `observability`:

- **Metricas de cluster/recursos**: kube-prometheus-stack 90.0.0
  (Prometheus + Grafana + node-exporter + kube-state-metrics, dashboards
  prontos de Kubernetes/Compute Resources). Alertmanager desligado (ver DECISIONS).
- **Logs**: Loki 7.3.0 (single-binary, PVC 1Gi, retencao 72h) + Grafana Alloy
  1.12.1 (DaemonSet coletando stdout de todos os pods). A app loga **JSON**
  (app + access log do gunicorn); o Alloy extrai `level`/`logger` como labels
  e `status/method/path/duration_us` como structured metadata.
  Dashboards `Logs — staging` e `Logs — production` (volume por nivel/logger,
  access log, erros, exploracao com variaveis). Alerta (Grafana-managed) para
  logs de erro acima de 0 em 5 min, com `for: 5m`.
- **Metricas da aplicacao**: `/metrics` na app (prometheus-flask-exporter,
  aditivo, multiprocess-safe p/ gunicorn) + ServiceMonitor por env.
- **Metricas do banco**: postgres-exporter como sidecar do Postgres +
  ServiceMonitor por env.
- **Dashboards**: `TodoList — Aplicacao e Recursos` (custom) e
  `PostgreSQL Database` (grafana.com #9628), auto-carregados pelo sidecar.

## O que esta onde

| Caminho | Papel |
|---|---|
| `clusters/local/k3d-config.yaml` | configuracao legada do k3d |
| `clusters/talos/argocd/` | projects, Applications e Ingress do Argo CD |
| `clusters/talos/observability/` | ServiceMonitors e dashboards |
| `k8s/base + k8s/overlays/staging|production/` | manifests da app (fonte unica: nao duplicar no repo da app) |
| `envs/*.env.example` | exemplos sem credenciais |
| `../todolist-app/.github/workflows/` | CI por branch (staging->overlay staging, production->production) |
| `terraform/platform/` | plataforma, namespaces e secrets Kubernetes; workloads seguem no Argo CD |
| `loadtest/` | teste de carga k6 como Job (prova do HPA) |
| `docs/` | logs, dumps e prints de navegador |

## Fluxo de branches (GitLab Flow, no repo da app)

`staging` e a branch principal (default). `production` e protegida:
sem push direto (so via PR), so aceita PR de `staging` ou `hotfix/*`,
exige CI verde e historico linear (approval=0: repo de uma pessoa; ver DECISIONS).
Hotfix: branch `hotfix/*` da `production` -> PR em `production` (+ back-merge em `staging`).

Promocao: PR `staging -> production` -> merge -> CI bumpar o overlay production
-> clicar Sync no Argo (production e manual de proposito).

## Pré-requisitos (Linux x86_64)

O cluster usa VMs Talos em libvirt. Consulte `terraform/infra/README.md` para
os requisitos do host e o provisionamento. O agente não executa `sudo`.

### 1. Utilitários base

```bash
sudo apt update && sudo apt install -y \
  curl git openssh-client python3 openssl iproute2 ca-certificates
```

(`curl`, `git`, `openssl` e `ss` são usados pelo script; `python3` valida YAML.)

### Ferramentas

| Ferramenta | Versão | Instalação |
|---|---|---|
| `terraform` | >= 1.5 | https://developer.hashicorp.com/terraform/install |
| `kubectl` | compatível com a versão do cluster | https://kubernetes.io/docs/tasks/tools/ |
| `kustomize` | v5.7.1 | tarball do release no `~/.local/bin` |
| `gh` | opcional (monitorar CI/PRs) | https://cli.github.com/manual/installation |

Obrigatórios para o `bootstrap.sh`: `terraform` e `kubectl`. O modulo `terraform/infra` deve criar o cluster Talos e o kubeconfig antes da execucao.
(`kustomize` é usado pelo CI e pela validação local.)

### GitHub: repos, token e acesso

1. **Repos** sob a mesma conta: `todolist-app` (codigo + CI) e
   `k8s-gitops-platform` (manifests + Argo CD). Se o seu usuario for diferente
   de `heitorfreitasferreira`, ajuste `IMAGE` em
   `todolist-app/.github/workflows/ci.yaml` e o nome da imagem nos overlays
   (`k8s/overlays/*/kustomization.yaml`).
2. **Secret `GITOPS_BUMP_TOKEN`** no repo do app: um *fine-grained PAT* com
   **Contents: read+write** no repo `k8s-gitops-platform`. É com ele que o job de
   bump commita o digest da imagem aqui. Se expirar, a CI falha fechado.
3. **Acesso ao GitHub** para o Argo CD clonar este repositorio.
4. **GHCR público**: as imagens precisam ser públicas, pois o kubelet puxa
   **sem credencial** (não há `imagePullSecret` em nenhum manifest). Após o
   primeiro build, verifique a visibilidade do pacote em
   `ghcr.io/<user>/todolist-app`.

### Acesso local

- Recursos: o stack sobe cerca de 25 pods. Reserve **4 vCPU / 6–8 GiB** para as VMs.
- `KUBECONFIG` isolado: `export KUBECONFIG=~/.kube/talos-kubeconfig`
  (nunca toque em `~/.kube/config`).
- Hosts locais: adicione os hosts abaixo a `/etc/hosts`, usando o IP atual do
  Service LoadBalancer do Traefik. Consulte-o com `kubectl -n traefik get svc`.

```text
<TRAEFIK_IP> staging.local prod.local argocd.local grafana.local hubble.local
```

## Reproducao (do zero)

Execute o bootstrap depois de criar o cluster Talos e exportar o kubeconfig:

```bash
export KUBECONFIG=~/.kube/talos-kubeconfig
./bootstrap.sh                 # aplica Terraform platform e registra as Applications
```

`bootstrap.sh` executa `terraform/platform`, que cria os Secrets, os projetos e
as Applications. O Argo CD instala os workloads, observabilidade e Hubble UI.

Novo deploy: `git push` em `staging`/`production` no repo `todolist-app`
dispara a CI (test -> build -> GHCR -> bump de digest no overlay certo -> Argo sync).

## Problemas encontrados no caminho

Registrados em detalhe no `DECISIONS.md`; os principais:

- `kustomize edit set image` reescrevia o overlay inteiro (comentarios perdidos,
  `newName` espurio) -> bump cirurgico por regex ancorado em `newTag`/`digest`.
- RBAC: `resourceNames` nao vale para `list` -> `/cleanup/status` tomava 403.
  Split: `list` sem restricao + `get/patch` travados por nome.
- Argo esconde da arvore recursos fora da allowlist do AppProject
  (`Pod/ReplicaSet/Job` entraram como view-only).
- Regra de alerta `threshold` auto-referente ("cannot reference itself") ->
  `reduce(last)` + `math $B > 0`.
- Grafana `OOMKilled` por limite chutado -> dimensionado apos medir uso real.

## Limitacoes conhecidas (o que eu faria em producao)

- Postgres de 1 replica (sem HA) e sem backup automatico; sem TLS no Ingress.
- Retencao de logs 72h e alerta sem notificacao (cluster local descartavel).
- Segredos selados sao *cluster-bound*: a chave precisa de backup externo.
- Em producao: Postgres gerenciado/HA + PITR, External Secrets, TLS, multi-cluster
  com ApplicationSet, NetworkPolicies e alertas com roteamento real.

Detalhes de operacao, secrets e observabilidade: `DECISIONS.md`
(+ `/k-secrets` no opencode).
