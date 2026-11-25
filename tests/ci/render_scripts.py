#!/usr/bin/env python3
"""Renders the shell scripts written from templates, without a cloud, for shellcheck.

    tests/ci/render_scripts.py --out <directory> [--tool tofu|terraform]

Each target is a stack and one of its mocked tests (tests/*.tftest.hcl): its variables, with the
overrides of the target, give the module its inputs. A run added for the time of the rendering
asserts that each script is empty; the failed assertion carries the script, base64-encoded, and
the script is written to <directory>/<target>-<name>. The test file added is always removed.
Python 3.11 or later, standard library only.
"""

import argparse
import base64
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
RUN = "zz_render.tftest.hcl"

CERTIFICATES = """certificates = {
      directory_url = "https://acme.example.org/directory"
      email         = "ops@example.org"
      dns = {
        provider  = "rfc2136"
        settings = {
          nameserver = "192.0.2.53:53", tsig_key_name = "acme", tsig_algorithm = "hmac-sha256", tsig_secret = "c2VjcmV0"
        }
        resolvers = ["192.0.2.53:53"]
      }
    }"""

DEMO = 'certificates = null\n    zones        = ["az-1"]'
CLUSTER_SCRIPTS = {name: f'output.scripts["{name}"]' for name in ("create-cluster.sh", "update-cluster.sh", "delete-cluster.sh")}
LEGO = {
    "lego-certificate.sh": 'module.acme.write_files["/usr/local/sbin/lego-certificate"].content',
    "lego-deploy.sh": 'module.acme.write_files["/usr/local/sbin/lego-deploy"].content',
}

# name: (configuration, test file whose variables are used, overrides of the variables, scripts,
# checks expected to warn). The demonstration mode (no certificates) is rendered from the module
# itself, where its warning (check.certificates) can be expected.
TARGETS = {
    "shared-kubernetes": ("stacks/shared/kubernetes", "dns.tftest.hcl", CERTIFICATES, CLUSTER_SCRIPTS),
    "kubernetes-demo": ("modules/kubernetes-cluster", "quorum.tftest.hcl", DEMO, CLUSTER_SCRIPTS, ["check.certificates"]),
    "tenant-kubernetes": ("stacks/tenants/kubernetes", "exposure.tftest.hcl",
                          'exposure = "entry-point"\n    edge_sources = ["198.51.100.5/32"]', CLUSTER_SCRIPTS),
    "vm": ("stacks/tenants/vm", "exposure.tftest.hcl", CERTIFICATES + '\n    zones        = ["az-1"]', LEGO),
}


def header(test_file):
    """The variables and mocks of a test file: everything before its first run."""
    text = test_file.read_text()
    first = re.search(r"^run ", text, re.M)
    return text[: first.start()] if first else text


def render(tool, name, target, out):
    stack, test, overrides, scripts, *expected = target
    expect = f"\n  expect_failures = [{', '.join(expected[0])}]" if expected else ""
    directory = ROOT / stack
    # One run with an assertion per script: tofu test skips the runs that follow a failed one.
    asserts = "".join(f'''
  assert {{
    condition     = {expression} == ""
    error_message = "BEGIN${{base64encode(nonsensitive({expression}))}}END"
  }}
''' for expression in scripts.values())
    run = f'''
run "render" {{
  command = plan{expect}
  variables {{
    {overrides}
  }}
{asserts}}}
'''
    test_file = directory / "tests" / RUN
    test_file.write_text(header(directory / "tests" / test) + run)
    try:
        subprocess.run([tool, f"-chdir={directory}", "init", "-backend=false", "-input=false"],
                       check=True, capture_output=True)  # fmt: skip
        result = subprocess.run([tool, f"-chdir={directory}", "test", "-no-color", f"-filter=tests/{RUN}"],
                                capture_output=True, text=True)  # fmt: skip
    finally:
        test_file.unlink()
    rendered = re.findall(r"BEGIN(.*?)END", re.sub(r"[\s│]", "", result.stdout + result.stderr))
    if len(rendered) != len(scripts):
        sys.exit(f"{name}: {len(rendered)} of {len(scripts)} scripts rendered\n{(result.stdout + result.stderr)[-2000:]}")
    for script, encoded in zip(scripts, rendered, strict=True):
        path = out / f"{name}-{script}"
        path.write_bytes(base64.b64decode(encoded))
        print(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--tool", default="tofu")
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, target in TARGETS.items():
        render(args.tool, name, target, out)


if __name__ == "__main__":
    main()
