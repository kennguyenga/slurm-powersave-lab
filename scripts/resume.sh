#!/bin/bash
# Level 1: actually starts slurmd via SSH. Runs as SlurmUser called by slurmctld.
export HOME=/var/lib/slurm
echo "$(date) RESUME $@" >> /var/log/slurm/power.log
for host in $(scontrol show hostnames "$1"); do
    echo "  starting slurmd on $host" >> /var/log/slurm/power.log
    ssh -i /var/lib/slurm/.ssh/id_ed25519 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/var/lib/slurm/.ssh/known_hosts \
        -o BatchMode=yes -o ConnectTimeout=10 \
        root@"$host" systemctl start slurmd >> /var/log/slurm/power.log 2>&1
    echo "  ssh exit: $?" >> /var/log/slurm/power.log
done
