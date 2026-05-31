#!/bin/bash
# verify_powersave.sh — 8-scenario power-save verification
#   0: Configured?   1: Clean start    2: Auto-suspend
#   3: SuspendProgram fired+effect   4: Controller safe
#   5: Resume on demand   6: ResumeProgram fired+effect   7: Back in service
#
# Run on the controller (vm1) as a user who can sudo.

set -u

CTRL_NODE=cloud-native-stack-vm1
TEST_NODE=cloud-native-stack-vm2
TEST_NODE_HOST=cloud-native-stack-vm2
POWERLOG=/var/log/slurm/power.log

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
declare -a RESULTS
pass(){ echo "${GREEN}  PASS${RESET}: $2"; RESULTS+=("$1|PASS|$2"); }
fail(){ echo "${RED}  FAIL${RESET}: $2"; RESULTS+=("$1|FAIL|$2"); }
skip(){ echo "${YELLOW}  SKIP${RESET}: $2"; RESULTS+=("$1|SKIP|$2"); }
info(){ echo "${YELLOW}  ..${RESET} $1"; }
hdr(){ echo; echo "${BOLD}=== $1 ===${RESET}"; }

NODE=$(sinfo -h -N -o "%N" 2>/dev/null | grep -E "^${TEST_NODE}(\.|$)" | head -1)
[ -z "$NODE" ] && NODE=$TEST_NODE
CTRL=$(sinfo -h -N -o "%N" 2>/dev/null | grep -E "^${CTRL_NODE}(\.|$)" | head -1)
[ -z "$CTRL" ] && CTRL=$CTRL_NODE

nodestate(){ sinfo -h -n "$1" -o "%t" 2>/dev/null | head -1; }
ground_truth_slurmd(){ ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o BatchMode=yes root@$TEST_NODE_HOST 'systemctl is-active slurmd' 2>/dev/null; }

# strip non-digits — handles "60 sec" / "INFINITE" gracefully
SUSPEND_TIME=$(scontrol show config 2>/dev/null | awk -F= '/^SuspendTime /{gsub(/[^0-9]/,"",$2);print $2}')
[ -z "$SUSPEND_TIME" ] && SUSPEND_TIME=60
WAIT_BUDGET=$((SUSPEND_TIME + 60))

echo "${BOLD}Slurm power-save verification — 8 scenarios${RESET}"
echo "Test node:   $NODE     Controller: $CTRL"
echo "SuspendTime: ${SUSPEND_TIME}s   wait budget: ${WAIT_BUDGET}s"

hdr "Scenario 0 — Power-save configured"
CFG=$(scontrol show config 2>/dev/null)
SUSP_PROG=$(echo "$CFG" | awk -F= '/^SuspendProgram /{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2}')
RES_PROG=$(echo "$CFG" | awk -F= '/^ResumeProgram /{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2}')
EXC=$(echo "$CFG" | awk -F= '/^SuspendExcNodes /{print $2}')
[ -n "$SUSP_PROG" ] && pass 0 "SuspendProgram=$SUSP_PROG" || fail 0 "SuspendProgram not set"
[ -n "$RES_PROG"  ] && pass 0 "ResumeProgram=$RES_PROG"  || fail 0 "ResumeProgram not set"
if [ "$SUSPEND_TIME" -gt 0 ] 2>/dev/null; then
    pass 0 "SuspendTime=${SUSPEND_TIME}s"
else
    fail 0 "SuspendTime not numeric/enabled — aborting"; exit 1
fi
[ -x "$SUSP_PROG" ] && pass 0 "$SUSP_PROG executable" || fail 0 "$SUSP_PROG not executable"
[ -x "$RES_PROG" ]  && pass 0 "$RES_PROG executable"  || fail 0 "$RES_PROG not executable"
if echo "$EXC" | grep -q "$CTRL_NODE"; then
    pass 0 "Controller in SuspendExcNodes"
else
    fail 0 "Controller NOT in SuspendExcNodes"
fi
SCRIPT_MODE="log-only"
if grep -qE "systemctl[[:space:]]+stop[[:space:]]+slurmd" "$SUSP_PROG" 2>/dev/null; then
    SCRIPT_MODE="Level 1 (real stop)"
fi
info "Script mode: $SCRIPT_MODE"

hdr "Scenario 1 — Clean start"
ST=$(nodestate "$NODE")
info "$NODE state: '$ST'"
if echo "$ST" | grep -qE "down"; then
    info "Recovering from down..."
    ssh -o ConnectTimeout=5 -o BatchMode=yes root@$TEST_NODE_HOST sudo systemctl restart slurmd 2>/dev/null
    sleep 3
    sudo scontrol update nodename="$NODE" state=idle reason="test reset" 2>/dev/null
elif echo "$ST" | grep -qE "~|%|#"; then
    info "Recovering from power-saved state..."
    sudo scontrol update nodename="$NODE" state=power_up 2>/dev/null
    sleep 5
    ssh -o ConnectTimeout=5 -o BatchMode=yes root@$TEST_NODE_HOST sudo systemctl start slurmd 2>/dev/null
    sleep 3
