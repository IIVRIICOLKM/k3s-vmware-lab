# Copy to a *.tfvars file outside Git only if you need to override defaults.
# Credentials never go here: scripts/tf.sh exports them from ~/.config/k3s-vmware-lab/secrets/vmrest.env.
golden_vm_name = "k3slab-golden-rocky98-20260918-1"

nodes = {
  "k3s-server"   = { cpus = 2, memory_mb = 3072, ansible_groups = ["k3s_server"] }
  "worker-cpu-1" = { cpus = 2, memory_mb = 6144, ansible_groups = ["k3s_agents", "platform_nodes"] }
  "worker-cpu-2" = { cpus = 2, memory_mb = 3072, ansible_groups = ["k3s_agents", "app_nodes"] }
}
