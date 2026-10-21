# talostack
Deploying Openstack inside Talos Linux



# Deploy vms 
`env file` - 00-terraform/terraform.tfvars
```bash
terraform plan
terraform apply
```

# Deploy talos
All commands run from `01-talos/`. The node IPs are the DHCP addresses the VMs got after booting the ISO.

```bash
cd 01-talos
CONTROL_PLANE_IP=(10.110.1.25 10.110.1.15 10.110.1.58)
BOOTSTRAP_IP=10.110.1.25   # any one of them; etcd is bootstrapped here
```

Set these in the same shell you run the steps below in.

## 1. Generate the configs
Cluster secrets are generated once and kept in `secrets.yaml`, so the configs can be regenerated without breaking the running cluster.
`patch.yaml` disables flannel and kube-proxy and sets the VIP 10.110.1.101; `init-bootstrap.yaml` adds the Job that installs Cilium and the Flux Operator.

```bash
[ -f secrets.yaml ] || talosctl gen secrets -o secrets.yaml

talosctl gen config talostack https://10.110.1.101:6443 \
  --with-secrets secrets.yaml \
  --install-disk /dev/sda \
  --config-patch-control-plane @patch.yaml \
  --config-patch-control-plane @init-bootstrap.yaml \
  --force

talosctl validate --config controlplane.yaml --mode metal
```

## 2. Apply the config to the nodes
The nodes are in maintenance mode, so the first apply goes without TLS (`--insecure`). Talos installs itself to disk and reboots.

```bash
for ip in "${CONTROL_PLANE_IP[@]}"; do
  talosctl apply-config --insecure --nodes "$ip" --file controlplane.yaml
done
```

## 3. Set up talosctl

```bash
export TALOSCONFIG=$PWD/talosconfig
talosctl config endpoint "${CONTROL_PLANE_IP[@]}"
talosctl config node "$BOOTSTRAP_IP"
```

## 4. Bootstrap etcd
Run **once**, on one node only. Wait until the nodes come back after the reboot (`talosctl dmesg` / `talosctl services` respond).

```bash
talosctl bootstrap --nodes "$BOOTSTRAP_IP"
```

## 5. Get the kubeconfig and check the cluster
The nodes stay `NotReady` until the `cluster-bootstrap` Job installs Cilium. The Job then installs the Flux Operator and the FluxInstance,
which syncs `02-flux/clusters/talostack` from this repo (branch `main`) and takes over the cilium and flux-operator releases and the FluxInstance itself.

```bash
talosctl kubeconfig --nodes "$BOOTSTRAP_IP" --merge=false --force ./kubeconfig   # admin credentials, gitignored
export KUBECONFIG=$PWD/kubeconfig

kubectl -n kube-system logs -f job/cluster-bootstrap
kubectl get nodes -o wide
kubectl -n flux-system get fluxinstance flux
kubectl get helmreleases -A

talosctl health --wait-timeout 15m
```
