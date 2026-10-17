# DECISIONS.md — log de decisoes

Formato: data + contexto + escolha + descarte. Sem cerimonia de ADR (1 decisao = 1 item).

- 2026-09-09 · k3d para o cluster. Contexto: o ambiente e local, descartavel.
  Escolha: k3d (k3s em Docker, descartavel em 1 comando). Descarte: kind (nao e k3s),
  minikube (sujaria ~/.minikube), cloud (custo + conta pessoal).
- 2026-09-09 · 2 repos (opcao A). Contexto: separar CI (app) de CD (GitOps).
  Escolha: `todolist-app` (codigo + workflow) + `k8s-gitops-platform` (manifests + Argo CD).
  Descarte: monorepo (misturaria CI com fonte de deploy).
- 2026-09-09 · Manifests em fonte unica. Contexto: evitar drift entre os dois repos.
  Escolha: `k8s/` SOMENTE em `k8s-gitops-platform`; repo da app sem `k8s/`. CI faz bump de digest aqui.
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
- 2026-10-16 · Secrets gerados pelo Terraform, sem Sealed Secrets. Contexto:
  o cluster Talos e provisionado pelo Terraform e nao depende de um provedor
  externo de secrets. Escolha: `random_password` gera credenciais e
  `kubernetes_secret` cria os Secrets de staging, production e Grafana. O state
  Terraform contem os valores em claro, mesmo com os atributos marcados como
  sensiveis. Em uso real, o state precisa de backend cifrado, controle de acesso
  e locking. Descarte: Sealed Secrets (chave adicional e ciclo de reseal) e
  External Secrets Operator (requer um provedor externo).
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
  e projeto de portfolio com segredos sinteticos, beleza do historico > purge.
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
- 2026-09-11 · `bootstrap.sh` com restore ou reseal (decisao substituida em 2026-10-16). Contexto: sealed secrets
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
  Secret gerido fora do Git para `argocd-secret` com `admin.password` bcrypt.
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
  Contexto: a `main` do repo da app era vestigial no GitLab Flow (o CI usa staging/
  production e o bump aponta para a main do k8s-gitops-platform, nao do app).
  Escolha: remover a `main` (ancestral de staging, sem perda de historico).
  Descarte: manter as 3 branches (ambiguidade sobre a principal).
- 2026-10-13 · Terraform provisiona o cluster, Argo entrega os workloads.
  Contexto: IaC com Terraform e requisito frequente e o k3d estava so no script.
  Escolha: `terraform/` cria/destroi o cluster a partir do `k3d-config.yaml`
  (binario k3d via `local-exec` com guard de idempotencia, hash do config nos
  triggers). Descarte: provider nao oficial do k3d (dependencia fragil) e
  duplicar manifests de app no Terraform (segunda fonte de verdade, o Argo ja
  reconcilia). Validado no CI (`fmt -check` + `validate`, backend local).
- 2026-10-15 · Talos com `cni = none` e `proxy.disabled = true`. Contexto: o
  Cilium entra na camada do `platform` em modo kube-proxy-free. Escolha: o
  `infra` desliga o CNI e o kube-proxy do Talos, o Cilium assume a rede e a
  substituicao do kube-proxy. Descarte: deixar o kube-proxy ligado (os dois
  programariam as mesmas rotas).
- 2026-10-15 · Plataforma instalada por Terraform Helms, nao por Argo CD.
  Contexto: o Argo CD precisa de rede, ingress e IP externo para existir, entao
  nao pode instalar os proprios pre-requisitos. Escolha: `terraform/platform/`
  instala Cilium, MetalLB, Traefik, Argo CD e metrics-server. Depois disso o
  Argo CD entrega os workloads (fonte de verdade segue no Git).
- 2026-10-15 · Cilium no Talos com KubePrism e sem `SYS_MODULE`. Contexto: o
  init container `clean-cilium-state` morria com `unable to apply caps` e o
  Cilium nao achava a API sem Service. Escolha: `k8sServiceHost=localhost` e
  porta `7445` (KubePrism do Talos), capabilities sem `SYS_MODULE`, cgroup
  reusando `/sys/fs/cgroup` e `bpf.hostLegacyRouting=true`. Descarte: apontar o
  Cilium para o IP do control plane (depende de Service que ainda nao existe) e
  manter as capabilities padrao (bloqueadas pelo Talos).
