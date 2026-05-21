"""KrakenD gateway config — routes, OpenAPI alignment, doc 05 rate limits."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
KRAKEND_JSON = ROOT / "krakend.json"
OPENAPI_YAML = ROOT / "openapi.yaml"
POST_SCHEMA = ROOT / "schemas" / "post-lancamento.request.json"

LANCAMENTOS_HOST = "http://svc-lancamentos.fluxo-caixa.svc.cluster.local:8000"
CONSULTA_HOST = "http://svc-consulta.fluxo-caixa.svc.cluster.local:8000"


@pytest.fixture
def config() -> dict:
    return json.loads(KRAKEND_JSON.read_text())


@pytest.fixture
def openapi() -> dict:
    return yaml.safe_load(OPENAPI_YAML.read_text())


@pytest.fixture
def post_schema() -> dict:
    return json.loads(POST_SCHEMA.read_text())


def _endpoints_by_key(config: dict) -> dict[tuple[str, str], dict]:
    return {(ep["endpoint"], ep["method"]): ep for ep in config["endpoints"]}


def test_openapi_public_paths_match_krakend(config: dict, openapi: dict) -> None:
    krakend_ops = {(ep["endpoint"], ep["method"].lower()) for ep in config["endpoints"]}
    for path, methods in openapi["paths"].items():
        for method in methods:
            if method in ("get", "post"):
                assert (path, method) in krakend_ops, f"missing KrakenD route {method.upper()} {path}"


def test_lancamentos_routes_target_lancamentos_service(config: dict) -> None:
    by_key = _endpoints_by_key(config)
    for method in ("GET", "POST"):
        ep = by_key[("/v1/lancamentos", method)]
        assert ep["backend"][0]["host"] == [LANCAMENTOS_HOST]
        assert ep["backend"][0]["url_pattern"] == "/v1/lancamentos"


def test_consolidado_route_targets_consulta(config: dict) -> None:
    ep = _endpoints_by_key(config)[("/v1/consolidado/{data}", "GET")]
    assert ep["backend"][0]["host"] == [CONSULTA_HOST]
    assert ep["backend"][0]["url_pattern"] == "/v1/consolidado/{data}"


def test_post_lancamentos_has_json_schema_validation(config: dict, post_schema: dict) -> None:
    ep = _endpoints_by_key(config)[("/v1/lancamentos", "POST")]
    gateway_schema = ep["extra_config"]["validation/json-schema"]
    assert gateway_schema == {
        k: v for k, v in post_schema.items() if k not in ("$schema", "$id", "title")
    }


def test_authenticated_endpoints_require_jwt_and_propagate_claims(config: dict) -> None:
    by_key = _endpoints_by_key(config)
    for key in (("/v1/lancamentos", "POST"), ("/v1/lancamentos", "GET"), ("/v1/consolidado/{data}", "GET")):
        validator = by_key[key]["extra_config"]["auth/validator"]
        assert validator["alg"] == "RS256"
        assert validator["cache"] is True
        assert validator["cache_duration"] == 300
        claims = dict(validator["propagate_claims"])
        assert claims["merchant_id"] == "x-merchant-id"
        assert claims["azp"] == "x-client-id"


def test_rate_limits_doc_05_token_bucket(config: dict) -> None:
    by_key = _endpoints_by_key(config)
    write = by_key[("/v1/lancamentos", "POST")]["extra_config"]["qos/ratelimit/router"]
    assert write["client_max_rate"] == 60
    assert write["client_capacity"] == 80
    assert write["max_rate"] == 120
    assert write["capacity"] == 140
    assert write["every"] == "1m"
    assert write["strategy"] == "header"
    assert write["key"] == "x-merchant-id"

    read = by_key[("/v1/consolidado/{data}", "GET")]["extra_config"]["qos/ratelimit/router"]
    assert read["client_max_rate"] == 300
    assert read["client_capacity"] == 320


def test_circuit_breaker_5_errors_30s(config: dict) -> None:
    by_key = _endpoints_by_key(config)
    for key in (("/v1/lancamentos", "POST"), ("/v1/lancamentos", "GET"), ("/v1/consolidado/{data}", "GET")):
        cb = by_key[key]["extra_config"]["github.com/devopsfaith/krakend-circuitbreaker/gobreaker"]
        assert cb["max_errors"] == 5
        assert cb["interval"] == 30
        assert cb["timeout"] == 30


def test_health_endpoint_has_no_jwt(config: dict) -> None:
    ep = _endpoints_by_key(config)[("/health", "GET")]
    assert "auth/validator" not in ep.get("extra_config", {})
