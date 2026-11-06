# MarketMate DevOps assignment

A small FastAPI app with Docker, GitLab CI/CD, Prometheus, and Grafana. This version covers the PDF's five required sections and includes simple Kubernetes manifests for the app.

## Configured local addresses

`docker-compose.yml` publishes the app at http://localhost:8000/docs, Prometheus at http://localhost:9090, and Grafana at http://localhost:3000/d/marketmate-overview. These are configured addresses, not confirmation that the current code is running. Use `docker compose ps` and the checks below to verify your deployment. The last startup attempt using only this file was blocked by occupied ports; see [validation results](#validation-results).

## Start

You need Docker with Docker Compose. On first setup, copy the example and set your own Grafana password:

```bash
cp .env.example .env
# Edit .env and set GRAFANA_ADMIN_PASSWORD.
```

If `.env` already exists, keep it rather than overwriting your settings.

Start everything with one command:

```bash
docker compose up -d --build
```

| Service | Address |
| --- | --- |
| Health | http://localhost:8000/health |
| Application information | http://localhost:8000/api/status |
| Interactive API docs | http://localhost:8000/docs |
| Metrics | http://localhost:8000/metrics |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000/d/marketmate-overview |

Grafana login: username `admin`, password from `.env`. The initial password only applies to a new Grafana database. Changing the variable later does not reset an existing account.

## Develop without Docker

