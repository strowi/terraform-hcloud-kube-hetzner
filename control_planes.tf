module "control_planes" {
  source = "./modules/host"

  for_each = local.control_plane_nodes

  name                   = "${var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""}${each.value.nodepool_name}"
  ssh_keys               = [hcloud_ssh_key.k3s.id]
  public_key             = var.public_key
  private_key            = var.private_key
  additional_public_keys = var.additional_public_keys
  firewall_ids           = [hcloud_firewall.k3s.id]
  placement_group_id     = var.placement_group_disable ? 0 : element(hcloud_placement_group.control_plane.*.id, ceil(each.value.index / 10))
  location               = each.value.location
  server_type            = each.value.server_type
  ipv4_subnet_id         = hcloud_network_subnet.control_plane[[for i, v in var.control_plane_nodepools : i if v.name == each.value.nodepool_name][0]].id
  packages_to_install    = concat(var.enable_longhorn ? ["open-iscsi"] : [], [])

  # We leave some room so 100 eventual Hetzner LBs that can be created perfectly safely
  # It leaves the subnet with 254 x 254 - 100 = 64416 IPs to use, so probably enough.
  private_ipv4 = cidrhost(hcloud_network_subnet.control_plane[[for i, v in var.control_plane_nodepools : i if v.name == each.value.nodepool_name][0]].ip_range, each.value.index + 101)

  labels = {
    "provisioner" = "terraform",
    "engine"      = "k3s"
  }

  depends_on = [
    hcloud_network_subnet.control_plane
  ]
}

resource "null_resource" "control_planes" {
  for_each = local.control_plane_nodes

  triggers = {
    control_plane_id = module.control_planes[each.key].id
  }

  connection {
    user           = "root"
    private_key    = local.ssh_private_key
    agent_identity = local.ssh_identity
    host           = module.control_planes[each.key].ipv4_address
  }

  # Generating k3s server config file
  provisioner "file" {
    content = yamlencode(merge({
      node-name                   = module.control_planes[each.key].name
      server                      = length(module.control_planes) == 1 ? null : "https://${module.control_planes[each.key].private_ipv4_address == module.control_planes[keys(module.control_planes)[0]].private_ipv4_address ? module.control_planes[keys(module.control_planes)[1]].private_ipv4_address : module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}:6443"
      token                       = random_password.k3s_token.result
      disable-cloud-controller    = true
      disable                     = local.disable_extras
      flannel-iface               = "eth1"
      kubelet-arg                 = ["cloud-provider=external", "volume-plugin-dir=/var/lib/kubelet/volumeplugins"]
      kube-controller-manager-arg = "flex-volume-plugin-dir=/var/lib/kubelet/volumeplugins"
      node-ip                     = module.control_planes[each.key].private_ipv4_address
      advertise-address           = module.control_planes[each.key].private_ipv4_address
      node-label                  = each.value.labels
      node-taint                  = each.value.taints
      disable-network-policy      = var.cni_plugin == "calico" ? true : var.disable_network_policy
      write-kubeconfig-mode       = "0644" # needed for import into rancher
      },
      var.cni_plugin == "calico" ? {
        flannel-backend = "none"
    } : {}))

    destination = "/tmp/config.yaml"
  }

  # Install k3s server
  provisioner "remote-exec" {
    inline = local.install_k3s_server
  }

  # Start the k3s server and wait for it to have started correctly
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s 2> /dev/null",
      <<-EOT
      timeout 120 bash <<EOF
        until systemctl status k3s > /dev/null; do
          systemctl start k3s 2> /dev/null
          echo "Waiting for the k3s server to start..."
          sleep 2
        done
      EOF
      EOT
    ]
  }

  depends_on = [
    null_resource.first_control_plane,
    hcloud_network_subnet.control_plane
  ]
}
