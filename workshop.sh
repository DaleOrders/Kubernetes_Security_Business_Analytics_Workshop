#!/usr/bin/env bash
# Workshop helper. Usage: ./workshop.sh <command>
#   unpack | tools | create | connect | trivy | incident | query <name> | fix | cleanup | verify
export PATH="$HOME/bin:$PATH"
C=sec-analytics-ws; R=ap-southeast-2
cd "$(dirname "$0")"

# Prints the first image tag that exists in the public registry (falls back to the first candidate).
pick_image() {
  local repo="$1"; shift
  local tok
  tok=$(aws ecr-public get-authorization-token --region us-east-1 --query authorizationData.authorizationToken --output text 2>/dev/null)
  if [ -n "$tok" ] && [ "$tok" != "None" ]; then
    for t in "$@"; do
      if curl -fsS --max-time 15 -o /dev/null -H "Authorization: Bearer $tok" \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
        "https://public.ecr.aws/v2/$repo/manifests/$t" 2>/dev/null; then
        echo "public.ecr.aws/$repo:$t"; return
      fi
    done
  fi
  echo "public.ecr.aws/$repo:$1"
}

# Writes the three working files into this folder: app.yaml, fixed.yaml, risk_report.py
cmd_unpack() {
  cat > app.yaml <<'APPYAML'
# Workshop app: 3 namespaces (teams) + deliberately flawed workloads. Read me!
# Three "teams". Labels and annotations carry the BUSINESS context we join to security data later.
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    team: payments
    tier: critical
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/audit: restricted
  annotations:
    workshop.example/revenue-aud-per-day: "40000"
---
apiVersion: v1
kind: Namespace
metadata:
  name: storefront
  labels:
    team: storefront
    tier: high
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/audit: restricted
  annotations:
    workshop.example/revenue-aud-per-day: "25000"
---
apiVersion: v1
kind: Namespace
metadata:
  name: dev-sandbox
  labels:
    team: platform-dev
    tier: low
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/audit: restricted
  annotations:
    workshop.example/revenue-aud-per-day: "0"
---
apiVersion: v1
kind: Secret
metadata:
  name: payments-db-credentials
  namespace: payments
type: Opaque
stringData:
  username: payments_app
  password: not-a-real-password-workshop-only
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
        - name: api
          image: __NGINX_OLD__
          ports:
            - containerPort: 80
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: payments-db-credentials
                  key: password
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-cache
  namespace: payments
  labels:
    app: payments-cache
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: payments-cache
  template:
    metadata:
      labels:
        app: payments-cache
    spec:
      containers:
        - name: cache
          image: __REDIS_OLD__
          ports:
            - containerPort: 6379
---
apiVersion: v1
kind: Secret
metadata:
  name: storefront-session-key
  namespace: storefront
type: Opaque
stringData:
  key: not-a-real-session-key-workshop-only
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront-web
  namespace: storefront
  labels:
    app: storefront-web
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: storefront-web
  template:
    metadata:
      labels:
        app: storefront-web
    spec:
      containers:
        - name: web
          image: __NGINX_OLD__
          ports:
            - containerPort: 80
          volumeMounts:
            - name: host-logs
              mountPath: /host-logs
      volumes:
        - name: host-logs
          hostPath:
            path: /var/log
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront-promo
  namespace: storefront
  labels:
    app: storefront-promo
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: storefront-promo
  template:
    metadata:
      labels:
        app: storefront-promo
    spec:
      containers:
        - name: promo
          image: __NGINX_OLD__
          ports:
            - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: debug-tool
  namespace: dev-sandbox
  labels:
    app: debug-tool
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: debug-tool
  template:
    metadata:
      labels:
        app: debug-tool
    spec:
      containers:
        - name: tool
          image: public.ecr.aws/docker/library/busybox:latest
          command: ["sleep", "infinity"]
          securityContext:
            privileged: true
---
# Over-broad: can do ANYTHING inside dev-sandbox
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-wildcard
  namespace: dev-sandbox
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-wildcard-binding
  namespace: dev-sandbox
subjects:
  - kind: ServiceAccount
    name: default
    namespace: dev-sandbox
roleRef:
  kind: Role
  name: dev-wildcard
  apiGroup: rbac.authorization.k8s.io
---
# Over-broad: can read secrets in EVERY namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dev-secrets-reader
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dev-secrets-reader-binding
subjects:
  - kind: ServiceAccount
    name: default
    namespace: dev-sandbox
roleRef:
  kind: ClusterRole
  name: dev-secrets-reader
  apiGroup: rbac.authorization.k8s.io
APPYAML
  cat > fixed.yaml <<'FIXEDYAML'
# The hardened replacements for the three nginx workloads
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: __NGINX_SAFE__
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront-web
  namespace: storefront
  labels:
    app: storefront-web
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: storefront-web
  template:
    metadata:
      labels:
        app: storefront-web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: __NGINX_SAFE__
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront-promo
  namespace: storefront
  labels:
    app: storefront-promo
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: storefront-promo
  template:
    metadata:
      labels:
        app: storefront-promo
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: promo
          image: __NGINX_SAFE__
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
FIXEDYAML
  cat > risk_report.py <<'RISKPY'
#!/usr/bin/env python3
"""Turns Trivy Operator findings into a business-weighted risk report.

Usage:
  python3 risk_report.py --label before
  python3 risk_report.py --label before --escalate dev-sandbox=critical
  python3 risk_report.py --label after          (also compares with the 'before' run)
Only needs python3 and kubectl.
"""
import argparse, csv, html, json, os, re, subprocess, sys
from collections import defaultdict

# ---- Tweak these to change how risk is scored -----------------------------
SEV_POINTS   = {"critical": 10, "high": 5, "medium": 2, "low": 0.5}
VULN_FACTOR  = 0.1   # a CVE is a *possible* problem; a misconfiguration is a *definite* one
TIER_FACTOR  = {"critical": 3, "high": 2, "low": 1}
# ---------------------------------------------------------------------------
NSKEY = "workshop.example/revenue-aud-per-day"

def kget(resource, all_ns=True):
    cmd = ["kubectl", "get", resource, "-o", "json"] + (["-A"] if all_ns else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  (could not read {resource}: {r.stderr.strip()[:100]})")
        return []
    return json.loads(r.stdout).get("items", [])

def sev_points(summary, factor=1.0):
    return factor * sum(SEV_POINTS[s] * summary.get(f"{s}Count", 0) for s in SEV_POINTS)

def workload(item):
    lb = item["metadata"].get("labels", {})
    name = lb.get("trivy-operator.resource.name", item["metadata"]["name"])
    kind = lb.get("trivy-operator.resource.kind", "")
    if kind == "ReplicaSet":
        name = re.sub(r"-[a-z0-9]{6,10}$", "", name)
    return kind, name

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="before")
    ap.add_argument("--escalate", action="append", default=[], help="namespace=tier (repeatable)")
    a = ap.parse_args()

    print("Reading cluster data...")
    ns_meta = {}
    for n in kget("namespaces", all_ns=False):
        lb = n["metadata"].get("labels", {})
        if "tier" in lb:
            ns_meta[n["metadata"]["name"]] = {
                "team": lb.get("team", "?"), "tier": lb["tier"],
                "revenue": float(n["metadata"].get("annotations", {}).get(NSKEY, 0))}
    for e in a.escalate:
        k, v = e.split("=")
        if k in ns_meta:
            ns_meta[k]["tier"] = v
            print(f"  >> Escalating {k} to tier '{v}' (based on audit-log evidence)")

    active_rs = {(r["metadata"]["namespace"], r["metadata"]["name"])
                 for r in kget("replicasets") if r.get("status", {}).get("replicas", 0) > 0}

    def keep(item):
        kind, name = item["metadata"].get("labels", {}).get("trivy-operator.resource.kind", ""), None
        if kind == "ReplicaSet":
            return (item["metadata"]["namespace"],
                    item["metadata"]["labels"]["trivy-operator.resource.name"]) in active_rs
        return True

    vulns = [i for i in kget("vulnerabilityreports") if keep(i)]
    conf  = [i for i in kget("configauditreports") if keep(i)]
    rbac  = [i for i in kget("rbacassessmentreports") if keep(i)]

    score = defaultdict(lambda: {"vuln": 0.0, "config": 0.0, "rbac": 0.0, "crit": 0, "high": 0})
    fixes = defaultdict(lambda: {"points": 0.0, "where": set(), "sev": "", "kind": ""})
    scanned = defaultdict(set)

    for it in vulns:
        ns = it["metadata"]["namespace"]
        if ns not in ns_meta: continue
        s = it["report"]["summary"]; _, wl = workload(it)
        scanned[ns].add(wl)
        pts = sev_points(s, VULN_FACTOR); mult = TIER_FACTOR[ns_meta[ns]["tier"]]
        score[ns]["vuln"] += pts * mult
        score[ns]["crit"] += s.get("criticalCount", 0); score[ns]["high"] += s.get("highCount", 0)
        art = it["report"].get("artifact", {})
        img = f'{art.get("repository","?")}:{art.get("tag","?")}'
        f = fixes[("Image", img)]
        f["points"] += pts * mult; f["where"].add(f"{ns}/{wl}"); f["kind"] = "Image"
        f["sev"] = f'{s.get("criticalCount",0)} crit / {s.get("highCount",0)} high CVEs'

    for kind_name, items, cat in (("Config", conf, "config"), ("RBAC", rbac, "rbac")):
        for it in items:
            ns = it["metadata"]["namespace"]
            if ns not in ns_meta: continue
            _, wl = workload(it); mult = TIER_FACTOR[ns_meta[ns]["tier"]]
            for c in it["report"].get("checks", []):
                if c.get("success", True): continue
                sv = c.get("severity", "LOW").lower()
                p = SEV_POINTS.get(sv, 0.5)
                score[ns][cat] += p * mult
                f = fixes[(kind_name, c["title"])]
                f["points"] += p * mult; f["where"].add(f"{ns}/{wl}"); f["sev"] = sv.upper(); f["kind"] = kind_name

    rows, total = [], 0.0
    for ns, m in ns_meta.items():
        s = score[ns]; w = s["vuln"] + s["config"] + s["rbac"]; total += w
        rows.append({"namespace": ns, "team": m["team"], "tier": m["tier"], "revenue_per_day": m["revenue"],
                     "critical_cves": s["crit"], "high_cves": s["high"],
                     "vuln_pts": round(s["vuln"]), "config_pts": round(s["config"]), "rbac_pts": round(s["rbac"]),
                     "risk": round(w), "workloads_scanned": len(scanned[ns])})
    rows.sort(key=lambda r: -r["risk"])
    for r in rows: r["share"] = round(100 * r["risk"] / total) if total else 0

    # ---- terminal output ----
    print(f"\n=== RISK BY NAMESPACE  ({a.label}) ===")
    print(f"{'Namespace':<13}{'Team':<14}{'Tier':<9}{'Crit':>5}{'High':>6}{'Risk':>8}{'Share':>7}  Bar")
    mx = max([r["risk"] for r in rows] + [1])
    for r in rows:
        print(f"{r['namespace']:<13}{r['team']:<14}{r['tier']:<9}{r['critical_cves']:>5}{r['high_cves']:>6}"
              f"{r['risk']:>8}{r['share']:>6}%  {'█' * int(30 * r['risk'] / mx)}")
    print(f"{'TOTAL':<47}{round(total):>8}")
    print("Workloads scanned: " + ", ".join(f"{r['namespace']}={r['workloads_scanned']}" for r in rows)
          + "   (if a number looks low, scans are still running - wait a minute and re-run)")

    top = sorted(fixes.items(), key=lambda kv: -kv[1]["points"])[:8]
    print("\n=== FIX-FIRST LIST (risk points removed if fixed) ===")
    print(f"{'#':<3}{'Type':<8}{'Pts':>6}  {'Finding':<46}Where")
    for i, ((k, title), f) in enumerate(top, 1):
        print(f"{i:<3}{f['kind']:<8}{round(f['points']):>6}  {title[:44]:<46}{len(f['where'])} workload(s): {', '.join(sorted(f['where']))[:60]}")

    # ---- files ----
    fn = f"risk-{a.label}"
    with open(fn + ".csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys())) if rows else None
        if w: w.writeheader(); w.writerows(rows)
    json.dump({r["namespace"]: r["risk"] for r in rows}, open(fn + ".json", "w"))
    cells = "".join(
        f"<tr><td>{html.escape(r['namespace'])}</td><td>{html.escape(r['team'])}</td><td>{r['tier']}</td>"
        f"<td>{r['risk']}</td><td><div style='background:#2563eb;height:14px;width:{int(300*r['risk']/mx)}px'></div></td></tr>"
        for r in rows)
    fx = "".join(f"<tr><td>{i}</td><td>{html.escape(t)}</td><td>{round(f['points'])}</td><td>{html.escape(', '.join(sorted(f['where'])))}</td></tr>"
                 for i, ((k, t), f) in enumerate(top, 1))
    open(fn + ".html", "w").write(
        "<html><body style='font-family:sans-serif;max-width:900px;margin:30px'>"
        f"<h2>Kubernetes risk report ({html.escape(a.label)})</h2><table cellpadding=6 border=1 style='border-collapse:collapse'>"
        f"<tr><th>Namespace</th><th>Team</th><th>Tier</th><th>Risk</th><th></th></tr>{cells}</table>"
        f"<h3>Fix-first list</h3><table cellpadding=6 border=1 style='border-collapse:collapse'>"
        f"<tr><th>#</th><th>Finding</th><th>Points</th><th>Where</th></tr>{fx}</table></body></html>")
    print(f"\nSaved: {fn}.csv  {fn}.html  {fn}.json")

    if a.label == "after" and os.path.exists("risk-before.json"):
        before = json.load(open("risk-before.json"))
        print("\n=== BEFORE vs AFTER ===")
        tb = ta = 0
        for r in rows:
            b = before.get(r["namespace"], 0); tb += b; ta += r["risk"]
            print(f"{r['namespace']:<13}{b:>7} -> {r['risk']:<7}")
        if tb: print(f"{'TOTAL':<13}{tb:>7} -> {ta:<7}  ({round(100*(tb-ta)/tb)}% risk reduction)")

if __name__ == "__main__":
    main()
RISKPY
  # Choose images that really exist in the public registry (first available wins).
  echo "Checking which workshop images are available..."
  NGINX_OLD=$(pick_image docker/library/nginx 1.19 1.21 1.23 1.24.0-alpine 1.25.3-alpine alpine)
  REDIS_OLD=$(pick_image docker/library/redis 5.0 6.0 6.2-alpine alpine)
  NGINX_SAFE=$(pick_image nginx/nginx-unprivileged 1.27-alpine stable-alpine alpine latest)
  sed -i "s|__NGINX_OLD__|$NGINX_OLD|g; s|__REDIS_OLD__|$REDIS_OLD|g; s|__NGINX_SAFE__|$NGINX_SAFE|g" app.yaml fixed.yaml
  echo "  old web image : $NGINX_OLD"
  echo "  old cache     : $REDIS_OLD"
  echo "  hardened web  : $NGINX_SAFE"
  echo "Created: app.yaml  fixed.yaml  risk_report.py"
}

cmd_tools() {
  mkdir -p "$HOME/bin"
  case "$(uname -m)" in x86_64) A=amd64 ;; *) A=arm64 ;; esac
  echo "==> Installing eksctl"
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${A}.tar.gz" | tar xz -C "$HOME/bin" eksctl
  echo "==> Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | USE_SUDO=false HELM_INSTALL_DIR="$HOME/bin" bash
  grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
  eksctl version; helm version --short
  echo "Tools installed. Now run:  source ~/.bashrc"
}

