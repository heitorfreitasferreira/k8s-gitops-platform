# Camada de plataforma: tudo o que o cluster precisa para servir workloads.
#
# Ordem (importa):
#   1. Cilium em modo kube-proxy-free + Hubble  -> a rede dos pods (o Talos
#      nasce com cni = none e proxy desligado, entao ate aqui os nos ficam
#      NotReady).
#   2. MetalLB                                   -> IPs do pool para Services
#      type LoadBalancer.
#   3. Traefik                                   -> ingress, com Service
#      LoadBalancer pegando IP do MetalLB.
#   4. Argo CD                                   -> GitOps, atras do Traefik.
#   5. metrics-server                            -> kubectl top.
#
# O Terraform instala os componentes e cria os secrets de workload. O Argo CD
# continua como fonte de verdade dos manifests da aplicacao.

locals {
  # Le o kubeconfig do infra. Serve para os providers e para descobrir o
  # endpoint do kube-apiserver, que o Cilium em modo kube-proxy-free precisa
  # conhecer direto (sem Service do Kubernetes, que ainda nao existe).
  kubeconfig        = yamldecode(file(pathexpand(var.kubeconfig_path)))
  kube_context_name = local.kubeconfig["current-context"]
  kube_context      = one([for c in local.kubeconfig.contexts : c.context if c.name == local.kube_context_name])
  kube_cluster      = one([for c in local.kubeconfig.clusters : c.cluster if c.name == local.kube_context.cluster])
  api_server_addr   = replace(local.kube_cluster.server, "https://", "")
  api_server_host   = split(":", local.api_server_addr)[0]
  api_server_port   = tonumber(split(":", local.api_server_addr)[1])

  # Valores obrigatorios do Cilium no Talos:
  # - KubePrism (localhost:7445): o Talos expoe o kube-apiserver em cada no por
  #   um proxy local, entao o Cilium nao precisa de Service nem de um IP externo
  #   para achar a API no modo kube-proxy-free.
  # - SYS_MODULE fora das capabilities: o Talos nao deixa workload carregar
  #   modulo de kernel; sem remover, o init container clean-cilium-state morre
  #   com "unable to apply caps: operation not permitted".
  # - cgroup.autoMount off + hostRoot /sys/fs/cgroup: reusa o cgroupv2 que o
  #   Talos ja monta, em vez de montar um proprio.
  # - bpf.hostLegacyRouting: o forwarding de DNS do kube-dns para o host (padrao
  #   no Talos >=1.8) nao funciona junto com o host-routing eBPF.
  cilium_values = <<-YAML
    kubeProxyReplacement: "true"
    k8sServiceHost: "localhost"
    k8sServicePort: 7445
    ipam:
      mode: kubernetes
    bpf:
      hostLegacyRouting: true
    cgroup:
      autoMount:
        enabled: false
      hostRoot: /sys/fs/cgroup
    securityContext:
      capabilities:
        ciliumAgent:
          - CHOWN
          - KILL
          - NET_ADMIN
          - NET_RAW
          - IPC_LOCK
          - SYS_ADMIN
          - SYS_RESOURCE
          - DAC_OVERRIDE
          - FOWNER
          - SETGID
          - SETUID
        cleanCiliumState:
          - NET_ADMIN
          - SYS_ADMIN
          - SYS_RESOURCE
    operator:
      replicas: 1
      prometheus:
        enabled: true
        serviceMonitor:
          enabled: true
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: false
      metrics:
        # Metricas de fluxo e de drops para o dashboard e o alerta de drop.
        enabled:
          - dns:query;ignoreAAAA
          - drop
          - tcp
          - flow
          - icmp
          - http
        serviceMonitor:
          enabled: true
  YAML

  # frrk8s (BGP via FRR) desligado: o pool aqui e anunciado em L2, entao o
  # backend FRR e peso morto.
  metallb_values = <<-YAML
    crds:
      enabled: true
    frrk8s:
      enabled: false
    prometheus:
      # RBAC para o Prometheus do kube-prometheus-stack raspar o metallb-system.
      serviceAccount: kube-prometheus-stack-prometheus
      namespace: observability
      serviceMonitor:
        enabled: true
  YAML

  traefik_values = <<-YAML
    service:
      type: LoadBalancer
    ingressClass:
      enabled: true
      isDefaultClass: true
    metrics:
      prometheus:
        addEntryPointsLabels: true
        addServicesLabels: true
        addRoutersLabels: true
        service:
          enabled: true
        serviceMonitor:
          enabled: true
  YAML

  argocd_values = <<-YAML
    configs:
      params:
        server.insecure: true
    server:
      service:
        type: ClusterIP
      ingress:
        enabled: false
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
    controller:
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
    repoServer:
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
    applicationSet:
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
  YAML

  # Talos usa certificado self-signed no kubelet; sem --kubelet-insecure-tls o
  # metrics-server nao consegue falar com o kubelet e /apis/metrics.k8s.io fica
  # indisponivel.
  metrics_server_values = <<-YAML
    args:
      - --kubelet-insecure-tls
  YAML

  local_path_config = jsonencode({
    nodePathMap = [{
      node  = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
      paths = ["/var/mnt/local-path-provisioner"]
    }]
  })

  local_path_helper_pod = yamlencode({
    apiVersion = "v1"
    kind       = "Pod"
    metadata   = { name = "helper-pod", namespace = "local-path-storage" }
    spec = {
      priorityClassName = "system-node-critical"
      tolerations = [{
        key      = "node.kubernetes.io/disk-pressure"
        operator = "Exists"
        effect   = "NoSchedule"
      }]
      containers = [{
        name            = "helper-pod"
        image           = "docker.io/library/busybox:1.36.1@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"
        imagePullPolicy = "IfNotPresent"
      }]
    }
  })
}

