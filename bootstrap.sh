#!/usr/bin/env bash
# ABOUTME: Bootstrap do cluster local: cluster + Argo + secrets + apps.
# ABOUTME: Repetivel e sem passos manuais no console. Uso: ./bootstrap.sh [--reseal]
#
# Fluxo:
#   1. cria o cluster k3d por codigo (k3d-config.yaml)
#   2. instala Argo CD, projetos e o controller do Sealed Secrets
#   3. resolve os secrets: restaura a chave do controller (se houver backup
#      local) OU re-sela a partir dos .env (criando-os se nao existirem)
#   4. aplica as Applications e espera tudo ficar Synced/Healthy
#
# Teardown: ./bootstrap.sh teardown
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${HOME}/.kube/local-k3d.kubeconfig"   # isolado (AGENTS.md)
CLUSTER="local"
ARGOCD_NS="argocd"
SEALED_NS="kube-system"
CERT="${ROOT}/clusters/local/sealed-secrets/cert.pem"
BACKUP="${ROOT}/sealed-backup/key.yaml"
RESEAL=0
[[ "${1:-}" == "--reseal" ]] && RESEAL=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

rand() { openssl rand -hex "${1:-16}"; }

preflight() {
  log "preflight: ferramentas"
  for t in k3d kubectl kustomize kubeseal openssl curl git; do
    command -v "$t" >/dev/null || die "ferramenta ausente: $t"
  done
  log "preflight: portas livres (6444, 80, 443)"
  if ss -tlnp 2>/dev/null | grep -qE ':(6444|80|443)\b'; then
    warn "alguma porta ja em uso — se o cluster ja existe, isso e esperado"
  fi
}

create_cluster() {
  if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER}\b"; then
    log "cluster '${CLUSTER}' ja existe — reaproveitando"
  else
    log "criando cluster '${CLUSTER}' a partir do k3d-config.yaml"
    k3d cluster create --config "${ROOT}/clusters/local/k3d-config.yaml"
  fi
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

wait_for_controller() {
  # O Argo cria o controller de forma assincrona; espera ele existir.
  log "aguardando o Argo criar o controller de secrets"
  for _ in $(seq 1 60); do
    kubectl -n "${SEALED_NS}" get deployment/sealed-secrets-controller >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl -n "${SEALED_NS}" rollout status deployment/sealed-secrets-controller --timeout=240s
}

install_argocd() {
  log "instalando Argo CD"
  kubectl apply -f "${ROOT}/clusters/local/argocd/namespace.yaml"
  kubectl apply -n "${ARGOCD_NS}" -f "${ROOT}/clusters/local/argocd/install.yaml"
  kubectl -n "${ARGOCD_NS}" rollout status deployment/argocd-server --timeout=300s
  kubectl -n "${ARGOCD_NS}" rollout status statefulset/argocd-application-controller --timeout=300s
  kubectl -n "${ARGOCD_NS}" rollout status deployment/argocd-repo-server --timeout=300s

  # UI via Ingress (bonus): argocd-server em --insecure + Ingress no Traefik.
  kubectl -n "${ARGOCD_NS}" patch deployment argocd-server --type=json \
    --patch-file "${ROOT}/clusters/local/argocd/argocd-server-insecure.patch.json" >/dev/null 2>&1 || true
  kubectl apply -f "${ROOT}/clusters/local/argocd/argocd-ui-ingress.yaml"
}

persist_argocd_credentials() {
  # A senha do admin do Argo CD e gerada no install e muda a cada cluster.
  # Gravamos no envs/ local (gitignored) para ela fazer parte do "pacote",
  # como fazemos com a do Grafana. Opcao B (senha deterministica via
  # SealedSecret) fica documentada no DECISIONS como evolucao.
  local pw
  pw="$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  if [[ -n "$pw" ]]; then
    printf 'admin-user=admin\nadmin-password=%s\n' "$pw" > "${ROOT}/envs/argocd.env"
    chmod 600 "${ROOT}/envs/argocd.env"
    log "credencial do Argo CD gravada em envs/argocd.env (local, gitignored)"
  else
    warn "nao achei argocd-initial-admin-secret (senha pode ja ter sido trocada)"
  fi
}

