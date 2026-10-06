# EKS cluster on AWS (us-east-1) with 3 worker nodes

Terraform project that creates:

- a **VPC** (3 private + 3 public subnets across 3 availability zones, 1 NAT gateway)
- an **EKS control plane** (the "master" node, run and scaled by AWS, not an EC2 instance you manage)
- a **managed node group** of **3 EC2 worker nodes** (default `m6i.2xlarge`, 8 vCPU / 32 GB each)

It is built so that `terraform destroy` removes everything, including the load
balancers, volumes and network interfaces that Kubernetes creates behind
Terraform's back.

> **First run:** this project was syntax-checked but not run against AWS. Run
> `terraform init && terraform validate` before your first apply, and if
> anything fails, fix it before building.

---

## 1. Project layout

```
.
├── versions.tf               Terraform + AWS provider versions, default tags
├── variables.tf              All inputs, with validation
├── main.tf                   VPC, EKS cluster, node group, destroy-time cleanup
├── outputs.tf                Cluster name, endpoint, kubectl command
├── terraform.tfvars.example  Copy to terraform.tfvars and edit
├── README.md                 This file
└── scripts/
    ├── preflight.sh          Checks tools, credentials and vCPU quota before apply
    ├── pre-destroy.sh        Cleans up Kubernetes-created AWS resources (runs automatically on destroy)
    ├── verify-destroyed.sh   Proves nothing was left behind after destroy
    └── destroy.sh            terraform destroy + verify-destroyed.sh in one command
```

---

## 2. Prerequisites

You need these on the machine that runs Terraform:

| Tool | Minimum | Check with |
|---|---|---|
| Terraform | 1.5.7 | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| kubectl | any recent | `kubectl version --client` |
| jq | any | `jq --version` |
| bash | 4+ | `bash --version` |

Install examples:

```bash
# macOS (Homebrew)
brew install terraform awscli kubectl jq

# Ubuntu / Debian: AWS CLI, kubectl and Terraform come from their vendors' repos.
sudo apt-get install -y jq
# Follow the official install pages for terraform, awscli and kubectl.
```

**Windows:** use **WSL2 (Ubuntu)** or Git Bash. The scripts are bash scripts.

### AWS credentials

```bash
aws configure                 # or: aws configure sso
aws sts get-caller-identity   # confirms you are logged in
```

The identity needs permission to create VPCs, EC2, EKS, IAM roles/policies, KMS
keys and load balancers. For a personal or learning account,
`AdministratorAccess` is the simplest. In a company account, ask for a role
that allows those services.

The identity that runs `terraform apply` is the one that gets **admin access to
the cluster**. Use the same profile later when you run `kubectl`.

---

## 3. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. The only required value is your public IP, which is
the only address allowed to reach the Kubernetes API:

```hcl
api_allowed_cidrs = ["203.0.113.10/32"]   # find yours: curl -s https://checkip.amazonaws.com
```

All options:

| Variable | Default | Meaning |
|---|---|---|
| `api_allowed_cidrs` | none (**required**) | CIDRs allowed to reach the Kubernetes API |
| `region` | `us-east-1` | AWS region |
| `cluster_name` | `heavy-cluster` | Cluster name, also the `Project` tag on every resource |
| `kubernetes_version` | `1.36` | Use a version still in standard support (see the [EKS version calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)) |
| `node_instance_type` | `m6i.2xlarge` | `c7i.*` for CPU-heavy, `r7i.*` for memory-heavy jobs |
| `node_count` | `3` | Number of worker nodes |
| `node_disk_size_gb` | `100` | Root volume per node |
| `vpc_cidr` | `10.0.0.0/16` | VPC address range |
| `enable_control_plane_logs` | `false` | CloudWatch control plane logs (off to avoid log-group leftovers) |
| `destroy_cleanup_enabled` | `true` | Run `scripts/pre-destroy.sh` on destroy |

---

## 4. Create the cluster

```bash
# 1. Make sure the scripts are executable (once)
chmod +x scripts/*.sh

# 2. Check tools, credentials and vCPU quota
./scripts/preflight.sh

# 3. Create everything (about 15-20 minutes)
terraform init
terraform validate
terraform plan
terraform apply
```

If preflight reports that your vCPU quota is too low, request an increase in
**Service Quotas > Amazon EC2 > Running On-Demand Standard instances**
(quota code `L-1216C47A`), or choose a smaller `node_instance_type` or
`node_count`. Three `m6i.2xlarge` nodes need 24 vCPUs.

---

## 5. Connect to the cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name heavy-cluster
# (or run: terraform output configure_kubectl)

kubectl get nodes          # expect 3 nodes, all Ready
kubectl get pods -A        # system pods should be Running
```

### From VS Code

1. Install the **Kubernetes** extension (`ms-kubernetes-tools.vscode-kubernetes-tools`).
   Optionally also **HashiCorp Terraform** (`hashicorp.terraform`).
2. Open the **Kubernetes** icon in the sidebar. The `heavy-cluster` context is read
   from `~/.kube/config`.
3. Expand it to browse Nodes, Workloads and Services. Right-click a pod for
   **Logs**, **Terminal** or **Describe**.
4. Open any YAML file, right-click and choose **Kubernetes: Apply** to deploy it.
5. The integrated terminal (`` Ctrl+` ``) works too, with the same kubeconfig.

