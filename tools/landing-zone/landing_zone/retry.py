"""Waits and retries, declared once by name instead of a loop in every step."""

import time
from dataclasses import dataclass


@dataclass(frozen=True)
class Policy:
    attempts: int
    delay: float  # seconds between attempts


POLICIES = {
    # A new instance: SSH answers once cloud-init has run.
    "ssh": Policy(attempts=30, delay=10),
    # Octavia: a load balancer reaches ACTIVE in a few minutes.
    "octavia": Policy(attempts=60, delay=10),
    # The entry point: its instances read their routes each on its own schedule.
    "entry-point": Policy(attempts=90, delay=2),
    # An instance behind its bastion: reachable once booted, then cloud-init reports.
    "instance": Policy(attempts=10, delay=20),
}


class GaveUp(RuntimeError):
    """Every attempt failed."""


class Fatal(RuntimeError):
    """A failure that another attempt cannot fix: raised at once, not retried."""


def retry(policy, attempt, sleep=time.sleep):
    """Calls `attempt()` until it returns a true value, at most `policy.attempts` times.

    `policy` is a Policy or the name of one in POLICIES. Returns the last value; raises GaveUp
    with the last exception or value when every attempt fails. Fatal is raised at once.
    """
    if isinstance(policy, str):
        policy = POLICIES[policy]
    last = None
    for number in range(1, policy.attempts + 1):
        try:
            value = attempt()
            if value:
                return value
            last = value
        except Fatal:
            raise
        except Exception as error:  # an attempt may fail in any way; the policy decides
            last = error
        if number < policy.attempts:
            sleep(policy.delay)
    raise GaveUp(f"{policy.attempts} attempts failed, last: {last!r}")
