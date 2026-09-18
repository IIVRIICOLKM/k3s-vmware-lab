output "nodes" {
  description = "Facts for Ansible. Guest IPs are not included: the provider's ip attribute is a fixed placeholder, so scripts/render-inventory.sh asks vmrest by id."
  value = {
    for name, vm in vmworkstation_virtual_machine.node : name => {
      id             = vm.id
      path           = vm.path
      processors     = vm.processors
      memory_mb      = vm.memory
      state          = vm.state
      ansible_groups = var.nodes[name].ansible_groups
    }
  }
}

output "golden_image" {
  value = {
    name = var.golden_vm_name
    id   = data.vmworkstation_virtual_machine.golden.id
  }
}