Python 3.12+ is required:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/uvicorn app.main:app --reload
```

Open http://localhost:8000/docs. Edit `app/main.py`; Uvicorn reloads automatically. In Docker, rebuild after changing Python files with `docker compose up -d --build app`.

## Test and inspect

```bash
.venv/bin/python -m pytest -q
docker compose ps
docker compose logs --tail=50 app
curl http://localhost:8000/health
curl http://localhost:8000/api/status
```

Stop containers with `docker compose down`. Named volumes preserve Grafana and Prometheus data. Do not add `--volumes` unless you intend to delete that data.

The latest plain-text results are in [FINAL-REPORT.txt](FINAL-REPORT.txt).

## Guide contents

- [Docker and deployment](#docker-and-deployment)
- [GitLab CI/CD and rollback](#gitlab-cicd-and-rollback)
- [Monitoring and Loki](#monitoring-and-loki)
- [Security and recovery](#security-and-recovery)
- [Nginx 502 troubleshooting](#nginx-502-troubleshooting)
- [Kubernetes](#kubernetes)
- [SonarQube](#sonarqube)
- [Validation results](#validation-results)
- [PDF requirement review](#pdf-requirement-review)

## Docker and deployment

### What I did

- Created a FastAPI app in `app/main.py` with `/health` and `/api/status`.
- Added `/metrics` for Prometheus. FastAPI also provides `/docs` for development.
- Used two Docker stages: `base` installs packages under `/install`; `runtime` copies them into `/usr/local` and adds the application. No virtual environment is used inside Docker.
- Created a non-root `userapp` user with UID/GID 10001 and no home directory. `WORKDIR /src` creates the application directory, which is owned by `10001:10001`; copied source files use the same ownership. Kubernetes runs the app with the same UID/GID.
- Added the HTTP health check to the app service in `docker-compose.yml`.
- Added three Compose services: app, Prometheus, and Grafana.

### How it works

Uvicorn listens on container port 8000. Compose maps it to localhost port 8000. `APP_ENV` and `APP_IMAGE` come from environment variables and appear in `/api/status`.

| Endpoint | Response |
| --- | --- |
| `GET /health` | `{"status":"ok"}`; app liveness only, without checking monitoring services |
| `GET /api/status` | `name: MarketMate`, `environment` from `APP_ENV` (default `development`), and `version` from `APP_IMAGE` (default `test`) |
| `GET /metrics` | Prometheus text exposition, including request counts and latency histogram |
| `GET /docs` | Interactive FastAPI API documentation |

`APP_IMAGE` also selects the Compose image. Without it, Compose builds `marketmate-devops:local` while the app reports version `test`.

```bash
docker compose up -d --build
curl http://localhost:8000/health
curl http://localhost:8000/api/status
```

Create `.env` and choose a Grafana password once, as described in the README. All services have restart policies and CPU/memory limits. App health is checked every 15 seconds.

The Dockerfile contains no health check. Compose runs the periodic check; Kubernetes uses its own probes. The remote deployment script pulls `APP_IMAGE`, starts only the app, and checks both the HTTP endpoint and Docker health status. `APP_IMAGE` also identifies the deployed version in `/api/status`. Without it, local builds use `marketmate-devops:local`, and the API reports `test` in its `version` field.

Compose has no database, background worker, or reverse proxy. `nginx/marketmate.conf` is an optional host Nginx example and is not installed automatically. For normal Python development, use `uvicorn app.main:app --reload` in the virtual environment.

## GitLab CI/CD and rollback

### Pipeline

The pipeline runs on pushes to the default branch. It tests the app, runs a blocking SonarQube analysis, builds and pushes `$DOCKER_REGISTRY/task:$CI_COMMIT_SHORT_SHA`, then deploys to staging over SSH. Production requires manual approval after staging succeeds. Follow the [SonarQube setup guide](#sonarqube) to configure the project, token, and GitLab variables.

The build job logs in before building, builds and pushes in `script`, and logs out afterward. The Kubernetes runner needs privileged Docker-in-Docker support and a shared `/certs/client` volume for TLS.

Configure GitLab variables `DOCKER_REGISTRY`, `DOCKER_USERNAME`, and `DOCKER_PASS`. Configure `SSH_PRIVATE_KEY` and `SSH_KNOWN_HOSTS` as file-type variables, plus `STAGING_HOST`, `STAGING_SSH_USER`, `PRODUCTION_HOST`, and `PRODUCTION_SSH_USER`. Use an operator-reviewed known-hosts file.

### Remote host setup

Use separate staging and production hosts because the Compose stack binds fixed host ports. Install Docker with Compose, Bash, curl, and flock. The SSH user needs Docker access and write access to `/opt/marketmate`.

Copy `docker-compose.yml`, `script/`, and `monitoring/` to `/opt/marketmate` on each host. CI invokes the files already present there; it does not upload them. Create `.env` from `.env.example` and set `GRAFANA_ADMIN_PASSWORD`. Compose requires this even when starting only the app. Authenticate to the private registry on each host using `docker login` with credentials that can pull the image; the CI build login does not authenticate remote hosts.

Start monitoring once on each host:

```bash
cd /opt/marketmate
docker compose -p marketmate-staging up -d prometheus grafana
```

Use `marketmate-production` on the production host.

### Deployment and rollback

CI invokes `bash ./script/deploy_remote.sh <environment> <image>` from `/opt/marketmate`. The script exports `APP_IMAGE` and `APP_ENV`. Compose uses that image, exposes the app on `127.0.0.1:8000`, and passes `APP_IMAGE` to the app, which reports it in the `version` response field. Local development still supports `docker compose up -d --build` without setting `APP_IMAGE`.

The script pulls the image and recreates only the app with `--no-build`. It checks `/health` and the container health status, then records the successful image in `.last-good-image-<environment>`. A startup or health failure attempts to restore that image. The first deployment has no recorded rollback image. Replacing a single Compose app container can briefly interrupt traffic.

### Validation

Compose interpolation and shell syntax can be checked locally. Live SSH deployments and GitLab pipeline execution require the configured runner and hosts; they were not run during this update.

## Monitoring and Loki

### Application metrics

`app/main.py` uses HTTP middleware to record requests and latency through `prometheus-client`:

| Metric | Labels | Meaning |
| --- | --- | --- |
| `marketmate_http_requests_total` | `method`, `path`, `status` | Count of completed requests, including failures recorded by the middleware |
| `marketmate_http_request_duration_seconds` | `method`, `path` | Histogram of elapsed time around `call_next`; exports `_bucket`, `_sum`, and `_count` series |

The middleware uses the matched route template for `path`, or `unmatched` when no route is available. It excludes `/metrics` from both custom metrics. Health probes count as requests. The status label uses the response status, with `500` as the fallback if request processing raises before returning a response. Counters reset when the process restarts. Default process and Python runtime metrics remain available.

Latency measures time until `call_next` returns a response; it is not a measurement of the client's full download time for streaming responses. `START_TIME` is defined in the app but is not returned by an endpoint or exported as a custom uptime metric.

### Prometheus

`monitoring/prometheus/prometheus.yml` configures job `marketmate` to scrape `app:8000/metrics` every 15 seconds. This uses Compose's internal service address, independent of the host port. Prometheus stores data in the `prometheus_data` volume and exposes its UI on localhost port `9090`.

There are no alert rules or Alertmanager configuration in this project. The dashboard's error panel is a visualization, not an alert.

### Grafana

Grafana provisions datasource `Prometheus` with UID `prometheus` and URL `http://prometheus:9090`. It loads dashboard files from `/var/lib/grafana/dashboards`, mounted from `monitoring/grafana/dashboards/`. Grafana state is kept in `grafana_data`.

