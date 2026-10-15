output "kubeconfig" {
  description = "Kubeconfig do cluster. Sensivel: grave em arquivo, nunca no log."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talosconfig (client) do cluster. Sensivel."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "controlplane_endpoint" {
  description = "Endpoint do kube-apiserver (https://<ip-do-cp>:6443)."
  value       = local.controlplane_endpoint
}

output "controlplane_ips" {
  description = "IPs dos nos de control plane."
  value       = [for node in local.controlplane_nodes : node.address]
}

output "worker_ips" {
  description = "IPs dos workers."
  value       = [for node in local.worker_nodes : node.address]
}

output "node_ips" {
  description = "Mapa nome -> IP de todos os nos (estaticos na rede NAT)."
  value       = { for node in local.nodes : node.name => node.address }
}
