# --- Proxmox connection -------------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox VE API token in the form user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification of the Proxmox VE API (self-signed certificate)"
  type        = bool
  default     = false
}

variable "proxmox_node" {
  description = "Proxmox VE node that hosts every VM and the Talos ISO"
  type        = string
  default     = "pve"
}

# --- Talos image --------------------------------------------------------------

variable "talos_version" {
  description = "Talos Linux version to build the ISO for"
  type        = string
  default     = "v1.14.3"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z.]+)?$", var.talos_version))
    error_message = "talos_version must look like v1.14.3."
  }
}

variable "talos_platform" {
  description = "Image Factory platform: nocloud (Proxmox cloud-init sets hostname and IP) or metal (DHCP only)"
  type        = string
  default     = "nocloud"

  validation {
    condition     = contains(["nocloud", "metal"], var.talos_platform)
    error_message = "talos_platform must be nocloud or metal."
  }
}

variable "talos_architecture" {
  description = "CPU architecture of the Talos image"
  type        = string
  default     = "amd64"
}

variable "talos_extensions" {
  description = "Official system extensions baked into the image"
  type        = list(string)
  default     = ["siderolabs/qemu-guest-agent"]
}

variable "talos_extra_kernel_args" {
  description = "Extra kernel arguments baked into the image"
  type        = list(string)
  default     = []
}

# --- ISO storage --------------------------------------------------------------

variable "iso_datastore_id" {
  description = "Proxmox datastore that stores the Talos ISO (must allow the iso content type)"
  type        = string
  default     = "local"
}

variable "iso_upload_timeout" {
  description = "Seconds Proxmox may spend downloading the ISO from Image Factory"
  type        = number
  default     = 1200
}

# --- VMs ----------------------------------------------------------------------

variable "vm_defaults" {
  description = "Settings shared by every VM; cpu_cores, memory_mb, disk_size_gb and extra_disks can be overridden per node"
  type = object({
    cpu_cores   = optional(number, 8)
    cpu_sockets = optional(number, 1)
    cpu_type    = optional(string, "host")
    memory_mb   = optional(number, 16384)

    datastore_id     = optional(string, "local-lvm")
    disk_size_gb     = optional(number, 100)
    disk_interface   = optional(string, "scsi0")
    disk_file_format = optional(string, "raw")
    disk_cache       = optional(string, "none")
    disk_discard     = optional(string, "on")
    disk_ssd         = optional(bool, true)
    disk_iothread    = optional(bool, true)
    # Extra raw disks (e.g. for Ceph), attached after disk_interface on its bus: scsi1, scsi2, ...
    extra_disks = optional(list(object({
      size_gb      = number
      datastore_id = optional(string)
    })), [])

    bios          = optional(string, "seabios")
    efi_disk_type = optional(string, "4m")
    machine       = optional(string, "q35")
    scsi_hardware = optional(string, "virtio-scsi-single")
    os_type       = optional(string, "l26")

    cdrom_interface        = optional(string, "ide2")
    cloudinit_interface    = optional(string, "ide0")
    cloudinit_datastore_id = optional(string)

    agent_enabled       = optional(bool, true)
    agent_timeout       = optional(string, "15m")
    agent_wait_for_ipv4 = optional(bool, false) # guest agent only runs once Talos is installed

    on_boot         = optional(bool, true)
    started         = optional(bool, true)
    protection      = optional(bool, false)
    stop_on_destroy = optional(bool, true)
    pool_id         = optional(string)
    description     = optional(string, "Talos Linux node, managed by Terraform")
    tags            = optional(list(string), ["talos", "terraform"])
  })
  default = {}

  validation {
    condition = length(distinct([
      var.vm_defaults.disk_interface, var.vm_defaults.cdrom_interface, var.vm_defaults.cloudinit_interface,
    ])) == 3
    error_message = "disk_interface, cdrom_interface and cloudinit_interface must all differ."
  }

  validation {
    condition     = can(regex("^(scsi|virtio|sata)\\d+$", var.vm_defaults.disk_interface))
    error_message = "disk_interface must be scsiN, virtioN or sataN; extra disks follow it on the same bus."
  }
}

variable "network" {
  description = "Network attachment shared by every VM; ipv4_gateway is required once any node has a static ipv4_address"
  type = object({
    bridge       = optional(string, "vmbr0")
    vlan_id      = optional(number)
    model        = optional(string, "virtio")
    mtu          = optional(number)
    firewall     = optional(bool, false)
    ipv4_gateway = optional(string)
    dns_servers  = optional(list(string), [])
    dns_domain   = optional(string)
  })
  default = {}
}

variable "nodes" {
  description = "VMs to create, keyed by VM name (also the Talos hostname). Unset ipv4_address means DHCP"
  type = map(object({
    vm_id        = number
    cpu_cores    = optional(number)
    memory_mb    = optional(number)
    disk_size_gb = optional(number)
    extra_disks = optional(list(object({
      size_gb      = number
      datastore_id = optional(string)
    })))
    mac_address  = optional(string)
    ipv4_address = optional(string) # CIDR, e.g. 192.168.1.101/24
    tags         = optional(list(string), [])
  }))
  default = {
    "talos-01" = { vm_id = 901 }
    "talos-02" = { vm_id = 902 }
    "talos-03" = { vm_id = 903 }
  }

  validation {
    condition     = alltrue([for name in keys(var.nodes) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name))])
    error_message = "Node names become Talos hostnames: lowercase letters, digits and '-', up to 63 characters."
  }

  validation {
    condition     = length(distinct([for n in values(var.nodes) : n.vm_id])) == length(var.nodes)
    error_message = "Every node must have a unique vm_id."
  }

  validation {
    condition = alltrue([
      for n in values(var.nodes) : n.ipv4_address == null ? true : (
        can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", n.ipv4_address)) && can(cidrhost(n.ipv4_address, 0))
      )
    ])
    error_message = "ipv4_address must be an IPv4 address with a prefix length, e.g. 192.168.1.101/24."
  }

  validation {
    condition     = var.network.ipv4_gateway != null || alltrue([for n in values(var.nodes) : n.ipv4_address == null])
    error_message = "network.ipv4_gateway must be set when any node has a static ipv4_address."
  }

  validation {
    condition     = var.talos_platform == "nocloud" || alltrue([for n in values(var.nodes) : n.ipv4_address == null])
    error_message = "Static ipv4_address is delivered via cloud-init and needs talos_platform = \"nocloud\"."
  }

  validation {
    condition = (
      length(distinct([for n in values(var.nodes) : split("/", n.ipv4_address)[0] if n.ipv4_address != null])) ==
      length([for n in values(var.nodes) : n if n.ipv4_address != null])
    )
    error_message = "Static ipv4_address values must be unique across nodes."
  }

  validation {
    condition = alltrue([
      for n in values(var.nodes) : n.mac_address == null ? true : can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", n.mac_address))
    ])
    error_message = "mac_address must look like BC:24:11:00:00:01."
  }
}
