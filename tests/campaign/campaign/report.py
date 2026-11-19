"""The report of a run: its steps, their status and duration, and what they measured (JSON)."""

import json
import time
from dataclasses import asdict, dataclass, field


@dataclass
class StepReport:
    name: str
    status: str = "running"  # running, ok, failed, not-ported
    seconds: float = 0.0
    measures: dict = field(default_factory=dict)
    error: str = ""


@dataclass
class Report:
    scenario: str
    profile: str
    mode: str
    dry_run: bool
    started: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    steps: list = field(default_factory=list)

    def step(self, name):
        entry = StepReport(name)
        self.steps.append(entry)
        return entry

    @property
    def ok(self):
        return all(s.status in ("ok", "not-ported") for s in self.steps)

    def write(self, path):
        path.write_text(json.dumps(asdict(self), indent=2) + "\n")

    def summary(self):
        lines = [f"{self.scenario} ({self.profile}, {self.mode}){' dry run' if self.dry_run else ''}"]
        for s in self.steps:
            measures = ", ".join(f"{k}={v}" for k, v in s.measures.items())
            lines.append(f"  {s.status:<10} {s.name:<16} {s.seconds:7.0f} s  {measures}")
        return "\n".join(lines)
