"""The checks shared by several steps: the isolation test, HTTPS through an address."""

import collections
import os
import re
import time

from .context import StepFailed
from .retry import POLICIES


def kubeconfig(ctx, cluster):
    """The kubeconfig of a cluster of the campaign (shared or published), in the work directory."""
    return ctx.work / f"{cluster}.kubeconfig"


def isolation_test(ctx, report, cluster=None):
    """The executable matrix, with the cluster that is deployed. Its output is kept for the results."""
    cmd = ["python3", "tests/isolation/check.py", "--receiver", ctx.stack("receiver"),
           "--user", ctx.setting("ssh_user"), "--key", os.path.expanduser(ctx.setting("ssh_key")),
           "--tool", ctx.tool]  # fmt: skip
    if ctx.has("acme"):
        cmd += ["--acme", ctx.stack("acme")]
    # Tenants sharing the vm stack's directory: one workspace each.
    if ctx.has("vm") and ctx.stack("vm").workspace:
        cmd += ["--web-workspace", ctx.stack("vm").workspace]
    if ctx.has("private"):
        private = ctx.stack("private")
        cmd += ["--private", private, "--private-workspace", private.workspace or ""]
    # Name resolution (ADR-0016, D3): every instance resolves the test zone; the private tenant
    # through the test resolver.
    if ctx.config.get("test_zone"):
        cmd += ["--zone", ctx.config["test_zone"]]
    if ctx.has("resolver"):
        cmd += ["--resolver", ctx.stack("resolver")]
    if cluster == "shared":
        cmd += ["--shared-kubeconfig", kubeconfig(ctx, "shared")]
    elif cluster == "published":
        cmd += ["--published-kubeconfig", kubeconfig(ctx, "published"), "--internal-service", ctx.stack("internal-service")]
    result = ctx.runner.run(cmd, cwd=ctx.root, check=False)
    output = result.stdout + result.stderr
    if not ctx.runner.dry_run:
        (ctx.work / f"isolation-{cluster or 'tenants'}.txt").write_text(output)
        ctx.runner.echo(output.rstrip())
    # The last line of check.py counts the rows: "N/M as expected".
    counted = re.findall(r"(\d+)/(\d+)", output.strip().splitlines()[-1]) if output.strip() else []
    if counted:
        report.measures[f"isolation {cluster or 'tenants'}"] = "/".join(counted[-1])
    if result.returncode != 0:
        raise StepFailed(f"isolation test failed ({cluster or 'tenants'})")


def root_certificate(ctx):
    """How curl trusts the test certificates: the root of the test ACME authority, if any."""
    return ["--cacert", str(ctx.work / "root.pem")] if ctx.has("acme") else ["--insecure"]


def curl(ctx, domain, address, *args, timeout=5):
    """HTTPS to a domain through an address, the certificate checked against the test root."""
    cmd = ["curl", "-s", *root_certificate(ctx), "--max-time", str(timeout),
           "--resolve", f"{domain}:443:{address}", f"https://{domain}/", *args]  # fmt: skip
    return ctx.runner.run(cmd, check=False, quiet=True)


def wait_https(ctx, domain, address, streak=6, report=None):
    """Up to 3 minutes for `streak` answers in a row: the instances of the entry point read their
    routes each on its own schedule, and the load balancer spreads the requests over them. With a
    report, the time until the answers are steady is measured."""
    policy = POLICIES["entry-point"]
    count = 0
    started = time.monotonic()
    for _ in range(policy.attempts):
        if curl(ctx, domain, address, "-f", "-o", "/dev/null").returncode == 0:
            count += 1
            if count >= streak:
                if report is not None:
                    report.measures[f"steady {domain}"] = f"{round(time.monotonic() - started)} s"
                return
        else:
            count = 0
        ctx.sleep(policy.delay)
    if not ctx.runner.dry_run:
        raise StepFailed(f"{domain} does not answer steadily on {address}")


def answer_lines(text):
    """The lines that tell which instance answered (whoami, nginx of the test tenants)."""
    lines = [re.sub(r"server=\S*", "", line) for line in text.splitlines() if re.match(r"host=|Hostname|X-Real-Ip", line)]
    return lines or ["FAIL"]


def https_probe(ctx, report, domain, address, requests=12):
    """HTTPS `requests` times through an address, results counted. Fails if one request failed."""
    if ctx.runner.dry_run:
        ctx.runner.echo(f"({requests} requests to {domain} through {address})")
        return
    counts = collections.Counter()
    for _ in range(requests):
        result = curl(ctx, domain, address, timeout=10)
        counts.update(answer_lines(result.stdout) if result.returncode == 0 else ["FAIL"])
    record(ctx, [f"{domain} {n:>4} {line}" for line, n in sorted(counts.items())])
    failed = counts.get("FAIL", 0)
    report.measures[f"https {domain}"] = f"{requests - failed}/{requests}"
    if failed and not ctx.runner.dry_run:
        raise StepFailed(f"{failed} of {requests} requests failed on {domain}")


def record(ctx, lines):
    """Lines of results: printed, and kept in https.txt for the test results."""
    for line in lines:
        ctx.runner.echo(line)
    if not ctx.runner.dry_run:
        with (ctx.work / "https.txt").open("a") as f:
            f.write("".join(line + "\n" for line in lines))

