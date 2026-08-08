"""Choose the interpreter before pytest collects anything.

The failure this file exists to stop: system python has no sqlite_vec, so
importing lib/memory.py makes it os.execv the store's venv interpreter with the
SAME argv — which re-runs pytest's __main__ under an interpreter that has no
pytest. The ModuleNotFoundError lands in a capture buffer pytest installed
before the exec, so nobody ever sees it, and `pytest` in this repo exits 1 with
no output on stdout or stderr. specs/test-harness.md: a test framework
invocation MUST NOT fail silently.

So: pin MEMORY_PYTHON to the interpreter already running, which makes the
re-exec in lib/memory.py a no-op it cannot take, and then say plainly whether
this interpreter can do the job.
"""

import importlib.util
import os
import sys

# Whatever happens below, lib/memory.py must not replace this process.
os.environ["MEMORY_PYTHON"] = sys.executable

_HAVE_VEC = importlib.util.find_spec("sqlite_vec") is not None
_VENV = os.path.expanduser("~/.local/share/deskcrab/venv/bin/python")

_MESSAGE = (
    "tests/test_memory.py loads lib/memory.py, which needs sqlite_vec, and "
    "%s cannot import it.\n"
    "Run the suite instead — it picks the interpreter for you:\n"
    "    bash tests/run.sh\n"
    "or name the store's own interpreter:\n"
    "    %s -m unittest tests.test_memory\n" % (sys.executable, _VENV)
)


def pytest_configure(config):
    """Refuse loudly rather than exit 1 with an empty terminal."""
    if _HAVE_VEC:
        return
    import pytest
    raise pytest.UsageError(_MESSAGE)


def pytest_report_header(config):
    return "memory store interpreter: %s (sqlite_vec %s)" % (
        sys.executable, "present" if _HAVE_VEC else "MISSING")