The dashboard is **MarketMate API Overview**, UID `marketmate-overview`. It refreshes every 15 seconds, defaults to the last hour, and uses browser timezone. Its four panels use the following queries:

#### Request rate (RPS)

```promql
sum by (method, path, status) (rate(marketmate_http_requests_total[5m]))
```

#### 5xx error rate (RPS)

```promql
sum(rate(marketmate_http_requests_total{status=~"5.."}[5m]))
```

#### p95 latency (seconds)

```promql
histogram_quantile(0.95, sum by (le, path) (rate(marketmate_http_request_duration_seconds_bucket[5m])))
```

#### Target health

```promql
up{job="marketmate"}
```

Request rate is grouped by method, route, and status. The 5xx panel aggregates all matching series and displays errors per second, not an error percentage. p95 latency is estimated per route with methods combined. Target health is Prometheus scrape success (`1` up, `0` down), not an external end-to-end health check.

Rate queries need at least two scrape samples. Generate traffic and allow several scrape intervals for useful charts. If no 5xx series exists yet, the current error query can show **No data** rather than zero. A 502 produced by Nginx before reaching FastAPI will not appear in these app metrics; use proxy logs or proxy metrics to investigate it.

The dashboard currently uses the same `method/path/status` legend template on all four panels. Only the request-rate query retains all three labels; the other panel legends can contain missing labels. This documentation update does not change the dashboard configuration.

### Run and check

From the project directory, with `.env` configured and ports available:

```bash
docker compose up -d --build
curl -f http://localhost:8000/health
curl -f http://localhost:8000/api/status
curl -fsS http://localhost:8000/metrics | grep marketmate_http_
curl -f http://localhost:9090/-/healthy
curl -f http://localhost:9090/-/ready
curl -f http://localhost:3000/api/health
docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
```

Open `/api/status` repeatedly to generate traffic, then inspect the queries above in Prometheus and the Grafana dashboard. Grafana login is `admin` with the initial password supplied through `GRAFANA_ADMIN_PASSWORD` in `.env`, mapped to `GF_SECURITY_ADMIN_PASSWORD`. An existing Grafana database retains its existing password.

After changing Prometheus configuration, restart it with `docker compose restart prometheus`. Dashboard files are provisioned from the mounted directory; if an edit does not appear, restart Grafana with `docker compose restart grafana`. Rebuild the app after changing its Python code.

Only the app has a Docker health check configured. Check Prometheus and Grafana through their HTTP health endpoints rather than expecting a Docker `healthy` status.

### How Loki could be used

Uvicorn writes request and error logs to container output. Grafana Alloy could collect app and Nginx logs and send them to Loki with labels for service and environment. Grafana could query the logs alongside metrics, and an alert rule could count repeated errors or proxy 502 responses and notify a configured contact point.

Loki, its collector, and notification delivery are explained only, as requested by the PDF; they are not deployed services in this project.

## Security and recovery

### What I did

- Run the application as a non-root user.
- Keep the Grafana password in ignored `.env`, not in source code.
- Read CI registry credentials from GitLab variables (`DOCKER_USERNAME` and `DOCKER_PASS`); configure separate pull-only credentials on deployment hosts.
- Bind Compose service ports to `127.0.0.1`. The optional Kubernetes NodePort exposes the app on reachable node addresses; restrict access with network/firewall rules.
- Set `restart: unless-stopped` and CPU/memory limits for every Compose service.
- Add an application health check.
- Preserve Prometheus and Grafana data in named volumes.

### Basic operating practices

