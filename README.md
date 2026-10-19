# Compie DevOps Home Assignment

A minimal FastAPI app, containerized with Docker, deployed with Terraform to AWS:
EC2 instances in an Auto Scaling Group (private subnets) behind a public Application
Load Balancer, with DynamoDB, ECR, SSM Parameter Store, CloudWatch Logs and KMS
encryption at rest. Releases go through GitHub Actions.

> **Status:** app and Docker done and tested locally. Network stack applied and verified,
> then destroyed overnight to save cost. App infrastructure and CI/CD are written and
> validated locally but **not yet deployed**.

## Architecture

```
Internet
   │ HTTP :80
   ▼
ALB  (public subnets, us-east-1a/b)            SG alb: in 80 from 0.0.0.0/0, out 8000 to app SG
   │ HTTP :8000, health check GET /health
   ▼
ASG: 2 × EC2 t3.micro (private subnets, no public IPs, one per AZ)
     Docker container, IMDSv2 only       SG app: in 8000 from alb SG only, out 443 only
   │
   ├── NAT Gateway ──► ECR API, SSM, CloudWatch Logs
   ├── S3 gateway endpoint ──► ECR image layers, dnf repos
   └── DynamoDB gateway endpoint ──► DynamoDB table
```

## Repository layout

```
app/                     FastAPI app, tests, Dockerfile
docker-compose.yml       local stack: app + DynamoDB Local
terraform/bootstrap/     one-time: S3 state bucket + ECR repo (local state)
terraform/               main stack (S3 backend)
  versions.tf            providers, backend, default tags
  network.tf             VPC, subnets, IGW, NAT, routes, gateway endpoints, security groups
  dynamodb.tf            table (KMS-encrypted)
  ssm.tf                 app config parameters (SecureString) + image_tag
  iam.tf                 EC2 instance role
  ci.tf                  GitHub OIDC provider + CI/CD role
  alb.tf                 ALB, target group, listener
  compute.tf             log group, launch template, Auto Scaling Group
  monitoring.tf          SNS alerts topic + CloudWatch alarms
  user_data.sh.tftpl     instance boot script
.github/workflows/       CI/CD pipeline
```

## Application

| Path      | Purpose | Response |
|-----------|---------|----------|
| `/`       | App name, welcome message, status | `200` |
| `/health` | **Liveness**: no dependencies. Used by Docker `HEALTHCHECK` and the ALB. | `200 {"status":"ok"}` |
| `/ready`  | **Readiness**: real DynamoDB `GetItem` | `200` or `503` |

`/health` deliberately does not check the database. If the ALB health check depended on
DynamoDB, a database problem would mark every instance unhealthy and the ASG would keep
replacing healthy instances.

**What `/ready` verifies.** It calls `GetItem` on the fixed key `pk = "healthcheck"`
(the item does not need to exist). Success means: the DynamoDB endpoint is reachable,
the request was signed with valid credentials, IAM allows `dynamodb:GetItem` on the
table, and the table exists and can serve reads. It does **not** verify write
permissions, and it does **not** prove the caller has `kms:Decrypt` on the table key:
DynamoDB handles at-rest encryption server-side. Error details are logged; the HTTP
response stays generic.

**Configuration** comes only from environment variables. In AWS, the boot script reads
them from SSM Parameter Store.

| Variable | Required | Source in AWS |
|---|---|---|
| `WELCOME_MESSAGE` | yes | SSM `/compie-app/dev/welcome_message` (SecureString) |
| `DYNAMODB_TABLE_NAME` | yes | SSM `/compie-app/dev/table_name` (SecureString) |
| `AWS_REGION` | yes | boot script |
| `APP_NAME` | no | default `compie-app` |
| `DYNAMODB_ENDPOINT_URL` | no | local only (DynamoDB Local) |

## Run and test locally

```bash
docker compose up --build -d
curl localhost:8000/ ; curl localhost:8000/health ; curl localhost:8000/ready   # 200s
docker compose stop dynamodb-local
curl -i localhost:8000/ready        # 503
curl -i localhost:8000/health       # still 200
docker compose down
```

Unit tests (same Python as the image; on Git Bash for Windows prefix with `MSYS_NO_PATHCONV=1`):

```bash
docker run --rm -v "$PWD/app:/src:ro" -w /src python:3.12-slim \
  sh -c "pip install -q -r requirements-dev.txt && pytest -v -p no:cacheprovider"
```

DynamoDB Local speaks the real DynamoDB API, so `/ready` is an honest check locally. It does
not emulate IAM, KMS or VPC networking; those are verified in AWS.

## Deploy to AWS

Prerequisites: Terraform >= 1.10, AWS CLI v2, Docker, an AWS profile with admin rights
for provisioning (region `us-east-1`).

There are two stacks, applied in order. This avoids `terraform apply -target`: the ECR
repository exists and holds an image before the Auto Scaling Group first launches.

