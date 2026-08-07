terraform {
  required_version = ">= 1.5.0"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.34"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

locals {
  ssh_public_key_path = pathexpand(var.ssh_public_key_path)
}

# Reuse an existing SSH key by name if the account already has one (shared
# dev account pattern, same as the main terraform/ config); otherwise upload.
data "digitalocean_ssh_keys" "by_name" {
  filter {
    key      = "name"
    values   = [var.ssh_key_name]
    match_by = "exact"
  }
}

resource "digitalocean_ssh_key" "casaos_test" {
  count = length(data.digitalocean_ssh_keys.by_name.ssh_keys) == 0 ? 1 : 0

  name       = var.ssh_key_name
  public_key = file(local.ssh_public_key_path)
}

resource "digitalocean_droplet" "casaos_test" {
  name       = "colmena-casaos-test"
  region     = var.region
  size       = var.droplet_size
  image      = var.droplet_image
  monitoring = true
  ipv6       = false

  ssh_keys = [
    coalesce(
      try(data.digitalocean_ssh_keys.by_name.ssh_keys[0].id, null),
      try(digitalocean_ssh_key.casaos_test[0].id, null),
    ),
  ]

  user_data = file("${path.module}/cloud-init.yaml")

  tags = ["colmena", "casaos-test", "terraform"]
}

# Plain host, no DNS records -- this is a throwaway verification droplet
# reached by IP only. Ports: 22 (ssh), 80 (CasaOS UI), 8080 (colmena
# frontend), 8000 (colmena backend API), per Apps/Colmena/docker-compose.yml
# in colmena-casaos-appstore.
resource "digitalocean_firewall" "casaos_test" {
  name = "colmena-casaos-test"

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8080"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8000"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "icmp"
    port_range       = "0"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  droplet_ids = [digitalocean_droplet.casaos_test.id]
}
