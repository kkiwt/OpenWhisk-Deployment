const http = require("http");
const https = require("https");

function main(params) {
    if (params.CONFIRM_TEST_DATA !== true && params.CONFIRM_TEST_DATA !== "true") {
        return {sent: false, error: "Test data disabled; pass CONFIRM_TEST_DATA=true explicitly"};
    }

    let target;
    try {
        target = new URL(params.TARGET_URL);
    } catch (error) {
        return {sent: false, error: "A valid TARGET_URL is required"};
    }
    if (target.protocol !== "http:" && target.protocol !== "https:") {
        return {sent: false, error: "TARGET_URL must use HTTP or HTTPS"};
    }

    return new Promise((resolve) => {
        const data = {
            req_id: "ow-test-" + Date.now(),
            cluster: params.CLUSTER || "c2",
            action: "dashboard-ingest-test",
            status: "test_only",
            duration_ms: 0,
            ts: new Date().toISOString()
        };

        const body = JSON.stringify(data);
        const requestPath = target.pathname.replace(/\/+$/, "") + "/ingest";

        const options = {
            hostname: target.hostname,
            port: target.port || (target.protocol === "https:" ? 443 : 80),
            path: requestPath,
            method: "POST",
            timeout: 5000,
            headers: {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(body)
            }
        };

        const client = target.protocol === "https:" ? https : http;
        const req = client.request(options, (res) => {
            let response = "";

            res.on("data", chunk => response += chunk);
            res.on("end", () => {
                resolve({
                    sent: res.statusCode === 200,
                    http_status: res.statusCode,
                    dashboard_response: response
                });
            });
        });

        req.on("timeout", () => {
            req.destroy(new Error("Connection timeout"));
        });

        req.on("error", (err) => {
            resolve({sent: false, error: err.message});
        });

        req.write(body);
        req.end();
    });
}

exports.main = main;
