#!/bin/bash
# Bootstrap the operator bastion: kubectl + helm only.
# The bastion never runs the gateway; it exists because CCE has no public
# endpoint in this design.
set -euo pipefail

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) KARCH=amd64 ;;
  aarch64) KARCH=arm64 ;;
  *) echo "unsupported arch $ARCH" >&2; exit 1 ;;
esac

mkdir -p /etc/apt/keyrings
apt-get update -qq
apt-get install -y -qq curl ca-certificates apt-transport-https gnupg jq >/dev/null

curl -fsSL "https://dl.k8s.io/release/${kubectl_version}/bin/linux/$${KARCH}/kubectl" \
  -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

curl -fsSL "https://get.helm.sh/helm-${helm_version}-linux-$${KARCH}.tar.gz" -o /tmp/helm.tgz
tar -xzf /tmp/helm.tgz -C /tmp
mv "/tmp/linux-$${KARCH}/helm" /usr/local/bin/helm
chmod 0755 /usr/local/bin/helm
rm -rf /tmp/helm.tgz "/tmp/linux-$${KARCH}"

# Convenience only: the real kubeconfig is delivered by the operator
# (scripts/deploy.sh deploy-app writes it locally, then users scp it here).
mkdir -p /root/.kube
chmod 0700 /root/.kube

cat >/root/README-bastion.txt <<'EOF'
Operator bastion

1. From your laptop, get the cluster kubeconfig from the deploy tooling:
     terraform -chdir=terraform/examples/cce-ha output -raw kube_config_raw > kubeconfig
2. Copy it here:
     scp kubeconfig root@<bastion-eip>:~/.kube/config
3. Run helm/kubectl on this host:
     helm -n litellm list

This host has the only public IP in the stack. It holds no credentials for
LiteLLM itself.
EOF