cmd_create() {
  CURRENT=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].RegionName" --output text 2>/dev/null)
  if [ -n "$CURRENT" ] && [ "$CURRENT" != "ap-southeast-2" ]; then
    echo "STOP: this CloudShell is in $CURRENT. Switch the console to Asia Pacific (Sydney) and reopen CloudShell."; exit 1
  fi
  echo "Logged in as: $(aws sts get-caller-identity --query Arn --output text)"
  cat > cluster.yaml <<'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: sec-analytics-ws
  region: ap-southeast-2
  tags:
    workshop: k8s-security-analytics
vpc:
  nat:
    gateway: Disable          # workshop shortcut: saves cost and ~5 min
cloudWatch:
  clusterLogging:
    enableTypes: ["audit"]    # the API server audit trail -> CloudWatch Logs
    logRetentionInDays: 1
managedNodeGroups:
  - name: workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
    volumeSize: 20
    volumeType: gp3
YAML
  nohup eksctl create cluster -f cluster.yaml > create-cluster.log 2>&1 &
  echo
  echo "Cluster creation started (about 15 minutes)."
  echo "Watch progress with:   tail -f create-cluster.log     (Ctrl+C stops watching, not the build)"
}

cmd_connect() {
  STATUS=$(aws eks describe-cluster --name "$C" --region "$R" --query cluster.status --output text 2>/dev/null || echo MISSING)
  if [ "$STATUS" != "ACTIVE" ]; then echo "Cluster status is $STATUS - not ready yet. Wait and retry."; exit 1; fi
  if ! command -v kubectl >/dev/null 2>&1; then
    V=$(aws eks describe-cluster --name "$C" --region "$R" --query cluster.version --output text)
    case "$(uname -m)" in x86_64) A=amd64 ;; *) A=arm64 ;; esac
    KV=$(curl -fsSL "https://dl.k8s.io/release/stable-${V}.txt")
    echo "==> Installing kubectl ${KV}"
    curl -fsSL -o "$HOME/bin/kubectl" "https://dl.k8s.io/release/${KV}/bin/linux/${A}/kubectl"
    chmod +x "$HOME/bin/kubectl"
  fi
  NG=$(aws eks describe-nodegroup --cluster-name "$C" --nodegroup-name workers --region "$R" --query nodegroup.status --output text 2>/dev/null || echo MISSING)
  if [ "$NG" != "ACTIVE" ]; then echo "Worker nodes are $NG - still building. Wait a minute or two and retry."; exit 1; fi
  aws eks update-kubeconfig --name "$C" --region "$R"
  echo "Waiting for both nodes to be Ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
  # Make sure the metrics add-on (for 'kubectl top') is present
  if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    echo "==> Installing the metrics-server add-on"
    aws eks create-addon --cluster-name "$C" --addon-name metrics-server --region "$R" >/dev/null || true
    aws eks wait addon-active --cluster-name "$C" --addon-name metrics-server --region "$R" || true
  fi
  echo; kubectl get nodes
}

