variable "do_token" {
  description = "DigitalOcean API token with write access to droplets, firewalls, and DNS"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "A domain already added to DigitalOcean (nameservers delegated to DO). Used for the A record pointing at the droplet."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install on the droplet. The matching private key is used to SSH in as root."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_key_name" {
  description = "Name under which the public key is (or will be) registered in DigitalOcean. If a key with this name already exists in the account (typical for shared dev accounts), it is reused -- Terraform will not upload a duplicate. On a fresh account the key is created under this name."
  type        = string
  default     = "colmena-installer"
}

variable "region" {
  description = "DigitalOcean region slug (e.g. nyc3, sfo3, fra1, blr1)."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug. s-2vcpu-4gb is the recommended minimum: pyenv+Python 3.10 compile is single-threaded and saturates 1 vCPU for ~3 min, while Docker pulls and npm install are RAM-hungry. s-1vcpu-1gb OOMs; s-2vcpu-2gb OOM-kills Caddy under the combined load. 4 GB RAM keeps everything healthy. See: https://docs.digitalocean.com/products/droplets/pricing/"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "droplet_image" {
  description = "DigitalOcean image slug. Ubuntu 24.04 LTS is the cloud-init target."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "letsencrypt_staging" {
  description = "If true, Caddy uses the Let's Encrypt staging CA (no rate-limit lockout during dev). Set to false for a real cert."
  type        = bool
  default     = true
}
