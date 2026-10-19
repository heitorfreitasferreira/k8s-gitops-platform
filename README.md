# k8s-gitops-platform

Manifests GitOps e bootstrap do cluster definido em codigo para uma plataforma
Kubernetes local que roda a todolist-app. O Argo CD reconcilia o Git no cluster;
o digest imutavel da imagem fica versionado aqui e o repo da app nao e segunda
fonte de verdade.

## O que a plataforma entrega

| Area | Como |
|---|---|
| Provisionamento | Cluster Talos em VMs libvirt pelo Terraform; Cilium, MetalLB, Traefik, Argo CD e secrets pela camada platform. O Terraform registra o ApplicationSet do Argo CD. |
| Deploy continuo | `git push` no repo da app -> CI (test + build GHCR) -> bump de digest no overlay -> Argo CD sincroniza. Sem passo manual. |
| Acesso externo | Ingress Traefik pelo IP LoadBalancer do MetalLB, por host local. |
| Escalabilidade e resiliencia | 2 replicas + HPA (2..5) + PDB + probes separadas (liveness `/livez`, readiness `/healthz`) + rolling update `maxUnavailable: 0` + requests/limits. Prova do 2 -> 5 sob carga em `docs/loadtest-hpa.txt`. |
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
        └── observability         (Prometheus/Grafana/Loki/Alloy/Tempo/OTel/ntfy)
```

## Ambientes e interfaces

| Env | Namespace | Cor | URL | Sync Argo |
|---|---|---|---|---|
| staging | `todolist-staging` | green | http://staging.local | automatico |
| production | `todolist-production` | blue | http://prod.local | manual (promocao) |
| Argo CD UI | argocd | — | http://argocd.local | — |
| Grafana | observability | — | http://grafana.local | — |
| ntfy | observability | — | http://ntfy.local | — |
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
- **Tracing distribuido**: Tempo 2.9.0 (single-binary, PVC `local-path`,
  retencao 72h) + OTel Collector (contrib 0.162.0, receiver OTLP gRPC/HTTP,
  exporter OTLP para o Tempo), ambos via Argo. A app roda com
  `opentelemetry-instrument` e exporta spans de HTTP (Flask) e do banco
  (SQLAlchemy). O Grafana tem o datasource do Tempo e correlacao nos dois
  sentidos: o log JSON carrega `trace_id` (link para o trace) e o trace
  aponta de volta para o Loki e para o Prometheus.
- **Alertas**: Alertmanager (ligado no kube-prometheus-stack) com uma rota
  unica para o ntfy self-hosted (chart `helmforge/ntfy` 1.2.3, topico privado
  com auth por token). O token vive num Secret montado no pod do Alertmanager.
  O `PrometheusRule` cobre a disponibilidade da app e traz um alerta de teste
  sempre ativo para provar o caminho Prometheus -> Alertmanager -> ntfy. A
  notificacao aparece em `http://ntfy.local` (app ntfy no celular ou na web).
- **Pecas de plataforma**: Cilium/Hubble, Traefik, Argo CD e MetalLB com
  metricas e ServiceMonitors ligados nos Helm values do `terraform/platform`,
  dashboards proprios e alertas (drops do Cilium, 5xx do Traefik, app fora de
  sync ou degradada no Argo CD, IP do MetalLB nao anunciado).
- **SLO**: SLI de disponibilidade da app (SLO de 99%), recording rules do error
  ratio em 5m/30m/1h/6h, alertas multi-janela de burn-rate e dashboard de error
  budget.
- **MinIO/S3 (VM fora do cluster)**: `node_exporter` e metricas do MinIO
  publicas, instalados pelo cloud-init da VM. O Prometheus raspa os dois
  endpoints por `additionalScrapeConfigs`, com o IP vindo do modulo `infra`
  (nao fica no Git). Dashboard `MinIO / S3` (uso por bucket, requisicoes,
  erros, capacidade) e alertas `MinIODown`, `MinIOStorageHigh` e
  `MinIOErrors`. A VM do MinIO entra tambem no dashboard `VMs / Hosts` e nos
  alertas de node.
- **etcd do Talos**: exposto em `:2381` por um patch do machine config do
  control plane e raspado pelo Prometheus (`kube-etcd`). Alertas de quorum
  (`EtcdNoLeader`) e de scrape indisponivel (`EtcdMetricsDown`).

## O que esta onde

| Caminho | Papel |
|---|---|
| `clusters/talos/argocd/` | projects, ApplicationSet e Ingress do Argo CD |
| `clusters/talos/observability/` | ServiceMonitors e dashboards |
| `k8s/base + k8s/overlays/staging|production/` | manifests da app (fonte unica: nao duplicar no repo da app) |
| `envs/*.env.example` | exemplos sem credenciais |
| `../todolist-app/.github/workflows/` | CI por branch (staging->overlay staging, production->production) |
| `terraform/infra/` | VMs Talos em libvirt + MinIO S3 externo (state local) |
| `terraform/platform/` | plataforma, namespaces e secrets Kubernetes; workloads seguem no Argo CD |
| `loadtest/` | teste de carga k6 como Job (prova do HPA), com o `securityContext` restricted e as NetworkPolicies do loadtest |
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

(`curl`, `git`, `openssl` e `ss` sao usados pelo `setup-host.sh`; `python3` valida YAML.)

### Ferramentas

| Ferramenta | Versão | Instalação |
|---|---|---|
| `terraform` | >= 1.5 | https://developer.hashicorp.com/terraform/install |
| `kubectl` | compatível com a versão do cluster | https://kubernetes.io/docs/tasks/tools/ |
| `kustomize` | v5.7.1 | tarball do release no `~/.local/bin` |
| `gh` | opcional (monitorar CI/PRs) | https://cli.github.com/manual/installation |

O `make up` exige `terraform` e `kubectl`. O `setup-host.sh` detecta a rede libvirt e gera o `terraform.tfvars` do `infra` antes do primeiro apply.
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
<TRAEFIK_IP> staging.local prod.local argocd.local grafana.local ntfy.local hubble.local
```

- Resolução de `.local`: o sufixo pertence ao mDNS. Se o sistema consulta o mDNS antes de `/etc/hosts`, os nomes acima nao resolvem mesmo com a linha presente. Confira com `getent hosts staging.local`. Se sair vazio, veja a ordem das fontes com `grep '^hosts:' /etc/nsswitch.conf` e coloque `files` em primeiro lugar:

```bash
sudo sed -i 's/^hosts:.*/hosts: files mymachines mdns_minimal [NOTFOUND=return] resolve myhostname dns/' /etc/nsswitch.conf
```

## Reproducao (do zero)

```bash
cd terraform/infra
./setup-host.sh        # detecta libvirt e gera terraform.tfvars (600, gitignored)
cd ../..
make up                # infra apply -> kubeconfig -> platform apply
```

`make up` aplica `terraform/infra` (VMs Talos + MinIO), grava o kubeconfig em
`~/.kube/talos-kubeconfig` e aplica `terraform/platform` (Cilium, MetalLB,
Traefik, Argo CD, secrets, Applications). O Argo CD instala os workloads,
observabilidade e Hubble UI. Desmonta com `make down` (ordem inversa).

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
- Secrets gerados pelo Terraform ficam em claro no state local. Em uso real, o
  state precisa de backend cifrado, controle de acesso e locking.
- Em producao: Postgres gerenciado/HA + PITR, External Secrets, TLS, multi-cluster
  com ApplicationSet, NetworkPolicies e alertas com roteamento real.

Detalhes de operacao, secrets e observabilidade: `DECISIONS.md`
(+ `/k-secrets` no opencode).
