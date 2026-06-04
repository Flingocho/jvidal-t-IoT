# Part 1 — K3s and Vagrant

Two virtual machines provisioned with Vagrant and libvirt, running a K3s cluster in server/agent mode.

## Machines

| Hostname     | IP              | Role           |
|--------------|-----------------|----------------|
| jvidal-tS    | 192.168.56.110  | control-plane  |
| jvidal-tSW   | 192.168.56.111  | agent (worker) |

## Start

```bash
vagrant up
```

## Verify

```bash
vagrant ssh jvidal-tS
kubectl get nodes -o wide
```

Expected output: both nodes in `Ready` status.

## Stop

```bash
vagrant halt
```

## Destroy

```bash
vagrant destroy -f
```
