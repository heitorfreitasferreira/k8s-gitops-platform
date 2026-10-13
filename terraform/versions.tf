terraform {
  required_version = ">= 1.5.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Estado local por padrao (projeto de portfolio, um operador). Em time real,
  # backend remoto com lock, para ninguem aplicar em paralelo sobre o mesmo estado.
  # Descomente e preencha para usar S3 + DynamoDB:
  #
  # backend "s3" {
  #   bucket         = "REPLACE-me-tfstate"
  #   key            = "gitops-platform/terraform.tfstate"
  #   region         = "REPLACE-me"
  #   dynamodb_table = "REPLACE-me-tf-lock"
  #   encrypt        = true
  # }
}
