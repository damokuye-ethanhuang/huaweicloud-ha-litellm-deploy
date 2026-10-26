# Operations

## Daily checks

```bash
kubectl -n litellm get deploy,pods
kubectl -n litellm get pdb
curl -s https://<eip>/health/readiness | jq
```

The readiness payload reports `db: connected|disconnected`; a pod that cannot
reach PostgreSQL removes itself from the ELB rotation within a few probe
periods.

## Scaling

### Pods

```bash
helm upgrade litellm charts/litellm -n litellm \
  --reuse-values --set replicaCount=5
```

Before raising replicas, check the connection budget:

```
replicas x workers x database_connection_pool_limit  <  RDS max_connections
```

With the defaults (1 worker, pool 10), five replicas need 50 connections. The
gateway logs the per-pod budget at startup, so the real number is in the logs:

```
Postgres connection budget per pod = 1 worker(s) x writer connection_limit 10 = up to 10 connections
```

Autoscaling is disabled by default. If you enable it, size `maxReplicas` from
the database ceiling, not from CPU alone: LiteLLM needs minutes to become ready
(startup probe allows 300 s), so a late replica does not relieve a spike.

### Worker nodes

```hcl
cce_node_count_per_az = 2
```

`terraform apply` adjusts each node pool. If you scale manually in the console
instead, set `ignore_initial_node_count = true` in the CCE module to stop
Terraform from reverting it on the next apply.

## Upgrading LiteLLM

Migrations run before the rollout, and the database is not downgrade-safe.

1. Read the release notes for every version you cross. Look for "action
   required" and migration changes.
2. Take a manual RDS backup (or verify the automated one finished).
3. Change `litellm_version` in `terraform.tfvars`.
4. `make app-deploy`.

What happens:

- Helm runs the migration Job (`litellm --skip_server_startup`,
  `DISABLE_SCHEMA_UPDATE=false`) as a `pre-upgrade` hook;
- only if it succeeds does the Deployment roll, one pod at a time, with
  `maxSurge: 1` and `maxUnavailable: 0`;
- the ready pods keep serving during the whole rollout.

Time the migration on a restored copy of production first. Spend-log index
builds dominate the runtime on large databases.

### Rollback

```bash
helm -n litellm history litellm
helm -n litellm rollback litellm <revision>
```

Rolling back the image does **not** undo schema changes. If the new version
applied a migration, the old version may fail to start; restore the database
snapshot instead.

## Backup and restore

| Data | Mechanism | RPO |
|---|---|---|
| PostgreSQL | RDS automated backups, `rds_backup_keep_days` (default 7) | backup window |
| Redis | DCS persistence; cache loss is tolerable | cache only |
| Kubernetes objects | Git (this repository) | commit |
| Secrets | CSMS versions + Terraform state | last apply |

Restore procedure:

1. Restore the RDS backup to a **new** instance (console or
   `huaweicloud_rds_restore`).
2. Point `DATABASE_URL` at the new endpoint — update the Kubernetes Secret.
3. `kubectl -n litellm rollout restart deploy/litellm`.
4. Run `scripts/migrate.sh` if the restored snapshot is older than the running
   image.

## Secret rotation

| Secret | Rotatable | Procedure |
|---|---|---|
| Master key | Yes | Update `LITELLM_MASTER_KEY`, restart pods, distribute the new key to admins |
| Salt key | **No** | It encrypts provider credentials in the database; rotating it makes them unreadable |
| DB password | Yes | Change in RDS → update Secret → restart; also update CSMS |
| Redis password | Yes | Change in DCS → update Secret → restart |
| Provider keys | Yes | Edit `$LITELLM_DEPLOY_HOME/secrets/app.env` → `make app-deploy` |

Master key rotation is a hard cutover: LiteLLM accepts one master key at a
time. Announce the window, update the Secret, restart, then re-issue any
automation that used the old key.

## Certificate rotation

1. Upload the renewed certificate in SCM and push it to ELB.
2. Put the new ELB certificate ID in `certificate_id`.
3. `terraform apply` then `make app-deploy` (the annotation is rewritten).

Verify with:

```bash
openssl s_client -connect <eip>:443 -servername <your-domain> </dev/null 2>/dev/null |
  openssl x509 -noout -dates -subject
```

## Alarms

Alarms are opt-in (`enable_alarms = true`) because Cloud Eye metric names and
dimensions differ between regions. The default definition in
`terraform/examples/cce-ha/main.tf` watches the ELB unhealthy-backend metric.
Add RDS/DCS metrics only after confirming the names in the CES console for your
region.

SMN sends a confirmation email when `alarm_email` is set; the subscription does
not deliver anything until it is confirmed.

## Runbook

| Symptom | First action |
|---|---|
| ELB returns 502 | `kubectl -n litellm get pods`; check readiness and Service targetPort |
| Service stays `Pending` | Check ELB annotations in `scripts/deploy-app.sh` against the CCE version |
| Pods `CrashLoopBackOff` | `kubectl logs`; usually the database URL or a missing provider key |
| Readiness 503 `db: disconnected` | RDS failover, security group, or connection limit |
| `too many clients already` | Lower `database_connection_pool_limit` or raise RDS `max_connections` |
| 401 on `/v1/models` | Missing `Authorization: Bearer $LITELLM_MASTER_KEY` |
| Migration job failed | `kubectl logs job/...`; fix DB access, rerun `scripts/migrate.sh` |
| Provider credentials unreadable | Someone rotated `LITELLM_SALT_KEY`; re-enter credentials |
| Image pull errors | Mirror the image to SWR and update `litellm_image_repository` |

## On-call hygiene

- Never edit resources created by Terraform in the console; the next apply
  reverts them.
- Never delete the `litellm-secrets` Secret to "reset" something; it holds the
  salt key.
- Keep one known-good image tag in the release history for rollback.
