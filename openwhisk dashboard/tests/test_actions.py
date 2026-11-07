import json
import os
from unittest.mock import patch

from actions import a1
from actions import publish_result


class AcceptedResponse:
    status = 202

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


def test_action_reports_real_activation_and_action_name():
    environment = {
        "__OW_API_HOST": "https://openwhisk.example",
        "__OW_API_KEY": "test-key",
        "__OW_ACTIVATION_ID": "activation-123",
    }
    with patch.dict(os.environ, environment), patch.object(a1.random, "random", return_value=0), patch.object(
        a1.urllib.request, "urlopen", return_value=AcceptedResponse()
    ) as urlopen:
        result = a1.main({
            "ACTION_NAME": "A2",
            "BUSY": 0,
            "CLUSTER": "c3",
            "SAMPLE_RATE": 1,
        })

    sent = json.loads(urlopen.call_args.args[0].data)
    assert result["action"] == "A2"
    assert sent["req_id"] == "activation-123"
    assert sent["cluster"] == "c3"
    assert sent["action"] == "A2"
    assert sent["duration_ms"] >= 0


def test_publisher_rejects_missing_event_fields_instead_of_fabricating_them():
    result = publish_result.main({"MODE": "dashboard", "TARGET_URL": "http://dashboard"})

    assert result["sent"] is False
    assert "req_id" in result["error"]