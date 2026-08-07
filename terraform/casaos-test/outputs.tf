output "droplet_ip" {
  description = "Public IPv4 address of the CasaOS test droplet."
  value       = digitalocean_droplet.casaos_test.ipv4_address
}

output "casaos_url" {
  description = "CasaOS dashboard URL."
  value       = "http://${digitalocean_droplet.casaos_test.ipv4_address}"
}

output "colmena_frontend_url" {
  description = "Colmena frontend URL, once the app is installed via CasaOS."
  value       = "http://${digitalocean_droplet.casaos_test.ipv4_address}:8080"
}

output "colmena_backend_url" {
  description = "Colmena backend API URL (enter this as the server URL when the frontend asks)."
  value       = "http://${digitalocean_droplet.casaos_test.ipv4_address}:8000"
}

output "ssh_command" {
  description = "SSH command to log in as root using the configured SSH key."
  value       = "ssh root@${digitalocean_droplet.casaos_test.ipv4_address}"
}

output "destroy_reminder" {
  description = "Always-visible reminder to avoid ongoing charges."
  value       = "This is a throwaway verification host. Run 'terraform destroy' in terraform/casaos-test/ when done."
}
