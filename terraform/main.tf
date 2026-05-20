data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# NAT gateway so the private inference VM can reach the internet (pip install, model download)
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.gw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.gw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "api_sg" {
  vpc_id = aws_vpc.main.id

  # Public HTTP inference endpoint
  ingress {
    from_port   = 3111
    to_port     = 3111
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # iii engine WebSocket — inference worker connects from private subnet
  ingress {
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.private.cidr_block]
  }

  # SSH — restrict to your IP in production
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "worker_sg" {
  vpc_id = aws_vpc.main.id

  # Allow all internal VPC traffic so api_gateway can also reach this host if needed
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = file(var.public_key_path)
}

resource "aws_instance" "api_gateway" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.api_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.deployer.key_name
  tags = { Name = "api-gateway" }

  user_data = <<EOF
#!/bin/bash
set -e
apt-get update -y
apt-get install -y git curl jq

# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# iii CLI
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
export PATH="/root/.local/bin:$$PATH"

# Project
git clone ${var.repo_url} /opt/app
cd /opt/app/quickstart/workers/caller-worker
npm install

cat > /etc/systemd/system/iii-engine.service << 'SVCEOF'
[Unit]
Description=iii engine
After=network.target

[Service]
WorkingDirectory=/opt/app/quickstart
ExecStart=/root/.local/bin/iii --config /opt/app/quickstart/config.yaml
Restart=on-failure
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now iii-engine
EOF
}

resource "aws_instance" "inference_worker" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.inference_instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.worker_sg.id]
  associate_public_ip_address = false
  key_name                    = aws_key_pair.deployer.key_name
  tags = { Name = "inference-worker" }

  user_data = <<EOF
#!/bin/bash
set -e
apt-get update -y
apt-get install -y git python3 python3-pip jq

# Project
git clone ${var.repo_url} /opt/app
cd /opt/app/quickstart/workers/inference-worker
pip3 install -r requirements.txt

cat > /etc/systemd/system/inference-worker.service << 'SVCEOF'
[Unit]
Description=iii inference worker
After=network.target

[Service]
WorkingDirectory=/opt/app/quickstart/workers/inference-worker
ExecStart=/usr/bin/python3 /opt/app/quickstart/workers/inference-worker/inference_worker.py
Restart=on-failure
Environment=III_URL=ws://${aws_instance.api_gateway.private_ip}:49134

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now inference-worker
EOF
}
