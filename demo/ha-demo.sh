#!/bin/bash
# ha-demo.sh — Semi-automated HA demonstration driver for config-man
#
# This is the "driver" terminal. Run it ALONGSIDE two other terminals:
#   - Terminal A: bash watch-health.sh        (continuous health probe)
#   - Terminal B: kubectl get pods -n config-man -w   (live pod status)
# And a browser open at http://localhost:30080 (or https://localhost).
#
# The script pauses before every action so YOU control the pace.
# Press Enter to advance each step.

set -u
NS=config-man

# ── colors ───────────────────────────────────────────────────────────────────
BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"
CYAN="\033[36m"; RED="\033[31m"; RESET="\033[0m"

pause() {
  echo ""
  echo -e "${DIM}  ── press Enter to continue ──${RESET}"
  read -r _
}

say() { echo -e "${CYAN}🗣  $1${RESET}"; }
act() { echo -e "${YELLOW}▶  $1${RESET}"; }
hdr() { echo ""; echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
        echo -e "${BOLD}  $1${RESET}"
        echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"; }

# ── intro ──────────────────────────────────────────────────────────────────--
clear
hdr "config-man — High Availability Demo"
echo ""
echo "  Before starting, make sure you have running:"
echo -e "   ${DIM}• Terminal A:${RESET} bash watch-health.sh"
echo -e "   ${DIM}• Terminal B:${RESET} kubectl get pods -n $NS -w"
echo -e "   ${DIM}• Browser   :${RESET} http://localhost:30080  (logged in)"
echo ""
say "\"Three views: the user's browser, a health probe every second, and live pod status.\""
pause

# ── show baseline ──────────────────────────────────────────────────────────--
hdr "Step 0 — Baseline: everything healthy"
act "kubectl get pods -n $NS"
kubectl get pods -n $NS
echo ""
say "\"3 backend, 2 frontend, and a PostgreSQL primary + standby. All green.\""
pause

# ── PART 1: stateless HA (backend) ─────────────────────────────────────────--
hdr "Part 1 — Stateless HA: kill a backend pod"
say "\"First the easy case. Backends are stateless — 3 replicas, PDB keeps min 2 alive.\""
say "\"I'll kill one. Watch Terminal B rebuild it, and Terminal A stay UP.\""
pause

VICTIM=$(kubectl get pods -n $NS -l app.kubernetes.io/component=backend \
         --field-selector=status.phase=Running \
         -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$VICTIM" ]; then
  echo -e "${RED}No running backend pod found — is the release installed?${RESET}"
  exit 1
fi
act "kubectl delete pod $VICTIM -n $NS"
kubectl delete pod "$VICTIM" -n $NS
echo ""
say "\"The health probe never dropped. Kubernetes is already creating a replacement.\""
echo -e "${DIM}  (give it ~10s, glance at Terminal B)${RESET}"
pause

act "kubectl get pods -n $NS -l app.kubernetes.io/component=backend"
kubectl get pods -n $NS -l app.kubernetes.io/component=backend
say "\"Back to 3. The user never noticed.\""
pause

# ── PART 2: stateful HA (postgres failover) ────────────────────────────────--
hdr "Part 2 — Stateful HA: kill the PostgreSQL primary"
say "\"Now the hard part. Databases have state — you can't just spin up copies.\""
say "\"We run a primary + standby via the Zalando operator. I'll kill the PRIMARY.\""
echo ""
act "current postgres roles:"
kubectl get pods -n $NS -l application=spilo -L spilo-role 2>/dev/null \
  || kubectl get pods -n $NS | grep postgres
pause

act "kubectl delete pod config-man-postgres-0 -n $NS"
kubectl delete pod config-man-postgres-0 -n $NS
echo ""
say "\"The operator now promotes the standby to primary. This takes ~30 seconds.\""
say "\"Note: there's a brief switch-over window — writes may fail for a few seconds.\""
say "\"That's the HA trade-off: no data loss + auto-recovery, not zero-second cutover.\""
echo ""
echo -e "${DIM}  waiting 35s for failover...${RESET}"
for i in $(seq 35 -1 1); do printf "\r${DIM}  %2ds remaining${RESET} " "$i"; sleep 1; done
echo ""
pause

act "kubectl get pods -n $NS -l application=spilo -L spilo-role 2>/dev/null || kubectl get pods -n $NS | grep postgres"
kubectl get pods -n $NS -l application=spilo -L spilo-role 2>/dev/null \
  || kubectl get pods -n $NS | grep postgres
echo ""
say "\"The standby is now primary. The old primary rejoined as the new standby.\""
say "\"In the browser, reload a data page — your records are all still there.\""
pause

# ── outro ──────────────────────────────────────────────────────────────────--
hdr "Demo complete"
act "kubectl get pods -n $NS"
kubectl get pods -n $NS
echo ""
say "\"We killed a stateless pod and the database primary.\""
say "\"Look at Terminal A — the down counter. That's our uptime story.\""
echo ""
echo -e "${GREEN}${BOLD}  pods failed. the service survived.${RESET}"
echo ""
