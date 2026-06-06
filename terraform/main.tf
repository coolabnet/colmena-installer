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

# Resolve ~ at the start so the data source and key upload work uniformly.
locals {
  ssh_public_key_path = pathexpand(var.ssh_public_key_path)
}

data "digitalocean_domain" "this" {
  name = var.domain_name
}

# Find any existing SSH key with this name in the account. The plural data
# source returns an empty list (not an error) when no key matches, so we can
# branch cleanly: if length > 0, reuse the first one; otherwise create.
data "digitalocean_ssh_keys" "by_name" {
  filter {
    key      = "name"
    values   = [var.ssh_key_name]
    match_by = "exact"
  }
}

resource "digitalocean_ssh_key" "installer" {
  count = length(data.digitalocean_ssh_keys.by_name.ssh_keys) == 0 ? 1 : 0

  name       = var.ssh_key_name
  public_key = file(local.ssh_public_key_path)
}

resource "digitalocean_droplet" "colmena" {
  name       = "colmena-droplet"
  region     = var.region
  size       = var.droplet_size
  image      = var.droplet_image
  monitoring = true
  ipv6       = false

  ssh_keys = [
    coalesce(
      try(data.digitalocean_ssh_keys.by_name.ssh_keys[0].id, null),
      try(digitalocean_ssh_key.installer[0].id, null),
    ),
  ]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    domain              = var.domain_name
    letsencrypt_staging = var.letsencrypt_staging
  })

  tags = ["colmena", "installer", "terraform"]
}

# A record for the bare domain. www is intentionally not created (Caddy serves both via Host header).
resource "digitalocean_record" "apex_a" {
  domain = data.digitalocean_domain.this.id
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.colmena.ipv4_address
  ttl    = 300
}

resource "digitalocean_firewall" "colmena" {
  name = "colmena-droplet"

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
    port_range       = "443"
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

  droplet_ids = [digitalocean_droplet.colmena.id]
}