ensure_env_files() {
  local file="$1"; shift
  # (re)cria o .env se ausente, vazio ou com algum valor em branco.
  # Chaves podem ter hifen (ex.: admin-password).
  local needs=0
  if [[ ! -f "$file" ]]; then
    needs=1
  elif ! grep -qE '^[A-Za-z0-9_-]+=.+' "$file"; then
    needs=1
  elif grep -qE '^[A-Za-z0-9_-]+=$' "$file"; then
    needs=1
  fi
  if [[ "$needs" == "1" ]]; then
    warn "gerando ${file#${ROOT}/} (sintetico)"
    printf '%s\n' "$@" > "$file"
    chmod 600 "$file"
  else
    log "mantendo ${file#${ROOT}/}"
  fi
}

resolve_secrets() {
  log "resolvendo secrets"
  mkdir -p "$(dirname "$BACKUP")"; chmod 700 "$(dirname "$BACKUP")" 2>/dev/null || true

  ensure_env_files "${ROOT}/envs/staging.env" \
    "ADMIN_USER=admin" "ADMIN_PASSWORD=$(rand 12)" \
    "SESSION_KEY=$(rand 32)" "CLEANUP_TOKEN=$(rand 16)"
  ensure_env_files "${ROOT}/envs/production.env" \
    "ADMIN_USER=admin" "ADMIN_PASSWORD=$(rand 12)" \
    "SESSION_KEY=$(rand 32)" "CLEANUP_TOKEN=$(rand 16)"
  ensure_env_files "${ROOT}/envs/postgres-staging.env" \
    "POSTGRES_USER=todolist" "POSTGRES_PASSWORD=$(rand 16)" "POSTGRES_DB=todolist"
  ensure_env_files "${ROOT}/envs/postgres-production.env" \
    "POSTGRES_USER=todolist" "POSTGRES_PASSWORD=$(rand 16)" "POSTGRES_DB=todolist"
  ensure_env_files "${ROOT}/envs/grafana-observability.env" \
    "admin-user=admin" "admin-password=$(rand 12)"

  if [[ "$RESEAL" == "0" && -f "$BACKUP" ]]; then
    log "restaurando a chave do controller de ${BACKUP#${ROOT}/} (mantem os selos do Git)"
    # Remove a chave gerada automaticamente para que so a chave do backup valha
    # (garante que o cert publico do repo continue valido).
    kubectl -n "${SEALED_NS}" delete secret \
      -l sealedsecrets.bitnami.com/sealed-secrets-key --ignore-not-found >/dev/null
    kubectl -n "${SEALED_NS}" apply -f "$BACKUP"
    # Deleta o pod (nao o Deployment) para o controller carregar a chave sem
    # gerar drift de annotation no que o Argo gerencia.
    kubectl -n "${SEALED_NS}" delete pod -l name=sealed-secrets-controller --ignore-not-found
    for _ in $(seq 1 60); do
      ready="$(kubectl -n "${SEALED_NS}" get pods -l name=sealed-secrets-controller \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
      [[ "$ready" == "true" ]] && break
      sleep 5
    done
    # cert.pem publico ja esta no repo; nao sobrescrever (evita arvore suja).
    [[ -f "$CERT" ]] || kubeseal --controller-namespace "${SEALED_NS}" \
      --controller-name sealed-secrets-controller --fetch-cert > "$CERT"
    return
  fi

  warn "sem backup de chave (ou --reseal): re-selando com o cert atual do cluster"
  kubeseal --controller-namespace "${SEALED_NS}" --controller-name sealed-secrets-controller \
    --fetch-cert > "$CERT"
  seal "${ROOT}/envs/postgres-staging.env"    todolist-staging    postgres-credentials "${ROOT}/k8s/overlays/staging/sealed-postgres.yaml"
  seal "${ROOT}/envs/staging.env"             todolist-staging    todolist-auth        "${ROOT}/k8s/overlays/staging/sealed-auth.yaml"
  seal "${ROOT}/envs/postgres-production.env" todolist-production postgres-credentials "${ROOT}/k8s/overlays/production/sealed-postgres.yaml"
  seal "${ROOT}/envs/production.env"          todolist-production todolist-auth        "${ROOT}/k8s/overlays/production/sealed-auth.yaml"
  seal "${ROOT}/envs/grafana-observability.env" observability     grafana-admin        "${ROOT}/clusters/local/observability/sealed-grafana-admin.yaml"

  if ! git -C "$ROOT" diff --quiet -- 'k8s/overlays/*/sealed-*.yaml' 'clusters/local/observability/sealed-*.yaml'; then
    log "commitando os selos re-gerados (o Argo le do Git)"
    git -C "$ROOT" add 'k8s/overlays/*/sealed-*.yaml' 'clusters/local/observability/sealed-*.yaml'
    git -C "$ROOT" commit -m "chore: reseal secrets ($(date +%F))"
    if [[ "${NO_PUSH:-0}" == "0" ]]; then
      git -C "$ROOT" pull --rebase origin main && git -C "$ROOT" push origin main
    else
      warn "NO_PUSH=1: os selos ficaram locais; faca push antes de esperar o Argo"
    fi
  else
    log "selos inalterados"
  fi

  log "backup da chave do controller em ${BACKUP#${ROOT}/} (NAO versionado)"
  kubectl -n "${SEALED_NS}" get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > "$BACKUP"
  chmod 600 "$BACKUP"
}