---

## 6. Run a test job

```bash
kubectl create job hello --image=busybox -- echo "hello from EKS"
kubectl wait --for=condition=complete job/hello --timeout=120s
kubectl logs job/hello
kubectl delete job hello
```

For real jobs, always set resource requests and limits so the scheduler can
place them well across the 3 nodes:

```yaml
resources:
  requests: { cpu: "4", memory: 8Gi }
  limits:   { cpu: "8", memory: 16Gi }
```

---

## 7. Changing the cluster later

Edit `terraform.tfvars`, then:

```bash
terraform plan
terraform apply
```

| Want to | Change |
|---|---|
| Different instance size | `node_instance_type` (nodes are replaced one at a time) |
| More or fewer nodes | `node_count` |
| New public IP | `api_allowed_cidrs` (only updates the allowlist) |
| Upgrade Kubernetes | `kubernetes_version`, one minor version at a time |

---

## 8. Destroy everything

```bash
./scripts/destroy.sh
```

This runs `terraform destroy` and then `scripts/verify-destroyed.sh`. Add
`-auto-approve` to skip the confirmation prompt: `./scripts/destroy.sh -auto-approve`.

Plain `terraform destroy` also works, because the cleanup runs automatically.

### What happens during destroy

1. `scripts/pre-destroy.sh` runs first, while the cluster still exists. It:
   - deletes Ingresses, `LoadBalancer` Services, workloads and PVCs
   - waits for the AWS load balancers to disappear and removes leftover `k8s-*` security groups and target groups
   - scales the node group to 0 and waits for the instances to terminate
   - deletes orphaned (detached) network interfaces
2. Terraform destroys the node group, the cluster and the VPC.
3. `scripts/verify-destroyed.sh` searches AWS for anything still tagged with your
   cluster and exits with an error if it finds something.

Destroy takes about 15-25 minutes. If it is interrupted, **run it again**:
every step is safe to repeat.

### Why destroy used to fail

| Cause | Handled by |
|---|---|
| Load balancers, volumes and security groups created by Kubernetes (unknown to Terraform) block VPC deletion | `pre-destroy.sh` |
| Leaked network interfaces block security group deletion | `pre-destroy.sh` sweeps them |
| Slow but healthy deletes reported as errors | Longer create/delete timeouts |
| CloudWatch log group re-created by EKS after deletion | Logging off by default |

### Good to know

- **KMS keys are never deleted instantly.** AWS keeps the cluster's key in "pending deletion" for 7 days (the minimum). The verify script treats that as clean. It costs a small amount until the key is removed.
- **Cleanup deletes every load balancer and detached network interface in this project's VPC.** That is safe because this project owns the VPC. Never point it at a shared VPC.
- **The tagging API is eventually consistent**, so the verify script re-checks for up to 2 minutes before reporting leftovers.
- If destroy stops because `kubectl` or API access is unavailable and you never deployed anything to the cluster, run: `SKIP_K8S_CLEANUP=1 terraform destroy`.

---

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `api_allowed_cidrs` validation error | Set it in `terraform.tfvars` as a list, e.g. `["1.2.3.4/32"]` |
| `kubectl` times out | Your IP changed. Update `api_allowed_cidrs` and `terraform apply` |
| `You must be logged in to the server` / access denied | Use the same AWS profile that ran `terraform apply` (`export AWS_PROFILE=...`) |
| Nodes stuck in `NotReady` or node group create fails | Check the vCPU quota and that the NAT gateway was created; look at the node group's Health issues in the EKS console |
| `UnauthorizedOperation` / `AccessDenied` during apply | The AWS identity is missing permissions (EKS, EC2, IAM, KMS) |
| `VcpuLimitExceeded` | Raise the quota or use fewer or smaller nodes |
| Destroy fails with `DependencyViolation` | Run `./scripts/destroy.sh` again. If it persists, run `./scripts/verify-destroyed.sh` to see what is left |
| `pre-destroy.sh: kubectl not found` | Install kubectl, or use `SKIP_K8S_CLEANUP=1` if nothing was deployed |
| Cluster gone but kubeconfig entry remains | `kubectl config delete-context <name>` |
| Wrong cluster in VS Code | `kubectl config get-contexts`, then `kubectl config use-context <name>` |

---

## 10. Cost while running (approximate, us-east-1)

- EKS control plane: about **$0.10/hour**
- 3 x `m6i.2xlarge` On-Demand: about **$0.38/hour each**
- NAT gateway: about **$0.045/hour** plus data processing
- EBS volumes (3 x 100 GB gp3) and any load balancers or volumes your jobs create

Prices change; check the AWS pricing pages. **Destroy the cluster when you are
not using it.**

---

## 11. Security notes

- The Kubernetes API is reachable only from `api_allowed_cidrs`. Never use `0.0.0.0/0`.
- Worker nodes are in private subnets with no public IPs.
- Node root volumes are encrypted. Kubernetes secrets are encrypted with a KMS key.
- Do not commit `terraform.tfvars` or `*.tfstate` files to git. Terraform state can contain sensitive values. For a team, use an S3 backend with locking.
