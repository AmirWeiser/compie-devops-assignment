# Compie DevOps Home Assignment

A minimal FastAPI app, containerized with Docker. Later stages deploy it to AWS
(EC2 Auto Scaling Group behind a public ALB, DynamoDB, ECR, CloudWatch, KMS)
with Terraform and GitHub Actions.

> Status: **Stage 1 — local app and Docker.**

## Layout

```
app/
  main.py               # the whole application
  tests/                # pytest (moto mocks DynamoDB)
  Dockerfile
  requirements.txt      # runtime deps (pinned)
  requirements-dev.txt  # test deps
docker-compose.yml      # local stack: app + DynamoDB Local
```

## Endpoints

| Path      | Purpose | Response |
|-----------|---------|----------|
| `/`       | App name, welcome message, status | `200` |
| `/health` | **Liveness**: no dependencies. Used by Docker `HEALTHCHECK` and later the ALB. | `200 {"status":"ok"}` |
| `/ready`  | **Readiness**: real DynamoDB `GetItem` | `200` or `503` |

`/health` deliberately does not check the database. If the ALB health check
depended on DynamoDB, a database problem would mark every instance unhealthy and
the ASG would keep replacing healthy instances.

### What `/ready` verifies

`/ready` calls `GetItem` on the fixed key `pk = "healthcheck"`. The item does not
need to exist. A successful call verifies that:

- the DynamoDB endpoint is reachable from the container,
- the request was signed with valid credentials,
- IAM allows `dynamodb:GetItem` on the table,
- the table exists and can serve reads.

It does **not** verify write permissions. It also does **not** prove the caller has
`kms:Decrypt` on the table's KMS key: DynamoDB handles at-rest encryption
server-side, so a successful read shows the service could serve the data, not that
the caller holds direct KMS permissions.

Error details are logged; the HTTP response stays generic.

## Configuration (environment variables)

| Variable | Required | Notes |
|---|---|---|
| `WELCOME_MESSAGE` | yes | Returned by `/` |
| `AWS_REGION` | yes | |
| `DYNAMODB_TABLE_NAME` | yes | |
| `APP_NAME` | no | Defaults to `compie-app` |
| `DYNAMODB_ENDPOINT_URL` | no | Local only (DynamoDB Local). Leave unset in AWS. |

The app refuses to start if a required variable is missing. AWS credentials are
never configured in the app; in AWS the EC2 instance profile provides them.

## Run locally

```bash
docker compose up --build -d
curl localhost:8000/
curl localhost:8000/health
curl localhost:8000/ready          # 200

docker compose stop dynamodb-local
curl localhost:8000/ready          # 503
curl localhost:8000/health         # still 200

docker compose logs app
docker compose down
```

DynamoDB Local speaks the real DynamoDB API, so `/ready` is an honest check. It
does not emulate IAM, KMS or VPC networking; those are verified in AWS. It runs
in-memory, so after restarting it run `docker compose up -d` again to recreate
the table.

## Tests

Run in the same Python version as the image:

```bash
docker run --rm -v "$PWD/app:/src:ro" -w /src python:3.12-slim \
  sh -c "pip install -q -r requirements-dev.txt && pytest -v -p no:cacheprovider"
```

On Git Bash for Windows, prefix the command with `MSYS_NO_PATHCONV=1`.