# Outputs do modulo infra (endpoint e credenciais do MinIO) abastecem o Secret
# de backup do Postgres. Os dois modulos usam backend local neste projeto.
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../infra/terraform.tfstate"
  }
}

resource "random_password" "app" {
  for_each         = toset(["staging-admin", "staging-session", "staging-cleanup", "production-admin", "production-session", "production-cleanup"])
  length           = 48
  special          = false
  override_special = ""
}

resource "random_password" "postgres" {
  for_each         = toset(["staging", "production"])
  length           = 48
  special          = false
  override_special = ""
}

resource "random_password" "grafana" {
  length  = 32
  special = false
}

resource "kubernetes_namespace" "workloads" {
  for_each = toset(["todolist-staging", "todolist-production", "observability"])
  metadata {
    name = each.key
    labels = each.key == "observability" ? {
      # O node-exporter (DaemonSet) usa hostNetwork, hostPID, hostPath e
      # hostPort, que o Pod Security Admission so libera em `privileged`.
      # Mesmo padrao do namespace do MetalLB.
      "pod-security.kubernetes.io/enforce" = "privileged"
      } : {
      "app.kubernetes.io/part-of" = "todolist"
      environment                 = trimprefix(each.key, "todolist-")
    }
  }

  # Argo CD adds its tracking annotation to the same namespaces.
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

resource "kubernetes_secret" "todolist_auth" {
  for_each = toset(["staging", "production"])
  metadata {
    name      = "todolist-auth"
    namespace = "todolist-${each.key}"
  }
  data = {
    ADMIN_USER     = "admin"
    ADMIN_PASSWORD = random_password.app["${each.key}-admin"].result
    SESSION_KEY    = random_password.app["${each.key}-session"].result
    CLEANUP_TOKEN  = random_password.app["${each.key}-cleanup"].result
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.workloads]
}

resource "kubernetes_secret" "postgres_credentials" {
  for_each = toset(["staging", "production"])
  metadata {
    name      = "postgres-credentials"
    namespace = "todolist-${each.key}"
  }
  data = {
    POSTGRES_USER     = "todolist"
    POSTGRES_PASSWORD = random_password.postgres[each.key].result
    POSTGRES_DB       = "todolist"
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.workloads]
}

# Credenciais do MinIO para o WAL-G (backup do Postgres). O prefixo separa os
# ambientes no bucket unico. Os valores vem dos outputs do modulo infra.
resource "kubernetes_secret" "minio_backup" {
  for_each = toset(["staging", "production"])
  metadata {
    name      = "minio-backup"
    namespace = "todolist-${each.key}"
  }
  data = {
    AWS_ACCESS_KEY_ID       = data.terraform_remote_state.infra.outputs.minio_root_user
    AWS_SECRET_ACCESS_KEY   = data.terraform_remote_state.infra.outputs.minio_root_password
    AWS_ENDPOINT            = data.terraform_remote_state.infra.outputs.minio_endpoint
    AWS_REGION              = "us-east-1"
    AWS_S3_FORCE_PATH_STYLE = "true"
    WALG_S3_PREFIX          = "s3://${data.terraform_remote_state.infra.outputs.minio_bucket}/${each.key}"
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.workloads]
}

resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = "observability"
  }
  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana.result
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.workloads]
}