Keep `.env` private. Do not share the output of `docker compose config`, because it includes substituted passwords. Never put credentials in URLs, logs, image layers, or Git. Environment variables are visible to people with Docker access; this is a small local setup, not a secret-management platform.

Use HTTPS and restrict metrics/admin access before exposing this application publicly. Review image and dependency updates and scan them before production deployment. These deployment controls are not implemented by the local example.

### Recovery

An exited container restarts automatically unless intentionally stopped. An unhealthy container that is still running does **not** restart just because a Docker health check fails; inspect logs and fix or restart it.

```bash
docker compose ps
docker compose logs --tail=50 app
docker compose restart app
```

The application is stateless. Rebuild it or deploy a previous image to recover from bad code. Back up named volumes if their monitoring data matters; `docker compose down` preserves them. There is no automatic backup job. A single-host deployment is not highly available and container replacement briefly interrupts requests.
If credentials may have leaked, rotate CI SSH key and registry token, revoke old credentials, review audit logs and redeploy.

## Nginx 502 troubleshooting

**Symptom:** `docker ps` shows the FastAPI container `Up`, but Nginx returns HTTP 502. A running container does **not** imply the process accepts traffic or passes its health check.

### 1. Confirm scope and reproduce

```bash
curl -v --max-time 5 https://marketmate.example.com/health
curl -v --max-time 5 http://127.0.0.1:8000/health
sudo nginx -t
sudo systemctl status nginx --no-pager
```

If loopback curl succeeds but public HTTPS fails, focus on Nginx upstream, virtual host, firewall/TLS or address routing. If loopback curl fails, focus on the app/Compose port binding. **On the server**, the container is deliberately published as `127.0.0.1:8000:8000`.

### 2. Inspect Docker container and app logs

```bash
cd /opt/marketmate
docker compose -p marketmate-production ps
docker compose -p marketmate-production logs --tail=100 --timestamps app
docker inspect "$(docker compose -p marketmate-production ps -q app)" \
  --format 'state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} ports={{json .NetworkSettings.Ports}}'
docker stats --no-stream
ss -lntp | grep ':8000' || true
curl -i --max-time 5 http://127.0.0.1:8000/api/status
```

Inspect the health history if unhealthy:

```bash
docker inspect "$(docker compose -p marketmate-production ps -q app)" \
  --format '{{json .State.Health.Log}}'
```

Potential app causes: Uvicorn crashing or slow startup, `127.0.0.1` binding **inside** the container instead of `0.0.0.0`, wrong internal port, missing variables, OOM/CPU pressure, unhealthy deployment or malformed Compose settings.

### 3. Examine Nginx upstream errors and configuration

```bash
sudo tail -n 100 /var/log/nginx/error.log
sudo tail -n 100 /var/log/nginx/access.log
sudo nginx -T | grep -A25 -B5 'upstream marketmate_backend'
sudo grep -R 'proxy_pass\|server_name' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ || true
```

Important error meanings:

| Nginx error | Likely explanation | Next action |
|---|---|---|
| `connect() failed (111: Connection refused)` | Wrong upstream IP/port or app not listening | Check `ss`, Docker port mappings, Uvicorn host |
| `upstream timed out` | Slow/hung application or exhausted resources | Inspect app traces/logs, CPU/memory, latency; fix bottleneck |
| `no live upstreams` | Incorrect upstream group / failing upstreams | Check upstream addresses, retries and health |
| `host not found in upstream` | Bad DNS / service name | For **host Nginx**, use `127.0.0.1:8000` rather than Docker-only `app:8000` |
| `upstream prematurely closed connection` | App crashed or closed the socket | Check traceback, Uvicorn worker crashes, resource limits |

**Common architecture mismatch:** `proxy_pass http://app:8000` only works when Nginx itself joins the Compose network and can resolve Docker DNS. For the supplied host-based Nginx setup, use `proxy_pass http://127.0.0.1:8000` and publish the app on host loopback.

### 4. Apply fix and verify

```bash
# Example: update upstream host/port in host Nginx config, then:
sudo nginx -t && sudo systemctl reload nginx
curl -f http://127.0.0.1:8000/health
curl -f https://marketmate.example.com/health
# If the new image is bad, rollback to a known-good SHA:
cd /opt/marketmate
bash ./script/deploy_remote.sh production 'registry.example.com/task:<previous-sha>'
```

