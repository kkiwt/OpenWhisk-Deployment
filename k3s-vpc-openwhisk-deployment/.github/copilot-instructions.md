# GitHub Copilot Instructions – K3s + OpenWhisk Project

## 1. Project Overview

This repository contains an experimental deployment of Apache OpenWhisk on a multi-node K3s Kubernetes cluster hosted on a VPC infrastructure.

The project focuses on:

- Kubernetes cluster deployment and management.
- Apache OpenWhisk serverless platform.
- Distributed workload execution.
- Performance benchmarking using k6.
- Chaos Engineering using Chaos Mesh.
- Monitoring using Prometheus and Grafana.
- Reliability, scalability, and fault-tolerance evaluation.

Copilot must understand the existing implementation before proposing modifications.

## 2. Infrastructure Architecture

The current cluster consists of four Ubuntu nodes.

| Node | Role | Private IP |
|---|---|---|
| c1-server | K3s Server / Control Plane | 192.168.1.5 |
| c1-agent1 | Worker | 192.168.1.102 |
| c1-agent2 | Worker | 192.168.1.46 |
| c1-agent3 | Worker | 192.168.1.242 |

Infrastructure details:

- Ubuntu 22.04.2 LTS
- K3s v1.35.5+k3s1
- Containerd runtime
- Private network interface: ens4
- Private network MTU: 1450
- K3s API endpoint: https://192.168.1.5:6443

IMPORTANT:
These values describe the recorded deployment environment. Always inspect the current configuration before applying changes.

Never assume that interface names, IP addresses, node states, or software versions remain unchanged.

## 3. Network Configuration Rules

The cluster uses a private VPC network for internal Kubernetes communication.

Known interface configuration:

- ens3: Public network.
- ens4: Private VPC network.

Important historical lesson:

Some nodes initially had incorrect ens8 references.

This caused problems with:

- Private interface activation.
- K3s node connectivity.
- Flannel networking.
- Node Ready status.

Corrective configuration used MAC-based interface matching in Netplan.

Copilot MUST:

1. Inspect `ip -br addr`.
2. Inspect `ip route`.
3. Inspect `/etc/netplan/`.
4. Verify interface MAC addresses.
5. Check private connectivity to 192.168.1.5.
6. Inspect K3s Flannel interface configuration.

Never blindly replace network configuration.

Never modify ens3 or public connectivity unless explicitly required.

Always back up configuration before modifying it.

Use `netplan try` before accepting network changes.

## 4. OpenWhisk Architecture

The deployment includes the following components:

- Controller
- Invoker
- Kafka
- Zookeeper
- CouchDB
- Redis
- API Gateway
- Alarm Provider
- Kafka Provider
- Nginx
- Wskadmin

Recorded workload distribution:

| Node | Components |
|---|---|
| c1-server | Controller, Alarm Provider, Nginx |
| c1-agent1 | API Gateway, Kafka, Kafka Provider, Wskadmin |
| c1-agent2 | CouchDB, Invoker 0 |
| c1-agent3 | Redis, Zookeeper, Invoker 1 |

This is the observed deployment state, not a mandatory scheduling policy.

Copilot must inspect actual Kubernetes workloads before proposing scheduling changes.

## 5. Monitoring Architecture

The project uses:

- Prometheus
- Grafana
- Prometheus Node Exporter
- kube-state-metrics
- Chaos Mesh

Monitoring should cover:

- CPU utilization.
- Memory utilization.
- Node health.
- Pod health.
- Container restarts.
- Network traffic.
- OpenWhisk invocation latency.
- Invoker execution behavior.
- Kafka resource utilization.

When evaluating performance, correlate application metrics with infrastructure metrics.

Do not draw conclusions from CPU utilization alone.

## 6. Benchmarking and Test Analysis

The project uses k6 for load testing.

Relevant existing results are stored in `results/`.

Recorded test scenarios include:

- 1 RPS
- 2 RPS
- 3 RPS
- 5 RPS
- 10 RPS
- 30 RPS
- Smoke tests
- Light user-load tests

Copilot must:

1. Read the complete JSON result.
2. Identify the test scenario.
3. Extract request count.
4. Calculate or inspect failure rate.
5. Analyze average latency.
6. Analyze p90 and p95 latency.
7. Inspect throughput.
8. Compare results across scenarios.
9. Correlate results with Invoker logs.
10. Identify potential bottlenecks.

Never invent missing benchmark values.

