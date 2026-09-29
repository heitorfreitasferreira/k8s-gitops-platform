# DECISIONS.md — log de decisoes

Formato: data + contexto + escolha + descarte. Sem cerimonia de ADR (1 decisao = 1 item).

- 2026-09-09 · k3d para o cluster. Contexto: o ambiente e local, descartavel.
  Escolha: k3d (k3s em Docker, descartavel em 1 comando). Descarte: kind (nao e k3s),
  minikube (sujaria ~/.minikube), cloud (custo + conta pessoal).
- 2026-09-09 · 2 repos (opcao A). Contexto: separar CI (app) de CD (GitOps).
  Escolha: fork `todolist-app` (codigo + workflow) + `k8s-gitops-platform` (manifests + Argo CD).
  Descarte: monorepo (misturaria CI com fonte de deploy).
- 2026-09-09 · Manifests em fonte unica. Contexto: evitar drift entre os dois repos.
  Escolha: `k8s/` SOMENTE em `k8s-gitops-platform`; fork sem `k8s/`. CI faz bump de digest aqui.
- 2026-09-09 · Postgres simples junto no k3d. Contexto: validar SELECT/health sem HA.
  Escolha: Deployment + Service + PVC (sem replicas). Descarte: StatefulSet/HA, Postgres externo.
- 2026-09-09 · Argo CD fonte de verdade. Escolha: Applications apontam para
  `k8s/overlays/staging` (sync automatico) e `k8s/overlays/production`
  (sync manual = promocao); imagem por digest imutavel (`@sha256:`), nunca `:latest`.
- 2026-09-09 · `.opencode/` fora do repo. Contexto: MCPs e comandos sao locais
  e nao pertencem ao que e versionado. Escolha: ficam no workspace local, fora do Git.
- 2026-09-09 · Digest com prefixo `sha256:` (fix). Contexto: primeiro bump gerou
  `InvalidImageName` (CI arrancava o prefixo). Escolha: kustomize exige
  `digest: sha256:<hex>`; workflow corrigido e validado pelo proprio loop CI->ArgoCD.
- 2026-09-09 · GitLab Flow (staging principal). Contexto: um env so nao mostra
  promocao; Git Flow seria pesado para 1 app. Escolha: `staging` = default,
  `production` protegida (sem push direto, PR so de `staging`/`hotfix/*`,
  CI verde + approval + linear). Descarte: trunk-based puro (sem gate de prod).
- 2026-09-09 · Sealed Secrets, nao ESO. Contexto: k3d descartavel, sem Vault/AWS.
  Escolha: controller vendorizado (digest pinado) via Argo + `kubeseal --scope strict`
  + `.env.example` tangivel + `/k-secrets` (opencode) como runbook. Descarte: ESO
  (exige provedor externo), Secret em claro (CHANGEME aposentado).
- 2026-09-09 · 1 volume projected, nao 2 mounts. Contexto: app le credenciais de
  arquivos no mesmo `SECRETS_DIR`; 2 volumeMounts no mesmo path esconderiam um.
  Escolha: `projected` com `items:` renomeando `POSTGRES_*` -> `DB_*`.
- 2026-09-09 · Host routing, nao 2a porta. Contexto: duas portas host -> mesma
  porta 80 do LB perdem a distincao no NAT; Traefik so diferencia por Host.
  Escolha: 1 porta (80) + `staging/prod.localhost` (sem /etc/hosts).
  Descarte: entrypoint Traefik extra (complexidade sem ganho na demo).
- 2026-09-09 · Bump cirurgico, nao kustomize edit. Contexto: `kustomize edit set image`
  reescrevia o kustomization (comentarios deslocados, `newName` espurio, `newTag`
  perdido). Escolha: regex ancorado so em `newTag:`/`digest:` (diff de 2 linhas).
- 2026-09-09 · CronJob citado. Contexto: `X-Cleanup-Token: ...` com dois-pontos+espaco
  em scalar plano virou mapa e o API server rejeitou o CronJob. Escolha: flow style
  com aspas. Sem CronJob, `/cleanup/status` fica vazio e a Role `patch` nao se prova.
- 2026-09-09 · Historico linear, sem purge. Contexto: `CHANGEME` antigo no historico.
  Escolha: correcao para frente (SealedSecrets novos), sem filter-repo/force-push;
  e teste tecnico com segredos sinteticos, beleza do historico > purge.
- 2026-09-11 · Observabilidade com kube-prometheus-stack + Loki + Alloy (via Argo/Helm
  pinado). Contexto: pedido de bonus com metricas de cluster, recursos, banco e app.
  Escolha: stack padrao do mercado com charts pinados e dashboards prontos
  (k8s Compute Resources) + 2 dashboards proprios. Descarte: Prometheus "avulso"
  (sem operator/ServiceMonitor/dashboards) e Elastic (pesado para k3d).
- 2026-09-11 · Alertmanager desligado e defaultRules off. Contexto: alerta sem
  destinatario em ambiente de teste polui o Prometheus. Escolha: desligar e
  documentar; ligar e 1 flag quando houver on-call.
