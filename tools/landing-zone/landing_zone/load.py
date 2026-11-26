"""Requests sent at a fixed pace while a step changes the deployment."""

import time


class Requests:
    """What a load reports: its duration, its requests and the share that failed. The count of
    requests follows the duration (one request every few seconds): it is not a throughput, and two
    counts compare only through their failure rates."""

    ok = failed = 0
    _started = _stopped = None

    def started(self):
        self._started = time.monotonic()

    def stopped(self):
        self._stopped = time.monotonic()

    def summary(self):
        total = self.ok + self.failed
        if self._started is None:
            return f"{total} requests, {self.failed} failed"
        minutes = ((self._stopped or time.monotonic()) - self._started) / 60
        rate = f" ({100 * self.failed / total:.1f} %)" if total else ""
        return f"{total} requests in {minutes:.0f} min, {self.failed} failed{rate}"
