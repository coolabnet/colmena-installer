variable "do_token" {
  description = "DigitalOcean API token with write access to droplets and firewalls"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install on the droplet. The matching private key is used to SSH in as root."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_key_name" {
  description = "Name under which the public key is (or will be) registered in DigitalOcean. If a key with this name already exists in the account it is reused."
  type        = string
  default     = "colmena-installer"
}

variable "region" {
  description = "DigitalOcean region slug (e.g. nyc3, sfo3, fra1, blr1)."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug. CasaOS + the colmena app (postgres + django/gunicorn + nginx) fit comfortably in 2 vCPU / 4 GB."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "droplet_image" {
  description = "DigitalOcean image slug. Ubuntu 24.04 LTS is officially supported by the CasaOS installer."
  type        = string
  default     = "ubuntu-24-04-x64"
}