Do not keep increasing Nginx timeouts to hide an unhealthy application. Do not run `docker compose down -v` in an incident unless destroying persistent data is explicitly intended.

### 5. Prevention and monitoring

- Gate deployments on **HTTP health** and Docker health, and retain previous known-good SHA image. The deployment script implements both checks.
- Add outside-in Nginx health checks and 502/5xx alerts; local `/health` checks alone do not validate the external route.
- Standardize internal listener (`0.0.0.0:8000`) and host routing (`127.0.0.1:8000`), review Nginx `proxy_pass` and `nginx -t` in change procedures.
- Monitor Prometheus `up`, error rate and latency; ship app and Nginx logs to Loki in a production extension.
- Review timeouts, file descriptors, resource constraints and request volume under load; add deployment smoke tests over HTTPS.

## Kubernetes

### What I added

- `k8s/configmap.yml`: stores `APP_ENV` and `APP_IMAGE`; the Deployment loads them using `envFrom`.

- `k8s/deployment.yml`: runs two FastAPI replicas with environment variables, a non-root user, resource limits, health checks, and rolling updates.
- `k8s/service.yml`: exposes the app on node port `30080`, forwarding Service port `80` to container port `8000`.

The readiness check stops traffic to an unready app. The liveness check restarts an unhealthy container. Both call `/health`, following the [Kubernetes probe documentation](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/).

These files deploy the app only. Prometheus and Grafana remain in Docker Compose. Kubernetes uses the probes in the Deployment, not the monitoring settings or health check from Compose.

### Run locally with Minikube

Install Docker, kubectl, and Minikube. Run these commands from the project directory:

```bash
minikube start
docker build -t marketmate-devops:local .
minikube image load marketmate-devops:local
kubectl config current-context
# Create the namespace once if it does not exist:
kubectl create namespace marketmate --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/
kubectl -n marketmate rollout status deployment/marketmate --timeout=120s
minikube service marketmate -n marketmate --url
```

Check that the current context is your intended local cluster before applying. Ensure the `marketmate` namespace exists before applying the manifests. Use the URL printed by Minikube; if it starts a tunnel, keep that terminal open. On a cluster with reachable node IPs, access `http://<node-ip>:30080/docs`. Network and firewall rules must allow TCP port `30080`.

In another terminal, replace `<node-ip>` with a reachable node IP (or use the URL printed by Minikube):

```bash
curl "http://<node-ip>:30080/health"
curl "http://<node-ip>:30080/api/status"
kubectl -n marketmate get pods
kubectl -n marketmate logs deployment/marketmate
```

For Kind, load the built image with `kind load docker-image marketmate-devops:local` instead of `minikube image load`, then use the same kubectl commands with the Kind context.

### Update the app

Prefer a new image tag for each change. Build and load it into your local cluster, then update `image` in `k8s/deployment.yml` and `APP_IMAGE` in `k8s/configmap.yml` and apply again. Changing the tag triggers a rollout; reapplying the same tag does not.

For a remote cluster, push the image to a registry the cluster can access and put the full image reference in the Deployment. A private registry also requires an image-pull Secret configured in that namespace. This example contains no registry credentials.

### Update environment variables

Edit `k8s/configmap.yml`, then apply it and restart the pods to load the new values:

```bash
kubectl apply -f k8s/configmap.yml
kubectl -n marketmate rollout restart deployment/marketmate
kubectl -n marketmate rollout status deployment/marketmate --timeout=120s
```

The ConfigMap and Deployment must be in the same namespace. `APP_IMAGE` is metadata reported by the app; it does not change the container image in the Deployment.

### Rolling updates without planned downtime

The Deployment keeps two replicas and replaces pods gradually:

- `maxUnavailable: 0`: do not deliberately reduce available replicas below two during an update.
- `maxSurge: 1`: start one extra replacement pod before removing an old pod.
- `minReadySeconds: 5`: a replacement must remain ready for five seconds before it counts as available.
- `preStop`: wait five seconds before stopping Uvicorn, giving traffic routing time to stop selecting the old pod.
- `terminationGracePeriodSeconds: 30`: allow graceful shutdown, including the pre-stop delay, before forcing termination.

