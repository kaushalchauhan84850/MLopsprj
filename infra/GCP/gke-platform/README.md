# gke-platform

Terraform for a small, private GKE cluster on Google Cloud (default `us-east1`),
plus scripts that make `terraform destroy` clean and prove it.

**What you get**

| Piece | Details |
|---|---|
| Control plane | 1 (zonal cluster, Google-managed, so there is no master VM to run or pay for) |
| Workers | 3 x `e2-standard-2`, fixed size, private IPs, Shielded Nodes, Workload Identity |
| Network | Custom VPC, one subnet with Pod/Service ranges, Cloud Router + Cloud NAT |
| IAM | Dedicated least-privilege node service account (non-authoritative role bindings) |

## Layout

```
.
├── versions.tf  providers.tf  variables.tf  locals.tf
├── apis.tf                 # Google APIs the stack needs
├── main.tf                 # wires the three modules together
├── outputs.tf
├── terraform.tfvars.example
├── backend.tf.example      # optional remote state in GCS
├── modules/
│   ├── network/            # VPC, subnet, router, NAT
│   ├── iam/                # node service account + roles
│   └── gke/                # cluster + worker node pool
├── scripts/
│   ├── preflight.sh        # BEFORE apply
│   ├── predestroy.sh       # BEFORE destroy
│   ├── destroy.sh          # the full teardown
│   ├── verifydestroy.sh    # AFTER destroy
│   └── lib/common.sh       # shared helpers
└── Makefile
```

## Prerequisites

Terraform >= 1.9, `gcloud`, `jq`, `kubectl`, and the auth plugin
(`gcloud components install gke-gcloud-auth-plugin`). An existing GCP project
with billing enabled, and:

```bash
gcloud auth login
gcloud auth application-default login
```

## Create

```bash
cp terraform.tfvars.example terraform.tfvars   # set project_id and authorized_networks
./scripts/preflight.sh                         # checks everything, ends with a terraform plan
terraform apply                                # about 10-15 minutes
$(terraform output -raw get_credentials_command)
kubectl get nodes                              # 3 nodes
```

## Destroy

```bash
./scripts/destroy.sh
```

That single command: confirms the project id, runs `predestroy.sh`, runs
`terraform destroy` (retried up to 3 times), then runs `verifydestroy.sh`.
You can also run the pieces yourself: `predestroy.sh`, `terraform destroy`,
`verifydestroy.sh`.

| Script | When | What it does |
|---|---|---|
| `preflight.sh` | before `apply` | tools and versions, gcloud login and ADC, project and billing, zone/machine type, CPU and disk quota, name collisions, `fmt`, `init`, `validate`, `plan` |
| `predestroy.sh` | before `destroy` | deletes Gateways, Ingresses, LoadBalancer Services, workloads, PVCs and PVs through Kubernetes, then waits until GCP has released the load balancer firewall rules and NEGs |
| `destroy.sh` | teardown | orchestrates the three steps above, with retries |
| `verifydestroy.sh` | after `destroy` | asks GCP directly whether anything is left (state, cluster, VMs, instance groups, NEGs, firewall rules, router/NAT, subnet, VPC, service account, IAM bindings, orphaned disks and forwarding rules) and prints the command to remove each leftover. Exit 0 = clean |

Settings are read from `terraform.tfvars` (or `TF_VAR_*`, or exported
`PROJECT_ID`, `ZONE`, `CLUSTER_NAME`, ...).

## Why destroy stays clean

1. **Dependency order.** Cluster -> network and IAM are wired through module
   inputs plus module-level `depends_on`, so Terraform deletes the worker pool,
   then the cluster, then IAM, then NAT/router/subnet/VPC.
2. **`deletion_protection = false`** is set explicitly. If you turn it on, apply
   `false` before destroying (predestroy.sh tells you).
3. **Resources Kubernetes creates behind Terraform's back** (load balancers,
   `k8s-*` firewall rules, NEGs, persistent disks) are removed by
   `predestroy.sh` first. They are the most common reason a VPC cannot be
   deleted and a destroy ends in an error state.
4. **Non-authoritative IAM** (`google_project_iam_member`) removes only its own
   bindings and never clobbers other people's.
5. **APIs stay enabled** (`disable_apis_on_destroy = false`). They are free, and
   disabling them is a classic source of "dependent services" errors. Set the
   variable to `true` if you really want them switched off.
6. **Retries** in `destroy.sh` cover GCP's asynchronous cleanup.
7. **Verification** by `verifydestroy.sh` checks GCP itself, not just
   Terraform's state.

## Notes

- Costs run while the cluster exists: 3 VMs, the Cloud NAT gateway, disks, and
  the GKE cluster management fee. Check current pricing on Google's GKE pages.
- `authorized_networks` defaults to `0.0.0.0/0` so you are never locked out.
  Change it to your own IP; preflight warns while it is open.
- Cheaper batch jobs: `use_spot_nodes = true` (nodes can be reclaimed).
- Commit `.terraform.lock.hcl` after the first `terraform init`.
- For team use, enable the GCS backend (`backend.tf.example`); keep the bucket
  outside this configuration so destroy never deletes its own state.
