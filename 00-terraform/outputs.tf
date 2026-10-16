output "talos_schematic_id" {
  description = "Image Factory schematic ID (extensions + kernel args)"
  value       = talos_image_factory_schematic.this.id
}

output "talos_installer_image" {
  description = "Installer image to put into machine.install.image of the Talos machine config"
  value       = data.talos_image_factory_urls.this.urls.installer
}

output "talos_iso_file_id" {
  description = "Proxmox file ID of the downloaded Talos ISO"
  value       = proxmox_download_file.talos_iso.id
}

output "nodes" {
  description = "Created VMs: ID, MAC and IPv4 address (static from vars, otherwise reported by the QEMU guest agent)"
  value = {
    for name, vm in proxmox_virtual_environment_vm.talos : name => {
      vm_id       = vm.vm_id
      mac_address = try(vm.mac_addresses[0], null)
      ipv4_address = coalesce(
        local.nodes_resolved[name].ipv4_host,
        try([for ip in flatten(vm.ipv4_addresses) : ip if ip != "127.0.0.1"][0], null),
        "unknown",
      )
    }
  }
}
