# 02 — Build & Test Workflow

The work was structured in phases, each with an explicit gate before
proceeding. This is what the cluster build looked like end-to-end.

```
   Phase 0 — Pre-flight (both VMs)
        |   hostnames, /etc/hosts, chrony, SELinux permissive
        v
   Phase 1 — Slurm base
        |   munge, slurm user (matched UIDs), slurm.conf, daemons up
        |   Gate: sinfo shows both nodes idle, srun -N2 hostname works
        v
   Phase 1.5 — Accounting (slurmdbd)
        |   MariaDB, slurmdbd.conf, sacctmgr register cluster
        |   Gate: sacctmgr show cluster lists 'cloudnative'
        v
   Phase 2 — Power-save (this work)
        |   suspend.sh, resume.sh, slurm.conf power-save block
        |   Gate: the 8 verification scenarios (see 03-scenarios.md)
        v
   Phase 3 — (next) Lua job-submit plugin
   Phase 4 — (next) K8s gang-scheduling on vm3/vm4
```

## Phase 2 build steps (this repo)

1. **Add power-save config to `slurm.conf`** — see `configs/slurm.conf.powersave-excerpt`.
2. **Create `suspend.sh` and `resume.sh`** — see `scripts/`.
3. **Make scripts executable, owned by `slurm`** — Slurm runs them as `SlurmUser`.
4. **Push config to vm2** — must be identical on both nodes.
5. **Set up passwordless SSH from `slurm@vm1` to `root@vm2`** — required for
   Level 1 scripts that actually stop/start `slurmd`.
6. **Reload Slurm config** — `scontrol reconfigure`.
7. **Walk through manual verification** — see `03-scenarios.md`.
8. **Run automated suite** — `scripts/verify_powersave.sh`.

## Test workflow (each cycle)

```
   1. Baseline check
        sinfo                         (vm1, vm2 both idle)
        scontrol ping                 (controller UP)
        ssh vm2 systemctl is-active slurmd   (active)
        ALL THREE must agree
        v
   2. Mark log
        echo "===== TEST RUN $(date) =====" >> power.log
        v
   3. Start journal tail in Terminal 2
        sudo journalctl -u slurmctld -f
        v
   4. Leave vm2 idle for SuspendTime+
        Watch sinfo: idle -> idle~
        Watch journal: "Powering down node" + "Running SuspendProgram"
        v
   5. Submit a job to trigger resume
        time srun -N1 -w cloud-native-stack-vm2 hostname
        Watch journal: "power_save: waking nodes" + "Running ResumeProgram"
        v
   6. Verify return to idle
        sinfo shows plain idle
        scontrol show node ... state=IDLE no flags
        ssh vm2 systemctl is-active slurmd   active
```

## The "both views agree" rule

Every check compares **Slurm's view** with **ground truth**:

- Slurm's view = `sinfo` / `scontrol show node`
- Ground truth = SSH to the node, check actual `slurmd` status

When the two disagree, that's the diagnostic signal. The biggest lesson from
this lab was understanding *why* they disagree:

> When you tell Slurm `state=idle` while `slurmd` is actually stopped on a node,
> Slurm trusts you, scheduler routes work there, the node can't respond, and
> after `ResumeTimeout` the node goes DOWN. The controller never calls
> `ResumeProgram` because it didn't believe the node needed resuming.

The fix is **always start `slurmd` first, then update Slurm's state to match.**
Never lie to the controller about a node being ready when it isn't.
