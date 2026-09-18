data "vmworkstation_virtual_machine" "golden" {
  denomination = var.golden_vm_name
}

resource "vmworkstation_virtual_machine" "node" {
  for_each = var.nodes

  sourceid     = data.vmworkstation_virtual_machine.golden.id
  denomination = each.key
  # A clone inherits the golden image's annotation and the provider cannot change it, so mirror it.
  description = data.vmworkstation_virtual_machine.golden.description
  path        = "${var.vm_root_dir}/${each.key}/${each.key}.vmx"
  processors  = each.value.cpus
  memory      = each.value.memory_mb
  state       = lookup(var.power_state_overrides, each.key, var.power_state)

  lifecycle {
    # Any update hard-powers the VM off first, and neither field can be changed through vmrest anyway.
    # Rebuild a node from a new golden image explicitly: scripts/cluster-apply.sh -replace='vmworkstation_virtual_machine.node["<name>"]'
    ignore_changes = [sourceid, description]

    precondition {
      condition     = data.vmworkstation_virtual_machine.golden.state == "off"
      error_message = "The golden image must stay powered off while it is being cloned."
    }
  }
}
