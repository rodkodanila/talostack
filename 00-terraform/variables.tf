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
  description = "Proxmox VE node that hosts every VM"
  type        = string
  default     = "pve"
}

# --- Talos ISO ----------------------------------------------------------------

variable "talos_iso_file_id" {
  description = "Talos ISO already uploaded to Proxmox storage, as <storage>:iso/<file>.iso"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*:iso/.+\\.iso$", var.talos_iso_file_id))
    error_message = "talos_iso_file_id must look like local:iso/talos-v1.14.3-nocloud-amd64.iso."
  }
}

variable "talos_platform" {
  description = "Platform the ISO was built for: nocloud (Proxmox cloud-init sets hostname and IPs) or metal (DHCP only)"
  type        = string
  default     = "nocloud"

  validation {
    condition     = contains(["nocloud", "metal"], var.talos_platform)
    error_message = "talos_platform must be nocloud or metal."
  }
}

# --- VMs ----------------------------------------------------------------------

variable "vm_defaults" {
  description = "Settings shared by every VM; cpu_cores, memory_mb and disks can be overridden per node"
  type = object({
    cpu_cores   = optional(number, 8)
    cpu_sockets = optional(number, 1)
    cpu_type    = optional(string, "host")
    memory_mb   = optional(number, 16384)

    # Storage for disks without their own `storage`, the EFI disk and the cloud-init drive.
    datastore_id = optional(string, "local-lvm")
    # Disks are attached in order as <disk_bus>0, <disk_bus>1, ...; the first one is the boot disk.
    disk_bus = optional(string, "scsi")
    disks = optional(list(object({
      size_gb     = number
      storage     = optional(string) # Proxmox storage name, e.g. local-lvm, ceph-ssd
      file_format = optional(string, "raw")
      cache       = optional(string, "none")
      discard     = optional(string, "on")
      ssd         = optional(bool, true) # ignored on virtio
      iothread    = optional(bool, true) # ignored on sata
      backup      = optional(bool, true)
    })), [{ size_gb = 100 }])

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
    condition     = length(var.vm_defaults.disks) > 0
    error_message = "vm_defaults.disks needs at least one disk; the first one is the boot disk."
  }

  validation {
    condition     = contains(["scsi", "virtio", "sata"], var.vm_defaults.disk_bus)
    error_message = "disk_bus must be scsi, virtio or sata."
  }

  # Keeping the cdrom and cloud-init drive on IDE means they can never collide with disks.
  validation {
    condition = (
      can(regex("^ide[0-3]$", var.vm_defaults.cdrom_interface)) &&
      can(regex("^ide[0-3]$", var.vm_defaults.cloudinit_interface))
    )
    error_message = "cdrom_interface and cloudinit_interface must be ide0..ide3."
  }

  validation {
    condition     = var.vm_defaults.cdrom_interface != var.vm_defaults.cloudinit_interface
    error_message = "cdrom_interface and cloudinit_interface must differ."
  }
}

variable "network" {
  description = "NICs every VM gets, in order (net0, net1, ...), plus DNS for cloud-init. Per-node MAC/IP go to nodes[*].network_interfaces"
  type = object({
    interfaces = optional(list(object({
      bridge       = optional(string, "vmbr0")
      vlan_id      = optional(number)
      model        = optional(string, "virtio")
      mtu          = optional(number)
      firewall     = optional(bool, false)
      queues       = optional(number)
      rate_limit   = optional(number) # MB/s
      ipv4_gateway = optional(string) # used only for nodes with a static IP on this NIC
    })), [{}])
    dns_servers = optional(list(string), [])
    dns_domain  = optional(string)
  })
  default = {}
}

variable "nodes" {
  description = "VMs to create, keyed by VM name (also the Talos hostname)"
  type = map(object({
    vm_id     = number
    cpu_cores = optional(number)
    memory_mb = optional(number)
    # Replaces vm_defaults.disks entirely for this node.
    disks = optional(list(object({
      size_gb     = number
      storage     = optional(string)
      file_format = optional(string, "raw")
      cache       = optional(string, "none")
      discard     = optional(string, "on")
      ssd         = optional(bool, true)
      iothread    = optional(bool, true)
      backup      = optional(bool, true)
    })))
    # Matched by position with network.interfaces; unset ipv4_address means DHCP, unset mac_address means auto.
    network_interfaces = optional(list(object({
      mac_address  = optional(string)
      ipv4_address = optional(string) # CIDR, e.g. 192.168.1.101/24
    })), [])
    tags = optional(list(string), [])
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
    condition     = alltrue([for n in values(var.nodes) : n.disks == null ? true : length(n.disks) > 0])
    error_message = "A node's disks override needs at least one disk (the first one is the boot disk); omit it to use vm_defaults.disks."
  }

  validation {
    condition     = alltrue([for n in values(var.nodes) : length(n.network_interfaces) <= length(var.network.interfaces)])
    error_message = "A node cannot list more network_interfaces than network.interfaces defines."
  }

  validation {
    condition = alltrue([
      for nic in flatten([for n in values(var.nodes) : n.network_interfaces]) : nic.ipv4_address == null ? true : (
        can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", nic.ipv4_address)) && can(cidrhost(nic.ipv4_address, 0))
      )
    ])
    error_message = "ipv4_address must be an IPv4 address with a prefix length, e.g. 192.168.1.101/24."
  }

  validation {
    condition = var.talos_platform == "nocloud" || alltrue([
      for nic in flatten([for n in values(var.nodes) : n.network_interfaces]) : nic.ipv4_address == null
    ])
    error_message = "Static ipv4_address is delivered via cloud-init and needs talos_platform = \"nocloud\"."
  }

  validation {
    condition = (
      length(distinct([
        for nic in flatten([for n in values(var.nodes) : n.network_interfaces]) : split("/", nic.ipv4_address)[0] if nic.ipv4_address != null
      ])) ==
      length([for nic in flatten([for n in values(var.nodes) : n.network_interfaces]) : nic if nic.ipv4_address != null])
    )
    error_message = "Static ipv4_address values must be unique across all nodes and NICs."
  }

  validation {
    condition = alltrue([
      for nic in flatten([for n in values(var.nodes) : n.network_interfaces]) :
      nic.mac_address == null ? true : can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", nic.mac_address))
    ])
    error_message = "mac_address must look like BC:24:11:00:00:01."
  }
}
