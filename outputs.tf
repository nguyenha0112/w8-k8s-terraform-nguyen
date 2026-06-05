output "app_url" {
  description = "Public URL of the application. It can take several minutes to become healthy."
  value       = "http://${aws_lb.app.dns_name}"
}

output "instance_id" {
  description = "EC2 instance ID, useful for troubleshooting with the AWS console or SSM if added."
  value       = aws_instance.minikube.id
}