fi
ST=$(nodestate "$NODE")
SL=$(ground_truth_slurmd)
info "After cleanup: state='$ST' slurmd=$SL"
if [ "$ST" = "idle" ] && [ "$SL" = "active" ]; then
    pass 1 "Clean baseline: idle + slurmd active"
else
    fail 1 "Couldn't reach clean idle (state=$ST slurmd=$SL) — aborting"
    exit 1
fi
LOGMARK=0
[ -f "$POWERLOG" ] && LOGMARK=$(wc -l < "$POWERLOG")

hdr "Scenario 2 — Auto-suspend"
info "Leaving $NODE idle for up to ${WAIT_BUDGET}s..."
SUSPENDED=0
for ((t=0; t<WAIT_BUDGET; t+=15)); do
    sleep 15
    ST=$(nodestate "$NODE")
    if echo "$ST" | grep -qE "~|%|#"; then
        SUSPENDED=1
        info "after ${t}s: '$ST' ✓"
        break
    fi
    info "after ${t}s: '$ST'"
done
if [ $SUSPENDED -eq 1 ]; then
    pass 2 "$NODE transitioned to '$ST'"
else
    fail 2 "$NODE did not suspend within ${WAIT_BUDGET}s"
fi

hdr "Scenario 3 — SuspendProgram fired"
NEW=$(tail -n +$((LOGMARK+1)) "$POWERLOG" 2>/dev/null)
if echo "$NEW" | grep -qi "SUSPEND"; then
    pass 3 "power.log shows SUSPEND"
    echo "$NEW" | grep -i suspend | head -3 | sed 's/^/      /'
else
    fail 3 "No SUSPEND entry"
fi
if [ "$SCRIPT_MODE" = "Level 1 (real stop)" ] && [ $SUSPENDED -eq 1 ]; then
    SL=$(ground_truth_slurmd)
    [ "$SL" != "active" ] && pass 3 "Level 1 effect: slurmd genuinely stopped" \
                          || fail 3 "Level 1 didn't take effect: slurmd still active"
fi

hdr "Scenario 4 — Controller safe"
CST=$(nodestate "$CTRL")
info "$CTRL state: '$CST'"
echo "$CST" | grep -qE "~|%|#|down" && fail 4 "Controller compromised ($CST)" \
                                    || pass 4 "Controller stayed safe ($CST)"

hdr "Scenario 5 — Resume on demand"
LOGMARK2=$(wc -l < "$POWERLOG" 2>/dev/null || echo 0)
info "srun -N1 -w $NODE hostname..."
START=$(date +%s)
OUT=$(timeout 120 srun -N1 -w "$NODE" --time=00:02:00 hostname 2>&1)
RC=$?
ELAPSED=$(( $(date +%s) - START ))
info "returned in ${ELAPSED}s (rc=$RC): $OUT"
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "$TEST_NODE"; then
    pass 5 "Job ran on $NODE (took ${ELAPSED}s)"
else
    fail 5 "Job did not run"
fi

hdr "Scenario 6 — ResumeProgram fired"
NEW2=$(tail -n +$((LOGMARK2+1)) "$POWERLOG" 2>/dev/null)
if echo "$NEW2" | grep -qi "RESUME"; then
    pass 6 "power.log shows RESUME"
    echo "$NEW2" | grep -i resume | head -3 | sed 's/^/      /'
else
    fail 6 "No RESUME entry"
fi

hdr "Scenario 7 — Back in service"
sleep 5
ST=$(nodestate "$NODE")
SL=$(ground_truth_slurmd)
info "Final: '$ST' slurmd=$SL"
if echo "$ST" | grep -qE "^(idle|mix|alloc)$" && [ "$SL" = "active" ]; then
    pass 7 "$NODE usable (state=$ST slurmd=active)"
elif echo "$ST" | grep -qE "down"; then
    fail 7 "DOWN — known ssh-stop fragility (see docs/04-findings.md)"
else
    fail 7 "Not cleanly in service (state=$ST slurmd=$SL)"
fi

echo
echo "${BOLD}===================== SUMMARY =====================${RESET}"
printf "%-4s %-7s %s\n" "SCEN" "RESULT" "DETAIL"
printf "%-4s %-7s %s\n" "----" "------" "------"
P=0; F=0; S=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r scen status detail <<< "$r"
    case "$status" in
        PASS) color=$GREEN; P=$((P+1));;
        FAIL) color=$RED;   F=$((F+1));;
        SKIP) color=$YELLOW;S=$((S+1));;
    esac
    printf "%-4s ${color}%-7s${RESET} %s\n" "$scen" "$status" "$detail"
done
echo "${BOLD}---------------------------------------------------${RESET}"
echo "${GREEN}PASS: $P${RESET}  ${RED}FAIL: $F${RESET}  ${YELLOW}SKIP: $S${RESET}"
exit $F