cmd_trivy() {
  helm repo add aqua https://aquasecurity.github.io/helm-charts/ >/dev/null
  helm repo update >/dev/null
  helm upgrade --install trivy-operator aqua/trivy-operator \
    --namespace trivy-system --create-namespace \
    --set targetNamespaces="payments\,storefront\,dev-sandbox" \
    --set operator.scanJobsConcurrentLimit=2 \
    --set operator.infraAssessmentScannerEnabled=false \
    --set operator.exposedSecretScannerEnabled=false \
    --wait --timeout 5m
  echo; echo "Trivy Operator is running. Scans start automatically."
}

# Plays the part of an intruder holding a stolen dev-sandbox token.
cmd_incident() {
  SA="system:serviceaccount:dev-sandbox:default"
  say() { printf '\n\033[1;36m[intruder] %s\033[0m\n' "$*"; }
  say "1. What can this stolen token do?"
  kubectl auth can-i list secrets --all-namespaces --as="$SA"
  say "2. Reading secrets in other teams' namespaces..."
  kubectl get secrets -n payments --as="$SA"
  kubectl get secrets -n storefront --as="$SA"
  say "3. Trying to go further (these should be denied)..."
  kubectl get nodes --as="$SA" 2>&1 | head -n 2
  kubectl exec -n payments deploy/payments-api --as="$SA" -- id 2>&1 | head -n 2
  kubectl get pods -n payments --as=system:anonymous 2>&1 | head -n 2
  say "4. Deploying a 'cache-warmer' in dev-sandbox..."
  kubectl apply --as="$SA" -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache-warmer
  namespace: dev-sandbox
  labels:
    app: cache-warmer
spec:
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: cache-warmer
  template:
    metadata:
      labels:
        app: cache-warmer
    spec:
      containers:
        - name: warmer
          image: public.ecr.aws/docker/library/busybox:latest
          command: ["sh", "-c"]
          args:
            - while true; do i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done; sleep 1; done
YAML
  echo; echo "Done. Audit logs take 1-3 minutes to reach CloudWatch."
}

