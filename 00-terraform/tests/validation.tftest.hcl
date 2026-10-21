mock_provider "proxmox" {}

# terraform test also loads terraform.tfvars, so pin every input the runs rely on.
variables {
  proxmox_endpoint  = "https://pve.example.com:8006/"
  proxmox_api_token = "terraform@pve!test=00000000-0000-0000-0000-000000000000"
  talos_iso_file_id = "local:iso/talos-v1.14.3-nocloud-amd64.iso"
  talos_platform    = "nocloud"
  vm_defaults       = {}
  network           = {}
  nodes = {
    "talos-01" = { vm_id = 901 }
    "talos-02" = { vm_id = 902 }
    "talos-03" = { vm_id = 903 }
  }
}

run "defaults_are_valid" {
  command = plan

  assert {
    condition     = length(proxmox_virtual_environment_vm.talos) == 3
    error_message = "Default nodes must produce exactly 3 VMs"
  }
}

run "accepts_multiple_nics_and_disks" {
  command = plan

  variables {
    network = {
      interfaces = [
        { bridge = "vmbr0", ipv4_gateway = "192.168.1.1" },
        { bridge = "vmbr1", vlan_id = 20 },
      ]
    }
    vm_defaults = {
      disks = [
        { size_gb = 100 },
        { size_gb = 500, storage = "ceph-hdd" },
      ]
    }
    nodes = {
      "talos-01" = {
        vm_id = 901
        network_interfaces = [
          { ipv4_address = "192.168.1.101/24", mac_address = "BC:24:11:00:00:01" },
          { ipv4_address = "10.0.20.101/24" },
        ]
      }
      "talos-02" = { vm_id = 902, disks = [{ size_gb = 50, storage = "nvme" }] }
    }
  }
}

run "rejects_duplicate_vm_ids" {
  command = plan

  variables {
    nodes = {
      "talos-01" = { vm_id = 901 }
      "talos-02" = { vm_id = 901 }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_ipv4_address_without_prefix" {
  command = plan

  variables {
    nodes = {
      "talos-01" = { vm_id = 901, network_interfaces = [{ ipv4_address = "192.168.1.101" }] }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_duplicate_ipv4_addresses" {
  command = plan

  variables {
    nodes = {
      "talos-01" = { vm_id = 901, network_interfaces = [{ ipv4_address = "192.168.1.101/24" }] }
      "talos-02" = { vm_id = 902, network_interfaces = [{ ipv4_address = "192.168.1.101/24" }] }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_malformed_mac_address" {
  command = plan

  variables {
    nodes = {
      "talos-01" = { vm_id = 901, network_interfaces = [{ mac_address = "BC:24:11:00:00" }] }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_node_name_that_is_not_a_hostname" {
  command = plan

  variables {
    nodes = {
      "talos_01" = { vm_id = 901 }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_unsupported_talos_platform" {
  command = plan

  variables {
    talos_platform = "aws"
  }

  expect_failures = [var.talos_platform]
}

run "rejects_static_ipv4_on_metal_platform" {
  command = plan

  variables {
    talos_platform = "metal"
    nodes = {
      "talos-01" = { vm_id = 901, network_interfaces = [{ ipv4_address = "192.168.1.101/24" }] }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_cloudinit_on_cdrom_interface" {
  command = plan

  variables {
    vm_defaults = { cloudinit_interface = "ide2" }
  }

  expect_failures = [var.vm_defaults]
}

run "rejects_more_node_nics_than_network_interfaces" {
  command = plan

  variables {
    nodes = {
      "talos-01" = {
        vm_id              = 901
        network_interfaces = [{ ipv4_address = "192.168.1.101/24" }, { ipv4_address = "10.0.20.101/24" }]
      }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_node_without_disks" {
  command = plan

  variables {
    nodes = {
      "talos-01" = { vm_id = 901, disks = [] }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_default_disks_empty" {
  command = plan

  variables {
    vm_defaults = { disks = [] }
  }

  expect_failures = [var.vm_defaults]
}

run "rejects_unknown_disk_bus" {
  command = plan

  variables {
    vm_defaults = { disk_bus = "nvme" }
  }

  expect_failures = [var.vm_defaults]
}

run "rejects_cdrom_on_disk_bus" {
  command = plan

  variables {
    vm_defaults = { cdrom_interface = "scsi1" }
  }

  expect_failures = [var.vm_defaults]
}

run "rejects_iso_file_id_without_storage_prefix" {
  command = plan

  variables {
    talos_iso_file_id = "talos-v1.14.3-nocloud-amd64.iso"
  }

  expect_failures = [var.talos_iso_file_id]
}

run "rejects_nested_virtualization_on_cpu_model_without_vmx" {
  command = plan

  variables {
    vm_defaults = { cpu_type = "x86-64-v2-AES" }
  }

  expect_failures = [var.vm_defaults]
}

run "accepts_named_cpu_model_without_nested_virtualization" {
  command = plan

  variables {
    vm_defaults = { cpu_type = "x86-64-v2-AES", nested_virtualization = false }
  }
}
