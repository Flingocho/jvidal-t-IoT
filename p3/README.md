# Part 3 — K3d and Argo CD

A K3d cluster running Argo CD that continuously deploys an application from a public GitHub repository. Any change pushed to the repository is automatically synchronized by Argo CD.

## Architecture

- **Cluster:** K3d (Kubernetes in Docker)
- **Namespace `argocd`:** Argo CD instance
- **Namespace `dev`:** application deployed and managed by Argo CD
- **App:** `wil42/playground` (port 8888), synced from `p3/confs/manifests/` in the GitHub repo

## Start (from scratch)

```bash
sudo bash scripts/install.sh
```

This installs Docker, kubectl, k3d, creates the cluster, installs Argo CD and deploys the application automatically.

## Verify namespaces and pods

```bash
kubectl get nodes
kubectl get ns
kubectl get pods -n argocd
kubectl get pods -n dev
```

## Access Argo CD UI

Run in a terminal (keep it open):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open in Chrome: `http://localhost:8080`

- **User:** `admin`
- **Password:** printed at the end of `install.sh`, or retrieve it with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Access the application

Run in a terminal (keep it open):

```bash
kubectl port-forward svc/wil-playground -n dev 8888:8888
```

Then:

```bash
curl http://localhost:8888/
# {"status":"ok", "message": "v1"}
```

## Change application version (v1 → v2)

Edit `p3/confs/manifests/deployment.yaml` and change the image tag:

```bash
sed -i 's/wil42\/playground:v1/wil42\/playground:v2/' p3/confs/manifests/deployment.yaml
git add p3/confs/manifests/deployment.yaml
git commit -m "Update wil-playground to v2"
git push
```

Argo CD will automatically detect the change and redeploy. The pod will restart — re-run the port-forward once the new pod is `Running`:

```bash
kubectl get pods -n dev   # wait for Running
kubectl port-forward svc/wil-playground -n dev 8888:8888
curl http://localhost:8888/
# {"status":"ok", "message": "v2"}
```

## Destroy

```bash
sudo k3d cluster delete iot-cluster
```
