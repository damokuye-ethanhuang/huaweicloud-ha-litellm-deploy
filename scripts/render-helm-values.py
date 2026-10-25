#!/usr/bin/env python3
"""Render the runtime Helm values used by both deployment paths.

`scripts/deploy.sh deploy-app` (local helm) and `scripts/remote-deploy.sh bundle`
(bundle executed on the bastion) must produce the same values, so the ELB/Ingress
wiring lives here and nowhere else.

Two modes, chosen by the Terraform output `elb_mode`:

  ingress     The CCE ELB Ingress controller creates the internal dedicated ELB
              from `kubernetes.io/elb.autocreate`. The chart Service stays
              ClusterIP and the Ingress owns 443.
  standalone  Terraform owns the ELB; the Service is a LoadBalancer bound to it
              through `kubernetes.io/elb.id`.
"""

from __future__ import annotations

import argparse
import json
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML is a documented requirement
    sys.exit("PyYAML is required: pip install pyyaml")


def ingress_annotations(cert_id: str, spec: dict) -> dict:
    """Annotations for a CCE-created ELB (dedicated, internal, L7)."""
    autocreate = {
        "type": "inner",
        "name": spec["name"],
        "available_zone": spec["available_zone"],
        "elb_virsubnet_ids": spec["elb_virsubnet_ids"],
        "vip_subnet_cidr_id": spec["vip_subnet_cidr_id"],
        "l7_flavor_name": spec["l7_flavor_name"],
        # Dedicated ELB requires both flavors; "" means "no L4 listener".
        "l4_flavor_name": "",
    }
    annotations = {
        "kubernetes.io/elb.class": spec.get("class", "performance"),
        "kubernetes.io/elb.port": "443",
        "kubernetes.io/elb.autocreate": json.dumps(autocreate, separators=(",", ":")),
    }
    if cert_id:
        annotations["kubernetes.io/elb.protocol-port"] = "https:443"
        annotations["kubernetes.io/elb.cert-id"] = cert_id
    else:
        annotations["kubernetes.io/elb.protocol-port"] = "http:443"
    return annotations


def service_annotations(cert_id: str, elb_id: str) -> dict:
    """Annotations for the Terraform-owned ELB (standalone mode)."""
    annotations = {
        "kubernetes.io/elb.id": elb_id,
        "kubernetes.io/elb.class": "performance",
        "kubernetes.io/elb.port": "443",
    }
    if cert_id:
        annotations["kubernetes.io/elb.protocol-port"] = "https:443"
        annotations["kubernetes.io/elb.cert-id"] = cert_id
    else:
        annotations["kubernetes.io/elb.protocol-port"] = "http:443"
    return annotations


def render(src: str, image: str, mode: str, elb_id: str, cert_id: str, ingress_spec: dict | None) -> dict:
    values = yaml.safe_load(open(src, encoding="utf-8")) or {}
    repository, _, tag = image.rpartition(":")
    values.setdefault("image", {}).update({"repository": repository, "tag": tag})

    if mode == "ingress":
        if not ingress_spec:
            sys.exit("elb_mode = ingress but the terraform output ingress_elb is empty")
        values["service"] = dict(values.get("service") or {})
        values["service"].update({"type": "ClusterIP", "port": 4000, "annotations": {}})
        values["ingress"] = {
            "enabled": True,
            "className": ingress_spec.get("className", "cce"),
            "annotations": ingress_annotations(cert_id, ingress_spec),
            "host": "",
            "path": "/",
            "pathType": "Prefix",
        }
    else:
        if not elb_id:
            sys.exit("elb_mode = standalone but loadbalancer_id is empty; did apply-infra finish?")
        values["service"] = dict(values.get("service") or {})
        values["service"].update(
            {"type": "LoadBalancer", "port": 443, "annotations": service_annotations(cert_id, elb_id)}
        )
        values.setdefault("ingress", {})["enabled"] = False
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", required=True, help="values rendered by preflight.py")
    parser.add_argument("--dst", required=True, help="output values file")
    parser.add_argument("--image", required=True, help="repository:tag")
    parser.add_argument("--mode", default="ingress", choices=["ingress", "standalone"])
    parser.add_argument("--elb-id", default="")
    parser.add_argument("--cert-id", default="")
    parser.add_argument("--ingress-json", default="null", help="terraform output -json ingress_elb")
    args = parser.parse_args()

    spec = json.loads(args.ingress_json) if args.ingress_json.strip() not in ("", "null") else None
    values = render(args.src, args.image, args.mode, args.elb_id, args.cert_id, spec)
    with open(args.dst, "w", encoding="utf-8") as handle:
        yaml.safe_dump(values, handle, sort_keys=False)


if __name__ == "__main__":
    main()