# Runs a saved CloudWatch Logs Insights query: ./workshop.sh query <forbidden|secrets|changes|psa> [minutes]
cmd_query() {
  LG="/aws/eks/$C/cluster"
  case "${1:-}" in
  forbidden) Q='fields impersonatedUser.username as actor, verb, objectRef.resource as resource, responseStatus.code as code
| filter ispresent(impersonatedUser.username) and responseStatus.code >= 400
| stats count(*) as attempts by actor, verb, resource, code
| sort attempts desc' ;;
  secrets) Q='fields impersonatedUser.username as actor, objectRef.namespace as ns, verb, responseStatus.code as code
| filter objectRef.resource = "secrets" and ispresent(impersonatedUser.username) and verb in ["get","list"]
| stats count(*) as reads by actor, ns, verb, code
| sort reads desc' ;;
  changes) Q='fields @timestamp, impersonatedUser.username as actor, verb, objectRef.resource as resource, objectRef.name as name, objectRef.namespace as ns
| filter ispresent(impersonatedUser.username) and verb in ["create","update","patch","delete"] and responseStatus.code < 300
| sort @timestamp asc
| limit 20' ;;
  psa) Q='fields objectRef.namespace as ns, objectRef.resource as resource
| filter @message like /audit-violations/
| stats count(*) as violations by ns, resource
| sort violations desc' ;;
  *) echo "Usage: $0 <forbidden|secrets|changes|psa> [minutes]"; exit 1 ;;
