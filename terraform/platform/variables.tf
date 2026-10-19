variable "kubeconfig_path" {
  description = <<-EOT
    Caminho do kubeconfig do cluster Talos, gerado pelo modulo `infra`:

      cd terraform/infra && terraform output -raw kubeconfig > ~/.kube/talos-kubeconfig

    O modulo le o arquivo para falar com o cluster e para descobrir o endpoint
    do kube-apiserver (usado pelo Cilium em modo kube-proxy-free).
  EOT
  type        = string
  default     = "~/.kube/talos-kubeconfig"
}

variable "cilium_version" {
  description = "Versao do chart do Cilium (chart e app version coincidem)."
  type        = string
  default     = "1.20.3"
}

variable "metallb_version" {
  description = "Versao do chart do MetalLB."
  type        = string
  default     = "0.16.1"
}

variable "traefik_version" {
  description = "Versao do chart do Traefik."
  type        = string
  default     = "42.0.0"
}

variable "argocd_version" {
  description = "Versao do chart do Argo CD."
  type        = string
  default     = "10.10.5"
}

variable "metrics_server_version" {
  description = "Versao do chart do metrics-server."
  type        = string
  default     = "3.14.0"
}

variable "metallb_namespace" {
  description = "Namespace do MetalLB."
  type        = string
  default     = "metallb-system"
}

variable "metallb_addresses" {
  description = <<-EOT
    Faixas do pool de IPs do MetalLB, na mesma rede das VMs. A rede NAT do
    libvirt usa 192.168.122.0/24 e as VMs ficam em .10-.12, entao o pool ocupa
    o fim da faixa para nao colidir.
  EOT
  type        = list(string)
  default     = ["192.168.122.200-192.168.122.210"]
}

variable "traefik_namespace" {
  description = "Namespace do Traefik."
  type        = string
  default     = "traefik"
}

variable "argocd_namespace" {
  description = "Namespace do Argo CD."
  type        = string
  default     = "argocd"
}

variable "argocd_hostname" {
  description = "Host local da UI do Argo CD."
  type        = string
  default     = "argocd.local"
}

variable "minio_address" {
  description = <<-EOT
    IP da VM do MinIO na rede NAT do libvirt, para o Prometheus raspar o
    node_exporter (:9100) e as metricas do MinIO (:9000). Vazio desliga os
    scrapes. O valor vem do output `minio_ip` do modulo `infra`, passado pelo
    Makefile, entao nao fica no Git.
  EOT
  type        = string
  default     = ""
}

variable "etcd_metrics_target" {
  description = <<-EOT
    Alvo host:2381 do scrape das metricas do etcd do Talos (primeiro control
    plane). Vazio desliga o scrape. Vem do output `etcd_metrics_target` do
    modulo `infra` (o Makefile passa), entao nao fica no Git.
  EOT
  type        = string
  default     = ""
}