- 2026-10-15 · Namespace do MetalLB com Pod Security `privileged`. Contexto: o
  Talos aplica Pod Security Admission em `baseline` por padrao e o speaker usa
  `hostNetwork` + `NET_RAW`. Escolha: criar `metallb-system` por
  `kubectl_manifest` com o rotulo `privileged` antes do chart. Descarte: confiar
  no `create_namespace` do Helm (namespace sem rotulo, pods barrados).
- 2026-10-16 · StorageClass `local-path` para PVCs do Talos. Contexto: Talos nao
  fornece provisionador de volumes por padrao. Escolha: Rancher Local Path
  Provisioner cria volumes locais em `/var/mnt/local-path-provisioner`, numa
  UserVolume de diretorio no volume EPHEMERAL. `WaitForFirstConsumer` coloca o
  PV no no que executa o Postgres. `Retain` preserva o diretorio quando o PVC
  some. O volume nao replica dados e nao acompanha o pod para outro no.
- 2026-10-15 · Teste de carga com k6 como Job no cluster. Contexto: o HPA existe
  mas faltava prova empirica do 2->N sob carga. Escolha: `loadtest/` roda
  `grafana/k6` como Job no namespace staging, alvo o Service `todolist`,
  credenciais do Secret `todolist-auth`, rampa ate 60 VUs. Descarte: k6 na
  maquina local (o Job deixa a evidencia repetivel e versionada).
- 2026-10-16 · Talos em vez de k3d ou kubeadm. Contexto: o k3d serviu no inicio
  por ser descartavel em 1 comando. Ele roda k3s em Docker e nao representa um
  cluster real. Escolha: Talos em VMs libvirt, com SO imutavel e API declarativa.
  Descarte: k3d (demo em container) e kubeadm (carga operacional de SO mutavel).
  O modulo Terraform raiz do k3d saiu do repo. A entrada unica agora e o Makefile.
- 2026-10-16 · Cilium com Hubble Relay no Terraform e UI no Argo CD. Contexto:
  o Talos nasce sem CNI e sem kube-proxy. A rede precisa existir antes dos
  workloads. Escolha: Cilium kube-proxy-free no `terraform/platform`, com Hubble
  Relay junto. A Hubble UI roda standalone pelo Argo CD. Descarte: CNI padrao do
  Talos e Flannel (sem eBPF nem Hubble). Detalhes de flags em itens anteriores.
- 2026-10-16 · Secrets gerados no Terraform, com valores em claro no state.
  Contexto: sem provedor externo de secrets neste ambiente. Escolha:
  `random_password` gera as credenciais e `kubernetes_secret` instala no cluster.
  O state local contem os valores em claro mesmo com atributos sensiveis. Em uso
  real o state exige backend cifrado com acesso restrito e locking. Descarte:
  Sealed Secrets e External Secrets Operator. Ver item de 2026-10-16 sobre o tema.
- 2026-10-16 · MetalLB em modo L2 com pool no fim da NAT. Contexto: VMs sem
  load balancer externo. O Traefik precisa de IP estavel para o Ingress. Escolha:
  MetalLB anuncia em L2 o pool `192.168.122.200-210`, longe das VMs (`.10-.12`).
  O namespace usa Pod Security `privileged`. Descarte: NodePort (portas altas
  fora do padrao HTTP) e backend FRR/BGP (peso morto para L2).
- 2026-10-16 · ApplicationSet para staging e production. Contexto: duas
  Applications manuais duplicavam a configuracao. Escolha: um gerador de lista
  define ambiente, namespace e politica de sync. Staging usa sync automatico.
  Production exige sync manual. O AppProject permite namespaces `todolist-*`,
  entao adicionar um ambiente novo exige uma entrada no gerador.
- 2026-10-16 · Tracing com Tempo monolitico + OTel Collector. Contexto: faltava
  tracing distribuido para fechar a observabilidade. Escolha: chart `grafana/tempo`
  em single-binary (1 pod, PVC `local-path` de 2Gi, retencao 72h) e chart
  `open-telemetry/opentelemetry-collector` como Deployment, recebendo OTLP gRPC/HTTP
  e exportando OTLP para o Tempo. `tempo.memBallastSizeMbs: 128` (o default de
  1024 estoura o limite do container) e `serviceMonitor` do Tempo desligado (o
  template do chart referencia a porta `jaeger-metrics`, que so existe com o
  `tempoQuery` ligado). Descarte: modo distribuido (microservicos sem ganho em 1 no)
  e Jaeger (projeto em modo manutencao).