resource "random_password" "ntfy_token" {
  # ntfy exige o formato `tk_` + 29 chars (allowedTokenRegex em user/util.go).
  length  = 29
  special = false
}

resource "kubernetes_secret" "ntfy_alertmanager" {
  metadata {
    name      = "ntfy-alertmanager"
    namespace = "observability"
  }
  data = {
    # ntfy le NTFY_AUTH_TOKENS no formato "<usuario>:<token>".
    "auth-tokens" = "alertmanager:tk_${random_password.ntfy_token.result}"
    # O Alertmanager le so o token, no header Authorization: Bearer.
    "token" = "tk_${random_password.ntfy_token.result}"
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.workloads]
}

locals {
  # Configs de scrape extra do Prometheus (VM do MinIO e etcd do Talos). Os
  # IPs/hosts vem do modulo `infra`, entao nao ficam no Git. Cada job vira uma
  # string JSON e o conjunto vira um array JSON (JSON e YAML valido).
  extra_scrape_jobs = concat(
    var.minio_address == "" ? [] : [
      jsonencode({ job_name = "minio-node", static_configs = [{ targets = ["${var.minio_address}:9100"] }] }),
      jsonencode({ job_name = "minio-cluster", metrics_path = "/minio/v2/metrics/cluster", static_configs = [{ targets = ["${var.minio_address}:9000"] }] }),
      jsonencode({ job_name = "minio-bucket", metrics_path = "/minio/v2/metrics/bucket", static_configs = [{ targets = ["${var.minio_address}:9000"] }] }),
      jsonencode({ job_name = "minio-resource", metrics_path = "/minio/v2/metrics/resource", static_configs = [{ targets = ["${var.minio_address}:9000"] }] }),
    ],
    var.etcd_metrics_target == "" ? [] : [
      jsonencode({ job_name = "kube-etcd", scheme = "http", static_configs = [{ targets = ["${var.etcd_metrics_target}"] }] }),
    ],
  )
  extra_scrape_configs = "[${join(",", local.extra_scrape_jobs)}]"
}

resource "kubernetes_secret" "prometheus_extra_scrape" {
  metadata {
    name      = "prometheus-extra-scrape"
    namespace = "observability"
  }
  data = {
    # Referenciado pelo additionalScrapeConfigsSecret do kube-prometheus-stack.
    "scrape-configs.yaml" = local.extra_scrape_configs
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.workloads]
}

resource "kubectl_manifest" "local_path_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "local-path-storage"
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  })
  depends_on = [helm_release.cilium]
}

resource "kubectl_manifest" "local_path_service_account" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "local-path-provisioner-service-account"
      namespace = "local-path-storage"
    }
  })
  depends_on = [kubectl_manifest.local_path_namespace]
}

