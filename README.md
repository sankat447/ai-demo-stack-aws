# AI Demo Stack on AWS

**End-to-end OpenShift + RHOAI + GenAI-application demo platform, provisioned on AWS by a single `./deploy.sh`.**

One command spins up a production-shaped OpenShift 4.21 cluster with Red Hat OpenShift AI, a service mesh, a Postgres/pgvector database, shared file storage, and 28 GitOps-managed applications — including chat, workflow, observability, secrets, identity, and LLM inference. One command tears it back down to zero cost.

Built for internal demos of what's possible when you combine the OpenShift AI stack with a curated set of open-source tools.

---

## What you get

**Platform layer (AWS + OpenShift):**
- OpenShift 4.21 IPI cluster — 3 control-plane + 2 worker nodes + autoscaling compute & GPU pools
- Aurora PostgreSQL 16.4 Serverless v2 with `pgvector`
- EFS RWX shared storage (mount targets in every AZ)
- S3 data lake, ECR image repos, Lambda automations, Route53 DNS
- All secured behind a wildcard `*.apps.ai-demo.iisdemolab.click` domain with edge-terminated TLS

**Application layer (GitOps via OpenShift GitOps / ArgoCD, 28 apps):**

| Category | Apps |
|---|---|
| **AI / LLM** | KServe · vLLM ServingRuntime · llama-3-1-8b InferenceService · Portkey AI Gateway · LangGraph Server · Open WebUI |
| **Data** | MongoDB · Redis · MinIO (S3-compatible) · MLflow · CloudBeaver |
| **Workflow** | n8n · OpenShift Pipelines |
| **Platform** | RHOAI (Red Hat OpenShift AI) · Service Mesh (Istio) · Kiali · Jaeger/Tempo · Grafana |
| **Security** | Vault · Keycloak · Authorino |
| **Serverless** | Knative Serving |
| **Hardware acceleration** | NVIDIA GPU Operator · Node Feature Discovery |

Full architecture diagram, credentials, and app URLs are documented in [ONBOARDING.md](ONBOARDING.md).

---

## Quick start

**One-time prereqs** (see [ONBOARDING.md §1](ONBOARDING.md#1-prerequisites) for full details):
- AWS SSO access to the target AWS account with `SystemAdministrator` role
- Red Hat account (for the pull secret and OCM registration)
- Local tools: `aws` (v2), `terraform` (1.8.x), `oc` (4.21), `openshift-install` (4.21), `git`, `jq`
- SSH key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`

**Provision** (~50 minutes unattended):

```bash
git clone https://github.com/sankat447/ai-demo-stack-aws.git
cd ai-demo-stack-aws
./deploy.sh
# answer 'y' when prompted; two browser tabs will open for AWS + Red Hat SSO
```

**Access** (after deploy):

```bash
export KUBECONFIG=$PWD/environments/demo/ocp-install-dir/ai-demo/auth/kubeconfig
cat environments/demo/ocp-install-dir/ai-demo/auth/kubeadmin-password   # OCP admin
oc -n openshift-gitops get secret openshift-gitops-cluster \
  -o jsonpath='{.data.admin\.password}' | base64 -d ; echo               # ArgoCD admin
open https://console-openshift-console.apps.ai-demo.iisdemolab.click
```

**Tear down** (~30 minutes, back to $0/month):

```bash
./destroy.sh
# type 'destroy-demo' when prompted
```

---

## Onboarding a teammate

Everything they need is in [ONBOARDING.md](ONBOARDING.md) — clone, provision, smoke-test, day-2 ops, and teardown. Shareable Claude Code link:

**https://claude.ai/claude-code/onboard/4khj8kVyIWMR**

---

## Cost

| State | Per day | Per month |
|---|---|---|
| Full cluster running | ~$37 | ~$1,123 |
| Workers drained, masters stopped | ~$7 | ~$210 |
| Fully torn down (S3 state bucket only) | <$0.01 | <$0.50 |

**Always tear down or pause when not actively using.** Scripts for pause/resume are in [`scripts/`](scripts/) — see [ONBOARDING.md §7](ONBOARDING.md#7-day-2-ops).

---

## Repository layout

```
deploy.sh                    Full provisioning entry point
destroy.sh                   Full teardown entry point
ONBOARDING.md                Step-by-step runbook for new team members
docs/
  LESSONS_LEARNED.md         20 hard-won IaC patterns — READ BEFORE MODIFYING
environments/demo/           Terraform root module
modules/                     Reusable Terraform modules
  ocp-ipi/                     openshift-install wrapper
  aurora-serverless/           Aurora 16.4 + pgvector
  efs-storage/                 EFS with per-AZ mount targets
  compute/                     Autoscaling MachineSets (compute + GPU)
  vpc/, route53/, s3-data-lake/, security-groups/, ecr-repos/,
  lambda-automation/, iam-irsa/
gitops/
  bootstrap-argocd.sh          Installs GitOps operator + App-of-Apps
  config/apps/*.yaml           28 ArgoCD Application manifests
  config/platform/             Operator subscriptions, storage classes
scripts/
  power-on-and-scaleup-aws-demo.sh
  power-down-masters-aws-ocp.sh
  drain-workers-aws-ocp.sh
  reauth.sh                    Refresh expired SSO mid-session
templates/
  install-config.yaml.tpl      OCP IPI install-config template
```

---

## Architecture highlights (things that took multiple failed attempts to get right)

- **Aurora + EFS live in the OCP-installer VPC**, not the Terraform VPC — cross-VPC peering is impossible when both have the same CIDR (10.0.0.0/16). Data sources look up the OCP VPC by tag after installation.
- **Two-phase Terraform apply** — first `-target=module.ocp` to bring up the cluster + its VPC, then a full apply so the OCP-VPC data source can resolve for Aurora + EFS.
- **Static IAM credentials for `openshift-install`** — Mint mode rejects SSO/STS tokens. `deploy.sh` auto-creates and caches a dedicated `ocp-installer` IAM user's key.
- **Service Mesh + Router NetworkPolicy** — pods in mesh-member namespaces need `maistra.io/expose-route: "true"` on their pod template, or external routes silently time out post-TLS.

Full list: [docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md) — currently 20 patterns.

---

## Contributing

Before making any structural change to Terraform, deploy.sh, destroy.sh, or gitops manifests: **read [docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)**. It documents non-obvious gotchas from three cycles of provision → break → fix. Adding to it is expected — when you discover something new, append it before moving on.

---

## Contact

- **Sanjeev Kumar** (`skumar@iisl.com`) — original author, deep context
- **Jesse Barker** (`jbarker@iisl.com`) — AWS account admin
- OpenShift / RHOAI issues: open a case at https://console.redhat.com
