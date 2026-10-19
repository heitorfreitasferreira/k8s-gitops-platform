terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Provider do libvirt: cria os volumes, dominios e a rede das VMs.
    # Pinado no 0.8.x de proposito: o 0.9.x trocou o schema dos recursos
    # (blocos aninhados) e este modulo segue o schema estavel conhecido.
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9"
    }

    # Provider oficial da Sidero: gera os secrets, a config por role, aplica
    # nos nos, faz o bootstrap do etcd e devolve o kubeconfig.
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }

    # Cria o bucket no MinIO falando S3 com path-style. Pinado no 5.x, serie
    # estavel conhecida; o 6.x mudou defaults de validacao de endpoint.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

# Aponta para o MinIO local com credenciais das variaveis. As validacoes de
# conta/regiao sao desligadas porque o MinIO nao e a AWS real.
provider "aws" {
  access_key = var.minio_root_user
  secret_key = var.minio_root_password
  region     = "us-east-1"

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "http://${cidrhost(var.network_cidr, var.minio_hostnum)}:9000"
  }
}
