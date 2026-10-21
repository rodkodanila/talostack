#!/usr/bin/env bash
# Brings up the Talos cluster in one go: configs -> apply -> etcd bootstrap -> kubeconfig -> Flux.
# Safe to re-run: configured nodes get the new config, etcd bootstrap is skipped if already done.
#
#   CONTROL_PLANE_IP="10.110.1.43 10.110.1.48 10.110.1.62" ./bootstrap.sh
#
# Env:
#   CONTROL_PLANE_IP  required, node IPs separated by spaces or commas
#   BOOTSTRAP_IP      node to bootstrap etcd on (default: first of CONTROL_PLANE_IP)
#   CLUSTER_NAME      default: talostack
#   CLUSTER_ENDPOINT  default: https://10.110.1.101:6443 (the VIP from patch.yaml)
#   INSTALL_DISK      default: /dev/sda
set -euo pipefail

cd "$(dirname "$0")"

: "${CONTROL_PLANE_IP:?set CONTROL_PLANE_IP, e.g. CONTROL_PLANE_IP=\"10.110.1.43 10.110.1.48 10.110.1.62\"}"
read -ra NODES <<< "${CONTROL_PLANE_IP//,/ }"
BOOTSTRAP_IP="${BOOTSTRAP_IP:-${NODES[0]}}"
CLUSTER_NAME="${CLUSTER_NAME:-talostack}"
CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT:-https://10.110.1.101:6443}"
INSTALL_DISK="${INSTALL_DISK:-/dev/sda}"

export TALOSCONFIG="$PWD/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"

log() { printf '\n==> %s\n' "$*"; }

# retry <timeout-seconds> <command...>: rerun the command every 5s until it succeeds.
retry() {
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "timed out: $*" >&2
      return 1
    fi
    sleep 5
  done
}

# A node that answers the authenticated API is installed; one in maintenance mode does not.
configured() { talosctl --nodes "$1" --endpoints "$1" version >/dev/null 2>&1; }

log "Generating configs for ${CLUSTER_NAME} (${CLUSTER_ENDPOINT}), nodes: ${NODES[*]}"
[[ -f secrets.yaml ]] || talosctl gen secrets -o secrets.yaml
talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
  --with-secrets secrets.yaml \
  --install-disk "$INSTALL_DISK" \
  --config-patch-control-plane @patch.yaml \
  --config-patch-control-plane @init-bootstrap.yaml \
  --force
talosctl validate --config controlplane.yaml --mode metal

talosctl config endpoint "${NODES[@]}"
talosctl config node "$BOOTSTRAP_IP"

for ip in "${NODES[@]}"; do
  if configured "$ip"; then
    log "Updating config on $ip"
    talosctl apply-config --nodes "$ip" --endpoints "$ip" --file controlplane.yaml
  else
    log "Installing Talos on $ip (maintenance mode)"
    talosctl apply-config --insecure --nodes "$ip" --file controlplane.yaml
  fi
done

log "Waiting for the nodes to come up after install/reboot"
for ip in "${NODES[@]}"; do
  retry 900 configured "$ip"
  echo "$ip is up"
done

log "Bootstrapping etcd on $BOOTSTRAP_IP"
deadline=$((SECONDS + 600))
until out=$(talosctl bootstrap --nodes "$BOOTSTRAP_IP" --endpoints "$BOOTSTRAP_IP" 2>&1); do
  if grep -qi 'AlreadyExists' <<< "$out"; then
    echo "already bootstrapped, skipping"
    break
  fi
  if ((SECONDS >= deadline)); then
    echo "$out" >&2
    exit 1
  fi
  sleep 5
done

log "Fetching kubeconfig to $KUBECONFIG"
retry 600 talosctl kubeconfig --nodes "$BOOTSTRAP_IP" --merge=false --force "$KUBECONFIG"

# Prints Complete or Failed once the Job has finished, nothing while it runs.
job_state() {
  kubectl -n kube-system get job cluster-bootstrap \
    -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{"\n"}{end}' 2>/dev/null \
    | grep -xE 'Complete|Failed' | head -1 || true
}

log "Bootstrap Job logs (Cilium, Flux Operator, FluxInstance)"
retry 900 kubectl -n kube-system get job cluster-bootstrap
deadline=$((SECONDS + 1800))
state=""
while [[ -z "$state" ]]; do
  # Follows the current container; returns when it exits or restarts after a failure.
  kubectl -n kube-system logs -f job/cluster-bootstrap --pod-running-timeout=10m || true
  # Give the Job controller a moment to record the result before following again.
  for _ in {1..6}; do
    state=$(job_state)
    [[ -n "$state" ]] && break
    sleep 5
  done
  if [[ -z "$state" ]] && ((SECONDS >= deadline)); then
    echo "timed out waiting for job/cluster-bootstrap" >&2
    exit 1
  fi
done
if [[ "$state" == Failed ]]; then
  echo "job/cluster-bootstrap failed, see the logs above" >&2
  exit 1
fi

log "Checking cluster health"
talosctl health --nodes "$BOOTSTRAP_IP" --control-plane-nodes "$(IFS=,; echo "${NODES[*]}")" --wait-timeout 15m

kubectl get nodes -o wide
kubectl -n flux-system get fluxinstance flux
kubectl get helmreleases -A

log "Done. Use: export TALOSCONFIG=$TALOSCONFIG KUBECONFIG=$KUBECONFIG"
