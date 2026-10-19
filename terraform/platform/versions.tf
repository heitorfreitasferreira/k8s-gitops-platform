terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Helm: instala os componentes de plataforma (Cilium, MetalLB, Traefik,
    # Argo CD e metrics-server) a partir dos charts oficiais pinados.
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }

    # kubectl: aplica os CRs do MetalLB (IPAddressPool e L2Advertisement), que
    # so existem depois que o chart instala as CRDs. O kubernetes_manifest
    # resolveria isso no plan e quebraria o primeiro apply.
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.4.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Estado local por padrao (projeto de portfolio, um operador). Em time real,
  # backend remoto com lock. Descomente e preencha para usar S3 + DynamoDB:
  #
  # backend "s3" {
  #   bucket         = "REPLACE-me-tfstate"
  #   key            = "gitops-platform/talos-platform.tfstate"
  #   region         = "REPLACE-me"
  #   dynamodb_table = "REPLACE-me-tf-lock"
  #   encrypt        = true
  # }
}

provider "helm" {
  kubernetes = {
    config_path = pathexpand(var.kubeconfig_path)
  }
}

provider "kubectl" {
  config_path      = pathexpand(var.kubeconfig_path)
  load_config_file = true
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}
