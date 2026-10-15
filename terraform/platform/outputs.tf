output "api_server" {
  description = "Endpoint do kube-apiserver lido do kubeconfig (usado pelo Cilium no modo kube-proxy-free)."
  value       = local.kube_cluster.server
}

output "metallb_addresses" {
  description = "Faixas do pool de IPs do MetalLB."
  value       = var.metallb_addresses
}

output "traefik_namespace" {
  description = "Namespace onde o Traefik foi instalado."
  value       = helm_release.traefik.namespace
}

output "argocd_url" {
  description = "URL da UI do Argo CD (via Ingress do Traefik)."
  value       = "http://${var.argocd_hostname}"
}

output "hubble_url" {
  description = "URL da UI do Hubble (via Ingress do Traefik)."
  value       = "http://${var.hubble_hostname}"
}
