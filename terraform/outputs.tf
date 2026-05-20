output "api_gateway_public_ip" {
  description = "Public IP of the API Gateway EC2 instance"
  value       = aws_instance.api_gateway.public_ip
}

output "inference_worker_private_ip" {
  description = "Private IP of the Inference Worker EC2 instance"
  value       = aws_instance.inference_worker.private_ip
}