resource "kubectl_manifest" "local_path_role" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "local-path-provisioner-role"
      namespace = "local-path-storage"
    }
    rules = [{
      apiGroups = [""]
      resources = ["pods"]
      verbs     = ["get", "list", "watch", "create", "patch", "update", "delete"]
    }]
  })
  depends_on = [kubectl_manifest.local_path_namespace]
}

resource "kubectl_manifest" "local_path_cluster_role" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata   = { name = "local-path-provisioner-role" }
    rules = [
      {
        apiGroups = [""]
        resources = ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = [""]
        resources = ["persistentvolumes"]
        verbs     = ["get", "list", "watch", "create", "patch", "update", "delete"]
      },
      {
        apiGroups = [""]
        resources = ["events"]
        verbs     = ["create", "patch"]
      },
      {
        apiGroups = ["storage.k8s.io"]
        resources = ["storageclasses"]
        verbs     = ["get", "list", "watch"]
      }
    ]
  })
  depends_on = [kubectl_manifest.local_path_namespace]
}

resource "kubectl_manifest" "local_path_role_binding" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "local-path-provisioner-bind"
      namespace = "local-path-storage"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "local-path-provisioner-role"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = "local-path-provisioner-service-account"
      namespace = "local-path-storage"
    }]
  })
  depends_on = [kubectl_manifest.local_path_role, kubectl_manifest.local_path_service_account]
}

resource "kubectl_manifest" "local_path_cluster_role_binding" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = "local-path-provisioner-bind" }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "local-path-provisioner-role"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = "local-path-provisioner-service-account"
      namespace = "local-path-storage"
    }]
  })
  depends_on = [kubectl_manifest.local_path_cluster_role, kubectl_manifest.local_path_service_account]
}

resource "kubectl_manifest" "local_path_config" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "local-path-config"
      namespace = "local-path-storage"
    }
    data = {
      "config.json"    = local.local_path_config
      setup            = "#!/bin/sh\nset -eu\nmkdir -m 0777 -p \"$VOL_DIR\""
      teardown         = "#!/bin/sh\nset -eu\nrm -rf \"$VOL_DIR\""
      "helperPod.yaml" = local.local_path_helper_pod
    }
  })
  depends_on = [kubectl_manifest.local_path_namespace]
}

resource "kubectl_manifest" "local_path_storage_class" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "local-path"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
    }
    provisioner       = "rancher.io/local-path"
    volumeBindingMode = "WaitForFirstConsumer"
    reclaimPolicy     = "Retain"
  })
  depends_on = [kubectl_manifest.local_path_namespace]
}

resource "kubectl_manifest" "local_path_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "local-path-provisioner"
      namespace = "local-path-storage"
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "local-path-provisioner" } }
      template = {
        metadata = { labels = { app = "local-path-provisioner" } }
        spec = {
          serviceAccountName = "local-path-provisioner-service-account"
          containers = [{
            name            = "local-path-provisioner"
            image           = "docker.io/rancher/local-path-provisioner:v0.0.31@sha256:80496fdeb307541007621959aa13aed41d31db9cd2dc4167c19833e0bfa3878c"
            imagePullPolicy = "IfNotPresent"
            command         = ["local-path-provisioner", "--debug", "start", "--config", "/etc/config/config.json"]
            env = [
              {
                name = "POD_NAMESPACE"
                valueFrom = {
                  fieldRef = { fieldPath = "metadata.namespace" }
                }
              },
              { name = "CONFIG_MOUNT_PATH", value = "/etc/config/" }
            ]
            volumeMounts = [{ name = "config-volume", mountPath = "/etc/config/" }]
          }]
          volumes = [{
            name      = "config-volume"
            configMap = { name = "local-path-config" }
          }]
        }
      }
    }
  })
  depends_on = [
    kubectl_manifest.local_path_config,
    kubectl_manifest.local_path_role_binding,
    kubectl_manifest.local_path_cluster_role_binding
  ]
}

