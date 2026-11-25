#!/usr/bin/env python3
"""The variables the two Kubernetes stacks declare identically stay identical.

    tests/ci/common_variables.py

The two stacks are separate on purpose (ADR-0010, D1), and Terraform cannot share variable
declarations between two root configurations: the variables they have in common are written
twice. Those of IDENTICAL must stay word for word the same; a variable that has to differ is
removed from the list, deliberately. Python 3.11 or later, standard library only.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
STACKS = ("stacks/shared/kubernetes", "stacks/tenants/kubernetes")

# Common to both stacks, declared word for word the same. The others differ on purpose: cloud,
# cluster, cluster_cidr, egress_network, plane_attachment, service_addresses, site (defaults or
# descriptions of the role of the stack).
IDENTICAL = [
    "admin", "admin_network", "boot_volume_size", "bootstrap", "certificates", "dns_nameservers",
    "flavor", "image", "monitoring", "network_mtu", "volume_zones", "zones",
]


def declarations(stack):
    text = (ROOT / stack / "variables.tf").read_text()
    return {m.group(1): m.group(0) for m in re.finditer(r'^variable "([^"]+)" \{.*?^\}', text, re.S | re.M)}


def main():
    first, second = (declarations(s) for s in STACKS)
    problems = []
    for name in IDENTICAL:
        if name not in first or name not in second:
            problems.append(f"{name}: not declared by both stacks")
        elif first[name] != second[name]:
            problems.append(f"{name}: declared differently in {STACKS[0]} and {STACKS[1]}")
    if problems:
        sys.exit("common variables of the Kubernetes stacks:\n  " + "\n  ".join(problems))
    print(f"{len(IDENTICAL)} common variables declared identically in both Kubernetes stacks")


if __name__ == "__main__":
    main()
