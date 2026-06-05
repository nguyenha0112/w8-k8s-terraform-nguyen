variable "aws_region" {
  description = "AWS region used for all resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix used for resource names and tags."
  type        = string
  default     = "minikube-alb"
}

variable "instance_type" {
  description = "EC2 instance type. Minikube needs at least 2 vCPU and 2 GiB RAM."
  type        = string
  default     = "t3.small"
}

variable "minikube_version" {
  description = "Minikube release installed on the EC2 instance."
  type        = string
  default     = "v1.37.0"
}

variable "kubectl_version" {
  description = "kubectl release installed on the EC2 instance."
  type        = string
  default     = "v1.34.1"
}
