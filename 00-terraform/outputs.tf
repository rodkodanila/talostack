output "nodes" {
  description = "Created VMs: ID, MACs and IPv4 addresses (static from vars, otherwise reported by the QEMU guest agent)"
  value = {
    for name, vm in proxmox_virtual_environment_vm.talos : name => {
      vm_id         = vm.vm_id
      mac_addresses = vm.mac_addresses
      ipv4_static   = [for nic in local.nodes_resolved[name].network_interfaces : nic.ipv4_host]
      ipv4_agent    = [for ip in flatten(vm.ipv4_addresses) : ip if ip != "127.0.0.1"]
    }
  }
}
