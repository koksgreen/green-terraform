
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Enable this after creating your S3 bucket.
  # backend "s3" {
  #   bucket       = "YOUR-UNIQUE-BUCKET-NAME"
  #   key          = "ts/terraform.tfstate"
  #   region       = "eu-north-1"
  #   use_lockfile  = true
  #   encrypt       = true
  # }
}

provider "aws" {
  region = "eu-north-1"
}

# --------------------------------------------------
# VARIABLES
# --------------------------------------------------

variable "db_password" {
  description = "Master password for the RDS database"
  type        = string
  sensitive   = true
}

variable "admin_cidr" {
  description = "Your public IP address in CIDR notation, e.g. 203.0.113.10/32"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.admin_cidr == null ? true : can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid CIDR block, for example 203.0.113.10/32."
  }
}

variable "ssh_key_name" {
  description = "Existing AWS EC2 key pair name"
  type        = string
  default     = null
  nullable    = true
}

# --------------------------------------------------
# VPC AND SUBNETS
# --------------------------------------------------

resource "aws_vpc" "ts_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "ts-vpc"
  }
}

resource "aws_subnet" "ts_public_subnet" {
  vpc_id                  = aws_vpc.ts_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.ts_vpc.cidr_block, 3, 1)
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "ts-public-subnet"
  }
}

resource "aws_subnet" "ts_private_subnet" {
  vpc_id            = aws_vpc.ts_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.ts_vpc.cidr_block, 5, 1)
  availability_zone = "eu-north-1a"

  tags = {
    Name = "ts-private-subnet"
  }
}

resource "aws_subnet" "ts_database_subnet" {
  vpc_id            = aws_vpc.ts_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.ts_vpc.cidr_block, 7, 1)
  availability_zone = "eu-north-1b"

  tags = {
    Name = "ts-database-subnet"
  }
}

# --------------------------------------------------
# INTERNET GATEWAY
# --------------------------------------------------

resource "aws_internet_gateway" "ts_gw" {
  vpc_id = aws_vpc.ts_vpc.id

  tags = {
    Name = "ts-igw"
  }
}

# --------------------------------------------------
# PUBLIC ROUTE TABLE
# --------------------------------------------------

resource "aws_route_table" "ts_public_rt" {
  vpc_id = aws_vpc.ts_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ts_gw.id
  }

  tags = {
    Name = "ts-public-rt"
  }
}

resource "aws_route_table_association" "ts_public_association" {
  subnet_id      = aws_subnet.ts_public_subnet.id
  route_table_id = aws_route_table.ts_public_rt.id
}

# --------------------------------------------------
# ELASTIC IP AND NAT GATEWAY
# --------------------------------------------------

resource "aws_eip" "example" {
  domain = "vpc"

  tags = {
    Name = "ts-nat-eip"
  }
}

resource "aws_nat_gateway" "ts_ng" {
  subnet_id     = aws_subnet.ts_public_subnet.id
  allocation_id = aws_eip.example.id

  depends_on = [
    aws_internet_gateway.ts_gw
  ]

  tags = {
    Name = "ts-nat-gateway"
  }
}

# --------------------------------------------------
# PRIVATE ROUTE TABLE
# --------------------------------------------------

resource "aws_route_table" "ts_private_rt" {
  vpc_id = aws_vpc.ts_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ts_ng.id
  }

  tags = {
    Name = "ts-private-rt"
  }
}

resource "aws_route_table_association" "ts_private_association" {
  subnet_id      = aws_subnet.ts_private_subnet.id
  route_table_id = aws_route_table.ts_private_rt.id
}

# --------------------------------------------------
# DATABASE ROUTE TABLE
# --------------------------------------------------

resource "aws_route_table" "ts_database_rt" {
  vpc_id = aws_vpc.ts_vpc.id

  tags = {
    Name = "ts-database-rt"
  }
}

resource "aws_route_table_association" "ts_database_association" {
  subnet_id      = aws_subnet.ts_database_subnet.id
  route_table_id = aws_route_table.ts_database_rt.id
}

# --------------------------------------------------
# SECURITY GROUPS
# --------------------------------------------------

# Frontend security group

resource "aws_security_group" "public_server" {
  name        = "ts-public-server"
  description = "Allows public HTTP and HTTPS traffic"
  vpc_id      = aws_vpc.ts_vpc.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.admin_cidr == null ? [] : [var.admin_cidr]

    content {
      description = "SSH from administrator IP"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ts-public-server-sg"
  }
}

# Backend security group

resource "aws_security_group" "private_server" {
  name        = "ts-private-server"
  description = "Allows traffic from the frontend server"
  vpc_id      = aws_vpc.ts_vpc.id

  ingress {
    description     = "HTTPS from frontend"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.public_server.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ts-private-server-sg"
  }
}

# Database security group

resource "aws_security_group" "database_server" {
  name        = "ts-database-server"
  description = "Allows MySQL traffic from backend server only"
  vpc_id      = aws_vpc.ts_vpc.id

  ingress {
    description     = "MySQL from backend"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.private_server.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ts-database-server-sg"
  }
}

# --------------------------------------------------
# UBUNTU AMI
# --------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name = "name"

    values = [
      "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    ]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
}

# --------------------------------------------------
# FRONTEND EC2 INSTANCE
# --------------------------------------------------

resource "aws_instance" "ts_frontend_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.ts_public_subnet.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.public_server.id]
  key_name                    = var.ssh_key_name

  tags = {
    Name = "frontend-server"
  }
}

# --------------------------------------------------
# BACKEND EC2 INSTANCE
# --------------------------------------------------

resource "aws_instance" "ts_backend_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.ts_private_subnet.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.private_server.id]
  key_name                    = var.ssh_key_name

  tags = {
    Name = "backend-server"
  }
}

# --------------------------------------------------
# RDS SUBNET GROUP
# --------------------------------------------------

resource "aws_db_subnet_group" "ts_rds_subnet_group" {
  name = "ts-subnet"

  subnet_ids = [
    aws_subnet.ts_private_subnet.id,
    aws_subnet.ts_database_subnet.id
  ]

  tags = {
    Name = "ts-rds-subnet-group"
  }
}

# --------------------------------------------------
# RDS MYSQL DATABASE
# --------------------------------------------------

resource "aws_db_instance" "ts_db" {
  allocated_storage      = 20
  max_allocated_storage  = 100
  storage_type           = "gp3"

  db_name  = "my_ts_db"
  engine   = "mysql"
  engine_version = "8.4"

  instance_class = "db.t3.micro"

  username = "mytsuser"
  password = var.db_password

  parameter_group_name   = "default.mysql8.4"
  db_subnet_group_name   = aws_db_subnet_group.ts_rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.database_server.id]

  publicly_accessible    = false
  storage_encrypted      = true
  backup_retention_period = 7

  skip_final_snapshot = true

  tags = {
    Name = "ts-mysql-database"
  }
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------

output "frontend_public_ip" {
  description = "Public IP address of frontend EC2"
  value       = aws_instance.ts_frontend_server.public_ip
}

output "backend_private_ip" {
  description = "Private IP address of backend EC2"
  value       = aws_instance.ts_backend_server.private_ip
}

output "db_endpoint" {
  description = "RDS MySQL endpoint"
  value       = aws_db_instance.ts_db.address
}

output "db_port" {
  description = "RDS MySQL port"
  value       = aws_db_instance.ts_db.port
}
