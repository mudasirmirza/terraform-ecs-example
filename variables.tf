
variable "aws_region" {
  default = "eu-west-1"
}

variable "vpc_name" {
  default = "ECS-Test"
}

variable "vpc_cidr" {
  default = "172.32.0.0/16"
}

variable "bastion_instance_type" {
  default = "t2.micro"
}

variable "key_pair_name" {
  default = "ecs_test"
}

variable "vpc_id" {
  default = ""
}

variable "subnet_id" {
  default = ""
}

variable "ami_id" {
  default = "ami-e9bfe49a"
}

variable "ecs_ami_id" {
  default = "ami-ba346ec9"
}

variable "launch_config_instance_type" {
  default = "t2.medium"
}

variable "asg_min" {
  default = 1
}

variable "asg_max" {
  default = 5
}

variable "asg_desired" {
  default = 2
}

variable "ecs_cluster_name" {
  default = "ecs_test_cluster"
}
