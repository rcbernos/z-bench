"""Regression tests for the z-bench <-> zstore pipe deadlock."""

import threading
from pathlib import Path

from z_bench.core import BenchmarkConfig, BenchmarkRunner

CHILD_OK = (
    "import sys\n"
    'sys.stdout.write("x" * (2 * 1024 * 1024))\n'
    "sys.stdout.flush()\n"
    'sys.stderr.write("e" * (2 * 1024 * 1024))\n'
    "sys.stderr.flush()\n"
)

CHILD_ERR_BOOM = (
    "import sys\n"
    'sys.stdout.write("x" * (1024 * 1024))\n'
    "sys.stdout.flush()\n"
    'sys.stderr.write("error: boom\\n")\n'
    "sys.stderr.flush()\n"
    "sys.exit(1)\n"
)

CHILD_EMPTY_ERR = "import sys\nsys.exit(1)\n"

CHILD_TAIL = (
    "import sys\n"
    'sys.stderr.write("x" * (1024 * 1024))\n'
    'sys.stderr.write("TAIL_MARKER\\n")\n'
    "sys.stderr.flush()\n"
    "sys.exit(1)\n"
)


def _write_child(tmp_path: Path, name: str, content: str) -> str:
    script = tmp_path / name
    script.write_text(content)
    return f"python {script}"


def _run_execute_command(cmd: str, timeout: float = 30.0):
    """Run BenchmarkRunner.execute_command in a thread with a hard timeout."""
    outcome: dict = {}

    def target() -> None:
        runner = BenchmarkRunner(config=BenchmarkConfig())
        outcome["value"] = runner.execute_command(cmd, "test.bin")

    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    thread.join(timeout)
    assert not thread.is_alive(), (
        f"execute_command hung; possible pipe deadlock (timeout={timeout})"
    )
    return outcome["value"]


def test_large_output_completes(tmp_path: Path) -> None:
    cmd = _write_child(tmp_path, "child_ok.py", CHILD_OK)
    success, error, latency_ns, cpu_peak, mem_peak = _run_execute_command(cmd)
    assert success is True
    assert error == ""


def test_error_message_preserved_after_large_output(tmp_path: Path) -> None:
    cmd = _write_child(tmp_path, "child_err.py", CHILD_ERR_BOOM)
    success, error, latency_ns, cpu_peak, mem_peak = _run_execute_command(cmd)
    assert success is False
    assert "boom" in error


def test_error_fallback_exit_code(tmp_path: Path) -> None:
    cmd = _write_child(tmp_path, "child_empty.py", CHILD_EMPTY_ERR)
    success, error, latency_ns, cpu_peak, mem_peak = _run_execute_command(cmd)
    assert success is False
    assert error == "Exit code: 1"


def test_error_tail_truncated_to_last_4096(tmp_path: Path) -> None:
    cmd = _write_child(tmp_path, "child_tail.py", CHILD_TAIL)
    success, error, latency_ns, cpu_peak, mem_peak = _run_execute_command(cmd)
    assert success is False
    assert "TAIL_MARKER" in error
    assert len(error) <= 4200
