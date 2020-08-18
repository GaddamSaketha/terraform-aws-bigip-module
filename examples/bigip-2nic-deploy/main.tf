provider "aws" {
  region = var.region
}

#
# Create a random id
#
resource "random_id" "id" {
  byte_length = 2
}

#
# Create random password for BIG-IP
#
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = " #%*+,-./:=?@[]^_~"
}

#
# Create Secret Store and Store BIG-IP Password
#
resource "aws_secretsmanager_secret" "bigip" {
  name = format("%s-bigip-secret-%s", var.prefix, random_id.id.hex)
}
resource "aws_secretsmanager_secret_version" "bigip-pwd" {
  secret_id     = aws_secretsmanager_secret.bigip.id
  secret_string = random_password.password.result
}

#
# Create the VPC
#
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name                 = format("%s-vpc-%s", var.prefix, random_id.id.hex)
  cidr                 = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  azs = var.availabilityZones


  tags = {
    Name        = format("%s-vpc-%s", var.prefix, random_id.id.hex)
    Terraform   = "true"
    Environment = "dev"
  }
}
resource "aws_internet_gateway" "gw" {
  vpc_id = module.vpc.vpc_id

  tags = {
    Name = "default"
  }
}
resource "aws_route_table" "internet-gw" {
  vpc_id = module.vpc.vpc_id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_subnet" "mgmt" {
  vpc_id     = module.vpc.vpc_id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "management"
  }
}
resource "aws_subnet" "external-public" {
  vpc_id     = module.vpc.vpc_id
  cidr_block = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "external"
  }
}
resource "aws_route_table_association" "route_table_external" {
  subnet_id      = aws_subnet.external-public.id
  route_table_id = aws_route_table.internet-gw.id
}


#
# Create a security group for BIG-IP
#
module "external-network-security-group-public" {
  source = "terraform-aws-modules/security-group/aws"

  name        = format("%s-external-public-nsg-%s", var.prefix, random_id.id.hex)
  description = "Security group for BIG-IP "
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [local.allowed_app_cidr]
  ingress_rules       = ["http-80-tcp", "https-443-tcp"]

}

#
# Create a security group for BIG-IP Management
#
module "mgmt-network-security-group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = format("%s-mgmt-nsg-%s", var.prefix, random_id.id.hex)
  description = "Security group for BIG-IP Management"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [local.allowed_mgmt_cidr]
  ingress_rules       = ["https-443-tcp", "https-8443-tcp", "ssh-tcp"]

}

resource "tls_private_key" "example" {
  algorithm   = "RSA"
  //ecdsa_curve = "P384"
}



resource "aws_key_pair" "generated_key" {
  key_name   = "${var.ec2_key_name}"
  public_key = "${tls_private_key.example.public_key_openssh}"
}
#
# Create BIG-IP
#
module bigip {
  source = "../../"

  prefix = format(
    "%s-bigip-3-nic_with_new_vpc-%s",
    var.prefix,
    random_id.id.hex
  )
  f5_instance_count           = 1
  ec2_key_name                = aws_key_pair.generated_key.key_name
  aws_secretmanager_secret_id = aws_secretsmanager_secret.bigip.id
  mgmt_securitygroup_id = [module.mgmt-network-security-group.this_security_group_id]

  external_securitygroup_id = [module.external-network-security-group-public.this_security_group_id]

  external_subnet_id   = [{ "subnet_id" = aws_subnet.external-public.id, "public_ip" = true }]
  mgmt_subnet_id    = [{ "subnet_id" = aws_subnet.mgmt.id, "public_ip" = true }]
}

#
# Variables used by this example
#
locals {
  allowed_mgmt_cidr = "0.0.0.0/0"
  allowed_app_cidr  = "0.0.0.0/0"
}