# ---------------------------------------------------------------------------
# 1. Cilium (CNI + kube-proxy replacement) + Hubble
# ---------------------------------------------------------------------------

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  wait    = true
  timeout = 600

  values = [local.cilium_values]
}

# ---------------------------------------------------------------------------
# 2. MetalLB (pool de IPs para Services LoadBalancer)
# ---------------------------------------------------------------------------

# O speaker do MetalLB usa hostNetwork e capabilities NET_RAW (anuncio L2). O
# Talos aplica Pod Security Admission no nivel "baseline" por padrao, que
# barra isso, entao o namespace e criado aqui com o rotulo "privileged" antes
# do chart. O create_namespace do Helm criaria um namespace sem rotulo.
resource "kubectl_manifest" "metallb_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.metallb_namespace
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  })
}

resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = var.metallb_version
  namespace        = var.metallb_namespace
  create_namespace = false

  wait    = true
  timeout = 600

  values = [local.metallb_values]

  depends_on = [helm_release.cilium, kubectl_manifest.metallb_namespace]
}

# As CRs so podem ser aplicadas depois que o chart instala as CRDs. Por isso o
# kubectl_manifest (aplica no apply) e nao o kubernetes_manifest (resolve no
# plan e quebraria o primeiro apply, quando a CRD ainda nao existe).
resource "kubectl_manifest" "metallb_pool" {
  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = "default-pool"
      namespace = var.metallb_namespace
    }
    spec = {
      addresses  = var.metallb_addresses
      autoAssign = true
    }
  })

  depends_on = [helm_release.metallb]
}

resource "kubectl_manifest" "metallb_l2" {
  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata = {
      name      = "default"
      namespace = var.metallb_namespace
    }
    spec = {
      ipAddressPools = ["default-pool"]
    }
  })

  depends_on = [kubectl_manifest.metallb_pool]
}

# ---------------------------------------------------------------------------
# 3. Traefik (ingress; Service LoadBalancer com IP do MetalLB)
# ---------------------------------------------------------------------------

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_version
  namespace        = var.traefik_namespace
  create_namespace = true

  wait    = true
  timeout = 600

  values = [local.traefik_values]

  depends_on = [kubectl_manifest.metallb_l2]
}

# ---------------------------------------------------------------------------
# 4. Argo CD (GitOps; UI atras do Ingress do Traefik)
# ---------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = var.argocd_namespace
  create_namespace = true

  wait    = true
  timeout = 900

  values = [local.argocd_values]

  depends_on = [helm_release.traefik]
}

resource "kubectl_manifest" "argocd_ingress" {
  yaml_body = templatefile("${path.module}/../../clusters/talos/argocd/argocd-ui-ingress.yaml", {
    hostname = var.argocd_hostname
  })

  depends_on = [helm_release.argocd]
}

resource "kubectl_manifest" "argocd_projects" {
  for_each  = toset(["project", "project-observability"])
  yaml_body = file("${path.module}/../../clusters/talos/argocd/${each.value}.yaml")

  depends_on = [helm_release.argocd]
}

resource "kubectl_manifest" "argocd_applications" {
  for_each = toset([
    "application-set-todolist",
    "application-kube-prometheus-stack",
    "application-loki",
    "application-alloy",
    "application-tempo",
    "application-otel-collector",
    "application-ntfy",
    "application-observability",
    "application-hubble",
  ])
  yaml_body = file("${path.module}/../../clusters/talos/argocd/${each.value}.yaml")

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.argocd_projects,
    kubernetes_secret.todolist_auth,
    kubernetes_secret.postgres_credentials,
    kubernetes_secret.grafana_admin,
    kubernetes_secret.ntfy_alertmanager,
    kubernetes_secret.prometheus_extra_scrape,
  ]
}

# ---------------------------------------------------------------------------
# 5. metrics-server (kubectl top)
# ---------------------------------------------------------------------------

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.metrics_server_version
  namespace  = "kube-system"

  wait    = true
  timeout = 600

  values = [local.metrics_server_values]

  depends_on = [helm_release.cilium]
}