```bash
# 1. Bootstrap (one time): S3 state bucket + ECR repository
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply

# 2. Push the first image, tagged with the git SHA
REPO=$(terraform -chdir=terraform/bootstrap output -raw ecr_repository_url)
TAG=$(git rev-parse --short HEAD)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build -t "$REPO:$TAG" app && docker push "$REPO:$TAG"

# 3. Main stack
terraform -chdir=terraform init -backend-config="bucket=$(terraform -chdir=terraform/bootstrap output -raw state_bucket)"
terraform -chdir=terraform apply -var="image_tag=$TAG" -var="alert_email=you@example.com"
terraform -chdir=terraform output alb_url
```

`image_tag` is only used on the first apply. Afterwards the pipeline owns the SSM
parameter, and Terraform ignores changes to its value.

## CI/CD (GitHub Actions)

`.github/workflows/deploy.yml`:

| Trigger | What runs |
|---|---|
| Pull request | Unit tests only |
| Push to `main` | Tests, then deploy to `dev` |
| Manual (`workflow_dispatch`) | Tests, then deploy to `dev` |

Deploy steps:

1. Authenticate to AWS with **OIDC**. There are no AWS keys in GitHub. The role trusts
   only `repo:AmirWeiser/compie-devops-assignment:ref:refs/heads/main`.
2. Build the image and push it to ECR, tagged with the short git SHA. Tags are
   immutable; a re-run reuses the existing image.
3. Write the tag to SSM `/compie-app/dev/image_tag`.
4. Start an ASG **instance refresh** that replaces every instance. Replacements launch
   before old instances terminate (min 100% / max 200% healthy). New instances read the
   tag from SSM at boot. The job waits until the refresh reports `Successful`.
5. Smoke test `/health`, `/ready` and `/` through the ALB.

One-time setup: after `terraform apply`, copy the `ci_role_arn` output into a GitHub
repository **variable** (not a secret) named `AWS_ROLE_ARN`.

**Rollback:** run the workflow on the previous commit, or set the previous tag in SSM and
start an instance refresh:

```bash
aws ssm put-parameter --name /compie-app/dev/image_tag --value <previous-sha> --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name compie-app-dev \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":200}'
```

## Security

- **Private compute.** Instances are in private subnets with no public IP. Only the ALB
  security group can reach port 8000. There is no SSH; shell access goes through SSM
  Session Manager.
- **IAM split by responsibility.**
  - Instance role: pull from this ECR repo, read `/compie-app/dev/*` parameters, write
    to the app log group, use SSM. `dynamodb:GetItem` on the table only, and only through
    the VPC gateway endpoint (`aws:SourceVpce`).
  - CI role: push to ECR, write the `image_tag` parameter, start and describe instance
    refreshes. It **cannot** read app config or decrypt anything.
  - Terraform runs with a separate admin identity.
- **Encryption at rest with AWS-managed KMS keys:** DynamoDB (`aws/dynamodb`), SSM
  SecureString (`aws/ssm`), EBS (`aws/ebs`). The state bucket uses SSE-S3, with
  versioning and all public access blocked.
- **No secrets in the repo or the image.**
- **IMDSv2 only.** The hop limit is 2 so the container can reach the instance role
  credentials.

Known trade-off: `AmazonSSMManagedInstanceCore` (the AWS-managed policy for the SSM agent)
also allows `ssm:GetParameter` on `*`, so it is broader than our custom parameter
statement. A fully custom SSM agent policy would remove that; it was left out for
simplicity.

## Capacity and scaling

- **Current:** `min 2 / desired 2 / max 4`, one instance per AZ. This survives the loss
  of an instance or an AZ (inbound), and leaves headroom for rolling deploys.
- **Health:** the ASG uses ELB health checks (grace period 180s), so instances failing
  `/health` are replaced automatically.
- **How I would scale:** add a target-tracking policy (e.g. average CPU 50% or ALB
  requests per target) between min and max. Raise `max_size` for traffic peaks and use a
  larger instance type if a single request needs more CPU or memory. The app is stateless
  and DynamoDB is on-demand, so horizontal scaling needs no app changes.
- The single NAT Gateway is a cost trade-off. For production, use one NAT per AZ or
  interface endpoints.

## Logging and monitoring

- Container stdout/stderr goes to CloudWatch Logs group `/compie-app/dev`, one log
  stream per instance ID, with 7-day retention. Uvicorn access logs include the real
  client IP (`FORWARDED_ALLOW_IPS`).

### Alerting (`terraform/monitoring.tf`)

Three CloudWatch alarms on ALB / target group metrics:

| Alarm | Metric | Fires when | Why it matters |
|---|---|---|---|
| `compie-app-dev-unhealthy-hosts` | `UnHealthyHostCount` (max) | > 0 for 3 consecutive minutes | An instance fails `/health`: container down, boot failure or bad image. 3 minutes so a deploy blip does not page. |
| `compie-app-dev-no-healthy-hosts` | `HealthyHostCount` (min) | < 1 for 2 consecutive minutes; missing data counts as breaching | The service is down for users. |
| `compie-app-dev-target-5xx` | `HTTPCode_Target_5XX_Count` (sum) | >= 5 in 5 minutes | The app returns server errors. Includes `/ready` 503s, so this is also the DynamoDB connectivity signal. |

**Notification flow:** CloudWatch alarm → SNS topic `compie-app-dev-alerts` → email
subscription. Both `ALARM` and `OK` transitions are sent, so you also get "recovered"
messages.

- **Email:** pass the address at apply time with `-var="alert_email=you@example.com"`;
  it is not stored in the repo. AWS sends a confirmation email that must be clicked once.
  With `alert_email` empty, the topic and alarms exist with no subscriber (a placeholder
  endpoint).
- **In a real setup** the topic would also deliver to the on-call tool: PagerDuty or
  Opsgenie (HTTPS subscription), or Slack/Teams via AWS Chatbot.
- **Encryption:** the topic is not KMS-encrypted. CloudWatch can publish to an encrypted
  topic only when it uses a customer-managed key with a key policy that allows CloudWatch,
  and alert messages contain no sensitive data.

Test the wiring without breaking anything (the alarm returns to its real state at the
next evaluation, within about a minute):

```bash
aws cloudwatch set-alarm-state --alarm-name compie-app-dev-unhealthy-hosts \
  --state-value ALARM --state-reason "Manual test of alert wiring"
```

## Verification checklist

After `terraform apply`, check each item:

```bash
ALB=$(terraform -chdir=terraform output -raw alb_url)
TG=$(aws elbv2 describe-target-groups --names compie-app-dev --query 'TargetGroups[0].TargetGroupArn' --output text)
```

- [ ] Two instances in different AZs:
      `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names compie-app-dev --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,HealthStatus]'`
- [ ] Instances have no public IP:
      `aws ec2 describe-instances --filters Name=tag:Name,Values=compie-app-dev --query 'Reservations[].Instances[].PublicIpAddress'` returns empty.
- [ ] Both targets `healthy`:
      `aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].TargetHealth.State'`
- [ ] `curl -i $ALB/` returns 200 with the welcome message from SSM.
- [ ] `curl -i $ALB/health` returns 200.
- [ ] `curl -i $ALB/ready` returns 200 with `"database":{"status":"ok"}`.
- [ ] Logs appear in CloudWatch: `aws logs tail /compie-app/dev --since 10m`
- [ ] Instances reach SSM: `aws ssm describe-instance-information` lists both.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Targets `unhealthy`, instances replaced repeatedly | Boot script failed (Docker install, SSM read, ECR pull) | `aws ec2 get-console-output --instance-id <id> --latest --output text \| grep user-data:` shows each step and the failing line, with no SSH or SSM needed. Or `aws ssm start-session --target <id>`, then `sudo cat /var/log/cloud-init-output.log` and `sudo docker ps -a` |
| Instances never show up in SSM | No outbound path to the SSM endpoints | NAT state, private route table `0.0.0.0/0 → NAT`, app SG egress 443 |
| `/ready` returns 503 | IAM, the endpoint condition, or the table | Log group shows the boto error (`AccessDenied`, `ResourceNotFound`, ...) |
| `/ready` AccessDenied | Request did not go through the DynamoDB gateway endpoint | Private route table has the DynamoDB prefix-list route |
| Container cannot get credentials | IMDS hop limit | Launch template `http_put_response_hop_limit = 2` |
| ALB returns 502/503 | No healthy targets | Target health; the app must listen on port 8000 |
| Pipeline: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC trust mismatch | Workflow runs on `main`, `AWS_ROLE_ARN` variable is set, no `environment:` in the job |
| Pipeline: `InstanceRefreshInProgress` | A refresh is already running | Wait, or check with `aws autoscaling describe-instance-refreshes` |

## Teardown

```bash
terraform -chdir=terraform destroy -var="image_tag=unused"   # all hourly-billed resources
```

This removes the NAT Gateway, ALB, EC2 and everything else in the main stack. To also
remove the bootstrap stack (ECR and the state bucket):

1. Empty the state bucket, including all object versions. It has `force_destroy = false`
   on purpose, to protect state history.
2. Run `terraform -chdir=terraform/bootstrap destroy`. The ECR repo has
   `force_delete = true`, so its images are removed with it.

## Cost (us-east-1, approximate)

| Resource | Per day |
|---|---|
| NAT Gateway + Elastic IP | ~$1.20 |
| ALB (incl. 2 public IPv4) | ~$0.80 |
| 2 × t3.micro + EBS | ~$0.55 |
| DynamoDB on-demand, SSM, CloudWatch Logs, ECR, S3 | cents |
| **Total while running** | **~$2.5/day** |

Destroy the main stack when it is not in use. The bootstrap stack costs cents per month.
