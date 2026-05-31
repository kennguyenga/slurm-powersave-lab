#!/bin/bash
# Recover cloud-native-stack-vm2 to plain idle after failed Level 1 cycle.
# RULE: Always start slurmd on vm2 FIRST, then update Slurm's state.
set -u
VM2_HOST=cloud-native-stack-vm2
NODE=cloud-native-stack-vm2

echo "==> Start slurmd on $NODE"
ssh -o BatchMode=yes -o ConnectTimeout=10 root@$VM2_HOST sudo systemctl restart slurmd
sleep 5

ACTIVE=$(ssh -o BatchMode=yes root@$VM2_HOST systemctl is-active slurmd)
if [ "$ACTIVE" != "active" ]; then
    echo "FAIL: slurmd on $NODE is '$ACTIVE'"
    exit 1
fi

echo "==> Clear power-saved flag"
sudo scontrol update nodename=$NODE state=power_up
sleep 10

STATE=$(sinfo -h -n $NODE -o "%t")
if [[ "$STATE" != "idle" ]]; then
    sudo scontrol update nodename=$NODE state=idle reason="recovered $(date +%s)"
    sleep 3
fi

echo "==> Final state:"
sinfo
