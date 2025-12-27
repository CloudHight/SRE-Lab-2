# SRE Full-Stack Observability & AI Incident Response (eksctl)

This is a complete, step-by-step guide to deploy a full observability stack and AI-assisted incident response on AWS using eksctl and Helm. Follow the numbered steps in order. Replace all placeholders like `<REGION>`, `<ACCOUNT_ID>`, `<AMP_WORKSPACE_ID>`, `<LOKI_BUCKET_NAME>`, `<ACM_CERT_ARN>`, `<YOUR_DOMAIN>`, `<RUNBOOK_ROLE>`, `<LAMBDA_ROLE_WITH_BEDROCK_AND_SNS>`.

## Repo layout (what’s here)
- `infra/cluster/eks-cluster.yaml` — eksctl cluster + VPC + nodegroups + OIDC.
- `infra/addons/` — values for metrics-server and AWS Load Balancer Controller.
- `observability/` — values for Loki, Promtail, OpenTelemetry Collector, Jaeger.
- `app/sample/` — sample app (Deployment/Service/Ingress) with OTEL env vars.
- `incident-automation/` — Incident Manager response plan, SSM runbook, AI Lambda stub.

## 1) Prep your workstation
1. Install AWS CLI v2, Docker, kubectl, eksctl, helm, jq, kubectx/kubens. (Windows/Chocolatey: `choco install awscli kubernetes-cli eksctl helm jq kubectx-ps`)
2. Configure AWS: `aws configure sso` (preferred) or `aws configure`; set default `<REGION>` (e.g., `us-east-1`) and output `json`.
3. Verify: `aws sts get-caller-identity`, `eksctl version`, `kubectl version --client`, `helm version`.

## 2) Prepare AWS account
1. Ensure you have an admin role you can assume; enforce MFA.
2. (Optional) Create an EC2 key pair for debugging: `aws ec2 create-key-pair --key-name sre-key --query KeyMaterial --output text > sre-key.pem`.
3. Capture your account ID: `ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`.

## 3) Create the EKS cluster (eksctl)
1. Edit `infra/cluster/eks-cluster.yaml` and set your `<REGION>` (and adjust CIDRs/instance types if desired).
2. Create cluster: `eksctl create cluster -f infra/cluster/eks-cluster.yaml`.
3. Export kubeconfig: `aws eks update-kubeconfig --name sre-observability --region <REGION>`.
4. Verify: `kubectl get nodes`, `kubectl get pods -A`.

## 4) Install core addons
### 4.1 Metrics Server
```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ && helm repo update
helm upgrade -i metrics-server metrics-server/metrics-server -n kube-system -f infra/addons/metrics-server-values.yaml
```
### 4.2 Cluster Autoscaler
```bash
CLUSTER=sre-observability
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/cluster-autoscaler-1.28.0/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml
kubectl -n kube-system patch deployment cluster-autoscaler -p '{"spec":{"template":{"spec":{"containers":[{"name":"cluster-autoscaler","command":["./cluster-autoscaler","--cloud-provider=aws","--cluster-name='${CLUSTER}'","--balance-similar-node-groups","--skip-nodes-with-system-pods=false","--skip-nodes-with-local-storage=false","--namespace=kube-system","--scale-down-delay-after-add=10m","--scale-down-unneeded-time=10m","--scan-interval=10s"]}]}}}}'
kubectl -n kube-system annotate deployment cluster-autoscaler cluster-autoscaler.kubernetes.io/safe-to-evict="false"
```
### 4.3 AWS Load Balancer Controller
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
curl -o /tmp/alb-iam.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.2/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file:///tmp/alb-iam.json
eksctl create iamserviceaccount \
  --cluster sre-observability \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
helm repo add eks https://aws.github.io/eks-charts
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=sre-observability \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=<REGION> \
  -f infra/addons/aws-load-balancer-controller-values.yaml
```

## 5) Create ECR repos (one per service)
```bash
aws ecr create-repository --repository-name app-api
aws ecr create-repository --repository-name app-frontend
```
Build/push example:
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=<REGION>
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
docker build -t $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/app-api:dev .
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/app-api:dev
```

