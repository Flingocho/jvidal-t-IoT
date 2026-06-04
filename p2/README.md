# Part 2 — K3s and Three Simple Applications

One virtual machine running a K3s server with three web applications exposed through an Ingress controller. Traffic is routed based on the `Host` HTTP header.

## Machine

| Hostname  | IP             | Role          |
|-----------|----------------|---------------|
| jvidal-tS | 192.168.56.110 | control-plane |

## Applications

| Host      | App     | Replicas | Default |
|-----------|---------|----------|---------|
| app1.com  | app-one | 1        | no      |
| app2.com  | app-two | 3        | no      |
| *(any)*   | app-three | 1      | yes     |

## Start

```bash
vagrant up
```

## Verify

```bash
curl -H "Host: app1.com" http://192.168.56.110
curl -H "Host: app2.com" http://192.168.56.110
curl http://192.168.56.110
```

Inside the VM:

```bash
vagrant ssh jvidal-tS
kubectl get all
kubectl get ingress
```

## Stop

```bash
vagrant halt
```

## Destroy

```bash
vagrant destroy -f
```
