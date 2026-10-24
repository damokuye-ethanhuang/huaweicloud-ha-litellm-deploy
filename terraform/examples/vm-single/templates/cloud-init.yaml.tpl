#cloud-config
# Rendered by Terraform. All long payloads are base64 encoded so YAML
# indentation can never corrupt them.

package_update: true
packages:
  - docker.io
  - curl
  - ca-certificates

write_files:
  - path: /opt/litellm/litellm.env
    owner: root:root
    permissions: '0600'
    encoding: b64
    content: ${env_b64}

  - path: /opt/litellm/config.yaml
    owner: root:root
    permissions: '0644'
    encoding: b64
    content: ${config_b64}

  - path: /opt/litellm/start.sh
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: ${start_b64}

  - path: /etc/systemd/system/litellm-stack.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=LiteLLM gateway with local PostgreSQL and Redis
      After=docker.service network-online.target
      Requires=docker.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/opt/litellm/start.sh
      ExecStop=/usr/bin/docker rm -f litellm
      TimeoutStartSec=900

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, litellm-stack.service]
