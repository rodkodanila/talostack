terraform {
  # 1.9+ is required for variable validations that reference other variables.
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.116"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
  }
}
