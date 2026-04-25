output "instance_id" {
  description = "EC2 instance ID for the smoke test host."
  value       = aws_instance.smoke.id
}

output "public_ip" {
  description = "Public IP of the smoke test host."
  value       = aws_instance.smoke.public_ip
}

output "public_dns" {
  description = "Public DNS of the smoke test host."
  value       = aws_instance.smoke.public_dns
}

output "security_group_id" {
  description = "Security group attached to the smoke test host."
  value       = aws_security_group.smoke.id
}
