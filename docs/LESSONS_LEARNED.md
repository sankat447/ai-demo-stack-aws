# AI Demo Stack — IaC Lessons Learned

Hard-won lessons from provisioning, troubleshooting, and tearing down this stack. Read this before making any structural change.

---

## 1. OCP IPI creates its own VPC — Aurora/EFS must live there

`openshift-install` creates a separate VPC (`<cluster_name>-*-vpc`) with the **same CIDR** as the Terraform VPC (`10.0.0.0/16`). Two VPCs with the same CIDR **cannot be peered**, so anything pods need to reach by IP (RDS, EFS, ElastiCache, MQ) must live in the OCP VPC, not the TF VPC.

**Implementation**: `environments/demo/main.tf` uses `data.aws_vpc.ocp` (lookup by tag `<cluster_name>-*-vpc`) + `data.aws_subnets.ocp_private`. Aurora and EFS modules consume those subnets.

S3/Lambda/ECR can stay in the TF VPC since pods reach them by public DNS via NAT.

## 2. `credentialsMode: Mint` requires static IAM keys, not SSO

openshift-install rejects STS session tokens for Mint mode. The cloud-credential-operator needs AKIA-style permanent keys.

**Implementation**: `deploy.sh` auto-creates an `ocp-installer` IAM user with `AdministratorAccess` and caches the secret in `.ocp-installer-creds.json` (gitignored). After install, the static key isn't used at runtime — IRSA + CCO-managed secrets take over.

## 3. macOS BSD sed `-i` text injection is broken across line boundaries

`sed -i.bak '/x/i\\\nfoo\\\nbar' f` works on GNU sed but silently collapses to a single line on BSD sed (macOS default). Original symptom: MachineSet YAMLs had `id: ami-... placement:` joined, YAML parser failed.

**Implementation**: `modules/compute/main.tf` uses awk for multi-line injection — portable across BSD/GNU.

## 4. Service Mesh enrollment + STRICT mTLS quietly breaks router routes

Namespaces with `maistra.io/member-of=istio-system` get an auto-created NetworkPolicy that only permits OCP router ingress to pods labeled `maistra.io/expose-route="true"`. Without the label, TLS handshake completes but routing to the backend silently times out.

**Implementation**: All deployments in mesh-member namespaces (`ai-demo`, `langchain`) have `maistra.io/expose-route: "true"` on the pod template.

## 5. Terraform cycle: OCP module can't depend on EFS/Aurora

Aurora/EFS depend on `data.aws_vpc.ocp` (which depends on `module.ocp`). If `module.ocp` also references `module.efs.file_system_id`, terraform produces a graph cycle.

**Implementation**: `null_resource.efs_storage_class` lives in `environments/demo/main.tf` (env-level), not inside `module.ocp`.

## 6. Data source `depends_on` blocks plan-time `count` evaluation

`data.aws_subnets.ocp_private` with `depends_on = [module.ocp]` becomes "known after apply", which makes `count = length(var.subnet_ids)` invalid (count must be known at plan time).

**Implementation**: `deploy.sh` runs a **2-phase apply** — first `terraform apply -target=module.ocp` to bring the OCP VPC into existence, then a full `terraform apply` to create Aurora/EFS in the discovered VPC.

## 7. StorageClass parameters are immutable

`oc apply` on a StorageClass with changed `parameters` fails with "Forbidden: updates to parameters are forbidden". Affects `efs-sc` whenever the EFS file system ID changes.

**Implementation**: `null_resource.efs_storage_class` does `oc delete --ignore-not-found && oc apply`.

## 8. Aurora cluster parameter group + subnet group don't auto-delete with cluster

`aws rds delete-db-cluster` removes only the cluster + instances. The `db_subnet_group` and `db_cluster_parameter_group` linger; subsequent apply fails with "AlreadyExists".

**Implementation**: `destroy.sh` Phase 9 explicitly deletes them as residual cleanup.

## 9. EFS PVCs survive EFS deletion as zombies

PV references the EFS ID directly via `csi.volumeHandle`. When EFS is recreated with a new ID, old PVs/PVCs point to the deleted FS and pods hang in `ContainerCreating` with mount errors.

**Implementation**: When rebuilding EFS, `oc delete pvc <name>` + remove finalizers (`oc patch pvc <name> --type=merge -p '{"metadata":{"finalizers":null}}'`) on every PVC bound to the old FS.

## 10. CloudBeaver setup-window expires after 1 hour

First-boot security feature: if the admin setup wizard isn't completed within ~1 hour, the server self-locks and requires restart.

**Workaround**: `oc rollout restart deploy/cloudbeaver -n rhoai-tools` resets the window.

## 11. Don't expect a UI on every deployed service

