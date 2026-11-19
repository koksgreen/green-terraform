terraform {
  required_version = ">= 1.7" # needed for the "removed" blocks at the bottom

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # ---------------------------------------------------------------------------
  # REMOTE STATE (strongly recommended before running in GitHub Actions).
  # Without it every pipeline run forgets what it built and tries to create
  # everything again. Create the bucket once (see the instructions I gave you),
  # then remove the "#" characters below.
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket       = "YOUR-UNIQUE-BUCKET-NAME"
  #   key          = "ts/terraform.tfstate"
  #   region       = "eu-north-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

provider "aws" {
  region = "eu-north-1"
}

# -----------------------------------------------------------------------------
# Inputs (supply secrets from GitHub, never write them in this file)
# -----------------------------------------------------------------------------
variable "db_password" {
  description = "Master password for the database (set TF_VAR_db_password from a GitHub secret)"
  type        = string
  sensitive   = true
}

variable "admin_cidr" {
  description = "Your public IP as x.x.x.x/32. If set, SSH (port 22) to the frontend is allowed from it only."
  type        = string
  default     = null
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair, so you can SSH into the servers"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Network (unchanged from your version, except the private route table)
# -----------------------------------------------------------------------------
resource "aws_vpc" "ts_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "ts_public_subnet" {
  vpc_id     = aws_vpc.ts_vpc.id
  cidr_block = cidrsubnet(aws_vpc.ts_vpc.cidr_block, 3, 1)

  tags = {
    Name = "ts public subnet"
  }
}

resource "aws_subnet" "ts_private_subnet" {
  availability_zone = "eu-north-1a"
  vpc_id            = aws_vpc.ts_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.ts_vpc.cidr_block, 5, 1)

  tags = {
    Name = "ts private subnet"
  }
}

resource "aws_subnet" "ts_database_subnet" {
  availability_zone = "eu-north-1b"
  vpc_id            = aws_vpc.ts_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.ts_vpc.cidr_block, 7, 1)

  tags = {
    Name = "ts database subnet"
  }
}

resource "aws_internet_gateway" "ts_gw" {
  vpc_id = aws_vpc.ts_vpc.id

  tags = {
    Name = "ts igw"
  }
}

resource "aws_route_table" "ts_public_rt" {
  vpc_id = aws_vpc.ts_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ts_gw.id
  }

  tags = {
    Name = "ts public rt"
  }
}

# FIX: the private subnet had no route to the NAT gateway, so the backend
# could not reach the internet (apt, updates, external APIs).
resource "aws_route_table" "ts_private_rt" {
  vpc_id = aws_vpc.ts_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ts_ng.id
  }

  tags = {
    Name = "ts private rt"
  }
}

resource "aws_route_table" "ts_database_rt" {
  vpc_id = aws_vpc.ts_vpc.id

  tags = {
    Name = "database rt"
  }
}

resource "aws_route_table_association" "ts_public_association" {
  subnet_id      = aws_subnet.ts_public_subnet.id
  route_table_id = aws_route_table.ts_public_rt.id
}

resource "aws_route_table_association" "ts_private_association" {
  subnet_id      = aws_subnet.ts_private_subnet.id
  route_table_id = aws_route_table.ts_private_rt.id
}

resource "aws_route_table_association" "ts_database_association" {
  subnet_id      = aws_subnet.ts_database_subnet.id
  route_table_id = aws_route_table.ts_database_rt.id
}

# FIX: only one Elastic IP is used (by the NAT gateway). The second one was
# unused and AWS charges for every public IPv4 address.
resource "aws_eip" "example" {
  count  = 1
  domain = "vpc"
}

resource "aws_nat_gateway" "ts_ng" {
  subnet_id     = aws_subnet.ts_public_subnet.id
  allocation_id = aws_eip.example[0].id

  tags = {
    Name = "gw NAT"
  }
  depends_on = [aws_internet_gateway.ts_gw]
}

# -----------------------------------------------------------------------------
# Security groups
# FIX: aws_security_group (new groups), NOT aws_default_security_group, which
# edits the VPC's single default group and made all three blocks collide.
# -----------------------------------------------------------------------------
resource "aws_security_group" "public_server" {
  name        = "ts-public-server"
  description = "Frontend: web traffic from the internet"
  vpc_id      = aws_vpc.ts_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Optional SSH, only from your own IP and only when admin_cidr is set.
  dynamic "ingress" {
    for_each = var.admin_cidr == null ? [] : [var.admin_cidr]
    content {
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
}

resource "aws_security_group" "private_server" {
  name        = "ts-private-server"
  description = "Backend: reachable only from the frontend"
  vpc_id      = aws_vpc.ts_vpc.id

  ingress {
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
}

resource "aws_security_group" "database_server" {
  name        = "ts-database-server"
  description = "Database: reachable only from the backend"
  vpc_id      = aws_vpc.ts_vpc.id

  ingress {
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
}

# -----------------------------------------------------------------------------
# Servers
# FIX: every instance now has a subnet_id inside ts_vpc, which removes the
# "security group and subnet belong to different networks" error.
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "ts_frontend_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.ts_public_subnet.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.public_server.id]
  key_name                    = var.ssh_key_name

  tags = {
    Name = "frontend server"
  }
}

resource "aws_instance" "ts_backend_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.ts_private_subnet.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.private_server.id]
  key_name                    = var.ssh_key_name

  tags = {
    Name = "backend server"
  }
}

# -----------------------------------------------------------------------------
# Database
# FIXES: attached to your subnet group and security group (before, it landed in
# the default VPC), password comes from a variable, storage encrypted, and the
# engine moved to MySQL 8.4 because 8.0 is past standard support.
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "ts_rds_subnet_group" {
  name       = "ts_subnet"
  subnet_ids = [aws_subnet.ts_private_subnet.id, aws_subnet.ts_database_subnet.id]

  tags = {
    Name = "My DB subnet group"
  }
}

resource "aws_db_instance" "ts_db" {
  allocated_storage      = 10
  db_name                = "my_ts_db"
  engine                 = "mysql"
  engine_version         = "8.4"
  instance_class         = "db.t3.micro"
  username               = "mytsuser"
  password               = var.db_password
  parameter_group_name   = "default.mysql8.4"
  db_subnet_group_name   = aws_db_subnet_group.ts_rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.database_server.id]
  publicly_accessible    = false
  storage_encrypted      = true
  skip_final_snapshot    = true
}

# -----------------------------------------------------------------------------
# Forget the old default-security-group resources WITHOUT deleting anything.
# (Needs Terraform 1.7+. You can delete these blocks after one successful apply.)
# -----------------------------------------------------------------------------
removed {
  from = aws_default_security_group.public_server
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_default_security_group.private_server
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_default_security_group.database_server
  lifecycle {
    destroy = false
  }
}

# -----------------------------------------------------------------------------
# Useful values after apply
# -----------------------------------------------------------------------------
output "frontend_public_ip" {
  value = aws_instance.ts_frontend_server.public_ip
}

output "backend_private_ip" {
  value = aws_instance.ts_backend_server.private_ip
}

output "db_endpoint" {
  value = aws_db_instance.ts_db.address
}