locals {
  # var.nodes with per-node overrides resolved against var.vm_defaults and var.network.
  nodes_resolved = {
    for name, node in var.nodes : name => {
      vm_id     = node.vm_id
      cpu_cores = coalesce(node.cpu_cores, var.vm_defaults.cpu_cores)
      memory_mb = coalesce(node.memory_mb, var.vm_defaults.memory_mb)
      tags      = distinct(concat(var.vm_defaults.tags, node.tags))

      disks = [
        for i, d in(node.disks != null ? node.disks : var.vm_defaults.disks) : merge(d, {
          interface = "${var.vm_defaults.disk_bus}${i}"
          storage   = coalesce(d.storage, var.vm_defaults.datastore_id)
          # Proxmox rejects ssd on virtio-blk and iothread on sata.
          ssd      = var.vm_defaults.disk_bus == "virtio" ? null : d.ssd
          iothread = var.vm_defaults.disk_bus == "sata" ? null : d.iothread
        })
      ]

      network_interfaces = [
        for i, nic in var.network.interfaces : merge(nic, {
          mac_address  = try(node.network_interfaces[i].mac_address, null)
          ipv4_address = try(node.network_interfaces[i].ipv4_address, null)
          ipv4_host    = try(split("/", node.network_interfaces[i].ipv4_address)[0], null)
        })
      ]
    }
  }

  cloudinit_enabled = var.talos_platform == "nocloud"
}

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

  # The boot disk is empty on first boot, so the VM falls through to the ISO;
  # once Talos is installed it boots from disk.
  boot_order = [each.value.disks[0].interface, var.vm_defaults.cdrom_interface]

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
    file_id   = var.talos_iso_file_id
  }

  dynamic "disk" {
    for_each = each.value.disks
    content {
      interface    = disk.value.interface
      datastore_id = disk.value.storage
      size         = disk.value.size_gb
      file_format  = disk.value.file_format
      cache        = disk.value.cache
      discard      = disk.value.discard
      ssd          = disk.value.ssd
      iothread     = disk.value.iothread
      backup       = disk.value.backup
    }
  }

  dynamic "network_device" {
    for_each = each.value.network_interfaces
    content {
      bridge      = network_device.value.bridge
      vlan_id     = network_device.value.vlan_id
      model       = network_device.value.model
      mtu         = network_device.value.mtu
      firewall    = network_device.value.firewall
      queues      = network_device.value.queues
      rate_limit  = network_device.value.rate_limit
      mac_address = network_device.value.mac_address
    }
  }

  # Talos nocloud reads hostname (the VM name) and network config from this drive;
  # ip_config entries map to network devices by position.
  dynamic "initialization" {
    for_each = local.cloudinit_enabled ? [1] : []
    content {
      interface    = var.vm_defaults.cloudinit_interface
      datastore_id = coalesce(var.vm_defaults.cloudinit_datastore_id, var.vm_defaults.datastore_id)

      dynamic "ip_config" {
        for_each = each.value.network_interfaces
        content {
          ipv4 {
            address = coalesce(ip_config.value.ipv4_address, "dhcp")
            gateway = ip_config.value.ipv4_address != null ? ip_config.value.ipv4_gateway : null
          }
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