Several apps in this stack are API-only by design:
- **portkey** — open-source AI Gateway is API-only (`/v1/chat/completions`); the dashboard is a separate commercial product
- **langchain-server** — LangGraph Server with `/assistants`, `/threads`, `/runs/stream`; use `/docs` for Swagger
- **prometheus-k8s** + **alertmanager-main** — routes only expose `/api`; UIs moved to OCP Console → Observe post-4.11
- **istio-ingressgateway** — internal mesh ingress, 503 on `/` is normal until VirtualServices exist

## 12. Service Account references must include the SA definition

A Deployment with `serviceAccountName: foo` referencing a SA that doesn't exist will produce `ReplicaFailure: FailedCreate` forever. If the pod uses non-default UIDs (`runAsUser: 0` or specific 1000), also add a `RoleBinding` to `system:openshift:scc:anyuid`.

**Implementation**: `gitops/config/apps/n8n.yaml` has both `ServiceAccount` and `RoleBinding` defined.

## 13. destroy.sh must destroy Aurora/EFS BEFORE openshift-install destroy

Aurora and EFS live in the OCP-installed VPC (lesson #1). When `openshift-install destroy cluster` runs, it tries to delete the VPC; NAT gateways won't terminate while Aurora ENIs and EFS mount target ENIs occupy the private subnets. Result: the installer enters an **infinite NAT-gateway delete-retry loop**.

**Implementation**: `destroy.sh` Phase 2.5 runs `terraform destroy -target=module.aurora -target=module.efs` (plus security groups + `null_resource.efs_storage_class`) before Phase 3.

## 14. grep alternation is BRE — use `-E` for `\|`

`grep "^a\|^b"` silently matches nothing because BRE treats `\|` as a literal two-char sequence. This caused destroy.sh Phase 2.5 guard to never fire — `grep -qE "^a|^b"` is the fix.

## 16. Phase 2.5 needs AWS-direct fallback (orphaned Aurora/EFS)

If terraform state is wiped or out of sync, `module.aurora` / `module.efs` aren't in state — Phase 2.5 says "skipping pre-destroy" — but Aurora/EFS may still exist in AWS, blocking openshift-install destroy via their ENIs. Caused a long-running NAT-gateway loop on 2026-06-26.

**Implementation**: Phase 2.5 now scans AWS directly for any Aurora cluster starting with `${PROJECT}-${ENV}` (default `ai-demo`) and any EFS file system with a Name tag matching the same prefix. Deletes them (with proper instance/mount-target ordering) regardless of TF state.

## 17. `data.aws_vpc.ocp` blocks `terraform destroy` after OCP is gone

After `openshift-install destroy` removes the OCP VPC, any subsequent `terraform plan/apply/destroy` fails at the refresh phase with `Error: no matching EC2 VPC found` for `data.aws_vpc.ocp` — blocking destroy of everything else in state (TF VPC, S3, ECR, Lambda, route53).

**Implementation**: `destroy.sh` Phase 5 detects this exact error string in the destroy log and retries with `-refresh=false`. The retry-after-reauth path also uses `-refresh=false` to be safe.

## 18. `openshift-install destroy` aborts if metadata.json missing

If a prior teardown succeeded partially (cluster gone) but the script was killed before residual cleanup, `metadata.json` is removed but the install-dir still exists. The next `destroy.sh` run hits Phase 3 → `openshift-install destroy` errors → `set -euo pipefail` kills the whole script → Phases 4-9 never run.

**Implementation**: Phase 3 now checks for BOTH `$INSTALL_DIR` AND `$INSTALL_DIR/metadata.json` before invoking the installer. Missing metadata.json → log a warning and skip. Also added `|| true` and explicit RC capture so a non-zero installer exit doesn't kill the script.

## 15. `terraform destroy -target` needs ALL dependents

Targeted destroy of `module.aurora` and `module.efs` once reported "0 destroyed" because `null_resource.efs_storage_class` had a dependency on `module.efs.file_system_id`. Terraform refused to drop the chain unless the dependent was also targeted.

**Pattern**: when running `terraform destroy -target=X`, also target every resource that references X.

---

## Recovery patterns

- **State drift after manual fixes**: `terraform state rm <resources>` + AWS CLI delete + `terraform apply` is usually faster than `terraform destroy -target` (cycles, dependency resolution).
- **ArgoCD reverts hot-patches**: any `oc set env / oc patch` to a Deployment is undone on next sync. For real fixes, edit the manifest in `gitops/config/apps/`, commit + push.
- **ArgoCD reads from GitHub remote**: local commits don't reach it without `git push origin main`.
- **IAM `AccessKeysPerUser: 2` error**: list existing keys with `aws iam list-access-keys --user-name ocp-installer`, delete the oldest with `aws iam delete-access-key --access-key-id <id>`, remove `.ocp-installer-creds.json`, re-run `./deploy.sh`.
