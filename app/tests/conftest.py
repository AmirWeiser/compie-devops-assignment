import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

from main import create_app


@pytest.fixture
def env(monkeypatch):
    # Fake credentials only satisfy moto/botocore; nothing touches real AWS.
    monkeypatch.setenv("WELCOME_MESSAGE", "Hello from tests")
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("DYNAMODB_TABLE_NAME", "test-table")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.delenv("DYNAMODB_ENDPOINT_URL", raising=False)


@pytest.fixture
def client(env):
    """App against mocked AWS with NO table created."""
    with mock_aws():
        yield TestClient(create_app())


@pytest.fixture
def table(client):
    boto3.client("dynamodb", region_name="us-east-1").create_table(
        TableName="test-table",
        KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
