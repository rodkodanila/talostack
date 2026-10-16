mock_provider "proxmox" {}
mock_provider "talos" {}

variables {
  proxmox_endpoint  = "https://pve.example.com:8006/"
  proxmox_api_token = "terraform@pve!test=00000000-0000-0000-0000-000000000000"
}

run "defaults_are_valid" {
  command = plan

  assert {
    condition     = length(proxmox_virtual_environment_vm.talos) == 3
    error_message = "Default nodes must produce exactly 3 VMs"
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
    network = { ipv4_gateway = "192.168.1.1" }
    nodes = {
      "talos-01" = { vm_id = 901, ipv4_address = "192.168.1.101" }
    }
  }

  expect_failures = [var.nodes]
}

run "accepts_static_ipv4_with_gateway" {
  command = plan

  variables {
    network = { ipv4_gateway = "192.168.1.1" }
    nodes = {
      "talos-01" = { vm_id = 901, ipv4_address = "192.168.1.101/24" }
      "talos-02" = { vm_id = 902 }
    }
  }
}

run "rejects_static_ipv4_without_gateway" {
  command = plan

  variables {
    nodes = {
      "talos-01" = { vm_id = 901, ipv4_address = "192.168.1.101/24" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_duplicate_ipv4_addresses" {
  command = plan

  variables {
    network = { ipv4_gateway = "192.168.1.1" }
    nodes = {
      "talos-01" = { vm_id = 901, ipv4_address = "192.168.1.101/24" }
      "talos-02" = { vm_id = 902, ipv4_address = "192.168.1.101/24" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_malformed_mac_address" {
  command = plan

  variables {
    nodes = {
      "talos-01" = { vm_id = 901, mac_address = "BC:24:11:00:00" }
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

run "rejects_talos_version_without_v_prefix" {
  command = plan

  variables {
    talos_version = "1.14.3"
  }

  expect_failures = [var.talos_version]
}

run "rejects_static_ipv4_on_metal_platform" {
  command = plan

  variables {
    talos_platform = "metal"
    network        = { ipv4_gateway = "192.168.1.1" }
    nodes = {
      "talos-01" = { vm_id = 901, ipv4_address = "192.168.1.101/24" }
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