esac
  MINS="${2:-90}"; NOW=$(date +%s)
  QID=$(aws logs start-query --region "$R" --log-group-name "$LG" \
    --start-time $((NOW - MINS*60)) --end-time "$NOW" --query-string "$Q" --query queryId --output text)
  echo "Query '$1' running..."
  while true; do
    OUT=$(aws logs get-query-results --region "$R" --query-id "$QID")
    ST=$(echo "$OUT" | jq -r .status)
    [ "$ST" = "Complete" ] && break
    case "$ST" in Failed|Cancelled|Timeout) echo "$OUT"; exit 1 ;; esac
    sleep 2
  done
  echo "$OUT" | jq -r '.results as $r
    | if ($r|length)==0 then "(no results yet - audit logs can take 1-3 minutes to arrive. Wait a minute and run it again.)"
      else (($r[0]|map(select(.field!="@ptr")|.field)|@tsv), ($r[]|map(select(.field!="@ptr")|.value)|@tsv)) end' \
    | column -t -s "$(printf '\t')"
}

# Removes the intruder's foothold and hardens the nginx workloads.
cmd_fix() {
  echo "==> Removing the cache-warmer, debug pod and over-broad access"
  kubectl delete deployment cache-warmer debug-tool -n dev-sandbox --ignore-not-found
  kubectl delete clusterrolebinding dev-secrets-reader-binding --ignore-not-found
  kubectl delete rolebinding dev-wildcard-binding -n dev-sandbox --ignore-not-found
  kubectl delete role dev-wildcard -n dev-sandbox --ignore-not-found
  echo "==> Applying hardened nginx workloads"
  kubectl apply -f fixed.yaml
  echo; echo "Trivy will now re-scan. Give it 2-3 minutes, then run: python3 risk_report.py --label after"
}

