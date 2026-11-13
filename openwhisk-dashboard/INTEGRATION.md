# OpenWhisk Dashboard Integration

The dashboard does not synthesize measurements. Real records flow from an
OpenWhisk activation through `A1`/`A2`/`A3` and `publish_result` to `POST
/ingest`. The receiver stores the observed events in memory; the browser polls
the stats and recent-event APIs.

## Run the dashboard

Run one worker because the event buffer is process-local:

```bash
cd openwhisk-dashboard
bash install-linux.sh
bash run-linux.sh
```

The dashboard host must be reachable from each OpenWhisk cluster. Use its
Tailscale address, not `127.0.0.1` or an SSH-forwarded address, for action
configuration. Restrict port 9000 to the group network.

## Deploy actions

Create `~/.wskprops.c1`, `~/.wskprops.c2`, and/or `~/.wskprops.c3` for the
clusters to configure, then run:

```bash
cd openwhisk-dashboard
./deploy-openwhisk-actions.sh
```

Set `CLUSTERS="c2"` to deploy only to a configured cluster. The helper checks
`GET /health`, updates the publisher target, and deploys A1/A2/A3 with the
selected cluster name and `provide-api-key` annotation. Do not put an OpenWhisk
key in the dashboard or event payload.

## Verify real data

Invoke an action using the properties file for the selected cluster, then query
the dashboard:

```bash
WSK_CONFIG_FILE="$HOME/.wskprops.c2" wsk -i action invoke A1 \
	--blocking --result --param SAMPLE_RATE 1
curl -s 'http://<TAILSCALE-DASHBOARD-IP>:9000/api/recent?limit=5&cluster=c2'
```

The event's `req_id` is the OpenWhisk activation ID. `duration_ms` is the action's
measured execution time, not end-to-end Gateway latency. The default sampling
rate is 5%; Dashboard RPS therefore counts received sampled events, not total
K6/OpenWhisk requests. Use `SAMPLE_RATE=1` only for a short, coordinated check.

`actions/dashboard-ingest-test.js` is test-only. It requires explicit
`CONFIRM_TEST_DATA=true` and `TARGET_URL`, and tags its record as `test_only`.
