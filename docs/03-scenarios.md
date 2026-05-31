# 03 — Verification Scenarios

Eight scenarios. Each validates one proof. The automated suite
(`scripts/verify_powersave.sh`) runs all eight and prints PASS/FAIL/SKIP.

| # | Scenario | What it proves |
|---|---|---|
| 0 | Configured? | SuspendProgram, ResumeProgram, SuspendTime set; scripts exist and are executable; controller in SuspendExcNodes |
| 1 | Clean start | vm2 at plain idle, slurmd active. Slurm view and ground truth agree before the test |
| 2 | Auto-suspend | Idle vm2 transitions to `idle~` after SuspendTime — the time-based mechanism works |
| 3 | SuspendProgram fired AND took effect | `power.log` shows SUSPEND + `ssh exit: 0`; slurmd genuinely stopped on vm2 |
| 4 | Controller exclusion | vm1 stayed plain `idle` — never self-suspended. Safety check |
| 5 | Resume on demand | `srun -N1 -w vm2` triggers `ResumeProgram`; vm2 wakes, job runs |
| 6 | ResumeProgram fired AND took effect | `power.log` shows RESUME + `ssh exit: 0`; slurmd active again on vm2 |
| 7 | Back in service | vm2 returns to plain `idle`, `State=IDLE` no flags, ready for next cycle |

## Manual walkthrough

Open **two terminals**.

**Terminal 2 — journal tail (live visibility into slurmctld):**
```bash
sudo journalctl -u slurmctld -f
```

**Terminal 1 — work session.** Mark the log:
```bash
echo "===== TEST RUN $(date) =====" | sudo tee -a /var/log/slurm/power.log
```

### Scenario 0 — Configured

```bash
scontrol show config | grep -iE "SuspendTime|SuspendTimeout|ResumeTimeout|SuspendProgram|ResumeProgram|SuspendExcNodes"
ls -l /etc/slurm/suspend.sh /etc/slurm/resume.sh
grep systemctl /etc/slurm/suspend.sh /etc/slurm/resume.sh
```

**Expect:** SuspendTime=60, SuspendTimeout=60, ResumeTimeout=600, both program
paths, exclusion contains vm1, scripts executable and owned by `slurm`,
each containing `systemctl stop slurmd` / `systemctl start slurmd`.

### Scenario 1 — Clean start

```bash
sinfo
ssh cloud-native-stack-vm2 systemctl is-active slurmd
```

**Expect:** both nodes plain `idle`; slurmd `active`. Both views agree.

### Scenario 2 — Auto-suspend

Leave vm2 alone (no commands targeting it) for ~90 seconds.

```bash
sinfo
```

**Expect:** vm2 shows `idle~`. Terminal 2 should show
`Powering down node cloud-native-stack-vm2` and `Running SuspendProgram`.

### Scenario 3 — SuspendProgram fired AND took effect

```bash
tail -10 /var/log/slurm/power.log
```

**Expect:** SUSPEND entry, `stopping slurmd on cloud-native-stack-vm2`,
`ssh exit: 0`.

```bash
sudo -u slurm HOME=/var/lib/slurm ssh -i /var/lib/slurm/.ssh/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/var/lib/slurm/.ssh/known_hosts \
    -o BatchMode=yes root@cloud-native-stack-vm2 'systemctl is-active slurmd'
```

**Expect:** `inactive`. (This is the proof Level 1 actually did something.)

### Scenario 4 — Controller exclusion

```bash
sinfo -n cloud-native-stack-vm1
```

**Expect:** vm1 plain `idle`. Controller stayed safe.

### Scenario 5 — Resume on demand

```bash
time srun -N1 -w cloud-native-stack-vm2 hostname
```

**Expect:** hangs ~20-60s, returns `cloud-native-stack-vm2.local`.
Terminal 2 should show `power_save: waking nodes`, `Running ResumeProgram`,
`Node cloud-native-stack-vm2 now responding`.

### Scenario 6 — ResumeProgram fired AND took effect

```bash
tail -10 /var/log/slurm/power.log
```

**Expect:** RESUME entry, `starting slurmd on cloud-native-stack-vm2`,
`ssh exit: 0`.

```bash
sudo -u slurm HOME=/var/lib/slurm ssh -i /var/lib/slurm/.ssh/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/var/lib/slurm/.ssh/known_hosts \
    -o BatchMode=yes root@cloud-native-stack-vm2 'systemctl is-active slurmd'
```

**Expect:** `active`. Level 1 brought it back.

### Scenario 7 — Back in service

```bash
sinfo
scontrol show node cloud-native-stack-vm2 | grep -i state
```

**Expect:** vm2 plain `idle`, `State=IDLE` no extra flags
(no `POWERED_DOWN`, no `NOT_RESPONDING`, no `DOWN`).

## Automated suite

```bash
chmod +x scripts/verify_powersave.sh
./scripts/verify_powersave.sh
```

Runs all eight scenarios, prints a PASS/FAIL/SKIP summary. Takes 3-5 minutes
(Scenario 2 has to wait out SuspendTime).

A clean run produces 7/8 or 8/8 PASS. The known fragility (Level 1 ssh-stop)
can cause Scenario 7 to end in `down~` on some cycles — that's documented in
`04-findings.md`.