- 2026-10-16 · Collector com `alternateConfig`, nao `config`. Contexto: o chart
  do collector faz merge do `.Values.config` com o default, e o default traz
  receivers Jaeger/Zipkin e pipelines de logs/metricas com o exporter `debug`
  (ruido e CPU sem uso). Escolha: `alternateConfig` substitui o config inteiro,
  deixando so o receiver OTLP, `batch` e `memory_limiter`. Descarte: aceitar o
  merge e filtrar depois (nao da para remover chave por merge de values).
- 2026-10-16 · Instrumentacao da app com `opentelemetry-instrument`. Contexto:
  a app roda sob gunicorn com 2 workers. Escolha: o entrypoint do container
  passa a ser `opentelemetry-instrument gunicorn ...`, o que instrumenta Flask
  (span HTTP) e SQLAlchemy (span do banco) e exporta OTLP para o collector via
  env `OTEL_*` do ConfigMap do overlay. `SQLAlchemy` pinado em 2.0.x porque a
  instrumentacao ainda nao cobre 2.1 (o dialeto `postgresql+psycopg2` ja era
  explicito). Descarte: instrumentacao programatica (mais codigo na app).
- 2026-10-16 · `trace_id` no log JSON e correlacao no Grafana. Contexto: sem o
  id do trace no log, o Loki e o Tempo ficam ilhas. Escolha: o formatter JSON
  inclui `trace_id`/`span_id` quando ha span ativo, o Alloy os extrai como
  structured metadata e o Grafana liga os dois sentidos (derived field do Loki
  para o Tempo, `tracesToLogsV2`/`tracesToMetrics` do Tempo para Loki e
  Prometheus). Limitacao conhecida: o access log do gunicorn e emitido fora do
  span, entao so os logs da app carregam o `trace_id`.
- 2026-10-16 · Namespace `observability` com Pod Security `privileged`. Contexto:
  o node-exporter e o Alloy usam hostNetwork/hostPID/hostPath/hostPort, que o
  PSA `baseline` barra, entao os DaemonSets ficavam sem pods e travavam o sync
  do kube-prometheus-stack. Escolha: rotulo `privileged` no namespace, igual ao
  do MetalLB. Descarte: desligar o node-exporter (o objetivo e observar as VMs).
- 2026-10-17 · ntfy self-hosted como canal de alertas. Contexto: o Alertmanager
  estava desligado por falta de destinatario. Escolha: chart `helmforge/ntfy`
  1.2.3 (o unico chart Helm mantido para ntfy) em `observability`, Ingress
  `ntfy.local`, PVC `local-path` de 1Gi. Descarte: conta no ntfy.sh publico
  (dados fora) e recebedor de e-mail (sem SMTP no cluster).
- 2026-10-17 · ntfy com `auth-default-access: deny-all` e token no Secret.
  Contexto: o topico nao pode ser publico. Escolha: usuario `alertmanager`
  provisionado por `auth-users` (bcrypt) e `auth-access` no topico
  `todolist-alerts`, mais um token `tk_<29>` gerado no Terraform e lido pelo
  ntfy via `NTFY_AUTH_TOKENS` (Secret `ntfy-alertmanager`, chave `auth-tokens`).
  O Alertmanager le a chave `token` do mesmo Secret via `credentials_file`,
  entao o valor nao entra no config versionado. Descarte: senha em texto no
  Git (o hash do bcrypt fica no values, a senha nao) e ntfy aberto.
- 2026-10-17 · Alertmanager com um receiver webhook para o ntfy. Contexto:
  fechar o ciclo detectar -> avisar. Escolha: `alertmanager.enabled: true` com
  rota unica para o receiver `ntfy`, `send_resolved: true` e o token lido de
  arquivo (`http_config.authorization.credentials_file`). O receiver `null` do
  chart precisa ser redeclarado porque a lista de receivers substitui a default
  inteira (a rota `Watchdog` do chart continua apontando para ele).
  `ruleSelectorNilUsesHelmValues: false` faz o Prometheus selecionar os
  PrometheusRules proprios. Descarte: `stringConfig` (menos legivel que o mapa).
- 2026-10-17 · Alerta de teste sempre ativo com repeat de 24h. Contexto: provar
  o caminho Prometheus -> Alertmanager -> ntfy sem depender de uma falha real.
  Escolha: `TodoListPipelineTest` (`vector(1)`) com rota dedicada e
  `repeat_interval: 24h` para nao virar spam. Nome proposital diferente de
  `Watchdog`, que o chart roteia para o receiver `null`. Descarte: injetar
  alerta na API do Alertmanager (prova so metade do caminho).
