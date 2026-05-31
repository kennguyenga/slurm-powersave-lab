# 05 — Production Mapping: Lab to XE9680 Cloud

The lab proved the *mechanism*. Production needs platform integration. Here's
how the work in this repo maps to a real datacenter deployment on Dell
PowerEdge XE9680 GPU nodes for a Service Provider Common Cloud Platform.

## What changes from lab to production

| Layer | Lab (this repo) | Production (XE9680 cloud) |
|---|---|---|
| Hardware | 2× Fedora 44 VMs on ESXi | N× Dell PowerEdge XE9680 (8 GPUs each), RHEL |
| Suspend backend | `ssh host systemctl stop slurmd` | `racadm serveraction powerdown` via iDRAC |
| Resume backend | `ssh host systemctl start slurmd` | `racadm serveraction powerup` via iDRAC |
| Power savings | Cosmetic (VM still running) | Real (~300W per node when off) |
| Reliability | Fragile beyond 1-2 cycles | Robust — clean off/on platform semantics |
| `ResumeTimeout` | 600s sufficient | 600-900s (real boot takes minutes) |
| GPU consideration | N/A | Pre-suspend: scrub GPU memory; post-resume: reset GRES |

## Production `suspend.sh` (XE9680/iDRAC)

> **Security note:** `$IDRAC_PASS` must come from a secrets manager
> (HashiCorp Vault, Kubernetes Secret, environment variable injected at
> runtime, etc.) — NEVER hardcode credentials in the script or in version
> control. In production, the script process inherits the secret at startup
> from the platform's secrets pipeline.

```bash
#!/bin/bash
echo "$(date) SUSPEND $@" >> /var/log/slurm/power.log
for host in $(scontrol show hostnames "$1"); do
    # Look up the node's iDRAC address (typically host-idrac.dc.example)
    IDRAC=$(getent hosts "${host}-idrac" | awk '{print $1}')
    racadm -r "$IDRAC" -u root -p "$IDRAC_PASS" \
        serveraction powerdown >> /var/log/slurm/power.log 2>&1
    echo "  racadm exit: $?" >> /var/log/slurm/power.log
done
```

## Production `resume.sh` (XE9680/iDRAC)

```bash
#!/bin/bash
echo "$(date) RESUME $@" >> /var/log/slurm/power.log
for host in $(scontrol show hostnames "$1"); do
    IDRAC=$(getent hosts "${host}-idrac" | awk '{print $1}')
    racadm -r "$IDRAC" -u root -p "$IDRAC_PASS" \
        serveraction powerup >> /var/log/slurm/power.log 2>&1
    echo "  racadm exit: $?" >> /var/log/slurm/power.log
done
```

For a vSphere-virtualized cluster, the equivalent uses `govc vm.power` or the
vSphere REST API.

## Why production won't hit the lab's failure modes

The lab's failures all trace to "Slurm's state and the node's actual state
got out of sync." With real power control:

1. **"Off" is unambiguous.** A powered-off chassis can't lie about its state.
   Slurm's `POWERED_DOWN` always matches reality.
2. **Boot takes long enough to be honest.** A real XE9680 takes 3-5 minutes
   to power up and have `slurmd` register — well within `ResumeTimeout=600`
   but long enough that Slurm correctly waits and observes the transition.
3. **No "ghost slurmd" problem.** In the lab, `slurmd` could be stopped on
   vm2 while the VM was still running, creating the desync. With real
   power-off, there's no slurmd anywhere on the box to confuse anyone.

## GPU-specific additions (XE9680)

XE9680 has 8 GPUs per node. Power-save in a GPU cloud needs extra steps:

**Pre-suspend (in suspend.sh or as Epilog):**
- Scrub GPU memory between tenants (security; tenant A's CUDA buffers
  shouldn't survive into tenant B's allocation)
- `nvidia-smi --gpu-reset` if needed
- Drain workload cleanly before stopping `slurmd`

**Post-resume (in resume.sh or as Prolog):**
- Re-register GRES: `scontrol update nodename=$host gres=gpu:8`
- DCGM health check (`dcgmi diag -r 1`) before accepting jobs
- Confirm NVLink topology is intact

## Multi-tenancy interactions

Power-save in a multi-tenant cloud (the goal of the XE9680 platform) also
needs:

- **Per-tenant `SuspendTime`** — premium tenants might keep nodes warm longer
- **Priority preemption interaction** — high-priority jobs shouldn't wait
  full `ResumeTimeout` if the cluster has warm capacity
- **Accounting** — `slurmdbd` already records this; power-state transitions
  add another dimension to per-tenant billing
- **SLA tiers** — tenants paying for "always warm" capacity vs "spin-up on
  demand"

## What the lab work was actually building toward

The 2-VM lab cluster isn't the goal — it's the rehearsal. By the time the
XE9680 deployment happens, the team has:

1. The Slurm power-save mental model (when does Slurm call resume? why does
   it sometimes not? what does `down~` mean?) — answered in this repo.
2. A repeatable verification suite that catches state-machine sync issues
   independent of the platform backend.
3. Concrete production scripts that just need the racadm/iDRAC calls swapped
   in — the structure (logging, hostlist expansion, error capture) carries
   over directly.
4. Honest documentation of the failure modes, so a future engineer who hits
   `down~` on day 2 of XE9680 deployment can find this repo and know it's a
   state-machine sync issue, not a hardware problem.

The lab was inexpensive education for a six- or seven-figure platform
investment. The transfer is clean.
