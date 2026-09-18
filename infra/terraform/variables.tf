variable "vmws_endpoint" {
  type        = string
  description = "vmrest endpoint. Loopback only: vmrest must never be reachable from the network."
  validation {
    condition     = can(regex("^https://(127\\.0\\.0\\.1|localhost):[0-9]+/api$", var.vmws_endpoint))
    error_message = "vmws_endpoint must be an https URL on 127.0.0.1 or localhost ending in /api."
  }
}

variable "vmws_username" {
  type = string
}

variable "vmws_password" {
  type      = string
  sensitive = true
}

variable "golden_vm_name" {
  type        = string
  description = "vmrest display name of the read-only golden image built by scripts/golden-build.sh."
  default     = "k3slab-golden-rocky98-20260918-1"
}

variable "vm_root_dir" {
  type        = string
  description = "Must equal Workstation's prefvmx.defaultVMPath: vmrest always creates clones there."
  validation {
    condition     = startswith(var.vm_root_dir, "/")
    error_message = "vm_root_dir must be an absolute path."
  }
}

variable "nodes" {
  type = map(object({
    cpus           = number
    memory_mb      = number
    ansible_groups = list(string)
  }))
  default = {
    "k3s-server"   = { cpus = 2, memory_mb = 3072, ansible_groups = ["k3s_server"] }
    "worker-cpu-1" = { cpus = 2, memory_mb = 6144, ansible_groups = ["k3s_agents", "platform_nodes"] }
    "worker-cpu-2" = { cpus = 2, memory_mb = 3072, ansible_groups = ["k3s_agents", "app_nodes"] }
  }
}

variable "power_state" {
  type    = string
  default = "on"
  validation {
    condition     = contains(["on", "off"], var.power_state)
    error_message = "power_state must be \"on\" or \"off\"."
  }
}

variable "power_state_overrides" {
  type        = map(string)
  description = "Per-node power state. scripts/cluster-apply.sh sets new nodes to \"off\": provider 2.0.1 cannot create a VM that is powered on."
  default     = {}
  validation {
    condition     = alltrue([for s in values(var.power_state_overrides) : contains(["on", "off"], s)])
    error_message = "power_state_overrides values must be \"on\" or \"off\"."
  }
}