The existing readiness probe checks `/health`. If a replacement never becomes ready, the old healthy replicas continue serving and the rollout waits. These settings follow the [Deployment rolling-update policy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment) and [Pod termination behavior](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination).

```bash
kubectl apply -f k8s/
kubectl -n marketmate rollout status deployment/marketmate --timeout=120s
```

Use a new image tag for each release. The cluster needs capacity for the extra pod; terminating pods can briefly consume additional resources too. This avoids planned rollout downtime when the existing replicas are healthy and traffic uses the Service. It cannot guarantee against node failures, application bugs, or slow routing updates; the five-second drain delay may need tuning for your ingress.

Use the Service or ingress to test uninterrupted traffic. `kubectl port-forward service/marketmate` connects to one selected pod and can disconnect when that pod is replaced.

### Remove the app

```bash
kubectl delete -f k8s/
```

The YAML and matching labels/ports were checked locally. No cluster was created or modified during implementation. Validate against your cluster before deployment with `kubectl apply --dry-run=server -f k8s/`.

## SonarQube

### What the project configures

The GitLab pipeline runs tests, uploads Python coverage, and runs SonarScanner before building the Docker image. The scanner waits for the quality gate; a failed scan or quality gate blocks the build and deployment.

This guide assumes SonarQube Server. The repository contains scanner configuration, not a SonarQube server installation. Use an existing server or have an administrator install one using the [official installation guide](https://docs.sonarsource.com/sonarqube-server/setup-and-upgrade/overview). The runner's job pods must be able to reach its URL. `localhost` inside a CI container refers to that container, not your SonarQube host.

### Create the project and token

1. Sign in to SonarQube and create a project with key `marketmate-task` and display name `marketmate`.
2. Ensure its main branch matches the GitLab default branch.
3. Select the project's quality gate. The server's default gate is sufficient to start; its conditions determine whether analysis passes.
4. Generate a project analysis token for this project from your account's security settings. The token owner needs permission to execute analysis. Store the token in GitLab, not in the repository.

### Project configuration

The project key has been corrected to remove the invalid inline comment. `sonar-project.properties` configures:

```properties
sonar.projectKey=marketmate-task
sonar.projectName=marketmate
sonar.sources=app
sonar.tests=tests
sonar.python.version=3.12
sonar.python.coverage.reportPaths=coverage.xml
```

The key must match the project on the server. Python `3.12` matches the pipeline's test image. See the [analysis parameter reference](https://docs.sonarsource.com/sonarqube-server/2025.4/analyzing-source-code/analysis-parameters).

### Optional GitLab project import

You can create the project manually as described above, or ask a SonarQube administrator to configure the GitLab connection under DevOps Platform Integrations and import the repository through **Create Project → From GitLab**. This needs a GitLab API URL and appropriately scoped GitLab credentials, which are separate from `SONAR_TOKEN`. Follow the linked GitLab integration guide for your server version and edition.

Repository import is optional for the scanner job. The current pipeline uses a Kubernetes executor; a Docker executor is not required. Its job pods need access to SonarQube and the scanner image registry.

### Configure GitLab variables

Open the GitLab project's **Settings → CI/CD → Variables** and add regular variables, not file-type variables:

| Variable | Value | Settings |
| --- | --- | --- |
| `SONAR_HOST_URL` | Your reachable SonarQube URL, such as `https://sonar.example.com` | Available to the analysis job |
| `SONAR_TOKEN` | The project analysis token | Masked; protected when the default branch is protected |

If you mark a variable protected, the job must run on a protected ref to receive it. Use an environment scope that includes the analysis job, such as `*`; this job has no deployment environment. The scanner reads these variables automatically. See [SonarQube's GitLab setup instructions](https://docs.sonarsource.com/sonarqube-server/2025.4/devops-platform-integration/gitlab-integration/adding-analysis-to-gitlab-ci-cd).

### How coverage and analysis work

The `unit_test` job installs `requirements-dev.txt`, which includes `pytest-cov`, and runs:

```bash
python -m pytest --cov=app --cov-report=xml:coverage.xml -q
```

It saves `coverage.xml` as an artifact for one day. The `sonarqube_check` job downloads that artifact through `dependencies: [unit_test]`. SonarQube imports the report; it does not run the tests itself.

The scanner job uses `GIT_DEPTH: "0"` for full Git history, caches downloaded analysis components under `.sonar/cache`, and runs:

```bash
sonar-scanner -Dsonar.qualitygate.wait=true
```

`allow_failure: false` makes the result blocking. The scanner image currently uses `latest`; pin a tested version if you need repeatable scanner upgrades. See the [Python coverage guide](https://docs.sonarsource.com/sonarqube-server/analyzing-source-code/test-coverage/python-test-coverage).

### Run and verify

Commit your changes and merge or push the changes to the GitLab default branch. The current workflow runs only for pushes to that branch; merge-request and manually started pipelines are excluded.

Check that `unit_test` produces `coverage.xml`, then open `sonarqube_check` and follow its analysis URL. Confirm that the project dashboard shows the current commit, coverage, and quality-gate result. A passing gate allows the image build to run. Staging then deploys automatically, and production remains manual.

### Troubleshooting

| Symptom | Check |
| --- | --- |
| Unauthorized analysis | Check token expiry, project permissions, and whether GitLab exposes the token to this branch. |
| Connection failure | Check `SONAR_HOST_URL`, runner network access, and certificate trust. |
| Coverage missing | Check the test artifact, downloaded report, and `sonar.python.coverage.reportPaths`. For unresolved source paths, follow the coverage guide's `relative_files` configuration. |
| Quality gate failed | Open the project's failed gate conditions and fix the reported issues. |
| No pipeline | Check that the event is a push to the GitLab default branch. |

### Validation status

During the configuration review, all four local tests passed and generated a coverage XML report. No scan against a live SonarQube server was run. The server, token, GitLab variables, and quality-gate outcome still require verification in your environment.

## Validation results

### Current documentation check

The documentation was compared with `app/main.py`, `docker-compose.yml`, Prometheus configuration, Grafana provisioning, dashboard JSON, and the test source. It now describes the middleware metrics and four-panel dashboard. Configuration and documentation links were checked locally; this documentation update did not rebuild containers, execute tests, or verify live monitoring.

`tests/test_app.py::test_metrics_count_status_requests` still looks for `api_status_requests_total`, which the new app no longer defines. Update that test for `marketmate_http_requests_total` and its method/path/status labels, and add checks for the latency histogram and `/metrics` exclusion. Earlier passing tests and 100% coverage describe the previous app, not this revision.

### Previous runtime checks

Before the middleware/dashboard changes, four tests passed locally and in Python 3.12 Docker, and the previous app and three-panel dashboard passed runtime checks. Those results do not validate the new metrics or dashboard.

The most recent `docker compose up -d --build` built the image but failed to start the default project because ports were occupied. Port `8000` was held by `observability-learning-lab-app-1`; ports `9090` and `3000` were held by the earlier `marketmate` stack. Failed-start containers were cleaned up without deleting volumes. No conflicting project was stopped. These are historical observations, not a fresh check of current container state.

Use only `docker-compose.yml` for the documented startup. Resolve port conflicts before running it, then check the endpoints in [monitoring](#monitoring-and-loki). The earlier temporary port-8080 override is not part of this setup.

### External verification still pending

GitLab pipeline execution, registry push, SonarQube analysis, live SSH deployment/rollback, Kubernetes deployment, and host Nginx/Loki operation have not been verified. The PDF does not require a working GitLab Runner or production server, and requires an explanation rather than a live deployment of Loki and the Nginx troubleshooting scenario.

## PDF requirement review

Reviewed against `Devops engineer task.pdf` in the workspace parent directory. The required source, configuration, and documentation deliverables are present after the corrections below. External CI/deployment services still need operator setup; they were not represented as tested.

### Required sections

| PDF requirement | Status and evidence |
| --- | --- |
| FastAPI `/health` and `/api/status` | Implemented; earlier endpoint tests passed. Current middleware revision requires retesting. |
| Dockerfile and Compose | Two-stage image built; app and monitoring restarted successfully. |
| Non-root application | Verified UID/GID `10001:10001` in the running container. |
| Environment and health checks | `APP_ENV` and `APP_IMAGE`; Compose health check and optional Kubernetes probes. |
| Single-command startup | `docker compose up -d --build` after creating `.env` and choosing a Grafana password. Default ports must be free; the last default startup was blocked by port conflicts. |
| GitLab tests, image build, registry push | Configured in `.gitlab-ci.yml`; tests also passed in the Python 3.12 image. Registry push and CI execution are not verified live. |
| Staging and production deployment | SSH jobs invoke `script/deploy_remote.sh`. Production requires manual approval after staging. Hosts, credentials, and files must be provisioned separately. |
| Rollback documentation | [CI guide](#gitlab-cicd-and-rollback) explains rollback; script attempts the last successful image on startup/health failure. Simulated paths passed; no live rollback performed. |
| Prometheus application metrics | Scrape configured; current app exports request count and latency. New revision not checked live. |
| Basic Grafana dashboard | Four panels configured for request rate, 5xx rate, p95 latency, and target health; new dashboard not checked live. |
| Explain Loki logging and alerting | Covered in [monitoring](#monitoring-and-loki). Running Loki is not required by the PDF. |
| No hardcoded credentials | Config uses `.env` and GitLab variables; `.env` is ignored. No credential values were found in the reviewed configuration. This is not a full repository-history secret audit. |
| Restart policies and limits | All Compose services have restart policies and CPU/memory limits. |
| Security and recovery documentation | Covered in [security and reliability](#security-and-recovery). |
| Nginx 502 investigation, commands, fix, prevention | Covered in [TROUBLESHOOTING.md](#nginx-502-troubleshooting); host example in `nginx/marketmate.conf`. |
| Repository deliverables | Source, Dockerfile, Compose, CI YAML, monitoring, README, and troubleshooting runbook present. |

### Optional bonuses

| Bonus | Status |
| --- | --- |
| Kubernetes Deployment and Service | Implemented with ConfigMap, NodePort, probes, and rolling updates. Local configuration checked; no cluster deployment performed. Namespace creation is documented. |
| RabbitMQ and Celery | Not implemented, following the earlier request to remove them. Optional, so this does not leave a required section incomplete. |
| SonarQube integration | Implemented in CI with coverage and a blocking gate; corrected invalid project key. Server, token, and a successful scan remain to be verified. |

### Corrections made during the earlier PDF review

- Fixed the deployment script to accept the two arguments sent by CI, use the correct default directory syntax, and check the actual `docker-compose.yml` filename.
- Separated rollback state by environment and rejected unsupported environment names.
- Removed invalid inline text from the Sonar project key.
- Replaced the nonexistent rollback-script command in the troubleshooting runbook with the actual deployment script.
- Consolidated Sonar setup/import notes into [one guide](#sonarqube), with the old guides linking to the corresponding README sections.
- Removed stale claims about mock deployments, old paths, and registry variables. Replaced the old validation history with current evidence.

### Remaining setup and practical limitations

1. Configure the Kubernetes GitLab runner for privileged DinD and its shared TLS certificate volume. Configure registry, Sonar, and SSH variables as described in [CI setup](#gitlab-cicd-and-rollback).
2. Prepare separate staging and production hosts with Docker/Compose, Bash, curl, flock, registry pull credentials, repository deployment files, and `.env`. The pipeline does not copy deployment files to hosts.
3. Provision SonarQube and its project/token. Because Sonar is blocking, a missing server or failed gate prevents builds and deployment.
4. For Kubernetes, create the `marketmate` namespace and make the container image available to the cluster. Its current local image tag is a development example.
5. Compose app replacement can briefly interrupt traffic. Kubernetes rolling-update settings are configured but uninterrupted availability has not been tested.
6. The deployment health loop waits approximately 25 seconds plus command execution time. Slow starts can trigger rollback; tune it for the target host if needed. A first deployment has no recorded previous image.
7. Current runtime/test dependencies include floating transitive dependencies, an unpinned `pytest-cov`, and a `latest` SonarScanner image. Reproducibility could be improved, but pinning every dependency is not required by the PDF.

No required section is intentionally omitted, but the metrics test must be updated to match the new app before the current test stage can pass. See [validation](#validation-results) for the distinction between tested behavior, local configuration checks, and external services that remain unverified.
