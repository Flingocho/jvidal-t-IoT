#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# All log functions write to stderr so they don't pollute stdout captures
log()   { echo -e "${GREEN}[+]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[!]${NC} $1" >&2; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

[ "$EUID" -ne 0 ] && error "Run as root: sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"
MANIFESTS_DIR="$CONFS_DIR/manifests"

# ── Prerequisites ─────────────────────────────────────────────────────────────

install_prerequisites() {
    log "Installing prerequisites..."
    apt-get update -qq
    apt-get install -y -qq curl git jq

    if ! command -v docker &>/dev/null; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        [ -n "$SUDO_USER" ] && usermod -aG docker "$SUDO_USER"
    fi

    if ! command -v kubectl &>/dev/null; then
        log "Installing kubectl..."
        curl -sfLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm -f kubectl
    fi

    if ! command -v k3d &>/dev/null; then
        log "Installing k3d..."
        curl -sfL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    fi
}

# ── Cluster ───────────────────────────────────────────────────────────────────

create_cluster() {
    log "Creating k3d cluster..."
    k3d cluster delete iot-cluster 2>/dev/null || true
    k3d cluster create iot-cluster \
        --port "80:80@loadbalancer" \
        --port "443:443@loadbalancer" \
        --wait
    log "Cluster ready"

    if [ -n "$SUDO_USER" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        mkdir -p "$USER_HOME/.kube"
        cp /root/.kube/config "$USER_HOME/.kube/config"
        chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube/config"
    fi
}

create_namespaces() {
    log "Creating namespaces..."
    for ns in gitlab argocd dev; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    done
}

# ── GitLab ────────────────────────────────────────────────────────────────────

install_gitlab() {
    log "Deploying GitLab CE (latest official image)..."
    kubectl apply -f "$CONFS_DIR/gitlab.yaml"

    log "Waiting for GitLab pod to start..."
    kubectl wait pod \
        -l app=gitlab \
        -n gitlab \
        --for=condition=Initialized \
        --timeout=120s

    log "GitLab initializing — waiting for /-/readiness (up to 20 min)..."
    local attempt=0
    local max=80
    # FIX: kubectl exec does not support -l flag — use deployment/gitlab directly
    until kubectl exec -n gitlab deployment/gitlab -- \
            curl -sf http://localhost/-/readiness > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        [ $attempt -ge $max ] && error "GitLab did not become ready after $((max * 15))s"
        printf "." >&2
        sleep 15
    done
    echo "" >&2
    log "GitLab ready"
}

create_gitlab_token() {
    log "Creating GitLab personal access token via rails runner..."

    # Use a temp file to avoid capturing Rails runner output in the variable.
    # log() writes to stderr so it won't pollute this function's stdout.
    local tmpfile
    tmpfile=$(mktemp)

    kubectl exec -n gitlab deployment/gitlab -- \
        gitlab-rails runner "
user = User.find_by_username('root')
token = user.personal_access_tokens.create!(
  name: 'iot-token',
  scopes: [:api, :read_repository, :write_repository],
  expires_at: 1.year.from_now
)
puts token.token
" > "$tmpfile" 2>/dev/null

    local token
    token=$(tail -1 "$tmpfile")
    rm -f "$tmpfile"

    [ -z "$token" ] && error "Failed to create GitLab token"
    echo "$token"   # only line printed to stdout — safe to capture with $()
}

setup_gitlab_repo() {
    local token=$1

    log "Port-forwarding GitLab for initial repo setup..."
    kubectl port-forward svc/gitlab -n gitlab 8929:80 &
    local pf_pid=$!

    log "Waiting for GitLab API to be accessible..."
    local attempt=0
    until curl -sf "http://localhost:8929/api/v4/version" \
            --header "PRIVATE-TOKEN: $token" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        [ $attempt -ge 30 ] && { kill $pf_pid 2>/dev/null; error "GitLab API not accessible after 300s"; }
        sleep 10
    done

    log "Creating iot-manifests project..."
    # || true: ignore error if project already exists
    curl -s --request POST \
        "http://localhost:8929/api/v4/projects" \
        --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data '{"name":"iot-manifests","visibility":"public","initialize_with_readme":true}' \
        > /dev/null || true

    log "Pushing manifests to GitLab..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    git clone "http://root:${token}@localhost:8929/root/iot-manifests.git" "$tmp_dir" 2>/dev/null
    cp "$MANIFESTS_DIR"/*.yaml "$tmp_dir/"
    git -C "$tmp_dir" config user.email "root@gitlab.local"
    git -C "$tmp_dir" config user.name "Root"
    git -C "$tmp_dir" add .
    git -C "$tmp_dir" commit -m "Add IoT manifests" 2>/dev/null || true
    git -C "$tmp_dir" push 2>/dev/null
    rm -rf "$tmp_dir"

    kill $pf_pid 2>/dev/null || true
    log "Manifests pushed successfully"
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

install_argocd() {
    log "Installing ArgoCD..."
    # Do not use --server-side: causes CRD annotation "too long" error on exit
    kubectl apply -n argocd \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
        2>&1 | grep -v "Too long" >&2 || true

    kubectl wait --for=condition=available deployment --all \
        -n argocd --timeout=300s

    log "Configuring ArgoCD in insecure mode..."
    kubectl patch configmap argocd-cmd-params-cm \
        -n argocd --type merge \
        -p '{"data":{"server.insecure":"true"}}'

    kubectl rollout restart deployment argocd-server -n argocd
    kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
    log "ArgoCD ready"
}

configure_argocd_repo() {
    local token=$1

    log "Registering GitLab repo in ArgoCD..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: http://gitlab.gitlab.svc.cluster.local/root/iot-manifests.git
  username: root
  password: "${token}"
EOF

    log "Deploying ArgoCD Application..."
    kubectl apply -f "$CONFS_DIR/argocd-app.yaml"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    install_prerequisites
    create_cluster
    create_namespaces
    install_gitlab

    GITLAB_TOKEN=$(create_gitlab_token)
    log "Token created: ${GITLAB_TOKEN:0:12}..."

    setup_gitlab_repo "$GITLAB_TOKEN"
    install_argocd
    configure_argocd_repo "$GITLAB_TOKEN"

    ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
        -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    GITLAB_PASSWORD=$(kubectl exec -n gitlab deployment/gitlab -- \
        grep Password /etc/gitlab/initial_root_password 2>/dev/null | awk '{print $2}')

    echo "" >&2
    log "=== Bonus setup complete ==="
    echo "" >&2
    echo "  GitLab:" >&2
    echo "    kubectl port-forward svc/gitlab -n gitlab 8929:80" >&2
    echo "    URL:      http://localhost:8929" >&2
    echo "    User:     root" >&2
    echo "    Password: $GITLAB_PASSWORD" >&2
    echo "" >&2
    echo "  ArgoCD:" >&2
    echo "    kubectl port-forward svc/argocd-server -n argocd 8080:80" >&2
    echo "    URL:      http://localhost:8080" >&2
    echo "    User:     admin" >&2
    echo "    Password: $ARGOCD_PASSWORD" >&2
    echo "" >&2
    echo "  App:" >&2
    echo "    kubectl port-forward svc/wil-playground -n dev 8888:8888" >&2
    echo "    curl http://localhost:8888/" >&2
    echo "" >&2
    echo "  GitLab token (for CLI operations):" >&2
    echo "    export GITLAB_TOKEN=\"$GITLAB_TOKEN\"" >&2
    echo "" >&2
}

main "$@"
