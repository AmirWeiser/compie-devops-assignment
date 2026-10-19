import pytest
from fastapi.testclient import TestClient

from main import create_app


def test_root(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {
        "app": "compie-app",
        "version": "dev",
        "message": "Hello from tests",
        "status": "running",
    }


def test_root_reports_build_version(env, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "abc1234")
    assert TestClient(create_app()).get("/").json()["version"] == "abc1234"


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_stays_ok_when_database_is_down(client):
    # No table exists: readiness fails, liveness must not.
    assert client.get("/ready").status_code == 503
    assert client.get("/health").status_code == 200


def test_ready_ok(client, table):
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready", "database": {"status": "ok", "table": "test-table"}}


def test_ready_503_when_table_missing(client):
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "not_ready", "database": {"status": "unavailable", "table": "test-table"}}


def test_ready_503_when_endpoint_unreachable(env, monkeypatch):
    # Nothing listens on port 9: a real connection failure, not a mock.
    monkeypatch.setenv("DYNAMODB_ENDPOINT_URL", "http://127.0.0.1:9")
    response = TestClient(create_app()).get("/ready")
    assert response.status_code == 503


@pytest.mark.parametrize("name", ["WELCOME_MESSAGE", "AWS_REGION", "DYNAMODB_TABLE_NAME"])
def test_missing_required_env_fails_at_startup(env, monkeypatch, name):
    monkeypatch.delenv(name)
    with pytest.raises(KeyError):
        create_app()
