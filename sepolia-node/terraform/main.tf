# Hetzner Cloud resources for the Sepolia node: server, chain data volume,
# firewall and SSH key. The node itself is bootstrapped by cloud-init.yaml.

terraform {
  required_version = ">= 1.5"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.name}-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# Inbound: SSH from the admin address only, plus the P2P ports from anywhere.
# The RPC ports (8545, 8551, 5052) are never opened here.
resource "hcloud_firewall" "node" {
  name = var.name

  rule {
    description = "SSH, admin only"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_cidrs
  }

  dynamic "rule" {
    for_each = {
      "geth devp2p (RLPx)"         = ["tcp", "30303"]
      "geth discovery (discv4/v5)" = ["udp", "30303"]
      "lighthouse libp2p"          = ["tcp", "9000"]
      "lighthouse discv5"          = ["udp", "9000"]
      "lighthouse QUIC"            = ["udp", "9001"]
    }
    content {
      description = rule.key
      direction   = "in"
      protocol    = rule.value[0]
      port        = rule.value[1]
      source_ips  = ["0.0.0.0/0", "::/0"]
    }
  }
}

# Chain data lives on its own volume, independent of the server's lifecycle
resource "hcloud_volume" "chaindata" {
  name     = "${var.name}-chaindata"
  size     = var.volume_size_gb
  location = var.location
  format   = "ext4"
}

resource "hcloud_server" "node" {
  name         = var.name
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.node.id]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    compose       = indent(6, file("${path.module}/../docker-compose.yml"))
    env_example   = indent(6, file("${path.module}/../.env.example"))
    gen_jwt       = indent(6, file("${path.module}/../scripts/gen-jwt.sh"))
    check_sync    = indent(6, file("${path.module}/../scripts/check-sync.sh"))
    collect       = indent(6, file("${path.module}/../scripts/collect-evidence.sh"))
    restart_test  = indent(6, file("${path.module}/../scripts/restart-test.sh"))
    preflight     = indent(6, file("${path.module}/../scripts/preflight.sh"))
    egress_filter = indent(6, file("${path.module}/../scripts/egress-filter.sh"))
  })

  # The files are baked into user_data at creation. Later changes are copied
  # over with scp instead of rebuilding the server.
  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_volume_attachment" "chaindata" {
  volume_id = hcloud_volume.chaindata.id
  server_id = hcloud_server.node.id
  automount = false # cloud-init mounts it at /srv/sepolia/data
}

output "public_ipv4" {
  value = hcloud_server.node.ipv4_address
}

output "ssh" {
  value = "ssh -i ~/.ssh/sepolia_hetzner root@${hcloud_server.node.ipv4_address}"
}
