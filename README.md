# Distributed Inference on AWS

Two EC2 instances running a distributed inference pipeline using the [iii](https://iii.dev) worker framework. Provisioned entirely with Terraform.

---

## AWS Infrastructure

```
                          ┌──────────────── VPC 10.0.0.0/16 ────────────────┐
                          │                                                   │
Internet ──► IGW ──►      │  Public Subnet 10.0.1.0/24                       │
                          │  ┌──────────────────────────────┐                │
                          │  │  api-gateway (t3.micro)       │                │
                          │  │  Ubuntu 22.04                 │                │
                          │  │  - iii engine  :49134         │                │
                          │  │  - iii-http    :3111          │                │
                          │  │  - caller-worker (systemd)    │                │
                          │  └──────────────┬───────────────┘                │
                          │                 │ ws://10.0.1.x:49134            │
                          │  Private Subnet 10.0.2.0/24                      │
                          │  ┌──────────────▼───────────────┐                │
                          │  │  inference-worker (t3.micro)  │                │
                          │  │  Ubuntu 22.04, 20GB EBS       │                │
                          │  │  - Python + llama-cpp-python  │                │
                          │  │  - gemma-3-270m-Q8_0.gguf    │                │
                          │  └──────────────────────────────┘                │
                          │                 │                                 │
                          │                 ▼                                 │
                          │       NAT Gateway (EIP)                           │
                          │       └──► IGW ──► Internet                       │
                          │           (model download only)                   │
                          └───────────────────────────────────────────────────┘
```

### Terraform resources

| Resource | Purpose |
|---|---|
| `aws_vpc.main` | VPC with DNS hostnames enabled, CIDR 10.0.0.0/16 |
| `aws_subnet.public` | api-gateway lives here, map_public_ip_on_launch = true |
| `aws_subnet.private` | inference-worker lives here, no public IP |
| `aws_internet_gateway.gw` | Outbound internet for public subnet |
| `aws_eip.nat` + `aws_nat_gateway.nat` | Lets the private VM reach the internet for pip install and model download |
| `aws_route_table.public` | Default route → IGW |
| `aws_route_table.private` | Default route → NAT gateway |
| `aws_security_group.api_sg` | Port 3111 open to internet, port 49134 open from private subnet only, port 22 from `var.ssh_allowed_cidr` |
| `aws_security_group.worker_sg` | All TCP from VPC CIDR (10.0.0.0/16) — api-gateway needs to be able to reach the worker |
| `aws_key_pair.deployer` | Deploys your public key to both instances |
| `aws_instance.api_gateway` | t3.micro, public subnet, runs iii engine + caller-worker via user_data |
| `aws_instance.inference_worker` | t3.micro, private subnet, 20GB EBS, runs Python inference worker via user_data |
| `data.aws_ami.ubuntu` | Always resolves to latest Ubuntu 22.04 LTS (Canonical owner ID) |

### Security groups

**api_sg (api-gateway):**
```
ingress  0.0.0.0/0          tcp  3111   # HTTP inference API
ingress  10.0.2.0/24        tcp  49134  # iii WebSocket — inference worker only
ingress  var.ssh_allowed_cidr tcp  22   # SSH
egress   0.0.0.0/0          all  *      # unrestricted
```

**worker_sg (inference-worker):**
```
ingress  10.0.0.0/16        tcp  0-65535  # all internal VPC traffic
egress   0.0.0.0/0          all  *        # NAT gateway → internet
```

---

## Variables (`terraform/variables.tf`)

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `instance_type` | `t3.micro` | api-gateway instance type |
| `inference_instance_type` | `t3.micro` | inference-worker instance type |
| `public_key_path` | — | Path to your SSH public key (required) |
| `ssh_allowed_cidr` | `0.0.0.0/0` | CIDR allowed to SSH into api-gateway |
| `repo_url` | — | Git repo URL cloned into /opt/app on both VMs (required) |

---

## Deploy

```bash
cd terraform

cp terraform.tfvars.example terraform.tfvars
# fill in public_key_path and repo_url

terraform init
terraform apply
```

Outputs after apply:
```
api_gateway_public_ip      = "x.x.x.x"
inference_worker_private_ip = "10.0.2.x"
```

---

## First-boot setup

`user_data` installs dependencies and sets up systemd services automatically. Two manual steps are needed once after the first apply:

### Inference worker (SSH via jump host)

```bash
ssh-add /path/to/keypair.pem
ssh -A -J ubuntu@<api_gateway_public_ip> ubuntu@<inference_worker_private_ip>

# The EBS volume is 20GB but the OS partition starts at 8GB — grow it
sudo growpart /dev/nvme0n1 1
sudo resize2fs /dev/nvme0n1p1
df -h /   # should show ~20GB

# 4GB swap so the model can load on 1GB RAM
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# llama-cpp-python compiles from source (~10 min on t3.micro)
sudo pip3 install llama-cpp-python huggingface-hub

sudo systemctl restart inference-worker
sudo journalctl -u inference-worker -f
# wait for: Inference worker started - listening for calls
```

### API gateway

```bash
ssh ubuntu@<api_gateway_public_ip>

sudo tee /etc/systemd/system/caller-worker.service << 'EOF'
[Unit]
Description=iii caller worker
After=iii-engine.service

[Service]
WorkingDirectory=/opt/app/quickstart/workers/caller-worker
ExecStart=/opt/app/quickstart/workers/caller-worker/node_modules/.bin/tsx src/worker.ts
Restart=on-failure
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now caller-worker
```

---

## Test

```bash
curl -s -X POST http://<api_gateway_public_ip>:3111/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello, what is 2+2?"}]}' | jq .
```

```json
{
  "result": {
    "response": "4",
    "success": "You've connected two workers and they're interoperating seamlessly..."
  }
}
```

---

## What I fixed

**Terraform (most of the work was here):**
- The starter had no AMI data source — it used a hardcoded `ami_id` variable that defaulted to an Amazon Linux 2 AMI. Amazon Linux 2 ships glibc 2.26 which is too old for the iii binary and Node.js 20. Added a `data "aws_ami" "ubuntu"` block pointing at Ubuntu 22.04 (Canonical owner `099720109477`) so the AMI always resolves to the latest Jammy LTS.
- No NAT gateway — the private subnet had a route table but nowhere to route outbound traffic. The inference worker couldn't run `pip install` or download the model. Added `aws_eip`, `aws_nat_gateway`, and a private route table pointing at it.
- The inference worker had no `root_block_device` block so it got the default 8GB EBS volume. That's not enough room for Python packages (~2GB), the GGUF model (~270MB), and OS overhead. Set `volume_size = 20`.
- `worker_sg` only allowed ingress from `10.0.2.0/24` (the private subnet itself). The api-gateway is at `10.0.1.x` so it couldn't reach the worker. Changed to `aws_vpc.main.cidr_block` (10.0.0.0/16).
- Added `ssh_allowed_cidr`, `inference_instance_type`, and `repo_url` variables that were missing.

**Application:**
- `config.yaml` had `host: 127.0.0.1` on the HTTP plugin — changed to `0.0.0.0`
- The iii-worker VM sandbox requires KVM which isn't available on EC2 (no nested virtualization). The caller-worker's TypeScript code never executed. Removed it from config.yaml and run it as a standalone systemd service instead.
- Switched inference backend from transformers to llama-cpp-python. transformers de-quantizes GGUF tensors to float32 at load time — the model fit in RAM but inference was too slow (~60-120s per query) for the 30s invocation timeout. llama-cpp-python runs the Q8 weights natively and completes in 5-10s.
- iii-sdk version on caller-worker was 0.11.0, iii binary was 0.12.0 — updated to match.

---

## Production hardening

**AWS/Terraform changes I'd make:**

- Move Terraform state to S3 + DynamoDB (`backend "s3"` block) — right now it's local and would be a problem with any team or CI pipeline
- Lock `ssh_allowed_cidr` to your office IP or a bastion host, not `0.0.0.0/0`
- Replace the EC2 key pair on the inference worker with SSM Session Manager — no inbound SSH needed at all for the private VM
- Put an ALB in front of port 3111 with an ACM certificate so the API is HTTPS
- Use an ASG for the inference worker (`aws_autoscaling_group`, min=1) so it recovers automatically if the instance dies
- Bake the model and Python dependencies into a custom AMI (`aws_ami` from Packer). Right now the model downloads from HuggingFace on every fresh instance and llama-cpp-python compiles from source — that's a 15-20 minute boot time
- The NAT gateway costs ~$35/month idle. For a dev setup use a NAT instance (`fck-nat` or similar) in the public subnet instead
- Add an IAM instance profile to the inference worker with read-only access to an S3 bucket where the model is stored — faster and cheaper than downloading from HuggingFace every time
- Add CloudWatch alarms on the inference worker's memory and CPU — it's running close to the limit and will silently OOM without any alerting
