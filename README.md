# Compie DevOps Home Assignment

A minimal FastAPI app, containerized with Docker and deployed to AWS with Terraform.
It runs on EC2 instances in an Auto Scaling Group in **private subnets**, behind a public
Application Load Balancer. It uses DynamoDB, ECR, SSM Parameter Store, CloudWatch
Logs and Alarms, and KMS encryption at rest. Every push to `main` is tested, built and rolled
out by GitHub Actions.

> **Status:** deployed and verified end to end on 2026-10-19 (us-east-1). See
> [Deployment evidence](#deployment-evidence). The environment is torn down after
> submission to avoid cost; `terraform apply` recreates it in about 10 minutes.

## Contents

- [Architecture](#architecture)
- [Application and Docker](#application-and-docker)
- [Deploy to AWS](#deploy-to-aws)
- [CI/CD (GitHub Actions)](#cicd-github-actions)
- [Security and IAM](#security-and-iam)
- [Capacity and scaling](#capacity-and-scaling)
- [Logging, monitoring and alerting](#logging-monitoring-and-alerting)
- [Deployment evidence](#deployment-evidence)
- [Assignment requirements checklist](#assignment-requirements-checklist)
- [Troubleshooting](#troubleshooting)
- [Lessons learned](#lessons-learned)
- [Cost and teardown](#cost-and-teardown)
- [How AI assistance was used](#how-ai-assistance-was-used)

## Architecture

```mermaid
flowchart TB
  user([Internet user]) -->|HTTP :80| alb
  gha([GitHub Actions]) -->|OIDC role: push image, set tag, start refresh| ecr & ssm & asg

  subgraph vpc[VPC 10.0.0.0/16, us-east-1a + us-east-1b]
    subgraph pub[Public subnets]
      alb[Application Load Balancer<br/>SG: 80 from internet]
      nat[NAT Gateway]
    end
    subgraph priv[Private subnets, no public IPs]
      asg[Auto Scaling Group, 2 x t3.micro<br/>Docker container on :8000<br/>SG: 8000 from ALB only, egress 443]
    end
    s3ep[S3 gateway endpoint]
    ddbep[DynamoDB gateway endpoint]
  end

  alb -->|HTTP :8000, health check /health| asg
  asg -->|ECR API, SSM, CloudWatch Logs| nat
  asg -->|image layers, dnf repos| s3ep
  asg -->|GetItem, only via this endpoint| ddbep --> ddb[(DynamoDB<br/>KMS-encrypted)]
  ecr[(ECR)] --- asg
  ssm[(SSM Parameter Store<br/>SecureString)] --- asg
  asg -->|awslogs| cw[CloudWatch Logs]
  alb -.metrics.-> alarms[CloudWatch Alarms] --> sns[SNS topic] --> mail([Email])
```

| Component | Responsibility |
|---|---|
| **ALB** (public subnets) | Only entry point from the internet. Forwards to instances on port 8000 and health-checks `/health`. |
| **Auto Scaling Group** (private subnets) | 2 instances, one per AZ. Replaces instances that fail the ALB health check, and rolls out new versions with instance refresh. |
| **Launch template + `user_data`** | Amazon Linux 2023, IMDSv2 only, encrypted gp3. At boot: installs Docker, reads config from SSM, pulls the image from ECR, runs the container with CloudWatch logging. |
| **NAT Gateway** (one) | Outbound HTTPS for the private instances (ECR API, SSM, CloudWatch Logs). |
| **S3 and DynamoDB gateway endpoints** (free) | Keep image layers, OS packages and database traffic on the AWS network. |
| **ECR** | Container registry with immutable tags (git SHA) and scan on push. |
| **SSM Parameter Store** | Welcome message and table name as SecureString (KMS), plus the deployed `image_tag`. |
| **DynamoDB** | Managed, private (IAM + VPC endpoint), on-demand, KMS-encrypted. |
| **CloudWatch Logs, Alarms + SNS** | Logs per instance; 3 alarms → SNS → email. |
| **GitHub Actions + OIDC** | Test → build → push → set tag → instance refresh → smoke test. No AWS keys stored in GitHub. |

### Repository layout

```
app/                     FastAPI app (main.py), tests, Dockerfile, requirements
docker-compose.yml       local stack: app + DynamoDB Local
terraform/bootstrap/     one-time: S3 state bucket + ECR repository (local state)
terraform/               main stack (S3 backend, native locking)
  versions.tf            providers, backend, default tags
  network.tf             VPC, subnets, IGW, NAT, routes, gateway endpoints, security groups
  alb.tf                 ALB, target group, listener
  compute.tf             log group, launch template, Auto Scaling Group
  user_data.sh.tftpl     instance boot script
  dynamodb.tf            table
  ssm.tf                 app config parameters + image_tag
  iam.tf                 EC2 instance role
  ci.tf                  GitHub OIDC provider + CI/CD role
  monitoring.tf          SNS topic + CloudWatch alarms
.github/workflows/       CI/CD pipeline
evidence/                screenshots and redacted CLI output from the live deployment
```

The Terraform is deliberately flat, one file per concern with no custom modules,
so each resource is easy to find and explain.

## Application and Docker

| Path | Purpose | Response |
|---|---|---|
| `/` | App name, deployed version (git SHA), welcome message, status | `200` |
| `/health` | **Liveness.** No dependencies. Used by the ALB and the Docker `HEALTHCHECK`. | `200 {"status":"ok"}` |
| `/ready` | **Readiness.** A real DynamoDB `GetItem`. | `200`, or `503` when the database is unreachable |

**Why two health endpoints.** If the ALB health check depended on DynamoDB, one database
problem would mark every instance unhealthy and the ASG would keep replacing healthy
instances, turning a dependency outage into a full outage. `/ready` reports the
database instead, and the 5xx alarm watches it.

**What `/ready` proves.** It calls `GetItem` on the key `pk = "healthcheck"`; the item does not
need to exist. Success shows that:

- the DynamoDB endpoint is reachable,
- the request was signed with valid credentials,
- IAM allows `GetItem` on the table,
- the table exists and serves reads.

It does **not** prove write permissions or direct `kms:Decrypt` rights, because DynamoDB
decrypts server-side. Errors are logged; the response stays generic.

**Configuration** comes only from environment variables. In AWS, the boot script reads
them from SSM.

| Variable | Required | Source in AWS |
|---|---|---|
| `WELCOME_MESSAGE` | yes | SSM `/compie-app/dev/welcome_message` (SecureString) |
| `DYNAMODB_TABLE_NAME` | yes | SSM `/compie-app/dev/table_name` (SecureString) |
| `AWS_REGION` | yes | boot script |
| `APP_NAME` | no | default `compie-app` |
| `APP_VERSION` | no | baked into the image at build time (git SHA). It is build metadata, not config. |
| `DYNAMODB_ENDPOINT_URL` | no | local only (DynamoDB Local) |

**Dockerfile practices:**

- `python:3.12-slim` base.
- Dependencies installed before the code is copied, so that layer stays cached.
- `--no-cache-dir`.
- Non-root user (UID 10001, no login shell); code is root-owned and read-only.
- `PYTHONUNBUFFERED` so logs reach CloudWatch immediately.
- Exec-form `CMD` so uvicorn is PID 1 and receives SIGTERM.
- `HEALTHCHECK` on `/health`.
- Allow-list `.dockerignore`.
- Final image size: 161 MB.

### Run and test locally

```bash
docker compose up --build -d      # app + DynamoDB Local + one-shot table creation
curl localhost:8000/ ; curl localhost:8000/health ; curl localhost:8000/ready
docker compose stop dynamodb-local
curl -i localhost:8000/ready      # 503: real connection failure
curl -i localhost:8000/health     # still 200
docker compose down
```

Unit tests run in the same Python version as the image. On Git Bash for Windows, prefix
the command with `MSYS_NO_PATHCONV=1`.

```bash
docker run --rm -v "$PWD/app:/src:ro" -w /src python:3.12-slim \
  sh -c "pip install -q -r requirements-dev.txt && pytest -v -p no:cacheprovider"
```

There are 10 tests: `/`, `/health`, `/ready` against mocked DynamoDB (moto), and the failure
cases: missing table, unreachable endpoint (a real connection refusal), and missing
configuration.

## Deploy to AWS

Prerequisites: Terraform >= 1.10, AWS CLI v2, Docker, and an admin AWS profile for
provisioning (region `us-east-1`).

There are two stacks, applied in order, so `-target` is never needed. The bootstrap stack
creates ECR, so the first image exists before the Auto Scaling Group launches.

```bash
# 1. Bootstrap (one time): S3 state bucket + ECR repository
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply

# 2. Push the first image, tagged with the git SHA
REPO=$(terraform -chdir=terraform/bootstrap output -raw ecr_repository_url)
TAG=$(git rev-parse --short HEAD)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build --build-arg APP_VERSION="$TAG" -t "$REPO:$TAG" app && docker push "$REPO:$TAG"

# 3. Main stack (44 resources, about 5 minutes)
terraform -chdir=terraform init -backend-config="bucket=$(terraform -chdir=terraform/bootstrap output -raw state_bucket)"
terraform -chdir=terraform apply -var="image_tag=$TAG" -var="alert_email=you@example.com"
terraform -chdir=terraform output alb_url
```

- **Health checks:** instances become healthy in the target group about 2–5 minutes after
  apply (the ASG health check grace period is 300s).
- **`image_tag`** is used only on the first apply. Afterwards the pipeline owns the SSM
  parameter, and Terraform ignores changes to its value.
- **Pass `alert_email` on every apply.** Omitting it makes Terraform plan to delete the
  subscription.

## CI/CD (GitHub Actions)

Workflow: [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml).

| Trigger | Runs |
|---|---|
| Pull request | `test` job only (pre-merge check) |
| Push to `main` | `test`, then `deploy` to `dev` |
| Manual (`workflow_dispatch`) | `test`, then `deploy` to `dev` |

`deploy` steps:

1. **AWS login via OIDC.** GitHub holds no AWS keys. The role trusts only the `main` branch
   of this repository. GitHub's `sub` claim uses immutable IDs:
   `repo:AmirWeiser@123477471/compie-devops-assignment@1424430511:ref:refs/heads/main`.
   That also blocks a deleted-and-recreated repo with the same name.
2. **Build and push** `compie-app:<short git SHA>` to ECR, with
   `--build-arg APP_VERSION=<sha>`. Tags are immutable; a re-run reuses the existing image.
3. **Set the image tag** in SSM `/compie-app/dev/image_tag`.
4. **Instance refresh** with `MinHealthyPercentage=100`, `MaxHealthyPercentage=200`, and
   `SkipMatching=false`.
   - New instances launch before old ones terminate, so capacity never drops.
   - Each new instance reads the tag from SSM at boot.
   - Every instance is replaced even though the launch template has not changed.
   - The job polls until the refresh reports `Successful`. A `concurrency` group prevents
     overlapping refreshes.
5. **Smoke test** through the ALB: `/health`, `/ready` and `/`, then it checks that the ALB
   serves **exactly the version just deployed**.

**One-time setup:** create a repository **variable** (not a secret) `AWS_ROLE_ARN` with the
`ci_role_arn` Terraform output.

**Rollback:** re-run the workflow for the previous commit. Or, manually:

```bash
aws ssm put-parameter --name /compie-app/dev/image_tag --value <previous-sha> --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name compie-app-dev \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":200}'
```

## Security and IAM

**Private compute and least-privilege networking:**

| Security group | Inbound | Outbound |
|---|---|---|
| `alb` | TCP 80 from `0.0.0.0/0` | TCP 8000 to the `app` SG only |
| `app` | TCP 8000 from the `alb` SG only | TCP 443 only (AWS APIs and packages) |

- Instances have **no public IPs** and **no SSH**. Shell access goes through SSM Session
  Manager.
- AWS's default allow-all outbound rule is removed.

**IAM is split by responsibility:**

| Identity | Can | Cannot |
|---|---|---|
| **EC2 instance role** | Pull from the `compie-app` ECR repo; `ssm:GetParameter` on `/compie-app/dev/*`; write to the app log group; SSM agent; `dynamodb:GetItem` on the app table **only through the VPC endpoint** (`aws:SourceVpce`) | Write to DynamoDB, scan, change parameters, push images |
| **CI/CD role** (GitHub OIDC) | Push to the `compie-app` ECR repo; `ssm:PutParameter` on `image_tag` only; `StartInstanceRefresh` on this ASG; describe refreshes and load balancers | **Read app config**, `kms:Decrypt`, DynamoDB, other repos |
| **Terraform operator** | Admin, used only from the operator's workstation | — |

These were verified live and with the IAM policy simulator; see
[`evidence/cli/`](evidence/cli). A leaked instance credential cannot read the table from
outside the VPC: the simulator returns `implicitDeny` without the endpoint context.

**Encryption at rest (AWS-managed KMS keys):**

- DynamoDB: `aws/dynamodb`.
- SSM SecureString: `aws/ssm`.
- EBS: `aws/ebs`.
- State bucket: SSE-S3, with versioning, all public access blocked, and
  `force_destroy = false` to protect state history.

**Secrets:** none in the repo or the image. Config lives in SSM. The alert email is passed
at apply time, not committed.

**Known trade-offs:**

- `AmazonSSMManagedInstanceCore` (the AWS policy for the SSM agent) also allows
  `ssm:GetParameter` on `*`. A custom agent policy would remove that.
- The ALB serves HTTP only; HTTPS needs a domain and an ACM certificate.
- The SNS topic is unencrypted, because CloudWatch can publish only to topics encrypted
  with a customer-managed key, and alerts contain no sensitive data.

## Capacity and scaling

- **Now:** `min 2 / desired 2 / max 4`, one instance per AZ, so the app survives the loss of
  an instance or an AZ for inbound traffic. `max 4` leaves room for the 200% rolling deploy.
- **Self-healing:** ELB health checks with a 300s grace period. An instance failing
  `/health` is replaced automatically.
- **How I would scale:**
  - Add a target-tracking policy (average CPU 50%, or ALB requests per target) between min
    and max.
  - Raise `max_size` for peaks.
  - Use a larger instance type if a single request needs more CPU or memory.
  - The app is stateless and DynamoDB is on-demand, so horizontal scaling needs no code
    change.
- **For production:** one NAT per AZ (or interface endpoints) instead of the single NAT
  Gateway, which is a cost trade-off. Also a baked AMI to cut boot time, which is about
  80s, mostly the Docker install.

## Logging, monitoring and alerting

**Logs:** container stdout/stderr goes through the Docker `awslogs` driver to the CloudWatch
log group `/compie-app/dev`. There is **one log stream per EC2 instance ID**, with 7-day
retention. Uvicorn access logs show the real client IP (`FORWARDED_ALLOW_IPS`). Boot
progress (`user-data:` lines) is visible in the EC2 console output without SSH.

**Alarms** (`terraform/monitoring.tf`):

| Alarm | Metric | Fires when | Why |
|---|---|---|---|
| `compie-app-dev-unhealthy-hosts` | `UnHealthyHostCount` (max) | > 0 for 3 consecutive minutes | An instance fails `/health` (boot failure, crashed container, bad image). 3 minutes so a deploy blip does not page. |
| `compie-app-dev-no-healthy-hosts` | `HealthyHostCount` (min) | < 1 for 2 minutes; missing data = breaching | The service is down for users. |
| `compie-app-dev-target-5xx` | `HTTPCode_Target_5XX_Count` (sum) | >= 5 in 5 minutes | Server errors, including `/ready` 503s, so this is also the DynamoDB connectivity signal. |

**Notification flow:** CloudWatch alarm → SNS topic `compie-app-dev-alerts` → email. Both
`ALARM` and `OK` transitions are sent, so you also get "recovered" messages.

- **Real setup:** the topic would also feed the on-call tool: PagerDuty or Opsgenie through
  an HTTPS subscription, or Slack through AWS Chatbot.
- **Test the wiring safely:** this changes only the alarm state, which returns at the next
  evaluation.

  ```bash
  aws cloudwatch set-alarm-state --alarm-name compie-app-dev-unhealthy-hosts \
    --state-value ALARM --state-reason "Manual test of alert wiring"
  ```

## Deployment evidence

All of this was captured from the live environment on 2026-10-19. Screenshots are real
browser captures. CLI evidence is read-only output with the account ID, the alert email
and client IPs redacted.

**Workflow runs:**

| Run | Commit | Result | Notes |
|---|---|---|---|
| [#1](https://github.com/AmirWeiser/compie-devops-assignment/actions/runs/39223860793) | `9851d3b` | ❌ deploy failed at AWS login | OIDC `sub` format mismatch; see [Lessons learned](#lessons-learned) |
| [#2](https://github.com/AmirWeiser/compie-devops-assignment/actions/runs/39224324049) | `33657ed` | ✅ 7m54s | First automated deployment after the trust-policy fix |
| [#3](https://github.com/AmirWeiser/compie-devops-assignment/actions/runs/39227466875) | `78dc9e1` | ✅ 7m40s | App change: `/` reports the version; the smoke test checks it |

**Instance refreshes:** `2b22df50…` Successful in 6m40s, and `0da3a977…` Successful in
6m28s. Both refreshes replaced both instances, with no 5xx responses from the ALB or the
targets and no alarm transitions during the rollouts. (Only the smoke tests sent traffic
then.)

**ECR images:** `45cc857` (manual bootstrap push), `33657ed` and `78dc9e1` (pushed by CI).
After run #3, both instances were running `compie-app:78dc9e1` with
`APP_VERSION=78dc9e1`, checked with `docker ps` on each instance through SSM.

**Alert test:** `SetAlarmState` → `ALARM` at 08:23:08 UTC → back to `OK` at 08:23:48. Both
SNS actions succeeded; SNS delivered 2 messages with 0 failed.

| Screenshot | Shows |
|---|---|
| [01-app-root-live-alb.png](evidence/screenshots/01-app-root-live-alb.png) | Live app through the public ALB, version `78dc9e1` |
| [02-app-health-live-alb.png](evidence/screenshots/02-app-health-live-alb.png) | `/health` through the ALB |
| [03-app-ready-live-alb.png](evidence/screenshots/03-app-ready-live-alb.png) | `/ready` through the ALB: DynamoDB reachable |
| [04-local-docker-root.png](evidence/screenshots/04-local-docker-root.png) | Image running locally: `/` |
| [05-local-docker-health.png](evidence/screenshots/05-local-docker-health.png) | Image running locally: `/health` |
| [10-github-actions-run3-success.png](evidence/screenshots/10-github-actions-run3-success.png) | Run #3: test + deploy succeeded |
| [14-github-actions-run2-success.png](evidence/screenshots/14-github-actions-run2-success.png) | Run #2: first successful deployment |
| [15-github-actions-run1-oidc-failure.png](evidence/screenshots/15-github-actions-run1-oidc-failure.png) | Run #1: the OIDC failure, kept for transparency |
| [12-github-commit-history.png](evidence/screenshots/12-github-commit-history.png) | Commit history |
| [13-github-repository.png](evidence/screenshots/13-github-repository.png) | Repository |

| CLI evidence | Shows |
|---|---|
| [01-local-docker-run.txt](evidence/cli/01-local-docker-run.txt) | Local run, non-root user, image size, `/ready` 503 during a simulated DB outage while `/health` stays 200 |
| [02-aws-network.txt](evidence/cli/02-aws-network.txt) | Subnets, NAT, routes, gateway endpoints, security group rules |
| [03-aws-compute-alb-asg.txt](evidence/cli/03-aws-compute-alb-asg.txt) | ASG sizing; 2 instances in 2 AZs with private IPs, no public IPs and IMDSv2; healthy targets; instance refreshes |
| [04-aws-ecr-ssm-dynamodb.txt](evidence/cli/04-aws-ecr-ssm-dynamodb.txt) | ECR image tags; SSM parameter **names** (no values); DynamoDB SSE (KMS) |
| [05-aws-instances-running-image.txt](evidence/cli/05-aws-instances-running-image.txt) | Image and version running on each instance |
| [06-aws-cloudwatch-logs.txt](evidence/cli/06-aws-cloudwatch-logs.txt) | Application logs from both instance streams |
| [07-aws-alerting.txt](evidence/cli/07-aws-alerting.txt) | SNS topic and confirmed subscription, alarm configuration, the `SetAlarmState` test |

## Assignment requirements checklist

| Requirement | Where |
|---|---|
| Minimal app exposing `/` and `GET /health` | `app/main.py`; screenshots 01–02 |
| Dockerfile; image runs locally and `/`, `/health` work | `app/Dockerfile`, `docker-compose.yml`; screenshots 04–05, `cli/01` |
| VPC with public and private subnets | `network.tf`; `cli/02` |
| EC2 in an ASG in private subnets, no public IPs | `compute.tf`; `cli/03` |
| Public ALB in front of the ASG | `alb.tf`; screenshots 01–03 |
| Launch template, target group, health checks, sensible min/desired/max | `compute.tf`, `alb.tf` |
| README explains capacity and scaling | [Capacity and scaling](#capacity-and-scaling) |
| No ECS or EKS | EC2 + Docker only |
| Least-privilege security groups | `network.tf`; [Security and IAM](#security-and-iam) |
| Image in ECR | `terraform/bootstrap`; `cli/04` |
| Config outside the image, in a managed store, consumed by the service | `ssm.tf`, `user_data.sh.tftpl` |
| Instance profile: ECR pull, read config, write logs, SSM | `iam.tf` |
| CI/CD identity: push to ECR and trigger rollout, cannot read secrets | `ci.tf` (verified with the policy simulator) |
| No oversized admin identity | Separate instance and CI roles |
| Managed, private DB; no hardcoded credentials | `dynamodb.tf` (IAM + VPC endpoint condition) |
| App proves DB connectivity | `/ready`; screenshot 03 |
| Logs in CloudWatch | `compute.tf`, `user_data`; `cli/06` |
| KMS at rest for the DB and the config store | DynamoDB `aws/dynamodb`, SSM `aws/ssm` (plus EBS) |
| Alarms on service state, sent to an endpoint, documented | `monitoring.tf`; `cli/07`; [Alerting](#logging-monitoring-and-alerting) |
| `terraform apply` (+ documented bootstrap) gives a working URL | [Deploy to AWS](#deploy-to-aws) |
| Pipeline builds, pushes to ECR and deploys to `dev` with no console steps | `deploy.yml`; runs #2 and #3 |
| Release trigger documented | [CI/CD](#cicd-github-actions) |
| No secrets in the zip | `.gitignore`; checked before each commit |
| Browser screenshot of the live app | `evidence/screenshots/01–03` |
| Bonus: architecture diagram, AI notes, encrypted EBS | Done |
| Bonus: PR / pre-merge checks | Configured (`test` job runs on `pull_request`), not yet exercised with a real PR |
| Bonus: dashboard, customer-managed KMS key, HTTPS, scaling policy, second environment | Not done (out of scope by choice) |

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Targets `unhealthy`, instances replaced repeatedly | Boot script failed (Docker install, SSM read, ECR pull) | `aws ec2 get-console-output --instance-id <id> --latest --output text \| grep user-data:` shows each step and the failing line. Or `aws ssm start-session --target <id>`, then `sudo cat /var/log/cloud-init-output.log`. |
| Instances never appear in SSM | No outbound path | NAT state; private route `0.0.0.0/0 → NAT`; app SG egress 443 |
| `/ready` returns 503 | IAM, the endpoint condition, or the table | The log stream shows the boto error (`AccessDenied`, `ResourceNotFound`, ...) |
| `/ready` AccessDenied | Request did not go through the DynamoDB gateway endpoint | Private route table has the DynamoDB prefix-list route |
| Container cannot get credentials | IMDS hop limit | Launch template `http_put_response_hop_limit = 2` |
| ALB returns 502/503 | No healthy targets | Target health; the app must listen on port 8000 |
| Pipeline: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC trust mismatch | CloudTrail `AssumeRoleWithWebIdentity` events show the exact `sub` claim GitHub sent; it must match `github_repository` in `ci.tf`. Also: the workflow runs on `main`, `AWS_ROLE_ARN` is set, and there is no `environment:` key in the job. |
| Pipeline: `InstanceRefreshInProgress` | A refresh is already running | Wait, or `aws autoscaling describe-instance-refreshes` |

## Lessons learned

1. **GitHub's OIDC `sub` claim uses immutable IDs.**
   - **What happened:** the first pipeline run failed to assume the role. CloudTrail
     showed the real claim: `repo:Owner@<id>/repo@<id>:ref:...`, not `repo:Owner/repo:...`.
   - **Fix:** the trust policy now matches the exact claim.
   - **Lesson:** debug from the provider's own audit log, not from assumptions.
2. **A just-created NAT Gateway can be briefly unreliable.**
   - **What happened:** on the very first apply, outbound HTTPS through the brand-new NAT
     timed out for a few minutes. One instance's boot took about 240s, overran the 180s
     grace period, and was replaced. Later boots take about 80s.
   - **Fix:** a 300s grace period, plus retries in `user_data`.
   - **Diagnosis:** the `user-data:` lines in the console output.
3. **Bash: never log to stdout inside a function used in `$(...)`.** Retry messages would
   become part of the captured value. Writing the log to stderr fixed it; a local test with
   a stubbed `aws` CLI caught it before deployment.
4. **`environment:` in a GitHub job changes the OIDC `sub` claim** to
   `...:environment:<name>`. That would break a branch-based trust policy, so the deploy job
   doesn't set it.
5. **Separate liveness from readiness.** This keeps a database incident from becoming an
   instance-replacement storm.

## Cost and teardown

Approximate us-east-1 cost while the main stack runs:

| Resource | Per day |
|---|---|
| NAT Gateway + Elastic IP | ~$1.20 |
| ALB + 2 public IPv4 | ~$0.80 |
| 2 × t3.micro + 2 × 8 GB gp3 | ~$0.55 |
| DynamoDB on-demand, SSM, CloudWatch Logs and alarms, ECR, S3 | cents |
| **Total** | **~$2.5/day** |

**Teardown:**

```bash
# All hourly-billed resources (NAT, ALB, EC2, ...):
terraform -chdir=terraform destroy -var="image_tag=unused" -var="alert_email=you@example.com"
```

To also remove the bootstrap stack (ECR and the state bucket, cents per month):

1. Empty the state bucket, including **all object versions**. It has
   `force_destroy = false` on purpose.
2. Run `terraform -chdir=terraform/bootstrap destroy`. ECR has `force_delete = true`, so its
   images are removed too.

## How AI assistance was used

The PDF encourages AI use, so here is how this project was built.

**Tool:** Claude Code (Anthropic), used as a pair engineer in the terminal.

**What the AI did:**

- Read the assignment PDF and proposed a staged plan.
- Wrote the application, Dockerfile, Terraform, workflow and README.
- Ran local tests and linters (pytest, `terraform validate`, actionlint, shellcheck).
- Ran `terraform plan` and, after approval, `apply`.
- Investigated failures through CloudTrail, the EC2 console output and SSM Run Command.
- Collected the evidence in `evidence/`.

**What I controlled:** I set rules up front. The AI worked in small stages, explained each
stage before building it, and waited for my explicit approval before:

- any implementation step,
- any `terraform apply` or `destroy`,
- any git commit or push.

Plans were reviewed resource by resource before every apply.

**Decisions I made or changed:**

- Split `/health` (liveness) from `/ready` (readiness) instead of one DB-coupled health check.
- Required the AI to state precisely what a DynamoDB `GetItem` does and does not prove
  (no claim about KMS permissions).
- Imposed a strict simplicity rule, which cut the first app version from four modules to
  one file and removed speculative features.
- One NAT Gateway plus gateway endpoints; AWS-managed KMS keys; ECR in the bootstrap stack
  instead of `-target`; `force_destroy = false` on the state bucket.
- Tore the network down overnight to avoid cost, and redeployed the next day.

**Verification over trust:** nothing was reported as working until it was checked on the
running system. That means target health, `docker ps` on each instance, IAM checks (live
allowed/denied calls and the policy simulator), the alarm-to-SNS test, and the ALB serving
the deployed version. The failures above were found this way and fixed, not hidden.
