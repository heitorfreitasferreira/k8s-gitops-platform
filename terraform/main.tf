locals {
  repo_root  = abspath("${path.module}/..")
  k3d_config = coalesce(var.k3d_config_path, "${local.repo_root}/clusters/local/k3d-config.yaml")
  # O hash entra nos triggers: mudar a topologia (portas, nodes, imagem do k3s)
  # recria o cluster, em vez de deixar um ambiente que nao corresponde ao codigo.
  config_hash = fileexists(local.k3d_config) ? filesha256(local.k3d_config) : "config-ausente"
  kubeconfig  = pathexpand(var.kubeconfig_path)
}

# O cluster e a unica parte que o Terraform gerencia. Os workloads (app,
# observabilidade, sealed-secrets) continuam no Git e sao entregues pelo Argo
# CD: o Terraform nao duplica manifests de aplicacao, para nao criar uma segunda
# fonte de verdade.
resource "null_resource" "cluster" {
  triggers = {
    cluster_name = var.cluster_name
    config_hash  = local.config_hash
    kubeconfig   = local.kubeconfig
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      K3D_CONFIG = local.k3d_config
    }
    # Idempotente: cria so se o cluster nao existir. O k3d escreve o kubeconfig
    # no caminho do k3d-config.yaml, que aponta para o arquivo isolado.
    command = <<-EOT
      set -euo pipefail
      if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx '${var.cluster_name}'; then
        echo "cluster '${var.cluster_name}' ja existe, nada a fazer"
      else
        k3d cluster create --config "$K3D_CONFIG"
      fi
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "k3d cluster delete '${self.triggers.cluster_name}' || true"
  }
}
