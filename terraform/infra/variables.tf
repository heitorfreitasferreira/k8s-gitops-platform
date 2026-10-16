variable "cluster_name" {
  description = "Nome do cluster Talos. Tambem vira prefixo dos nomes das VMs."
  type        = string
  default     = "talos"
}

variable "libvirt_uri" {
  description = "URI libvirt detectada pelo setup-host.sh ou configurada pelo operador."
  type        = string
  default     = null
}

variable "storage_pool" {
  description = "Pool ativo detectado pelo setup-host.sh ou configurado pelo operador."
  type        = string
  default     = null
}

variable "network_name" {
  description = "Rede NAT libvirt detectada pelo setup-host.sh ou configurada pelo operador."
  type        = string
  default     = null
}

variable "network_cidr" {
  description = "CIDR da rede libvirt configurada no terraform.tfvars local, detectada pelo script de setup."
  type        = string
  default     = null

  validation {
    condition     = var.network_cidr == null || can(cidrhost(var.network_cidr, 1))
    error_message = "network_cidr deve ser um CIDR IPv4 valido, detectado da rede libvirt local."
  }
}

variable "controlplane_hostnum_start" {
  description = "Hostnum do primeiro control plane dentro do network_cidr (.10 -> IP .10)."
  type        = number
  default     = 10
}

variable "worker_hostnum_start" {
  description = "Hostnum do primeiro worker dentro do network_cidr (.11 -> IP .11)."
  type        = number
  default     = 11
}

variable "controlplane_count" {
  description = "Numero de nos de control plane."
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Numero de workers."
  type        = number
  default     = 2
}

variable "talos_version" {
  description = "Versao do Talos (sem o 'v'). Precisa existir na Image Factory."
  type        = string
  default     = "1.13.3"
}

variable "kubernetes_version" {
  description = "Versao do Kubernetes. Vazio deixa o provider escolher a compativel com o Talos."
  type        = string
  default     = null
}

variable "image_schematic_id" {
  description = <<-EOT
    ID do schematic da Image Factory (https://factory.talos.dev) com as
    extensoes embutidas. O default corresponde ao YAML:

      customization:
        systemExtensions:
          officialExtensions:
            - siderolabs/qemu-guest-agent
            - siderolabs/iscsi-tools

    Regenere com:
      curl -sS -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
  EOT
  type        = string
  default     = "6ebbfe35c8225645c05d4d19eaad385bd1ec795954932d0ada671388272fec19"
}

variable "image_platform" {
  description = "Plataforma da imagem na Image Factory."
  type        = string
  default     = "metal"
}

variable "image_architecture" {
  description = "Arquitetura da imagem."
  type        = string
  default     = "amd64"
}

variable "vcpu" {
  description = "vCPUs por VM."
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Memoria (MiB) por VM."
  type        = number
  default     = 4096
}

variable "disk_size_gb" {
  description = "Tamanho do disco (GiB) de cada no. O Talos cresce as particoes no boot."
  type        = number
  default     = 20
}

variable "debian_image_url" {
  description = "Imagem cloud do Debian 12 (genericcloud, com cloud-init). Vira o disco da VM do MinIO."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
}

variable "minio_vcpu" {
  description = "vCPUs da VM do MinIO."
  type        = number
  default     = 1
}

variable "minio_memory_mb" {
  description = "Memoria (MiB) da VM do MinIO."
  type        = number
  default     = 2048
}

variable "minio_disk_size_gb" {
  description = "Tamanho do disco (GiB) da VM do MinIO. O cloud-init cresce a particao no boot."
  type        = number
  default     = 20
}

variable "minio_machine_type" {
  description = <<-EOT
    Tipo de maquina qemu da VM do MinIO. E "pc" (i440fx) de proposito: o
    provider libvirt 0.8.3 anexa o ISO do cloud-init como cdrom IDE, que o
    QEMU nao aceita no q35. A imagem Debian da boot por BIOS sem problema.
  EOT
  type        = string
  default     = "pc"
}

variable "minio_hostnum" {
  description = "Hostnum do MinIO dentro do network_cidr (.20 -> IP .20)."
  type        = number
  default     = 20
}

variable "minio_root_user" {
  description = "Usuario root do MinIO (MINIO_ROOT_USER). Troque no tfvars, nunca commite segredo."
  type        = string
  default     = "minioadmin"
}

variable "minio_root_password" {
  description = "Senha root do MinIO (MINIO_ROOT_PASSWORD, minimo 8 chars). Troque no tfvars, nunca commite."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.minio_root_password == null || length(var.minio_root_password) >= 8
    error_message = "minio_root_password deve ter pelo menos 8 caracteres."
  }
}

variable "minio_release" {
  description = <<-EOT
    Release do MinIO instalado na VM. Pinado no ultimo release legado com
    binario pre-compilado: o dl.min.io responde 410 Gone desde que a edicao
    comunitaria virou so codigo fonte.
  EOT
  type        = string
  default     = "RELEASE.2025-09-07T16-13-09Z"
}

variable "minio_ssh_pubkey" {
  description = "Chave publica SSH do operador, instalada no usuario debian da VM. Passe por -var ou tfvars local, nunca commite."
  type        = string
  default     = null

  validation {
    condition     = var.minio_ssh_pubkey == null || can(regex("^ssh-(ed25519|rsa|ecdsa)", var.minio_ssh_pubkey))
    error_message = "minio_ssh_pubkey deve conter uma chave publica SSH reconhecida."
  }
}

variable "minio_bucket_name" {
  description = "Bucket unico do MinIO (backups do Postgres e demonstracao de S3)."
  type        = string
  default     = "postgres-backups"
}

variable "machine_type" {
  description = "Tipo de maquina qemu (q35 e o recomendado para UEFI)."
  type        = string
  default     = "q35"
}

variable "firmware_path" {
  description = "Caminho do firmware UEFI (OVMF) detectado pelo setup-host.sh ou configurado pelo operador."
  type        = string
  default     = null
}