# Deletes EVERYTHING the workshop created.
cmd_cleanup() {
  echo "==> Deleting the cluster, node group, VPC and IAM roles (about 10 minutes)..."
  eksctl delete cluster --name "$C" --region "$R" --wait
  echo "==> Deleting the audit log group (EKS does not remove it for you)..."
  aws logs delete-log-group --log-group-name "/aws/eks/$C/cluster" --region "$R" 2>/dev/null && echo "log group deleted" || echo "log group already gone"
  echo; cmd_verify
}

# Checks that nothing from the workshop is left. Safe to run any time.
cmd_verify() {
  BAD=0
  # Larger of several counts; if any check errored, return its message so chk reports "could not check".
  maxof() { local m=0 x; for x in "$@"; do if [[ "$x" =~ ^[0-9]+$ ]]; then [ "$x" -gt "$m" ] && m="$x"; else echo "$x"; return; fi; done; echo "$m"; }
  chk() {
    if ! [[ "$2" =~ ^[0-9]+$ ]]; then echo "  [ ?? ] $1: could not check ($2)"; BAD=1
    elif [ "$2" = "0" ]; then echo "  [ OK ] $1: none left"
    else echo "  [LEFT] $1: $2 remaining"; BAD=1; fi
  }
  echo "Checking region $R for leftovers from cluster '$C'..."
  chk "EKS clusters"          "$(aws eks list-clusters --region $R --query "length(clusters[?@=='$C'])" --output text 2>&1)"
  chk "CloudFormation stacks" "$(aws cloudformation list-stacks --region $R --stack-status-filter CREATE_IN_PROGRESS CREATE_COMPLETE ROLLBACK_COMPLETE UPDATE_COMPLETE DELETE_IN_PROGRESS DELETE_FAILED --query "length(StackSummaries[?starts_with(StackName,'eksctl-$C')])" --output text 2>&1)"
  ST="Name=instance-state-name,Values=pending,running,stopping,stopped"
  chk "EC2 instances"         "$(maxof "$(aws ec2 describe-instances --region $R --filters "Name=tag:aws:eks:cluster-name,Values=$C" "$ST" --query "length(Reservations[].Instances[])" --output text 2>&1)" "$(aws ec2 describe-instances --region $R --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=$C" "$ST" --query "length(Reservations[].Instances[])" --output text 2>&1)")"
  chk "VPCs"                  "$(maxof "$(aws ec2 describe-vpcs --region $R --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=$C" --query "length(Vpcs)" --output text 2>&1)" "$(aws ec2 describe-vpcs --region $R --filters "Name=tag:Name,Values=eksctl-$C-cluster/*" --query "length(Vpcs)" --output text 2>&1)")"
  chk "NAT gateways"          "$(maxof "$(aws ec2 describe-nat-gateways --region $R --filter "Name=tag:alpha.eksctl.io/cluster-name,Values=$C" "Name=state,Values=pending,available,deleting" --query "length(NatGateways)" --output text 2>&1)" "$(aws ec2 describe-nat-gateways --region $R --filter "Name=tag:Name,Values=eksctl-$C-cluster/*" "Name=state,Values=pending,available,deleting" --query "length(NatGateways)" --output text 2>&1)")"
  chk "IAM roles"             "$(aws iam list-roles --query "length(Roles[?starts_with(RoleName,'eksctl-$C')])" --output text 2>&1)"
  chk "CloudWatch log groups" "$(aws logs describe-log-groups --region $R --log-group-name-prefix /aws/eks/$C --query "length(logGroups)" --output text 2>&1)"
  echo
  if [ "$BAD" = "0" ]; then echo "ALL CLEAN - nothing is left running or billing."; else echo "Some items remain. If the cluster is still deleting, wait a few minutes and re-run ./workshop.sh verify"; fi
}

case "${1:-help}" in
  unpack) cmd_unpack ;; tools) cmd_tools ;; create) cmd_create ;; connect) cmd_connect ;; trivy) cmd_trivy ;;
  incident) cmd_incident ;; query) shift; cmd_query "$@" ;; fix) cmd_fix ;;
  cleanup) cmd_cleanup ;; verify) cmd_verify ;;
  *) echo "Usage: ./workshop.sh <unpack|tools|create|connect|trivy|incident|query <name>|fix|cleanup|verify>" ;;
esac
