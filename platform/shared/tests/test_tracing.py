from fcx_shared.tracing import traceparent_from_correlation_id


def test_traceparent_from_correlation_id() -> None:
    correlation_id = "22222222-2222-4222-8222-222222222222"
    tp = traceparent_from_correlation_id(correlation_id)
    assert tp == "00-22222222222242228222222222222222-2222222222224222-01"
