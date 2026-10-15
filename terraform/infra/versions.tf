terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Provider do libvirt: cria os volumes, dominios e a rede das VMs.
    # Pinado no 0.8.x de proposito: o 0.9.x trocou o schema dos recursos
    # (blocos aninhados) e este modulo segue o schema estavel conhecido.
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.8.3"
    }

    # Provider oficial da Sidero: gera os secrets, a config por role, aplica
    # nos nos, faz o bootstrap do etcd e devolve o kubeconfig.
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }

  # Estado local por padrao (projeto de portfolio, um operador). Em time real,
  # backend remoto com lock, para ninguem aplicar em paralelo sobre o mesmo
  # estado. Descomente e preencha para usar S3 + DynamoDB:
  #
  # backend "s3" {
  #   bucket         = "REPLACE-me-tfstate"
  #   key            = "gitops-platform/talos-infra.tfstate"
  #   region         = "REPLACE-me"
  #   dynamodb_table = "REPLACE-me-tf-lock"
  #   encrypt        = true
  # }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

provider "talos" {}