- 2026-09-11 · Loki single-binary + filesystem + retencao 72h. Contexto: k3d
  descartavel, sem S3. Escolha: minimal com PVC local; descarte: SimpleScalable
  (6+ pods sem ganho), MinIO.
- 2026-09-11 · Coleta de logs com Alloy (nao Promtail). Contexto: Promtail esta
  em EOL; Alloy e o sucessor oficial. Escolha: DaemonSet Alloy com
  discovery.kubernetes -> loki.write. Descarte: Promtail (legado).
- 2026-09-11 · Metricas da app aditivas (prometheus-flask-exporter com
  GunicornInternalPrometheusMetrics). Contexto: gunicorn com 2 workers duplica
  contadores se cada worker expuser o proprio registry. Escolha: coletor
  multiprocess (PROMETHEUS_MULTIPROC_DIR + emptyDir), nenhuma rota alterada.
- 2026-09-11 · Metricas do banco via postgres-exporter sidecar no pod do Postgres.
  Contexto: sem credencial extra e sem Service novo apontando para fora.
  Escolha: sidecar + porta `metrics` no Service existente + ServiceMonitor.
- 2026-09-11 · Dashboard do Postgres: grafana.com #9628 (template pronto),
  transformado (datasource `Prometheus`, `__inputs` removidos) e versionado.
- 2026-09-11 · Argo CD UI via Ingress no mesmo LB (bonus). Contexto: port-forward
  nao serve como acesso permanente. Escolha: Ingress + `argocd-server --insecure` (TLS terminaria
  no LB em ambiente real); patch JSON versionado. Descarte: ServersTransport do
  Traefik (nao surtiu efeito nesta versao do k3s).
- 2026-09-11 · production: PR obrigatorio com 0 approvals. Contexto: repo de uma
  pessoa; self-approve e impossivel e travaria o proprio fluxo. Escolha: manter
  PR + CI verde + historico linear + sem bypass de admin (push direto continua
  barrado). Descarte: approval=1 (inviavel single-dev).
- 2026-09-11 · Memoria do Grafana 256Mi -> 768Mi. Contexto: OOMKilled (exit 137)
  com ~30 dashboards (uso real ~390Mi); UI alternava 200/503. Escolha: subir o
  limite observando `kubectl top` + restarts em vez de chutar "pequeno".
- 2026-09-11 · RBAC: `list` de cronjobs sem resourceNames. Contexto: /cleanup/status
  mostrava "unknown state" + 403 no log; `auth can-i list cronjobs` = no.
  Escolha: split em 2 regras — `list` sem resourceNames (RBAC ignora resourceNames
  p/ list/watch/create; a app descobre o CronJob por list) + `get/patch` travados
  em `todolist-cleanup`. Validacao anti-falso-verde: pagina retorna 200 mesmo com
  erro, entao conferir banner ausente + spec.suspend alternando + logs sem 403.
  Residual conhecido: `patch` com resourceNames impede pivor p/ outros CronJobs,
  mas nao restringe por campo (jobTemplate do proprio). Aceito: namespace e so
  da app; alternativa futura = SA separada p/ escrita.
- 2026-09-11 · Pod/ReplicaSet/Job na allowlist do AppProject (visibilidade).
  Contexto: arvore do Argo mostrava so os pais (sem Pods, sem aba LOGS).
  Escolha: adicionar as 3 kinds a `project.yaml` — view-only (nao existem no
  Git, o Argo nao passa a gerenciar nada). O Argo esconde da arvore recursos
  fora da allowlist, e Pods herdam visibilidade do ReplicaSet (Jobs, do CronJob).
- 2026-09-11 · Logs em JSON na app (sem lib extra). Contexto: logs em texto nao
  davam filtro por nivel/status no Loki; e nao havia access log nenhum (gunicorn
  sem `--access-logfile`). Escolha: `logging_json.py` (formatter proprio, campos
  time/level/logger/message/exception) no logger raiz + `gunicorn.conf.py` com
  access/error em JSON. Descarte: python-json-logger (dependencia dispensavel).
- 2026-09-11 · Parsing no Alloy (loki.process). `stage.json` -> labels `level` e
  `logger` (cardinalidade baixa, filtro/agregacao) + structured metadata de
  `status/method/path/duration_us` (evita explodir series). `drop_malformed:false`
  (default): linhas de texto de outros containers passam intactas.
