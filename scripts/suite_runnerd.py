#!/usr/bin/env python3
"""Minimal suite-runnerd HTTP service.

ADR-0011 companion service for Docker-backed execution runs.
This first implementation is intentionally narrow:

- POST /api/runs          → spawn a detached docker container
- GET /api/runs/:id       → inspect current provider state
- POST /api/runs/:id/stop → graceful stop (docker stop)
- POST /api/runs/:id/kill → force kill (docker kill)
- GET /health             → liveness probe

The service is stateless with a tiny on-disk index used only for remembering
container ids and the last requested stop mode. Containers are also labeled with
suite metadata so they can be rediscovered by run_id if the index is missing.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse

HOST = os.environ.get("SUITE_RUNNERD_HOST", "0.0.0.0")
PORT = int(os.environ.get("SUITE_RUNNERD_PORT", "4101"))
TOKEN = os.environ.get("SUITE_RUNNERD_TOKEN")
STATE_DIR = Path(os.environ.get("SUITE_RUNNERD_STATE_DIR", "/tmp/suite-runnerd"))
DEFAULT_IMAGE = os.environ.get("SUITE_RUNNER_IMAGE", "suite-runner:dev")
DEFAULT_NETWORK = os.environ.get("SUITE_RUNNER_NETWORK")

RUNS_DIR = STATE_DIR / "runs"
CONTAINERS_DIR = STATE_DIR / "containers"


class RunnerdError(Exception):
    def __init__(self, status: int, message: str, details: Any = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.details = details


def ensure_state_dirs() -> None:
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    CONTAINERS_DIR.mkdir(parents=True, exist_ok=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def slug(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-") or "run"


def run_cmd(args: List[str], *, input_text: Optional[str] = None, check: bool = True) -> str:
    proc = subprocess.run(
        args,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and proc.returncode != 0:
        raise RunnerdError(
            HTTPStatus.BAD_GATEWAY,
            f"command failed: {' '.join(args)}",
            {"exit_code": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr},
        )
    return proc.stdout.strip()


def docker(*args: str, check: bool = True) -> str:
    return run_cmd(["docker", *args], check=check)


def write_state(run_id: str, container_id: str, data: Dict[str, Any]) -> None:
    ensure_state_dirs()
    run_path = RUNS_DIR / f"{slug(run_id)}.json"
    container_path = CONTAINERS_DIR / f"{container_id}.json"
    payload = {"run_id": run_id, "container_id": container_id, **data}
    text = json.dumps(payload, indent=2, sort_keys=True)
    run_path.write_text(text)
    container_path.write_text(text)


def read_state(identifier: str) -> Optional[Dict[str, Any]]:
    ensure_state_dirs()
    candidates = [RUNS_DIR / f"{slug(identifier)}.json", CONTAINERS_DIR / f"{identifier}.json"]
    for path in candidates:
      if path.exists():
            return json.loads(path.read_text())
    return None


def resolve_container(identifier: str) -> Tuple[str, Optional[Dict[str, Any]]]:
    state = read_state(identifier)
    if state and state.get("container_id"):
        return state["container_id"], state

    lookup = docker("ps", "-aq", "--filter", f"label=suite.run_id={identifier}", check=False).splitlines()
    lookup = [line.strip() for line in lookup if line.strip()]
    if lookup:
        container_id = lookup[0]
        state = state or {"run_id": identifier, "container_id": container_id}
        write_state(state.get("run_id", identifier), container_id, state)
        return container_id, state

    inspect = docker("inspect", identifier, check=False)
    if inspect:
        container_id = identifier
        state = state or {"run_id": identifier, "container_id": container_id}
        write_state(state.get("run_id", identifier), container_id, state)
        return container_id, state

    raise RunnerdError(HTTPStatus.NOT_FOUND, f"run not found: {identifier}")


def build_mounts(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    mounts: List[Dict[str, Any]] = []

    primary = payload.get("mount")
    if isinstance(primary, dict):
        mounts.append(primary)

    extra = payload.get("mounts") or []
    if isinstance(extra, list):
        mounts.extend([m for m in extra if isinstance(m, dict)])

    meta = payload.get("meta") or {}
    meta_mounts = meta.get("mounts") or meta.get("extra_mounts") or []
    if isinstance(meta_mounts, list):
        mounts.extend([m for m in meta_mounts if isinstance(m, dict)])

    deduped: List[Dict[str, Any]] = []
    seen = set()
    for mount in mounts:
        key = (mount.get("host_source"), mount.get("container_target"), mount.get("read_only", False))
        if key not in seen:
            seen.add(key)
            deduped.append(mount)
    return deduped


def build_docker_run_cmd(payload: Dict[str, Any]) -> Tuple[List[str], str, Dict[str, Any]]:
    run_id = str(payload.get("run_id") or "")
    if not run_id:
        raise RunnerdError(HTTPStatus.BAD_REQUEST, "spawn payload missing run_id")

    command = payload.get("command")
    if not isinstance(command, str) or not command:
        raise RunnerdError(HTTPStatus.BAD_REQUEST, "spawn payload missing command")

    args = payload.get("args") or []
    if not isinstance(args, list):
        raise RunnerdError(HTTPStatus.BAD_REQUEST, "spawn payload args must be a list")

    meta = payload.get("meta") or {}
    image = meta.get("runner_image") or DEFAULT_IMAGE
    if not image:
        raise RunnerdError(HTTPStatus.BAD_REQUEST, "runner image missing")

    env = payload.get("env") or {}
    if not isinstance(env, dict):
        raise RunnerdError(HTTPStatus.BAD_REQUEST, "spawn payload env must be a map")

    mounts = build_mounts(payload)
    security = payload.get("security") or {}
    container_name = f"suite-run-{slug(run_id)}-{int(time.time())}"

    cmd = ["docker", "run", "-d", "--name", container_name]
    cmd += ["--label", f"suite.run_id={run_id}"]
    for key in ["task_id", "project_id", "epic_id"]:
        value = payload.get(key)
        if value:
            cmd += ["--label", f"suite.{key}={value}"]
    cmd += ["--label", "suite.managed_by=suite-runnerd"]

    if DEFAULT_NETWORK:
        cmd += ["--network", DEFAULT_NETWORK]

    user = security.get("user")
    if user:
        cmd += ["--user", str(user)]

    if security.get("no_new_privileges", True):
        cmd += ["--security-opt", "no-new-privileges:true"]

    for cap in security.get("capability_drop", []) or []:
        cmd += ["--cap-drop", str(cap)]

    for cap in security.get("capability_add", []) or []:
        cmd += ["--cap-add", str(cap)]

    workspace_dir = None
    for mount in mounts:
        if mount.get("type", "bind") != "bind":
            continue
        host = mount.get("host_source")
        target = mount.get("container_target")
        if not host or not target:
            raise RunnerdError(HTTPStatus.BAD_REQUEST, "bind mount missing host_source/container_target")
        spec = f"{host}:{target}"
        if mount.get("read_only"):
            spec += ":ro"
        cmd += ["-v", spec]
        if target == (payload.get("mount") or {}).get("container_target"):
            workspace_dir = target

    if workspace_dir:
        cmd += ["-w", workspace_dir]

    for key, value in env.items():
        cmd += ["-e", f"{key}={value}"]

    cmd.append(image)
    cmd.append(command)
    cmd += [str(arg) for arg in args]

    return cmd, image, {"run_id": run_id, "container_name": container_name, "image": image, "meta": meta}


def docker_inspect_json(container_id: str) -> Dict[str, Any]:
    output = docker("inspect", container_id)
    parsed = json.loads(output)
    if not parsed:
        raise RunnerdError(HTTPStatus.NOT_FOUND, f"container not found: {container_id}")
    return parsed[0]


def normalize_state(state: str) -> str:
    mapping = {
        "created": "starting",
        "restarting": "starting",
        "running": "running",
        "exited": "exited",
        "dead": "dead",
        "paused": "running",
        "removing": "stopped",
    }
    return mapping.get((state or "").lower(), state or "unknown")


def normalize_health(health: Optional[str]) -> Optional[str]:
    if not health:
        return None
    mapping = {"healthy": "healthy", "starting": "unknown", "unhealthy": "degraded"}
    return mapping.get(health.lower(), health.lower())


def normalize_timestamp(value: str) -> Optional[str]:
    if not value or value.startswith("0001-01-01"):
        return None
    return value


def describe_container(identifier: str) -> Dict[str, Any]:
    container_id, state = resolve_container(identifier)
    inspect = docker_inspect_json(container_id)
    status = normalize_state(((inspect.get("State") or {}).get("Status")) or "unknown")
    health = normalize_health((((inspect.get("State") or {}).get("Health") or {}).get("Status")))
    exit_code = ((inspect.get("State") or {}).get("ExitCode"))
    started_at = normalize_timestamp((inspect.get("State") or {}).get("StartedAt"))
    finished_at = normalize_timestamp((inspect.get("State") or {}).get("FinishedAt"))
    logs = docker("logs", "--tail", "50", container_id, check=False)
    payload = {
        "provider": "docker",
        "run_id": (state or {}).get("run_id"),
        "container_id": container_id,
        "container_name": inspect.get("Name", "").lstrip("/"),
        "image": ((inspect.get("Config") or {}).get("Image")) or (state or {}).get("image"),
        "status": status,
        "exit_code": exit_code,
        "stop_mode": (state or {}).get("stop_mode"),
        "started_at": started_at,
        "finished_at": finished_at,
        "exit_message": logs[-4000:] if logs else None,
        "health": health,
        "at": now_iso(),
    }
    if payload.get("run_id"):
        write_state(payload["run_id"], container_id, {**(state or {}), **payload})
    return payload


def spawn_container(payload: Dict[str, Any]) -> Dict[str, Any]:
    run_id = str(payload.get("run_id") or "")
    existing = docker("ps", "-aq", "--filter", f"label=suite.run_id={run_id}", check=False).splitlines()
    existing = [line.strip() for line in existing if line.strip()]
    if existing:
        current = describe_container(run_id)
        if current["status"] not in {"exited", "dead", "stopped"}:
            raise RunnerdError(HTTPStatus.CONFLICT, f"run already exists: {run_id}", current)

    cmd, image, state = build_docker_run_cmd(payload)
    container_id = run_cmd(cmd)
    provider_ref = {
        "provider": "docker",
        "run_id": run_id,
        "container_id": container_id,
        "container_name": state["container_name"],
        "image": image,
        "status": "starting",
        "started_at": now_iso(),
    }
    write_state(run_id, container_id, provider_ref)
    return provider_ref


def mark_stop_mode(identifier: str, mode: str) -> Dict[str, Any]:
    container_id, state = resolve_container(identifier)
    updated = {**(state or {}), "run_id": (state or {}).get("run_id", identifier), "container_id": container_id, "stop_mode": mode}
    write_state(updated["run_id"], container_id, updated)
    return updated


def request_stop(identifier: str, mode: str) -> Dict[str, Any]:
    updated = mark_stop_mode(identifier, mode)
    container_id = updated["container_id"]
    if mode == "graceful":
        docker("stop", container_id, check=False)
    else:
        docker("kill", container_id, check=False)
    return describe_container(container_id)


class Handler(BaseHTTPRequestHandler):
    server_version = "suite-runnerd/0.1"

    def _send(self, status: int, payload: Any) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError as exc:
            raise RunnerdError(HTTPStatus.BAD_REQUEST, f"invalid json: {exc}")

    def _require_auth(self) -> None:
        if not TOKEN:
            return
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {TOKEN}":
            raise RunnerdError(HTTPStatus.UNAUTHORIZED, "unauthorized")

    def do_GET(self) -> None:
        try:
            self._require_auth()
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                self._send(HTTPStatus.OK, {"ok": True, "at": now_iso()})
                return

            parts = [p for p in parsed.path.split("/") if p]
            if len(parts) == 3 and parts[:2] == ["api", "runs"]:
                self._send(HTTPStatus.OK, describe_container(parts[2]))
                return

            raise RunnerdError(HTTPStatus.NOT_FOUND, f"unknown path: {parsed.path}")
        except RunnerdError as exc:
            self._send(exc.status, {"error": exc.message, "details": exc.details})
        except Exception as exc:  # pragma: no cover
            self._send(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})

    def do_POST(self) -> None:
        try:
            self._require_auth()
            parsed = urlparse(self.path)
            parts = [p for p in parsed.path.split("/") if p]

            if parts == ["api", "runs"]:
                payload = self._read_json()
                self._send(HTTPStatus.CREATED, spawn_container(payload))
                return

            if len(parts) == 4 and parts[:2] == ["api", "runs"] and parts[3] in {"stop", "kill"}:
                mode = "graceful" if parts[3] == "stop" else "kill"
                self._send(HTTPStatus.OK, request_stop(parts[2], mode))
                return

            raise RunnerdError(HTTPStatus.NOT_FOUND, f"unknown path: {parsed.path}")
        except RunnerdError as exc:
            self._send(exc.status, {"error": exc.message, "details": exc.details})
        except Exception as exc:  # pragma: no cover
            self._send(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})

    def log_message(self, fmt: str, *args: Any) -> None:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        print(f"[{ts}] {self.address_string()} {fmt % args}")


def main() -> None:
    ensure_state_dirs()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"suite-runnerd listening on http://{HOST}:{PORT} state_dir={STATE_DIR}")
    server.serve_forever()


if __name__ == "__main__":
    main()
