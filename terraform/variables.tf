variable "cluster_name" {
  description = "Nome do cluster k3d gerenciado por este modulo."
  type        = string
  default     = "local"
}

variable "kubeconfig_path" {
  description = "Onde o k3d escreve o kubeconfig isolado do cluster."
  type        = string
  default     = "~/.kube/local-k3d.kubeconfig"
}

variable "k3d_config_path" {
  description = "Manifesto k3d-config.yaml que descreve o cluster (fonte de verdade da topologia)."
  type        = string
  default     = null
}
