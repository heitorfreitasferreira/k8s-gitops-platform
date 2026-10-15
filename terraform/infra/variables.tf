variable "cluster_name" {
  description = "Nome do cluster Talos. Tambem vira prefixo dos nomes das VMs."
  type        = string
  default     = "talos"
}

variable "libvirt_uri" {
  description = "URI de conexao do libvirt. qemu:///system usa a rede NAT padrao (virbr0) e exige o grupo libvirt."
  type        = string
  default     = "qemu:///system"
}

variable "storage_pool" {
  description = "Pool de storage do libvirt onde ficam os volumes qcow2."
  type        = string
  default     = "default"
}

variable "network_name" {
  description = "Rede libvirt a que as VMs se conectam. 'default' e a rede NAT padrao do libvirt (virbr0)."
  type        = string
  default     = "default"
}

variable "network_cidr" {
  description = "CIDR da rede NAT padrao do libvirt. Os IPs estaticos saem daqui."
  type        = string
  default     = "192.168.122.0/24"
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

variable "machine_type" {
  description = "Tipo de maquina qemu (q35 e o recomendado para UEFI)."
  type        = string
  default     = "q35"
}

variable "firmware_path" {
  description = "Caminho do firmware UEFI (OVMF) no host. No Arch/Omarchy: /usr/share/edk2/x64/OVMF_CODE.4m.fd."
  type        = string
  default     = "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
}
