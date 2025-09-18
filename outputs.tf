# Outputs for easy access to important values
output "instance_ip" {
  description = "Public IP address of the K3s server"
  value       = aws_eip.k3s_eip.public_ip
}

output "instance_id" {
  description = "EC2 instance ID of the K3s server"
  value       = aws_instance.k3s_server.id
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.k3s_eip.public_ip}"
}

output "domain_records" {
  description = "All domain records created for the application"
  value = {
    prod_backend      = "${var.domain_name} -> ${aws_eip.k3s_eip.public_ip}"
    prod_frontend     = "app.${var.domain_name} -> ${aws_eip.k3s_eip.public_ip}"
    staging_backend   = "staging.${var.domain_name} -> ${aws_eip.k3s_eip.public_ip}"
    staging_frontend  = "staging-app.${var.domain_name} -> ${aws_eip.k3s_eip.public_ip}"
    dev_backend       = "dev.${var.domain_name} -> ${aws_eip.k3s_eip.public_ip}"
    dev_frontend      = "dev-app.${var.domain_name} -> ${aws_eip.k3s_eip.public_ip}"
  }
}