### 5.1 Build and push the included sample app image (optional)
The sample Deployment references your own image. A simple Dockerfile is provided in `app/sample/Dockerfile` (static nginx site).
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=<REGION>
IMAGE="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/sample-api:dev"
aws ecr create-repository --repository-name sample-api || true
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
docker build -t $IMAGE -f app/sample/Dockerfile app/sample
docker push $IMAGE
```
Then set that image in `app/sample/deployment.yaml`.

## 6) Namespaces and sample app
```bash
kubectl create ns app
kubectl create ns observability
kubectl create ns ops
kubectl apply -f app/sample/deployment.yaml    # ensure image points to your ECR image
kubectl apply -f app/sample/ingress.yaml      # fill <ACM_CERT_ARN> and <YOUR_DOMAIN>
```
Check: `kubectl get deploy,svc,ing -n app`.

## 7) Loki (logs) + Promtail
1. Create S3 bucket `<LOKI_BUCKET_NAME>` in `<REGION>` for Loki storage.
2. Update `observability/loki/loki-values.yaml` with your bucket and region.
3. Install:
```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm upgrade -i loki grafana/loki -n observability -f observability/loki/loki-values.yaml
helm upgrade -i promtail grafana/promtail -n observability -f observability/promtail/promtail-values.yaml
```
4. Verify: `kubectl get pods -n observability`.

## 8) Managed Prometheus (AMP) + Managed Grafana (AMG)
1. Create AMP workspace: `aws amp create-workspace --alias sre-amp` → note `<AMP_WORKSPACE_ID>`.
2. Create AMP IAM policy:
```bash
cat > /tmp/amp-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ],
      "Resource": "arn:aws:aps:<REGION>:<ACCOUNT_ID>:workspace/<AMP_WORKSPACE_ID>"
    }
  ]
}
EOF
aws iam create-policy --policy-name AMPRemoteWriteRead --policy-document file:///tmp/amp-policy.json
```
3. Create AMG workspace (console); enable SSO/IAM. Add AMP as data source (use AMP endpoint). Later add Loki.

## 9) OpenTelemetry Collector
1. Update `observability/otel/otel-values.yaml` with `<REGION>`, `<AMP_WORKSPACE_ID>`, and any Loki endpoint changes.
2. Create IRSA for Collector:
```bash
eksctl create iamserviceaccount \
  --cluster sre-observability \
  --namespace observability \
  --name otel-collector \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AMPRemoteWriteRead \
  --approve
