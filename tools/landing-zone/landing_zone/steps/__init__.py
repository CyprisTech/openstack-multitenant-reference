"""The steps of the campaigns. A step is a function of the context, registered by name."""

import importlib

STEPS = {}
# The guide sections a step runs ("path#anchor"): the campaign verifies them, and a unit test
# checks that the scripts their code blocks name are those the step calls.
GUIDES = {}

# The modules of steps, one per family; importing them registers their steps.
FAMILIES = ["foundation", "shared", "published", "end", "upgrade"]


def step(name, guide=()):
    """Registers a function as the step `name`, with the guide sections it runs."""

    def register(function):
        if name in STEPS:
            raise ValueError(f"step {name} registered twice")
        STEPS[name] = function
        if guide:
            GUIDES[name] = [guide] if isinstance(guide, str) else list(guide)
        return function

    return register


def load():
    for family in FAMILIES:
        importlib.import_module(f"{__name__}.{family}")
    return STEPS