- 2026-10-17 · Metricas das pecas de plataforma nos Helm values. Contexto: os
  componentes nao expunham ServiceMonitor, entao o Prometheus nao os raspava.
  Escolha: ligar metricas e ServiceMonitor no `terraform/platform` para Cilium
  (agent, operator, Hubble), Traefik (Prometheus com labels de
  entrypoint/service/router), Argo CD (controller, server, repo-server,
  applicationSet) e MetalLB (speaker e controller, que exige
  `prometheus.serviceAccount`/`namespace` para o RBAC do Prometheus). O
  `serviceMonitorSelectorNilUsesHelmValues: false` ja pega qualquer
  ServiceMonitor. Descarte: PodMonitor (menos preciso por porta) e scrape por
  anotacao.
- 2026-10-17 · etcd do Talos fica fora do scrape por enquanto. Contexto: o
  endpoint de metricas do etcd do Talos exige client cert (mTLS), entao o
  ServiceMonitor `kube-etcd` do chart fica sem endpoints. Escolha: kubelet e
  apiserver seguem raspados, e o alerta de quorum fica para a issue #34.
  Descarte: apontar o etcd sem cert (nao sobe) e usar metrica de apiserver como
  proxy de quorum (nao representa o raft).
- 2026-10-17 · SLO de disponibilidade com burn-rate multi-janela. Contexto:
  faltava o lado de SLO/SLI. Escolha: SLI de disponibilidade a partir de
  `flask_http_request_total` (SLO de 99%, error budget de 1%), recording rules
  do error ratio em 5m/30m/1h/6h e alertas nas janelas rapida (14.4x) e media
  (6x) do modelo do Google SRE. Descarte: Sloth (mais um operador para gerar o
  que da para escrever a mao) e a janela lenta (3d/6h) porque a retencao do
  Prometheus e de 6h.
- 2026-10-17 · Backup do Postgres com WAL-G, nao pg_dump. Contexto: o objetivo e
  recuperar qualquer instante (PITR) e nao so um dump logico diario. Escolha:
  o WAL-G roda dentro do pod do Postgres (archive_command `wal-g wal-push %p` +
  sidecar `wal-g-backup` com `backup-push` a cada 24h), tudo no MinIO.
  Descarte: CronJob de pg_dump (sem PITR e sem acesso ao PGDATA) e pg_basebackup
  manual (sem retencao nem WAL continuo).
- 2026-10-17 · Imagem `postgres-walg` propria com gcompat. Contexto: o WAL-G nao
  publica imagem oficial e o binario de release e glibc. Escolha: imagem propria
  a partir do `postgres:16-alpine` pinado por digest, com o binario do WAL-G
  pinado por versao e sha256, rodando no musl via gcompat. Mantem uid 70 e o
  layout de PGDATA, sem migrar o volume. Descarte: imagem comunitaria de
  terceiros (risco de supply chain) e trocar para a base Debian (uid 999
  brigaria com o volume ja em 70).
- 2026-10-17 · Credenciais do MinIO via `terraform_remote_state`. Contexto: o
  modulo `platform` precisa da senha do MinIO que so o modulo `infra` conhece.
  Escolha: output sensivel `minio_root_password` no infra + `terraform_remote_state`
  (backend local) no platform, virando o Secret `minio-backup` por ambiente.
  Descarte: duplicar as credenciais nos tfvars dos dois modulos.
- 2026-10-17 · Retencao no proprio WAL-G (`delete retain FULL 7`). Contexto: o
  sidecar roda todo dia e ja fala com o MinIO. Escolha: apagar base backups
  antigos ali mesmo (os WAL correspondentes vao junto). Descarte: lifecycle do
  bucket (exige novo apply no infra) e CronJob extra de verificacao.
- 2026-10-17 · Alerta de backup por restart do sidecar. Contexto: o WAL-G nao
  expoe metrica propria. Escolha: o sidecar sai com erro quando o `backup-push`
  falha, o kubelet reinicia e o `PrometheusRule` `PostgresBackupFalhando`
  observa `kube_pod_container_status_restarts_total`. Descarte: checagem de
  frescor por CronJob propria (mais um componente) e alerta so por log.