```
3. Install Collector:
```bash
helm repo add aws-otel https://aws-observability.github.io/aws-otel-helm-chart && helm repo update
helm upgrade -i otel-collector aws-otel/aws-otel-collector -n observability -f observability/otel/otel-values.yaml
```
4. Check logs: `kubectl logs deploy/otel-collector -n observability`.

## 10) Instrument your app (OTEL)
1. In each Deployment, set:
   - `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317`
   - `OTEL_RESOURCE_ATTRIBUTES=service.name=<svc>,service.namespace=app,env=prod`
2. Add language-specific OTEL SDK/auto-instrumentation and enable W3C trace propagation.
3. Deploy your images (from ECR) and generate traffic.

## 11) Traces UI: Jaeger + X-Ray
1. Install Jaeger:
```bash
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts && helm repo update
helm upgrade -i jaeger jaegertracing/jaeger -n observability -f observability/jaeger/jaeger-values.yaml
```
2. X-Ray: already exported by Collector; set sampling rules in X-Ray console (start with 5–10%).

## 12) Dashboards and alerts
1. In AMG, add data sources: AMP (metrics) and Loki (logs). Link traces via exemplars to X-Ray/Jaeger.
2. Create dashboards: golden signals per service, infra (node/pod health), trace latency histograms.
3. Configure alerting (PrometheusRule/Alertmanager or OTel) to publish to SNS topic `sre-incidents`.

## 13) DevOps Guru
1. Enable coverage: `aws devops-guru start-resource-coverage --resource-collection CloudFormation={StackNames=[sre-observability-*]}` or enable in console for the account/region.
2. Confirm insights appear after some load/faults.

## 14) Incident Manager
1. Create SNS topic: `aws sns create-topic --name sre-incidents`.
2. Create replication set: `aws ssm-incidents create-replication-set --regions <REGION>`.
3. Create contacts/rotation: `aws ssm-contacts create-contact ...`.
4. Update placeholders in `incident-automation/response-plan.json` and apply:
```bash
aws ssm-incidents create-response-plan --cli-input-json file://incident-automation/response-plan.json
```
5. Update placeholders in `incident-automation/runbooks/restart-pod.json` and register as an SSM Automation document (or keep as a reference for your own runbook).

## 15) ChatOps (AWS Chatbot)
1. In console, configure Chatbot for Slack/Teams; select SNS topic `sre-incidents`; attach an IAM role with read-only + needed observability actions.
2. Subscribe topic to Chatbot:
```bash
aws sns subscribe --topic-arn arn:aws:sns:<REGION>:<ACCOUNT_ID>:sre-incidents --protocol chatbot --notification-endpoint <CHATBOT_CHANNEL_ARN>
```
3. Test: `aws sns publish --topic-arn arn:aws:sns:<REGION>:<ACCOUNT_ID>:sre-incidents --message "chatbot test"`.

## 16) AI suggestion Lambda
1. Update placeholders in `incident-automation/lambda/main.py` environment expectations.
2. Build and deploy:
```bash
cd incident-automation/lambda
pip install -r requirements.txt -t ./pkg
cp main.py pkg/
cd pkg && zip -r ../incident-ai.zip .
aws lambda create-function \
  --function-name incident-ai-suggestions \
  --handler main.handler \
  --runtime python3.11 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/<LAMBDA_ROLE_WITH_BEDROCK_AND_SNS> \
  --timeout 30 \
  --memory-size 512 \
  --environment Variables="{SNS_TOPIC_ARN=arn:aws:sns:<REGION>:<ACCOUNT_ID>:sre-incidents,BEDROCK_MODEL=anthropic.claude-v2}" \
  --zip-file fileb://incident-ai.zip
aws lambda add-permission --function-name incident-ai-suggestions --statement-id sns --action lambda:InvokeFunction --principal sns.amazonaws.com
aws sns subscribe --topic-arn arn:aws:sns:<REGION>:<ACCOUNT_ID>:sre-incidents --protocol lambda --notification-endpoint arn:aws:lambda:<REGION>:<ACCOUNT_ID>:function:incident-ai-suggestions
```
3. (Optional) Extend Lambda to query DynamoDB/OpenSearch for past incidents and redact PII before posting.

## 17) Fault injection and validation
1. Deploy a load generator (k6/locust) or a chaos pod.
2. Induce: pod crash loop, latency spike, 5xx burst.
3. Verify end-to-end:
   - Metrics in AMP, logs in Loki, traces in X-Ray/Jaeger.
   - Alerts fire to SNS → Incident Manager → Chatbot.
   - AI Lambda posts suggestions; runbook executes (manual/auto).

## Cleanup (to avoid costs)
- `helm uninstall` the charts (loki, promtail, otel-collector, jaeger, aws-load-balancer-controller, metrics-server).
- `eksctl delete cluster -f infra/cluster/eks-cluster.yaml`.
- Delete ECR images, S3 buckets (Loki), AMP/AMG workspaces, SNS topics, IAM roles/policies.

## Placeholder checklist (fill before applying)
- `<REGION>`, `<ACCOUNT_ID>`, `<LOKI_BUCKET_NAME>`, `<AMP_WORKSPACE_ID>`, `<ACM_CERT_ARN>`, `<YOUR_DOMAIN>`, `<RUNBOOK_ROLE>`, `<LAMBDA_ROLE_WITH_BEDROCK_AND_SNS>`.
