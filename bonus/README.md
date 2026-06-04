# Bonus — GitLab CE in Cluster

GitLab CE running inside the k3d cluster (namespace `gitlab`). Argo CD syncs from the local GitLab repository instead of GitHub — a fully self-hosted GitOps pipeline.

## Architecture

```
bonus/confs/manifests/   ← source of truth (pushed to local GitLab on install)
                                │
          ┌─────────────────────┘
          │
    GitLab CE  (namespace: gitlab)
    image: gitlab/gitlab-ce:latest
    service: gitlab.gitlab.svc.cluster.local:80
          │
          │  automated sync (Argo CD watches every ~3 min)
          ▼
      Argo CD  (namespace: argocd)
          │
          │  deploys
          ▼
    wil-playground  (namespace: dev)
    image: wil42/playground:v1
    port: 8888
```

## Configuration files

| File | Purpose |
|:-----|:--------|
| `scripts/install.sh` | Full automated setup — installs prerequisites, creates cluster, deploys GitLab and Argo CD |
| `confs/gitlab.yaml` | GitLab CE deployment (pod + service in namespace `gitlab`) |
| `confs/argocd-app.yaml` | Argo CD Application pointing to the local GitLab repo |
| `confs/manifests/deployment.yaml` | wil-playground Deployment pushed to GitLab |
| `confs/manifests/service.yaml` | wil-playground Service pushed to GitLab |

## Technologies

| Tool | Role |
|:----:|:-----|
| **k3d** | Kubernetes cluster inside Docker (no VMs) |
| **GitLab CE** | Self-hosted Git server, latest official image |
| **Argo CD** | GitOps controller — watches GitLab and auto-deploys on push |
| **kubectl** | Cluster management |

---

## Start

```bash
cd bonus
sudo bash scripts/install.sh
```

> GitLab takes **8–15 minutes** to initialize on first boot (database setup).

---

## Step 1 — Access GitLab

Open a terminal and run:

```bash
kubectl port-forward svc/gitlab -n gitlab 8929:80
```

Keep this terminal open. Open `http://localhost:8929` in a browser.

**Credentials:**

```bash
# Username: root
# Password:
kubectl exec -n gitlab deployment/gitlab -- grep Password /etc/gitlab/initial_root_password
```

---

## Step 2 — Get a personal access token

The token is needed to interact with GitLab from the terminal.

Run the command below and **copy the printed token** (the long `glpat-...` string):

```bash
kubectl exec -n gitlab deployment/gitlab -- gitlab-rails runner "
token = User.find_by_username('root').personal_access_tokens.create!(
  name: 'eval-token',
  scopes: [:api, :read_repository, :write_repository],
  expires_at: 30.days.from_now
)
puts token.token
" 2>/dev/null | tail -1
```

Then export it (replace with your actual token):

```bash
export GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"
```

> The command takes ~30 seconds to respond (Rails environment load).

---

## Step 3 — Create a new repository in GitLab and add code

### Option A — Web UI (recommended for evaluation)

1. Open `http://localhost:8929` and log in as `root`
2. Click **"New project"** → **"Create blank project"**
3. Fill in **Project name**: `my-test-repo`, set visibility to **Public**, check **"Initialize repository with a README"**
4. Click **"Create project"**

Then clone it, add a file and push from the terminal:

```bash
# Make sure GITLAB_TOKEN is set (see Step 2)
cd /tmp && rm -rf my-test-repo

git clone "http://root:${GITLAB_TOKEN}@localhost:8929/root/my-test-repo.git"
cd my-test-repo

echo 'echo "Hello from local GitLab!"' > hello.sh
git add hello.sh
git commit -m "Add hello.sh"
git push

cd /tmp && rm -rf my-test-repo
```

Go back to `http://localhost:8929/root/my-test-repo` — `hello.sh` should appear in the repository.

### Option B — Terminal only

```bash
# Make sure GITLAB_TOKEN is set (see Step 2)

# Create the repo via API
curl -sf --request POST http://localhost:8929/api/v4/projects \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"name":"my-test-repo","visibility":"public","initialize_with_readme":true}' \
  | jq '{id, name, http_url_to_repo}'

# Clone, add a file, push
cd /tmp && rm -rf my-test-repo
git clone "http://root:${GITLAB_TOKEN}@localhost:8929/root/my-test-repo.git"
cd my-test-repo

echo 'echo "Hello from local GitLab!"' > hello.sh
git add hello.sh
git commit -m "Add hello.sh"
git push

# Verify the file is in GitLab
curl -sf "http://localhost:8929/api/v4/projects/$(
  curl -sf http://localhost:8929/api/v4/projects \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '.[] | select(.name=="my-test-repo") | .id'
)/repository/files/hello.sh?ref=main" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  | jq '{file_name, content: (.content | @base64d)}'

cd /tmp && rm -rf my-test-repo
```

---

## Step 4 — Verify Argo CD syncs from local GitLab

```bash
kubectl get application -n argocd
# NAME             SYNC STATUS   HEALTH STATUS
# wil-playground   Synced        Healthy

# Confirm the repo URL is local GitLab (not GitHub)
kubectl get secret gitlab-repo-secret -n argocd \
  -o jsonpath='{.data.url}' | base64 -d && echo
# http://gitlab.gitlab.svc.cluster.local/root/iot-manifests.git
```

Access Argo CD UI:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open `http://localhost:8080` — user: `admin`

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## Step 5 — Test version change (v1 → v2)

```bash
# Make sure GITLAB_TOKEN is set and GitLab port-forward is running (Step 1)

cd /tmp && rm -rf iot-update
git clone "http://root:${GITLAB_TOKEN}@localhost:8929/root/iot-manifests.git" iot-update

sed -i 's/playground:v1/playground:v2/' /tmp/iot-update/deployment.yaml

git -C /tmp/iot-update config user.email "root@gitlab.local"
git -C /tmp/iot-update config user.name "Root"
git -C /tmp/iot-update add .
git -C /tmp/iot-update commit -m "Update wil-playground to v2"
git -C /tmp/iot-update push

cd /tmp && rm -rf iot-update
```

Wait ~30 seconds for Argo CD to detect the change, then verify:

```bash
kubectl get pods -n dev
# New pod is created automatically

kubectl port-forward svc/wil-playground -n dev 8888:8888
curl http://localhost:8888/
# {"status":"ok", "message": "v2"}
```

Revert to v1:

```bash
cd /tmp && rm -rf iot-revert
git clone "http://root:${GITLAB_TOKEN}@localhost:8929/root/iot-manifests.git" iot-revert
sed -i 's/playground:v2/playground:v1/' /tmp/iot-revert/deployment.yaml
git -C /tmp/iot-revert config user.email "root@gitlab.local"
git -C /tmp/iot-revert config user.name "Root"
git -C /tmp/iot-revert add .
git -C /tmp/iot-revert commit -m "Revert wil-playground to v1"
git -C /tmp/iot-revert push
cd /tmp && rm -rf iot-revert
```

---

## Verify all pods

```bash
kubectl get pods -n gitlab    # GitLab:  1/1 Running
kubectl get pods -n argocd    # ArgoCD:  all Running
kubectl get pods -n dev       # App:     1/1 Running
```

---

## Destroy cluster

```bash
sudo k3d cluster delete iot-cluster
```
