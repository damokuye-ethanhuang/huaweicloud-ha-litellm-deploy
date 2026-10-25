#!/bin/bash
# Bootstrap the operator bastion: SSH access + kubectl + helm only.
# The bastion never runs the gateway; it exists because CCE has no public
# endpoint in this design.
set -euo pipefail

%{ if ssh_public_key != "" ~}
# Key delivery happens here, not through the platform keypair, because the
# keypair is visible on the instance record yet never reaches the guest's
# authorized_keys on this image. This block sits before everything else so a
# later failure still leaves a usable login.
install -d -m 0700 -o root -g root /root/.ssh
cat >/root/.ssh/authorized_keys <<'SSHKEY'
${ssh_public_key}
SSHKEY
chmod 0600 /root/.ssh/authorized_keys

# Named operator account with passwordless sudo. Root SSH is left enabled for
# break-glass use, but day-to-day work happens as this user so the audit trail
# says who did what.
if ! id opt >/dev/null 2>&1; then
  useradd -m -s /bin/bash opt
fi
install -d -m 0700 -o opt -g opt /home/opt/.ssh
cat >/home/opt/.ssh/authorized_keys <<'SSHKEY'
${ssh_public_key}
SSHKEY
chmod 0600 /home/opt/.ssh/authorized_keys
chown -R opt:opt /home/opt/.ssh
printf 'opt ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-opt
chmod 0440 /etc/sudoers.d/90-opt

# Make the sshd side explicit instead of trusting image defaults: key auth on,
# no password auth anywhere.
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-bastion-key.conf <<'SSHDCFG'
PubkeyAuthentication yes
PermitRootLogin prohibit-password
PasswordAuthentication no
SSHDCFG
chmod 0644 /etc/ssh/sshd_config.d/99-bastion-key.conf
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
%{ endif ~}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) KARCH=amd64 ;;
  aarch64) KARCH=arm64 ;;
  *) echo "unsupported arch $ARCH" >&2; exit 1 ;;
esac

# Package names differ per base image (Ubuntu on Huawei Cloud today, EulerOS or
# openEuler on others); pick whichever package manager exists.
if command -v apt-get >/dev/null 2>&1; then
  mkdir -p /etc/apt/keyrings
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg jq docker.io >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl ca-certificates jq docker >/dev/null
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q curl ca-certificates jq docker >/dev/null
fi

# docker is how the image gets from the upstream mirror into SWR: the nodes have
# no public egress, so the bastion is the only place that can pull it.
systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true

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
install -d -m 0700 -o root -g root /root/.kube

cat >/root/README-bastion.txt <<'EOF'
Operator bastion

1. From your laptop, get the cluster kubeconfig from the deploy tooling:
     terraform -chdir=terraform/examples/cce-ha output -raw kube_config_raw > kubeconfig
2. Copy it here:
     scp kubeconfig opt@<bastion-eip>:~/kubeconfig
3. Run helm/kubectl on this host as `opt` (passwordless sudo):
     helm -n litellm list

This host has the only public IP in the stack. It holds no credentials for
LiteLLM itself.
EOF
chown opt:opt /root/README-bastion.txt 2>/dev/null || true
