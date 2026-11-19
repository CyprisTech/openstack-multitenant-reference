"""The steps of the campaigns. A step is a function of the context, registered by name."""

import importlib

STEPS = {}

# The modules of steps, one per family; importing them registers their steps.
FAMILIES = ["foundation", "shared", "published", "end"]


def step(name):
    """Registers a function as the step `name`."""

    def register(function):
        if name in STEPS:
            raise ValueError(f"step {name} registered twice")
        STEPS[name] = function
        return function

    return register


def load():
    for family in FAMILIES:
        importlib.import_module(f"{__name__}.{family}")
    return STEPS