- 2026-09-11 · Alerta Grafana-managed (reduce+math) sobre logs de erro, sem
  contato de notificacao. Contexto: ambiente local descartavel (sem SMTP/Slack);
  um threshold sem destinatario ainda demonstra a avaliacao na UI. Primeiro
  modelo usava `threshold` com `expression` apontando para si ("cannot reference
  itself"); corrigido para reduce(last) + math `$B > 0`.
- 2026-09-11 · Alloy descarta kube-system/kube-public/kube-node-lease/argocd.
  Contexto: volume e ruido sem valor para a demo; mantem observability para
  depurar a propria stack. Retencao Loki: 72h.
- 2026-09-11 · Liveness `/livez` separada de readiness `/healthz`. Contexto: as
  duas usavam `/healthz` (que consulta o banco); queda do Postgres reiniciava o
  pod em loop sem resolver nada. Escolha: `/livez` nao toca no banco e alimenta
  a liveness; `/healthz` continua na readiness (tira do balanceamento).
- 2026-09-11 · Testes + gate de CI. Escolha: pytest (probes, auth, CRUD, dedupe,
  `/metrics`, token do cleanup) rodando contra Postgres como service container;
  job `test` virou check obrigatorio em `production`. Descarte: testar so em
  runtime (sem gate) — nao protege a promocao.
- 2026-09-11 · CI do repo GitOps (`validate`): `kustomize build` + `kubeconform`
  + grep de segredos + gitleaks. Contexto: o Argo aplica o que esta no Git;
  validar antes evita `OutOfSync`/erro de schema na reconciliacao.
- 2026-09-11 · `bootstrap.sh` com restore ou reseal. Contexto: sealed secrets
  sao cluster-bound; em cluster novo os selos do Git ficam indecifraveis.
  Escolha: restaura a chave do backup local (mantem os selos) ou, sem backup,
  cria os `.env` sinteticos e re-sela, commitando. Descartado: versionar a chave
  privada (vazamento) e depender de passo manual.
- 2026-09-11 · Hosts em `*.localhost` em vez de `*.127.0.0.1.nip.io`. Contexto:
  no rehearsal do zero o nip.io passou a resolver para um IPv6/IP de parking
  (DNS da rede sequestrando wildcard publico), quebrando o browser. Escolha:
  `staging/prod/argocd/grafana.localhost` (RFC 6761: resolve para loopback sem
  DNS externo). Descarte: nip.io/sslip.io (dependem de DNS publico) e editar
  `/etc/hosts` (exigiria sudo).
- 2026-09-11 · `initContainer wait-for-postgres` + `startupProbe`. Contexto: no
  primeiro deploy do cluster o Postgres ainda subia e a app entrava em CrashLoop
  (gunicorn roda `create_all()` no import e sai se o banco nao responde).
  Escolha: initContainer espera o `pg_isready` e startupProbe da ate 2 min antes
  de ligar liveness/readiness. Efeito: zero restarts no bootstrap do zero.
- 2026-09-11 · LB em 80/443 (sem sufixo de porta) + TLS terminado no Ingress.
  Contexto: URIs mais limpas (`http://staging.localhost`) e demonstrar terminacao
  TLS. Escolha: publicar o Traefik em 80 e 443 e habilitar `tls` nos Ingress (sem
  `secretName` -> cert self-signed padrao do Traefik). HTTP segue funcionando para
  a demo. Descarte: cert-manager + CA confiavel agora (custo/risco para um cluster
  local); em producao o caminho e cert-manager + ACME/CA interna.
- 2026-09-11 · Credencial do admin do Argo CD no `envs/argocd.env` (local).
  Contexto: a senha e gerada no install e muda a cada cluster; so aparecia no
  output do bootstrap. Escolha: `bootstrap.sh` grava `envs/argocd.env` (gitignored,
  como o do Grafana). Evolucao futura (Opcao B): senha deterministica num
  SealedSecret (`argocd-secret` com `admin.password` bcrypt) para ser gerida em Git.
- 2026-09-11 · APP_COLOR via `configMapGenerator` (hash no nome). Contexto: trocar a
  cor mudava o ConfigMap, mas sem rollout o env do container nao atualiza (envFrom
  so injeta na criacao do pod) — a cor so mudava com restart manual. Escolha:
  `configMapGenerator` por overlay; o hash do conteudo entra no nome e o kustomize
  reescreve o `envFrom.configMapRef`, entao a mudanca dispara rollout sozinha.
  Descarte: Reloader/stakater (mais um componente) e restart manual (nao-GitOps).
- 2026-09-15 · Grafana pinado em 12.4.9. Contexto: todos os dashboards vazios
  ("No data") com o Prometheus coletando normalmente (targets `todolist` e
  `postgres` up, series `flask_http_*`/`pg_*` presentes). Causa raiz: o chart
  90.0.0 usa Grafana 13.2, onde prometheus/loki sao plugins externos
  instalados via grafana.com no restart (`preinstall_sync`); sem o download,
  `/api/plugins` nao lista nenhum dos dois e toda query falha com
  `plugin.notRegistered` (visivel tambem no log do alerte `todolist-erros-logs`).
  Escolha: `grafana.image.tag: "12.4.9"` (ambos embutidos, sem download).
  Descarte: `preinstall_sync` no 13.2 (depende de egress para grafana.com a
  cada restart) e dashboards por UID (nao era a causa: o datasource existia,
  o plugin e que nao).
- 2026-09-11 · Repo da app so com `staging` (default) + `production` (protegida).
  Contexto: a `main` do fork era vestigial no GitLab Flow (o CI usa staging/
  production e o bump aponta para a main do k8s-gitops-platform, nao do app).
  Escolha: remover a `main` (ancestral de staging, sem perda de historico).
  Descarte: manter as 3 branches (ambiguidade sobre a principal).
