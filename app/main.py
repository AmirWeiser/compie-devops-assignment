"""Minimal FastAPI app for the Compie DevOps assignment.

GET /        app info and welcome message
GET /health  liveness: no dependencies (used by Docker and the ALB)
GET /ready   readiness: real DynamoDB GetItem, returns 200 or 503
"""

import logging
import os

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI
from fastapi.responses import JSONResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("app")


def create_app() -> FastAPI:
    # Required settings raise KeyError if missing, so the app fails at startup.
    app_name = os.environ.get("APP_NAME", "compie-app")
    app_version = os.environ.get("APP_VERSION", "dev")  # baked into the image at build time (git SHA)
    welcome_message = os.environ["WELCOME_MESSAGE"]
    table_name = os.environ["DYNAMODB_TABLE_NAME"]

    dynamodb = boto3.client(
        "dynamodb",
        region_name=os.environ["AWS_REGION"],
        endpoint_url=os.environ.get("DYNAMODB_ENDPOINT_URL"),  # set only for DynamoDB Local
        # Fail fast: a readiness probe should answer quickly, so 2s timeouts and no retries.
        config=Config(connect_timeout=2, read_timeout=2, retries={"max_attempts": 1}),
    )

    app = FastAPI(title=app_name)

    @app.get("/")
    def root():
        return {"app": app_name, "version": app_version, "message": welcome_message, "status": "running"}

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/ready")
    def ready():
        # GetItem on a fixed key; the item does not need to exist. Success means the
        # endpoint is reachable, credentials are valid, IAM allows dynamodb:GetItem on
        # the table, and the table exists. See README for what it does not prove.
        try:
            dynamodb.get_item(TableName=table_name, Key={"pk": {"S": "healthcheck"}})
            ok = True
        except (ClientError, BotoCoreError) as exc:
            # Details go to the logs only, not to the HTTP response.
            logger.warning("DynamoDB readiness check failed: %s", exc)
            ok = False

        return JSONResponse(
            status_code=200 if ok else 503,
            content={
                "status": "ready" if ok else "not_ready",
                "database": {"status": "ok" if ok else "unavailable", "table": table_name},
            },
        )

    return app
