variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the API gateway VM"
  type        = string
  default     = "t3.micro"
}

variable "inference_instance_type" {
  description = "EC2 instance type for the inference worker VM"
  type        = string
  default     = "t3.micro"
}

variable "public_key_path" {
  description = "Path to your SSH public key"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for Ubuntu 20.04 LTS"
  type        = string
  default     = "ami-0c94855ba95c71c99"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH into the API gateway. Restrict to your IP in production (e.g. 1.2.3.4/32)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "repo_url" {
  description = "Git repository URL containing the quickstart project (used in EC2 user_data)"
  type        = string
}
