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

output "minio_endpoint" {
  description = "Endpoint S3 do MinIO na rede interna (http://<ip>:9000). A API nao e exposta na LAN."
  value       = local.minio_endpoint
}

output "minio_ip" {
  description = "IP reservado para a VM MinIO na rede NAT libvirt local."
  value       = local.minio_address
}

output "minio_bucket" {
  description = "Bucket S3 criado no MinIO."
  value       = aws_s3_bucket.minio.bucket
}

output "minio_root_user" {
  description = "Usuario root do MinIO (nao sensivel; a senha sai so por variavel)."
  value       = var.minio_root_user
}

output "node_ips" {
  description = "Mapa nome -> IP de todos os nos (estaticos na rede NAT)."
  value       = { for node in local.nodes : node.name => node.address }
}