seal() { # envfile namespace name output
  kubectl create secret generic "$3" -n "$2" --from-env-file="$1" \
    --dry-run=client -o yaml \
    | kubeseal --cert "$CERT" --scope strict --namespace "$2" --name "$3" \
        --format yaml > "$4"
  log "selado $2/$3 -> ${4#${ROOT}/}"
}

apply_platform() {
  log "aplicando projetos e Applications"
  kubectl apply -f "${ROOT}/clusters/local/argocd/project.yaml"
  kubectl apply -f "${ROOT}/clusters/local/argocd/project-observability.yaml"
  for app in \
    application-sealed \
    application-staging application-production \
    application-kube-prometheus-stack application-loki application-alloy application-observability ; do
    kubectl apply -f "${ROOT}/clusters/local/argocd/${app}.yaml"
  done
  # Provisionamento INICIAL: sincroniza production uma vez para o ambiente
  # ficar pronto. Promocoes seguintes continuam manuais (de proposito).
  log "sincronizando production (provisionamento inicial)"
  kubectl -n "${ARGOCD_NS}" patch application todolist-production --type merge \
    -p '{"operation":{"initiatedBy":{"username":"bootstrap"},"sync":{"revision":"HEAD"}}}' >/dev/null
}

wait_ready() {
  log "aguardando as Applications ficarem Synced/Healthy (ate 10 min)"
  local deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    local out
    out="$(kubectl -n "${ARGOCD_NS}" get applications \
      -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers 2>/dev/null || true)"
    if [[ -n "$out" ]] && ! awk '{print $2"/"$3}' <<<"$out" | grep -qvE 'Synced/Healthy'; then
      printf '%s\n' "$out"; return 0
    fi
    sleep 15
  done
  warn "timeout; estado atual:"; kubectl -n "${ARGOCD_NS}" get applications || true
}

show_access() {
  local argopw grafanapw
  argopw="$(grep -h admin-password "${ROOT}/envs/argocd.env" 2>/dev/null | cut -d= -f2)"
  if [[ -z "$argopw" ]]; then
    argopw="$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '?')"
  fi
  grafanapw="$(grep -h admin-password "${ROOT}/envs/grafana-observability.env" 2>/dev/null | cut -d= -f2 || echo '?')"
  cat <<EOF

Pronto. Acesso (LB 127.0.0.1:80/443; hosts *.localhost):
  staging      http://staging.localhost     (login admin / senha em envs/staging.env)
  production   http://prod.localhost        (login admin / senha em envs/production.env)
  Argo CD UI   http://argocd.localhost      (admin / ${argopw})
  Grafana      http://grafana.localhost     (admin / ${grafanapw})
EOF
}

teardown() {
  log "teardown"
  k3d cluster delete "$CLUSTER" || true
  # Prune global e agressivo: pode remover volumes/redes de OUTROS projetos
  # (ex.: ambiente de trabalho). So roda com PRUNE=1 explicito.
  if [[ "${PRUNE:-0}" == "1" ]]; then
    warn "PRUNE=1: rodando docker volume/network prune globais"
    docker volume prune -f || true
    docker network prune -f || true
  else
    warn "prune global pulado (use PRUNE=1 se quiser limpar volumes/redes orfaos)"
  fi
  rm -f "$KUBECONFIG"
  warn "repos e backup de chave NAO foram removidos (remocao manual se desejado)"
}

main() {
  if [[ "${1:-}" == "teardown" ]]; then teardown; return; fi
  preflight
  create_cluster
  install_argocd
  persist_argocd_credentials
  # Projetos ANTES das Applications (o Application valida o AppProject ja na spec).
  kubectl apply -f "${ROOT}/clusters/local/argocd/project.yaml"
  kubectl apply -f "${ROOT}/clusters/local/argocd/project-observability.yaml"
  kubectl apply -f "${ROOT}/clusters/local/argocd/application-sealed.yaml"
  wait_for_controller
  resolve_secrets
  apply_platform
  wait_ready
  show_access
}

main "$@"
