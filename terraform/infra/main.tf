# Infra pesada do cluster: VMs Talos no libvirt + bootstrap.
#
# Este modulo cuida so do cluster (VMs, rede, bootstrap). Os workloads
# continuam entregues pelo Argo CD, que e a fonte de verdade dos manifests.

locals {
  talos_version_tag = "v${var.talos_version}"

  # MAC fixo por no: sem isso o libvirt sorteia um MAC novo a cada apply, a
  # reserva DHCP muda de dono e o IP estatico deixa de ser estavel.
  controlplane_nodes = [
    for i in range(var.controlplane_count) : {
      name    = "${var.cluster_name}-cp-${i + 1}"
      role    = "controlplane"
      address = cidrhost(var.network_cidr, var.controlplane_hostnum_start + i)
      mac     = format("52:54:00:ca:fe:%02x", i + 1)
    }
  ]

  worker_nodes = [
    for i in range(var.worker_count) : {
      name    = "${var.cluster_name}-worker-${i + 1}"
      role    = "worker"
      address = cidrhost(var.network_cidr, var.worker_hostnum_start + i)
      mac     = format("52:54:00:be:ef:%02x", i + 1)
    }
  ]

  nodes = concat(local.controlplane_nodes, local.worker_nodes)

  # Endpoint do kube-apiserver: o IP do primeiro control plane.
  controlplane_endpoint = "https://${local.controlplane_nodes[0].address}:6443"

  # Imagem da Image Factory: ja vem no formato qcow2, com qemu-guest-agent e
  # iscsi-tools embutidos pelo schematic. Sem download manual e sem descompactar.
  image_url = "https://factory.talos.dev/image/${var.image_schematic_id}/${local.talos_version_tag}/${var.image_platform}-${var.image_architecture}.qcow2"

  # Rede fica fora daqui: o Cilium entra na camada do platform.
  # - cni = none: o Talos nao sobe CNI proprio.
  # - proxy.disabled: o Cilium roda em modo kube-proxy-free, entao o
  #   kube-proxy do Talos precisa estar desligado (os dois juntos brigariam
  #   pelas mesmas rotas).
  base_config_patches = [
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "local-path-provisioner"
      volumeType = "directory"
    }),
  ]
}

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------

# Volume base: uma copia da imagem Talos no pool. Os volumes dos nos viram
# camadas CoW sobre ele, entao a imagem de ~216 MB e baixada uma unica vez.
resource "libvirt_volume" "base" {
  name   = "${var.cluster_name}-talos-${var.talos_version}.qcow2"
  pool   = var.storage_pool
  source = local.image_url
  format = "qcow2"
}

resource "libvirt_volume" "controlplane" {
  count          = var.controlplane_count
  name           = "${local.controlplane_nodes[count.index].name}.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.base.id
  format         = "qcow2"
  size           = var.disk_size_gb * 1024 * 1024 * 1024
}

resource "libvirt_volume" "worker" {
  count          = var.worker_count
  name           = "${local.worker_nodes[count.index].name}.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.base.id
  format         = "qcow2"
  size           = var.disk_size_gb * 1024 * 1024 * 1024
}

# ---------------------------------------------------------------------------
# VMs
# ---------------------------------------------------------------------------

resource "libvirt_domain" "controlplane" {
  count      = var.controlplane_count
  name       = local.controlplane_nodes[count.index].name
  type       = "kvm"
  vcpu       = var.vcpu
  memory     = var.memory_mb
  machine    = var.machine_type
  firmware   = var.firmware_path
  qemu_agent = true

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.controlplane[count.index].id
    scsi      = true
  }

  network_interface {
    network_name   = var.network_name
    mac            = local.controlplane_nodes[count.index].mac
    addresses      = [local.controlplane_nodes[count.index].address]
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  lifecycle {
    ignore_changes = [
      nvram,
      disk[0].wwn,
      network_interface[0].addresses,
    ]
  }
}

resource "libvirt_domain" "worker" {
  count      = var.worker_count
  name       = local.worker_nodes[count.index].name
  type       = "kvm"
  vcpu       = var.vcpu
  memory     = var.memory_mb
  machine    = var.machine_type
  firmware   = var.firmware_path
  qemu_agent = true

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.worker[count.index].id
    scsi      = true
  }

  network_interface {
    network_name   = var.network_name
    mac            = local.worker_nodes[count.index].mac
    addresses      = [local.worker_nodes[count.index].address]
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  lifecycle {
    ignore_changes = [
      nvram,
      disk[0].wwn,
      network_interface[0].addresses,
    ]
  }
}

# ---------------------------------------------------------------------------
# Talos: secrets -> config por role -> apply -> bootstrap -> kubeconfig
# ---------------------------------------------------------------------------

resource "talos_machine_secrets" "this" {
  talos_version = local.talos_version_tag
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.controlplane_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version_tag
  kubernetes_version = var.kubernetes_version
  config_patches     = local.base_config_patches
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.controlplane_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version_tag
  kubernetes_version = var.kubernetes_version
  config_patches     = local.base_config_patches
}

resource "talos_machine_configuration_apply" "controlplane" {
  count                       = var.controlplane_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.controlplane_nodes[count.index].address
  endpoint                    = local.controlplane_nodes[count.index].address
  config_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = local.controlplane_nodes[count.index].name
    }),
    # Expor as metricas do etcd em :2381 (todas as interfaces, HTTP). O
    # Prometheus raspa esse endpoint para o alerta de quorum. Sem o patch o etcd
    # so serve /metrics na porta de cliente (2379, mTLS).
    yamlencode({
      cluster = {
        etcd = {
          extraArgs = {
            listen-metrics-urls = "http://0.0.0.0:2381"
          }
        }
      }
    }),
  ]
  depends_on = [libvirt_domain.controlplane]
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = local.worker_nodes[count.index].address
  endpoint                    = local.worker_nodes[count.index].address
  config_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = local.worker_nodes[count.index].name
    }),
  ]
  depends_on = [libvirt_domain.worker]
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_nodes[0].address
  endpoint             = local.controlplane_nodes[0].address
  depends_on           = [talos_machine_configuration_apply.controlplane]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.controlplane_nodes[0].address]
  nodes                = [for node in local.nodes : node.address]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_nodes[0].address
  endpoint             = local.controlplane_nodes[0].address
  depends_on           = [talos_machine_bootstrap.this]
}
