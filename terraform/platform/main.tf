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
# O Terraform instala os componentes; os workloads continuam no Argo CD. Aqui
# nao entra manifest de aplicacao, para nao criar uma segunda fonte de verdade.

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
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
        ingress:
          enabled: true
          className: traefik
          hosts:
            - ${var.hubble_hostname}
  YAML

  # frrk8s (BGP via FRR) desligado: o pool aqui e anunciado em L2, entao o
  # backend FRR e peso morto.
  metallb_values = <<-YAML
    crds:
      enabled: true
    frrk8s:
      enabled: false
  YAML

  traefik_values = <<-YAML
    service:
      type: LoadBalancer
    ingressClass:
      enabled: true
      isDefaultClass: true
  YAML

  argocd_values = <<-YAML
    configs:
      params:
        server.insecure: true
    server:
      service:
        type: ClusterIP
      ingress:
        enabled: true
        ingressClassName: traefik
        hostname: ${var.argocd_hostname}
  YAML

  # Talos usa certificado self-signed no kubelet; sem --kubelet-insecure-tls o
  # metrics-server nao consegue falar com o kubelet e /apis/metrics.k8s.io fica
  # indisponivel.
  metrics_server_values = <<-YAML
    args:
      - --kubelet-insecure-tls
  YAML
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
