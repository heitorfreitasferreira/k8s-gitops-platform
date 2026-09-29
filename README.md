# k8s-gitops-platform

Manifests GitOps e bootstrap do cluster definido em codigo para uma plataforma
Kubernetes local que roda a todolist-app. O Argo CD reconcilia o Git no cluster;
o digest imutavel da imagem fica versionado aqui e o repo da app nao e segunda
fonte de verdade.

## O que a plataforma entrega

| Area | Como |
|---|---|
| Provisionamento | Cluster k3d definido em codigo (`clusters/local/k3d-config.yaml`); Argo CD, controller de secrets e apps aplicados por `bootstrap.sh` (um comando, repetivel, sem console). Observabilidade via Helm charts pinados. |
| Deploy continuo | `git push` no repo da app -> CI (test + build GHCR) -> bump de digest no overlay -> Argo CD sincroniza. Sem passo manual. |
| Acesso externo | Ingress (Traefik) no LB `127.0.0.1:80/443`, por host: staging/production/argocd/grafana. |
| Escalabilidade e resiliencia | 2 replicas + HPA (2..5) + PDB + probes separadas (liveness `/livez`, readiness `/healthz`) + rolling update `maxUnavailable: 0` + requests/limits. |
| Documentacao | Este README, `DECISIONS.md` (escolhas e descartes) e `evidencias/` (logs e screenshots de execucoes). |

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
   k3d cluster "local" ── Traefik (127.0.0.1:80/443)
        ├── todolist-staging      (auto-sync)
        ├── todolist-production   (sync manual = promocao)
        └── observability         (Prometheus/Grafana/Loki/Alloy)
