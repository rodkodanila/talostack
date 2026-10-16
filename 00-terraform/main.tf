locals {
  # System disk interface split into bus and index, e.g. scsi0 -> ["scsi", "0"];
  # extra disks continue on the same bus: scsi1, scsi2, ...
  disk_bus   = regex("^([a-z]+)(\\d+)$", var.vm_defaults.disk_interface)[0]
  disk_index = tonumber(regex("^([a-z]+)(\\d+)$", var.vm_defaults.disk_interface)[1])

  # var.nodes with per-node overrides resolved against var.vm_defaults.
  nodes_resolved = {
    for name, node in var.nodes : name => {
      vm_id        = node.vm_id
      cpu_cores    = coalesce(node.cpu_cores, var.vm_defaults.cpu_cores)
      memory_mb    = coalesce(node.memory_mb, var.vm_defaults.memory_mb)
      mac_address  = node.mac_address
      ipv4_address = node.ipv4_address
      ipv4_host    = node.ipv4_address != null ? split("/", node.ipv4_address)[0] : null
      tags         = distinct(concat(var.vm_defaults.tags, node.tags))
      disks = concat(
        [{
          interface    = var.vm_defaults.disk_interface
          datastore_id = var.vm_defaults.datastore_id
          size_gb      = coalesce(node.disk_size_gb, var.vm_defaults.disk_size_gb)
        }],
        [
          for i, d in(node.extra_disks != null ? node.extra_disks : var.vm_defaults.extra_disks) : {
            interface    = "${local.disk_bus}${local.disk_index + i + 1}"
            datastore_id = coalesce(d.datastore_id, var.vm_defaults.datastore_id)
            size_gb      = d.size_gb
          }
        ],
      )
    }
  }

  cloudinit_enabled = var.talos_platform == "nocloud"
}

# --- Talos ISO ----------------------------------------------------------------

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      extraKernelArgs = var.talos_extra_kernel_args
      systemExtensions = {
        officialExtensions = var.talos_extensions
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = var.talos_platform
  architecture  = var.talos_architecture
}

resource "proxmox_download_file" "talos_iso" {
  node_name      = var.proxmox_node
  datastore_id   = var.iso_datastore_id
  content_type   = "iso"
  url            = data.talos_image_factory_urls.this.urls.iso
  file_name      = "talos-${var.talos_version}-${var.talos_platform}-${var.talos_architecture}-${substr(talos_image_factory_schematic.this.id, 0, 12)}.iso"
  upload_timeout = var.iso_upload_timeout
  overwrite      = false

  # A new Talos version/schematic yields a new file name; keep the old ISO
  # until every VM's cdrom has been switched to the new one.
  lifecycle {
    create_before_destroy = true
  }
}

# --- VMs ----------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.nodes_resolved

  name        = each.key
  vm_id       = each.value.vm_id
  node_name   = var.proxmox_node
  description = var.vm_defaults.description
  tags        = each.value.tags
  pool_id     = var.vm_defaults.pool_id

  bios          = var.vm_defaults.bios
  machine       = var.vm_defaults.machine
  scsi_hardware = var.vm_defaults.scsi_hardware

  on_boot         = var.vm_defaults.on_boot
  started         = var.vm_defaults.started
  protection      = var.vm_defaults.protection
  stop_on_destroy = var.vm_defaults.stop_on_destroy

  # The system disk is empty on first boot, so the VM falls through to the ISO;
  # once Talos is installed it boots from disk.
  boot_order = [var.vm_defaults.disk_interface, var.vm_defaults.cdrom_interface]

  operating_system {
    type = var.vm_defaults.os_type
  }

  cpu {
    cores   = each.value.cpu_cores
    sockets = var.vm_defaults.cpu_sockets
    type    = var.vm_defaults.cpu_type
  }

  # Talos does not support memory ballooning.
  memory {
    dedicated = each.value.memory_mb
    floating  = 0
  }

  agent {
    enabled = var.vm_defaults.agent_enabled
    timeout = var.vm_defaults.agent_timeout

    # Talos runs no extensions (so no guest agent) in maintenance mode;
    # waiting for an IP right after creation would only hit the timeout.
    wait_for_ip {
      disabled = !var.vm_defaults.agent_wait_for_ipv4
      ipv4     = var.vm_defaults.agent_wait_for_ipv4
    }
  }

  dynamic "efi_disk" {
    for_each = var.vm_defaults.bios == "ovmf" ? [1] : []
    content {
      datastore_id      = var.vm_defaults.datastore_id
      type              = var.vm_defaults.efi_disk_type
      pre_enrolled_keys = false
    }
  }

  cdrom {
    interface = var.vm_defaults.cdrom_interface
    file_id   = proxmox_download_file.talos_iso.id
  }

  dynamic "disk" {
    for_each = each.value.disks
    content {
      interface    = disk.value.interface
      datastore_id = disk.value.datastore_id
      size         = disk.value.size_gb
      file_format  = var.vm_defaults.disk_file_format
      cache        = var.vm_defaults.disk_cache
      discard      = var.vm_defaults.disk_discard
      ssd          = var.vm_defaults.disk_ssd
      iothread     = var.vm_defaults.disk_iothread
    }
  }

  network_device {
    bridge      = var.network.bridge
    vlan_id     = var.network.vlan_id
    model       = var.network.model
    mtu         = var.network.mtu
    firewall    = var.network.firewall
    mac_address = each.value.mac_address
  }

  # Talos nocloud reads hostname (the VM name) and network config from this drive.
  dynamic "initialization" {
    for_each = local.cloudinit_enabled ? [1] : []
    content {
      interface    = var.vm_defaults.cloudinit_interface
      datastore_id = coalesce(var.vm_defaults.cloudinit_datastore_id, var.vm_defaults.datastore_id)

      ip_config {
        ipv4 {
          address = coalesce(each.value.ipv4_address, "dhcp")
          gateway = each.value.ipv4_address != null ? var.network.ipv4_gateway : null
        }
      }

      dynamic "dns" {
        for_each = length(var.network.dns_servers) > 0 || var.network.dns_domain != null ? [1] : []
        content {
          servers = var.network.dns_servers
          domain  = var.network.dns_domain
        }
      }
    }
  }
}
