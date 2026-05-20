# Distributed Inference on AWS with iii

This project deploys a distributed inference system across two EC2 instances using the [iii](https://iii.dev) worker framework. A public-facing API gateway handles HTTP requests and routes them to a private inference worker running gemma-3-270m (GGUF Q8) via llama.cpp.

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────┐
│  api-gateway (public subnet)        │
│  10.0.1.0/24                        │
│                                     │
│  iii engine   :49134  (WebSocket)   │
│  iii-http     :3111   (HTTP API)    │
│  caller-worker (tsx, systemd)       │
└──────────────┬──────────────────────┘
               │ WebSocket ws://10.0.1.x:49134
               ▼
┌─────────────────────────────────────┐
│  inference-worker (private subnet)  │
│  10.0.2.0/24                        │
│                                     │
│  Python worker + llama-cpp-python   │
│  gemma-3-270m-Q8_0.gguf            │
└─────────────────────────────────────┘
```

**Request flow:**
```
POST /v1/chat/completions
  → iii-http plugin
  → http::run_inference_over_http  (caller-worker)
  → inference::get_response        (caller-worker)
  → inference::run_inference       (inference-worker, private VM)
  → response back through chain
```

The inference worker lives in the private subnet with no public IP. It connects outbound to the iii engine over WebSocket — the engine never needs to reach into the private subnet.

---

## Prerequisites

- AWS account with credentials configured (`aws configure`)
- Terraform >= 1.3
- An EC2 key pair — generate one and note the path to the `.pem` file

---

## Deploy

```bash
cd terraform

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   public_key_path = "/path/to/your/keypair.pub"
#   repo_url        = "https://github.com/<you>/distributed-inference.git"

terraform init
terraform apply
```

Terraform provisions:
- VPC with public and private subnets
- NAT gateway (so the private VM can download the model on first boot)
- api-gateway EC2 (Ubuntu 22.04, t3.micro, public subnet)
- inference-worker EC2 (Ubuntu 22.04, t3.micro, private subnet, 20GB EBS)
- Security groups — port 3111 open to internet, port 49134 open only from private subnet

After `apply` you'll get:
```
api_gateway_public_ip      = "x.x.x.x"
inference_worker_private_ip = "10.0.2.x"
```

---

## First-boot setup (manual steps after terraform apply)

The user_data scripts handle installing dependencies and setting up systemd services on both VMs. But a few things need to be done manually once:

### On the inference worker (jump through api-gateway)

```bash
ssh-add /path/to/keypair.pem
ssh -A -J ubuntu@<api_gateway_ip> ubuntu@<inference_worker_private_ip>

# Expand filesystem to use the full 20GB EBS volume
sudo growpart /dev/nvme0n1 1
sudo resize2fs /dev/nvme0n1p1

# Add swap (model loading needs it on t3.micro)
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Install llama-cpp-python (compiles from source, takes ~10 min)
sudo pip3 install llama-cpp-python huggingface-hub

sudo systemctl restart inference-worker
sudo journalctl -u inference-worker -f
# Wait for: "Inference worker started - listening for calls"
```

### On the api-gateway

```bash
ssh ubuntu@<api_gateway_ip>

# Create the caller-worker systemd service
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

Expected response shape:
```json
{
  "result": {
    "response": "4",
    "success": "You've connected two workers and they're interoperating seamlessly..."
  }
}
```

---

## What I fixed from the starter code

The repo had a working skeleton but several things were broken or missing for actual deployment:

**Terraform:**
- No AMI data source — added `data "aws_ami" "ubuntu"` to pin to Ubuntu 22.04 (Amazon Linux 2's glibc 2.26 is too old for the iii binary and Node 20)
- No NAT gateway — the private inference VM couldn't reach the internet to download the model
- Missing `root_block_device` on inference worker — 8GB default was too small for the model + dependencies
- Security group for inference worker only allowed ingress from its own subnet; changed to full VPC CIDR so the api-gateway can reach it
- Added `ssh_allowed_cidr`, `inference_instance_type`, and `repo_url` variables

**config.yaml:**
- `host` was `127.0.0.1` — changed to `0.0.0.0` so external traffic reaches the iii-http endpoint
- Removed inference-worker from the managed workers list (iii-worker requires KVM for its VM sandbox, which EC2 doesn't support; the inference worker connects as a standalone process instead)

**inference_worker.py:**
- Worker name was `math-worker` instead of `inference-worker`
- Switched inference backend from transformers (which de-quantizes GGUF to float32, ~1GB RAM, too slow for 30s timeout) to llama-cpp-python (runs Q8 natively on CPU, 5-15x faster)
- Used few-shot completion prompt format since gemma-3-270m is a base model, not instruction-tuned

**requirements.txt:**
- Pinned `transformers<5.0.0` (5.x removed `gguf` from the package distribution mapping, breaking the GGUF loader)
- Replaced transformers+torch stack with llama-cpp-python after the performance issue was discovered

**caller-worker:**
- The iii-sdk was at 0.11.0 while the iii binary was 0.12.0 — updated to match
- Fixed response structure: `...result` spreads a Python string as `{}` in JS; changed to `response: result`

---

## Production hardening notes

Things I'd change before running this in production:

**Security:**
- `ssh_allowed_cidr` defaults to `0.0.0.0/0` — should be locked to a specific IP or bastion range
- The inference VM has no SSH access from outside at all (only via jump host) which is correct, but I'd also remove the key pair from it entirely and use SSM Session Manager instead
- The API has no authentication — add an API key check in the caller-worker before routing to inference

**Reliability:**
- The model download happens at service startup and isn't cached between restarts — pre-bake the model into an AMI or mount it from EFS
- llama-cpp-python is compiled from source on every fresh instance — add it to the AMI or use a pre-built Docker image
- Both VMs are single instances with no auto-recovery — put the inference worker in an ASG with min=1 to auto-replace failed instances

**Performance:**
- t3.micro (1 vCPU, 1GB RAM) with 4GB swap works but is slow (~5-10s per response for 32 tokens). For anything real, use at least a c5.xlarge for the inference VM, or switch to a GPU instance
- The iii-http `default_timeout` is 120s and the invocation timeout appears to be hardcoded at 30s — worth raising this if using larger models

**Infrastructure:**
- Terraform state is local — move it to S3 + DynamoDB for team use
- No TLS on port 3111 — put an ALB with ACM cert in front
- The NAT gateway costs ~$35/month even when idle — use a NAT instance instead for a dev environment
