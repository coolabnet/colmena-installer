output "droplet_ip" {
  description = "Public IPv4 address of the droplet. Use this in scripts/wait-and-test.sh to bypass DNS."
  value       = digitalocean_droplet.colmena.ipv4_address
}

output "url" {
  description = "HTTPS URL of the deployed stack, served by Caddy with a Let's Encrypt certificate."
  value       = "https://${var.domain_name}"
}

output "ssh_command" {
  description = "SSH command to log in as root using the configured SSH key."
  value       = "ssh root@${digitalocean_droplet.colmena.ipv4_address}"
}

output "destroy_reminder" {
  description = "Always-visible reminder to avoid ongoing charges."
  value       = "When done, run 'terraform destroy' to drop the droplet and firewall (the domain and its A record are preserved)."
}

output "e2e_command" {
  description = "One-shot command to wait for the stack to be ready and run the Playwright e2e suite from the local machine."
  value       = "COLMENA_DOMAIN=${var.domain_name} bash scripts/wait-and-test.sh"
}
