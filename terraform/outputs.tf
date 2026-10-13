output "cluster_name" {
  description = "Nome do cluster gerenciado."
  value       = var.cluster_name
}

output "kubeconfig_path" {
  description = "Kubeconfig isolado. Exporte antes de usar kubectl."
  value       = local.kubeconfig
}

output "next_steps" {
  description = "O que rodar depois do apply para ter a plataforma no ar."
  value       = "export KUBECONFIG=${local.kubeconfig} && ./bootstrap.sh"
}