```

## Ambientes e interfaces

| Env | Namespace | Cor | URL | Sync Argo |
|---|---|---|---|---|
| staging | `todolist-staging` | green | http://staging.localhost (https tb) | automatico |
| production | `todolist-production` | blue | http://prod.localhost (https tb) | manual (promocao) |
| Argo CD UI (bonus) | argocd | — | http://argocd.localhost | — |
| Grafana | observability | — | http://grafana.localhost | — |

Trocar a cor de um env = 1 linha (`APP_COLOR`) no `configMapGenerator` do
overlay + push: o hash do ConfigMap muda, o kustomize reescreve o `envFrom` do
Deployment e o rollout acontece sozinho (sem restart manual).
Login app: `admin` + senha do SealedSecret (ver `/k-secrets` no opencode).
Login Grafana: `admin` + senha em `envs/grafana-observability.env` (local, gitignored).

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
| `clusters/local/k3d-config.yaml` | cluster criado por codigo |
| `clusters/local/argocd/` | install + projects + applications do Argo CD |
| `clusters/local/argocd/argocd-ui-ingress.yaml` | UI do Argo no Ingress |
| `clusters/local/sealed-secrets/` | controller Sealed Secrets (vendorizado, digest pinado) + cert publico |
| `clusters/local/observability/` | ServiceMonitors, dashboards e secret do Grafana |
| `k8s/base + k8s/overlays/staging|production/` | manifests da app (fonte unica: nao duplicar no fork) |
| `envs/*.env.example` | modelo tangivel dos secrets (o `.env` preenchido nunca e commitado) |
| `../todolist-app/.github/workflows/` | CI por branch (staging->overlay staging, production->production) |
| `evidencias/` | logs, dumps e prints de navegador |

## Fluxo de branches (GitLab Flow, no repo da app)

`staging` e a branch principal (default). `production` e protegida:
sem push direto (so via PR), so aceita PR de `staging` ou `hotfix/*`,
exige CI verde e historico linear (approval=0: repo de uma pessoa; ver DECISIONS).
Hotfix: branch `hotfix/*` da `production` -> PR em `production` (+ back-merge em `staging`).

Promocao: PR `staging -> production` -> merge -> CI bumpar o overlay production
-> clicar Sync no Argo (production e manual de proposito).

## Pré-requisitos (Linux x86_64 recém-instalado)

Tudo que `bootstrap.sh` e o fluxo precisam, do zero até o cluster no ar. O agente
**nunca roda `sudo` sozinho** — os passos com `sudo` você executa no terminal.

### 1. Utilitários base

```bash
sudo apt update && sudo apt install -y \
  curl git openssh-client python3 openssl iproute2 ca-certificates
```

(`curl`, `git`, `openssl` e `ss` são usados pelo script; `python3` valida YAML.)

### 2. Docker

Pela doc oficial (https://docs.docker.com/engine/install/), depois libere o acesso:

```bash
sudo usermod -aG docker "$USER"
# relogue (ou reboot) e confira:
docker info
```

Gate: `docker info` verde antes de continuar.

### 3. CLIs (versões testadas aqui)

| Ferramenta | Versão | Instalação |
|---|---|---|
| `k3d` | v5.9.0 (cria k3s v1.35) | `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash` |
| `kubectl` | v1.37 (skew ±1 do k3s vale) | https://kubernetes.io/docs/tasks/tools/ |
| `kubeseal` | 0.39.1 (casa com o controller vendorizado) | tarball do release no `~/.local/bin` |
| `kustomize` | v5.7.1 | tarball do release no `~/.local/bin` |
| `gh` | opcional (monitorar CI/forks) | https://cli.github.com/manual/installation |

Obrigatórios para o `bootstrap.sh`: `k3d`, `kubectl` e `kubeseal`.
(`kustomize` é usado pelo CI e pela validação local.)

### 4. GitHub: fork, token e acesso

1. **Fork** `andreffcastro/todolist-app` para a sua conta. Se o seu usuário for
   diferente de `heitorfreitasferreira`, ajuste `IMAGE` em
   `todolist-app/.github/workflows/ci.yaml` e o nome da imagem nos overlays
   (`k8s/overlays/*/kustomization.yaml`).
2. **Secret `GITOPS_BUMP_TOKEN`** no repo do app: um *fine-grained PAT* com
   **Contents: read+write** no repo `k8s-gitops-platform`. É com ele que o job de
   bump commita o digest da imagem aqui. Se expirar, a CI falha fechado.
3. **SSH no GitHub** (`ssh -T git@github.com` ok) — o caminho `--reseal` do
   `bootstrap.sh` dá `push` neste repo.
4. **GHCR público**: as imagens precisam ser públicas, pois o kubelet puxa
   **sem credencial** (não há `imagePullSecret` em nenhum manifest). Após o
   primeiro build, verifique a visibilidade do pacote em
   `ghcr.io/<user>/todolist-app`.

### 5. Máquina e rede

- Recursos: o stack sobe ~25 pods — reserve **4 vCPU / 6–8 GiB** livres para o Docker.
- Portas livres em loopback: **6444** (API), **80 e 443** (LB):
  `ss -tlnp | grep -E ':(80|443|6444)\b'` deve sair vazio.
- `KUBECONFIG` isolado: `export KUBECONFIG=~/.kube/local-k3d.kubeconfig`
  (nunca toque em `~/.kube/config`).

## Reproducao (do zero)

Forma curta (recomendada) — um comando, repete do zero:

```bash
export KUBECONFIG=~/.kube/local-k3d.kubeconfig
./bootstrap.sh                 # cluster -> Argo -> secrets -> apps -> espera Synced/Healthy
# ./bootstrap.sh --reseal       # forca re-selar os secrets com o cert atual
# ./bootstrap.sh teardown       # derruba o cluster
```

O script resolve os secrets automaticamente: se existir `sealed-backup/key.yaml`
(backup local da chave do controller, **nunca versionado**) ele restaura a chave e
mantem os selos do Git; caso contrario, cria os `envs/*.env` sinteticos que faltarem
e **re-sela**, commitando o resultado (o Argo le do Git).

<details><summary>Passo a passo manual (equivalente)</summary>

```bash
k3d cluster create --config clusters/local/k3d-config.yaml
kubectl apply -f clusters/local/argocd/namespace.yaml
kubectl apply -n argocd -f clusters/local/argocd/install.yaml
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd patch deployment argocd-server --type=json \
  --patch-file clusters/local/argocd/argocd-server-insecure.patch.json
kubectl apply -f clusters/local/argocd/argocd-ui-ingress.yaml
kubectl apply -f clusters/local/argocd/project.yaml
kubectl apply -f clusters/local/argocd/project-observability.yaml
kubectl apply -f clusters/local/argocd/application-sealed.yaml
kubectl -n kube-system rollout status deployment/sealed-secrets-controller
# ... secrets (ver bootstrap.sh) ...
for app in staging production kube-prometheus-stack loki alloy observability; do
  kubectl apply -f clusters/local/argocd/application-$app.yaml
done
kubectl -n argocd get applications
```
</details>

Novo deploy: `git push` em `staging`/`production` no fork `todolist-app`
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