Never claim that a benchmark passed without checking its thresholds.

When comparing tests, account for differences in workload, duration, configuration, and cluster state.

## 7. Invoker Log Analysis

Important logs include:

- `invoker-0-20261114-155951.log`
- `invoker-1-20261114-155951.log`

These logs should be used to investigate:

- Action execution.
- Invocation failures.
- Container initialization.
- Execution latency.
- Runtime errors.
- Resource exhaustion.
- Concurrency behavior.
- Scheduling delays.

When analyzing logs:

1. Identify timestamps.
2. Identify error severity.
3. Group repeated errors.
4. Find the first occurrence of failures.
5. Correlate timestamps with k6 results.
6. Identify whether failures originate from infrastructure or application behavior.
7. Provide evidence before suggesting fixes.

Do not treat every warning as a critical error.

## 8. Chaos Engineering

Chaos Mesh is installed in the cluster.

The project uses Chaos Engineering to evaluate fault tolerance.

Potential test categories:

- Pod failure.
- Pod kill.
- Network delay.
- Network partition.
- CPU stress.
- Memory stress.
- Node failure.

For every experiment, document:

- Experiment objective.
- Target resource.
- Initial cluster state.
- Experiment configuration.
- Experiment duration.
- Expected behavior.
- Actual behavior.
- Recovery time.
- Impact on OpenWhisk.
- Observed errors.
- Lessons learned.

Never execute destructive experiments without checking their scope.

Do not run multiple destructive experiments simultaneously unless explicitly requested.

Always verify cluster recovery after an experiment.

## 9. Script Modification Rules

Before modifying any script:

1. Read the complete existing file.
2. Understand its dependencies.
3. Identify all environment variables.
4. Check whether the script is idempotent.
5. Identify destructive commands.
6. Check compatibility with Ubuntu 22.04.
7. Check compatibility with K3s v1.35.5+k3s1.
8. Preserve existing working functionality.

Prefer small, focused changes.

Do not rewrite entire scripts when a targeted correction is sufficient.

All scripts should:

- Validate required variables.
- Provide useful error messages.
- Handle failures.
- Avoid exposing credentials.
- Be safe to execute more than once where possible.

## 10. Security Requirements

NEVER commit:

- K3s tokens.
- Kubernetes credentials.
- SSH private keys.
- Passwords.
- CouchDB credentials.
- Kafka credentials.
- Production secrets.
- Private certificates.

Use environment variables or secret-management mechanisms.

Do not print secrets in logs.

Do not include real credentials in examples or documentation.

Before recommending a commit, inspect staged changes for sensitive information.

## 11. Production Safety

This is an experimental infrastructure environment, but the existing cluster must be treated as an active system.

Copilot must NOT automatically:

- Reboot nodes.
- Reinstall K3s.
- Delete Kubernetes namespaces.
- Delete PersistentVolumeClaims.
- Delete PersistentVolumes.
- Reset cluster networking.
- Modify Flannel configuration.
- Restart all OpenWhisk components.
- Remove monitoring components.

Before potentially disruptive operations:

1. Explain the reason.
2. Identify affected resources.
3. Explain possible consequences.
4. Provide backup or rollback instructions.
5. Request explicit user approval.

## 12. Required Analysis Workflow

For every debugging task:

STEP 1 — Inspect current state.

STEP 2 — Collect logs and events.

STEP 3 — Identify the root cause.

STEP 4 — Compare with previous known behavior.

STEP 5 — Propose the smallest safe correction.

STEP 6 — Explain the expected impact.

STEP 7 — Wait for approval before destructive changes.

STEP 8 — Verify the correction.

STEP 9 — Update documentation if necessary.

## 13. Documentation Requirements

When discovering an important issue or solution, update the relevant documentation.

Important files:

- `PROJECT-LEARNINGS.md`
- `README.md`
- `.github/copilot-instructions.md`

Record:

- Problem.
- Root cause.
- Diagnostic commands.
- Solution.
- Verification.
- Prevention.

Do not document an unverified hypothesis as an established fact.

## 14. Expected Copilot Behavior

Copilot should act as a senior Kubernetes, DevOps, and Site Reliability Engineering assistant.

It should prioritize:

1. Correctness.
2. Reliability.
3. Security.
4. Reproducibility.
5. Observability.
6. Performance.
7. Maintainability.

The objective is not simply to make the deployment work.

The objective is to build a reproducible, observable, reliable, and experimentally verifiable K3s + OpenWhisk environment.
