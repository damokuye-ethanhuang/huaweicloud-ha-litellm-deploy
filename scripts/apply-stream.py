#!/usr/bin/env python3
"""Stream `terraform apply -json` as a live, per-resource progress feed.

Why this exists: `terraform apply` prints a line when a resource *starts* and
when it *ends*. For a CCE cluster or an RDS instance that is 5-15 minutes of
silence, and the only way to know whether it is progressing or wedged used to be
to poll the cloud API from another shell (a "probe"). Terraform already emits a
stable machine-readable stream (`ui` 1.0) with `apply_start`, `apply_progress`
every ~10s, `apply_complete` with `elapsed_seconds`, `provision_*` and
diagnostics; this script renders it.

Design rules:

  * it never replaces Terraform — it execs `terraform apply -json <plan>` and
    passes the exit code through, so the plan-review gate still holds;
  * a saved plan is mandatory: no plan, no apply (AGENTS.md, golden rule 3);
  * every event is archived as JSONL (`$LITELLM_DEPLOY_HOME/out/apply-timeline.jsonl`
    by default, outside the repository) so
    a slow stage can be analysed after the fact instead of by re-running it;
  * output values are counted, never printed — they are frequently sensitive;
  * if the provider goes quiet for `--heartbeat` seconds, the in-flight
    resources are re-printed with their elapsed time, so nobody has to guess
    whether the process died.

Usage:
    ./scripts/apply-stream.py --dir terraform/examples/cce-ha --plan tfplan
    ./scripts/apply-stream.py --dir ... --plan ... --plain       # CI logs
    ./scripts/apply-stream.py --replay ~/.litellm-deploy/out/apply-timeline.jsonl
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

SYMBOL = {
    "create": "+",
    "update": "~",
    "replace": "±",
    "delete": "-",
    "read": "←",
    "noop": "=",
}

RESET = "\033[0m"
DIM = "\033[2m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"


class Style:
    """ANSI only when it helps: a terminal, and the operator did not opt out."""

    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled

    def __call__(self, text: str, code: str) -> str:
        return f"{code}{text}{RESET}" if self.enabled else text


def fmt_duration(seconds: float) -> str:
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    minutes, rest = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m{rest:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"


def resource_addr(payload: dict) -> str:
    """Address from a hook/change payload, tolerating both shapes."""
    for key in ("hook", "change"):
        node = payload.get(key) or {}
        res = node.get("resource") or {}
        if res.get("addr"):
            return res["addr"]
    return payload.get("@message", "?")


class Renderer:
    def __init__(self, style: Style, plan_path: str) -> None:
        self.style = style
        self.plan_path = plan_path
        self.started_at = time.monotonic()
        self.pending: dict[str, str] = {}
        self.running: dict[str, tuple[str, float]] = {}
        self.done: list[tuple[str, str, float]] = []
        self.counts = {"add": 0, "change": 0, "remove": 0}
        self.failed = 0
        self.outputs = 0
        self.last_event = time.monotonic()

    # -- rendering ---------------------------------------------------------

    def _stamp(self) -> str:
        return self.style(time.strftime("%H:%M:%S"), DIM)

    def line(self, text: str) -> None:
        print(text, flush=True)

    def start(self) -> None:
        self.line(f"{self._stamp()} {self.style('apply', CYAN)} {self.style(self.plan_path, DIM)}")
        if self.pending:
            kinds = {}
            for action in self.pending.values():
                kinds[action] = kinds.get(action, 0) + 1
            summary = ", ".join(f"{n} {k}" for k, n in sorted(kinds.items()))
            self.line(f"{self._stamp()} plan: {summary}")

    def handle(self, event: dict) -> None:
        self.last_event = time.monotonic()
        kind = event.get("type", "")

        if kind == "planned_change":
            change = event.get("change") or {}
            action = change.get("action", "noop")
            self.pending[resource_addr(event)] = action
            return

        if kind == "apply_start":
            addr = resource_addr(event)
            action = (event.get("hook") or {}).get("action") or self.pending.pop(addr, "create")
            self.pending.pop(addr, None)
            self.running[addr] = (action, time.monotonic())
            mark = self.style(SYMBOL.get(action, "*"), CYAN)
            self.line(f"{self._stamp()} {mark} {action:<7} {addr}")

        elif kind == "apply_progress":
            addr = resource_addr(event)
            # Terraform's own message already carries the elapsed time
            # ("Still creating... [10s elapsed]"); do not print it twice.
            detail = (event.get("@message") or "").split(": ", 1)[-1]
            self.line(f"{self._stamp()} {self.style('·', DIM)} {addr} {self.style(detail, DIM)}")

        elif kind == "apply_complete":
            hook = event.get("hook") or {}
            addr = resource_addr(event)
            action, started = self.running.pop(addr, (hook.get("action", "create"), time.monotonic()))
            elapsed = float(hook.get("elapsed_seconds", time.monotonic() - started))
            self.done.append((addr, action, elapsed))
            self._count(action)
            ident = ""
            if hook.get("id_value"):
                ident = self.style(f"id={self._shorten(str(hook['id_value']))}", DIM)
            self.line(
                f"{self._stamp()} {self.style('✓', GREEN)} {addr} "
                f"{self.style(fmt_duration(elapsed), DIM)} {ident}".rstrip()
            )

        elif kind == "apply_errored":
            addr = resource_addr(event)
            self.running.pop(addr, None)
            self.failed += 1
            self.line(f"{self._stamp()} {self.style('✗', RED)} {addr} failed")

        elif kind in ("provision_start", "provision_progress", "provision_complete"):
            if kind == "provision_progress":
                addr = resource_addr(event)
                detail = (event.get("@message") or "").split(": ", 1)[-1]
                self.line(f"{self._stamp()}   {self.style('└', DIM)} {detail} {self.style(addr, DIM)}")

        elif kind == "change_summary":
            changes = event.get("changes") or {}
            if changes.get("operation") == "apply":
                add, change, remove = (changes.get(k, 0) for k in ("add", "change", "remove"))
                self.counts = {"add": add, "change": change, "remove": remove}
                self.line(
                    f"{self._stamp()} {self.style('apply complete', GREEN)} "
                    f"{add} added, {change} changed, {remove} destroyed "
                    f"{self.style('in ' + fmt_duration(time.monotonic() - self.started_at), DIM)}"
                )

        elif kind == "outputs":
            self.outputs = len(event.get("outputs") or {})
            self.line(f"{self._stamp()} outputs: {self.outputs} {self.style('(values not printed)', DIM)}")

        elif kind == "diagnostic":
            diag = event.get("diagnostic") or {}
            severity = diag.get("severity", "error")
            colour = RED if severity == "error" else YELLOW
            summary = diag.get("summary", "").strip()
            detail = (diag.get("detail") or "").strip()
            self.line(f"{self._stamp()} {self.style(severity, colour)}: {summary}")
            if detail:
                for row in detail.splitlines()[:12]:
                    self.line(f"    {row}")
            if severity == "error":
                self.failed += 1

        elif kind in ("version", "init_output", "log"):
            return  # noise; the JSONL has them if anyone needs them

        else:
            message = event.get("@message")
            if message and event.get("@level") in ("error", "warn"):
                self.line(f"{self._stamp()} {message}")

    def heartbeat(self) -> None:
        if not self.running:
            return
        parts = [
            f"{addr} {fmt_duration(self._elapsed(addr))}" for addr in sorted(self.running)
        ]
        waiting = len(self.pending)
        tail = f" (+{waiting} queued)" if waiting else ""
        self.line(f"{self._stamp()} {self.style('…', DIM)} {', '.join(parts)}{tail}")

    def summary(self) -> None:
        if not self.done and not self.failed:
            return
        slowest = sorted(self.done, key=lambda row: row[2], reverse=True)[:5]
        if slowest:
            self.line("")
            self.line(self.style("slowest resources", DIM))
            for addr, action, elapsed in slowest:
                self.line(f"  {fmt_duration(elapsed):>7}  {SYMBOL.get(action, '*')} {addr}")
        self.line(
            f"{self._stamp()} total {fmt_duration(time.monotonic() - self.started_at)}, "
            f"{len(self.done)} resources applied"
            + (f", {self.failed} error(s)" if self.failed else "")
        )

    # -- helpers -----------------------------------------------------------

    def _count(self, action: str) -> None:
        key = {"create": "add", "update": "change", "delete": "remove", "replace": "change"}.get(action)
        if key:
            self.counts[key] += 1

    def _elapsed(self, addr: str) -> float:
        _, started = self.running.get(addr, ("", time.monotonic()))
        return time.monotonic() - started

    @staticmethod
    def _shorten(value: str, limit: int = 44) -> str:
        return value if len(value) <= limit else value[: limit - 1] + "…"


def run_terraform(args: argparse.Namespace, style: Style) -> int:
    cmd = [
        "terraform",
        f"-chdir={args.dir}",
        "apply",
        "-json",
        "-input=false",
        "-no-color",
        args.plan,
    ]
    log_path = args.json_log
    os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
    log = open(log_path, "w", encoding="utf-8")

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        print("apply-stream: terraform not found on PATH", file=sys.stderr)
        return 127

    events: queue.Queue[str | None] = queue.Queue()

    def pump(stream) -> None:
        assert stream is not None
        for raw in stream:
            events.put(raw)
        events.put(None)

    threading.Thread(target=pump, args=(proc.stdout,), daemon=True).start()
    threading.Thread(target=pump_stderr, args=(proc.stderr,), daemon=True).start()

    renderer = Renderer(style, args.plan)
    header_done = False

    while True:
        try:
            raw = events.get(timeout=1.0)
        except queue.Empty:
            if time.monotonic() - renderer.last_event >= args.heartbeat:
                renderer.heartbeat()
                renderer.last_event = time.monotonic()
            continue
        if raw is None:
            break
        raw = raw.strip()
        if not raw:
            continue
        log.write(raw + "\n")
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            print(raw, flush=True)
            continue

        if event.get("type") == "planned_change":
            renderer.handle(event)  # accumulate, print the header once apply starts
            continue
        if not header_done and event.get("type") == "apply_start":
            renderer.start()
            header_done = True
        renderer.handle(event)

    log.close()
    code = proc.wait()
    renderer.summary()
    print(style(f"timeline: {log_path}", DIM), flush=True)
    return code


def pump_stderr(stream) -> None:
    assert stream is not None
    for raw in stream:
        raw = raw.rstrip()
        if raw:
            print(f"terraform: {raw}", file=sys.stderr, flush=True)


def replay(path: str, style: Style) -> int:
    renderer = Renderer(style, path)
    header_done = False
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                print(raw)
                continue
            if event.get("type") == "planned_change":
                renderer.handle(event)
                continue
            if not header_done and event.get("type") == "apply_start":
                renderer.start()
                header_done = True
            renderer.handle(event)
    renderer.summary()
    return 1 if renderer.failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Live per-resource progress for terraform apply.")
    parser.add_argument("--dir", default=".", help="Terraform working directory")
    parser.add_argument("--plan", help="Saved plan file (required unless --replay)")
    parser.add_argument(
        "--json-log",
        default=str(Path(os.environ.get("OUT_DIR") or Path.home() / ".litellm-deploy" / "out") / "apply-timeline.jsonl"),
        help="Where to archive the event stream (defaults outside the repository)",
    )
    parser.add_argument("--heartbeat", type=float, default=30.0, help="Seconds of silence before re-printing in-flight resources")
    parser.add_argument("--plain", action="store_true", help="No ANSI colour (CI logs)")
    parser.add_argument("--replay", help="Render an existing JSONL timeline instead of running Terraform")
    args = parser.parse_args()

    style = Style(enabled=not args.plain and sys.stdout.isatty())
    if args.replay:
        return replay(args.replay, style)
    if not args.plan:
        print("apply-stream: --plan is required (review a saved plan, then apply it)", file=sys.stderr)
        return 2
    return run_terraform(args, style)


if __name__ == "__main__":
    sys.exit(main())
