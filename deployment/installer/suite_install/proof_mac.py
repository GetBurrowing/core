"""``suite-install proof <command>``: data-plane proof for a Burrow install on a Mac.

Task 01a0d6ab stage 5. Run ON the Mac, against an install made by
``suite-install setup``. Every command prints ``key value`` lines and ends with
one ``RESULT PASS|FAIL|CHECK <command>`` line; the exit code is 0 only for
PASS (and for CHECK, which is a listing a human reads). Output carries only
ids, digests, ranks, scores, counts and names, never a secret value, and it is
passed through the same scrubber as the setup CLI as a second layer.

Commands (``--dir`` defaults to the single install under ~/suite):

  init --zone Z [--tag T] [--core-image REF] [--embed-url U --embed-model M]
       [--stt-url U --stt-model M | --no-transcription]
      Create the proof install ``suite-<T>`` with hostnames ``suite-<T>``,
      ``auth-<T>`` and ``livekit-<T>`` flat under zone Z, from
      deployment/examples/mac.install.toml with meetings OFF. Its render
      equals the mac-lite render in every file except one added models.json
      that no container mounts (tests pin both halves), and meetings is then
      a one-flag flip (`setup init --meetings on`), which a mac-lite-based
      manifest cannot do: it has no [meetings] table. REF pins core-platform
      (images.refs). The --embed-*/--stt-* flags swap the hosted OpenAI
      endpoints for self-hosted OpenAI-compatible ones (the rock proof used a
      LAN llama-server and speaches).
  ports
      Listening TCP/UDP ports with their process names, the LiveKit media
      ports 7881/tcp and 7882/udp, and existing containers whose names the
      install's fixed container_name values would collide with.
  ram --label L
      ``docker stats`` memory per container, the runtime VM's memory, the host
      RAM and ``memory_pressure``'s free percentage.
  arch
      Architecture of every running service's image, and ``uname -m`` inside
      core-platform, files-service and memory-service.
  memory [--tag T] [--expect-dim 1536] [--wait 240]
      pgvector width of embeddings.embedding; a canary and a control journal
      entry written through the memory_create tool function; two searches
      through the memory_search tool function, whose opposite orderings are
      the positive and negative controls.
  files [--url https://<primary>] [--size 1048576]
      Mint a proof runtime token via rpc into a 0600 file, upload random bytes
      through attachment.upload_start over the public URL, download them back,
      compare sha256 and bytes, show an unauthenticated GET is denied, then
      revoke the runtime row, show the same token is refused, and delete the
      token file.
  meetings --expect on|off
      Whether livekit runs, and how many LIVEKIT_* names core-platform's
      environment carries (names counted, values never read out).
  livekit [--room R] [--seconds 45]
      Two synthetic publishers (``lk load-test``) join room R through the
      tunnel, then ``lk room participants list R``. The key and secret reach
      ``lk`` through its environment, never its argv.
  grep-transcript --transcript F --marker M [--key-file P ...]
                  [--human-turns [--expect-human-turns N]]
      Count occurrences of every secret value this install knows of in F
      (secrets.env, customer-secrets.env, secrets/*, every resolvable setup
      input, the Docker Hub token inside REGISTRY_AUTH, the one-time login
      link, and each --key-file). Prints counts per NAME only. M is the
      positive control and must be found. With --human-turns it also lists
      every turn a HUMAN typed (see human_turns()), one
      ``transcript.human_turn <n> <json text>`` line each, scrubbed like every
      other line; the verdict is CHECK (a human reads the list) unless
      --expect-human-turns N makes the count a PASS/FAIL check.
"""

import argparse
import base64
import hashlib
import json
import os
import secrets as pysecrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from .manifest import load
from .secrets import redact
from .setup import cli as setup_cli
from .setup.state import Install, SetupError, dumps_toml, resolve_dir
from .setup.steps import compose_ps

HERE = os.path.dirname(os.path.abspath(__file__))
EXAMPLES = os.path.join(os.path.dirname(os.path.dirname(HERE)), "examples")
DEFAULT_TAG = "01a0d6ab"
DEFAULT_CORE_IMAGE = "docker.io/example/suite-core:feat-01a0d6ab-multiarch"
USER_AGENT = "suite-install-proof/1"
RELEASE = "/app/bin/platform"
ARM_SERVICES = ("core-platform", "files-service", "memory-service")
MEDIA_PORTS = (("tcp", 7881), ("udp", 7882))

CANARY = "{tag} canary {nonce}: the lighthouse keeper's cat is named Quasar"
CONTROL = "{tag} control {nonce}: quarterly VAT filing uses form 9-B"
CANARY_QUERY = "what is the lighthouse cat called"
CONTROL_QUERY = "which form is used for the quarterly VAT filing"


class Out:
    """Collects ``key value`` lines; scrubs each against every known secret."""

    def __init__(self, stream, secret_values):
        self.stream = stream
        self.secret_values = secret_values  # callable -> {name: value}
        self.failed = False
        self.check = False

    def line(self, *parts):
        text = " ".join(str(p) for p in parts)
        print(redact(text, self.secret_values()), file=self.stream)

    def expect(self, ok, *parts):
        self.line("PASS" if ok else "FAIL", *parts)
        if not ok:
            self.failed = True
        return ok

    def result(self, command):
        if self.failed:
            verdict = "FAIL"
        elif self.check:
            verdict = "CHECK"
        else:
            verdict = "PASS"
        self.line("RESULT", verdict, command)
        return 1 if self.failed else 0


# ---------------------------------------------------------------------------
# Elixir, run inside core-platform with ``bin/platform rpc``.
# ---------------------------------------------------------------------------


def ex_str(value):
    """An Elixir string literal for ``value`` (JSON escapes, no interpolation)."""
    return json.dumps(value).replace("#", "\\#")


def ex_memory_create(date, entries):
    lines = [
        "alias Platform.Federation.ToolSurface",
        f"path = {ex_str(f'org/journal/{date}.md')}",
    ]
    for label, text in entries:
        lines.append(
            'case ToolSurface.execute("memory_create", '
            f'%{{"path" => path, "file_text" => {ex_str(text)}}}, %{{}}) do\n'
            f'  {{:ok, %{{entry_id: id}}}} -> IO.puts("{label}_id #{{id}}")\n'
            f'  other -> IO.puts("{label}_error " <> String.slice(inspect(other), 0, 300))\n'
            "end"
        )
    return "\n".join(lines)


def ex_memory_search(query, limit=20):
    return (
        "alias Platform.Federation.ToolSurface\n"
        'args = %{"query" => ' + ex_str(query) + ', "source" => "journal", '
        f'"limit" => {int(limit)}}}\n'
        'case ToolSurface.execute("memory_search", args, %{}) do\n'
        "  {:ok, p} ->\n"
        '    IO.puts("status #{Map.get(p, :retrieval_status)}")\n'
        "    hits = Map.get(p, :results) || Map.get(p, :partial_results) || []\n"
        "    hits |> Enum.with_index(1) |> Enum.each(fn {h, i} ->\n"
        '      sem = Map.get(h, :semantic_rank) || "-"\n'
        '      lex = Map.get(h, :lexical_rank) || "-"\n'
        '      IO.puts("hit #{i} #{Map.get(h, :id)} #{sem} #{lex} #{Map.get(h, :score)}")\n'
        "    end)\n"
        "  {:error, e} ->\n"
        '    IO.puts("status error " <> inspect(Map.get(e, :code)))\n'
        "end"
    )


def ex_mint(runtime_id):
    """A proof agent in its own channel, and an active runtime bound to it.

    The agent row is inserted directly and the runtime carries ``agent_id``
    (the ``register_voice_runtime`` shape) rather than going through
    ``link_agent``, whose auto-roster would add the proof agent to every
    channel of the instance. The runtime may call the attachment bundle only.
    """
    rid = ex_str(runtime_id)
    return (
        "import Ecto.Query\n"
        "alias Platform.{Repo, Federation, Chat}\n"
        "alias Platform.Agents.Agent\n"
        f"rid = {rid}\n"
        "user = Repo.one(from u in Platform.Accounts.User, where: is_nil(u.archived_at),"
        " order_by: [asc: u.inserted_at], limit: 1)\n"
        "if is_nil(user) do\n"
        '  IO.puts("error no_user")\n'
        "else\n"
        "  with {:ok, agent} <- Repo.insert(Agent.changeset(%Agent{},"
        ' %{name: rid, slug: rid, status: "active"})),\n'
        "       {:ok, space} <- Chat.create_channel(%{name: rid, slug: rid}),\n"
        "       {:ok, _} <- Chat.add_agent_participant(space.id, agent.id),\n"
        "       {:ok, rt} <- Federation.register_runtime(user.id, %{runtime_id: rid,"
        ' display_name: rid, agent_id: agent.id, transport: "websocket",'
        ' status: "pending", allowed_bundles: ["attachment"]}),\n'
        "       {:ok, _rt, token} <- Federation.activate_runtime(rt) do\n"
        '    IO.puts("runtime_id #{rid}")\n'
        '    IO.puts("owner_user_id #{user.id}")\n'
        '    IO.puts("agent_id #{agent.id}")\n'
        '    IO.puts("space_id #{space.id}")\n'
        '    IO.puts("token #{token}")\n'
        "  else\n"
        '    other -> IO.puts("error " <> String.slice(inspect(other), 0, 300))\n'
        "  end\n"
        "end"
    )


def ex_revoke(runtime_id):
    """Revoke the runtime row (status revoked, hash cleared), archive agent and channel."""
    rid = ex_str(runtime_id)
    return (
        "alias Platform.{Repo, Federation, Chat}\n"
        "alias Platform.Agents.Agent\n"
        f"rid = {rid}\n"
        "case Federation.get_runtime_by_runtime_id(rid) do\n"
        '  nil -> IO.puts("runtime_status missing")\n'
        "  rt ->\n"
        "    case Federation.revoke_runtime(rt) do\n"
        "      {:ok, r} ->\n"
        '        IO.puts("runtime_status #{r.status} token_hash_nil=#{is_nil(r.auth_token_hash)}")\n'
        '      other -> IO.puts("runtime_status error " <> String.slice(inspect(other), 0, 200))\n'
        "    end\n"
        "end\n"
        "case Repo.get_by(Agent, slug: rid) do\n"
        '  nil -> IO.puts("agent_status missing")\n'
        "  agent ->\n"
        '    {:ok, a} = Repo.update(Agent.changeset(agent, %{status: "archived"}))\n'
        '    IO.puts("agent_status #{a.status}")\n'
        "end\n"
        "case Repo.get_by(Platform.Chat.Space, slug: rid) do\n"
        '  nil -> IO.puts("space_status missing")\n'
        "  space ->\n"
        "    {:ok, sp} = Chat.archive_space(space)\n"
        '    IO.puts("space_status archived=#{not is_nil(sp.archived_at)}")\n'
        "end"
    )


def parse_kv(text):
    """``key rest`` lines -> {key: rest}; the last occurrence wins."""
    out = {}
    for line in text.splitlines():
        key, _, rest = line.strip().partition(" ")
        if key:
            out[key] = rest.strip()
    return out


def parse_hits(text):
    """``(status, [{rank, id, sem, lex, score}])`` from ex_memory_search output."""
    status, hits = None, []
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "status":
            status = " ".join(parts[1:])
        elif parts[0] == "hit" and len(parts) >= 6:
            hits.append(
                {
                    "rank": int(parts[1]),
                    "id": parts[2],
                    "sem": None if parts[3] == "-" else int(parts[3]),
                    "lex": None if parts[4] == "-" else int(parts[4]),
                    "score": parts[5],
                }
            )
    return status, hits


def judge_order(hits, first_id, second_id):
    """Is ``first_id`` rank 1 and ranked above ``second_id``, fused AND semantically?

    Returns ``(ok, facts)``. The semantic comparison is what proves the hosted
    embeddings work: the lexical channel alone could order these two texts.
    """
    by_id = {h["id"]: h for h in hits}
    first, second = by_id.get(first_id), by_id.get(second_id)
    facts = {
        "top_id": hits[0]["id"] if hits else "none",
        "first_rank": first["rank"] if first else "absent",
        "second_rank": second["rank"] if second else "absent",
        "first_semantic_rank": first["sem"] if first and first["sem"] else "absent",
        "second_semantic_rank": second["sem"] if second and second["sem"] else "absent",
    }
    if not first or first["rank"] != 1 or first["sem"] is None:
        return False, facts
    if second is None:
        return True, facts
    if second["rank"] <= first["rank"]:
        return False, facts
    if second["sem"] is not None and second["sem"] <= first["sem"]:
        return False, facts
    return True, facts


# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------


class Proof:
    def __init__(self, install, env, stream):
        self.install = install
        self.env = env
        self.ctx = setup_cli._ctx(install, env)
        self.extra_secrets = {}
        self.out = Out(stream, self.secret_values)

    @property
    def host(self):
        return self.env.host

    def secret_values(self):
        values = dict(self.ctx.secret_values())
        values.update({k: v for k, v in self.extra_secrets.items() if v})
        return values

    def compose(self, *args, timeout=600):
        return self.ctx.compose(*args, timeout=timeout)

    def rpc(self, code, timeout=180):
        result = self.compose("exec", "-T", "core-platform", RELEASE, "rpc", code, timeout=timeout)
        if not result.ok:
            tail = " ".join((result.stderr or result.stdout or "").strip().splitlines()[-3:])
            raise SetupError("rpc_failed", f"bin/platform rpc exited {result.returncode}: {tail}")
        return result.stdout

    def primary(self):
        return self.ctx.manifest["domain"]["primary"]


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def apply_endpoint_overrides(raw, args):
    """Point the proof manifest at self-hosted OpenAI-compatible endpoints.

    The defaults keep mac.install.toml's hosted OpenAI endpoints. The rock
    proof (2026-10-05) used a LAN llama-server for embeddings and a LAN
    speaches for speech-to-text instead; both still go through the same
    `api_key_ref` (a dummy key file there, since neither checks a bearer).
    The width the memory proof expects then follows the model (`memory
    --expect-dim`), never this function.
    """
    if args.embed_url:
        raw["embeddings"]["base_url"] = args.embed_url.rstrip("/")
    if args.embed_model:
        raw["embeddings"]["model"] = args.embed_model
    endpoint = raw["models"]["endpoints"][0]
    if args.stt_url:
        endpoint["base_url"] = args.stt_url.rstrip("/")
        endpoint["kind"] = "byo"
    if args.stt_model:
        raw["meetings"]["stt_model"] = args.stt_model
    if args.no_transcription:
        raw["meetings"]["transcription"] = False
        raw["meetings"].pop("stt_endpoint", None)
        raw["meetings"].pop("stt_model", None)


def cmd_init(args, env, stream):
    tag = args.tag
    zone = args.zone.strip().strip(".")
    raw = load(os.path.join(EXAMPLES, "mac.install.toml"))
    raw.setdefault("images", {}).setdefault("refs", {})["core-platform"] = args.core_image
    apply_endpoint_overrides(raw, args)
    work = tempfile.mkdtemp(prefix=f"suite-proof-{tag}-")
    path = os.path.join(work, f"suite-{tag}.install.toml")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            dumps_toml(
                raw,
                [
                    f"Proof manifest for task {tag}: mac.install.toml with meetings off",
                    f"(the mac-lite render plus an unmounted models.json); core-platform {args.core_image}.",
                ],
            )
        )
    argv = [
        "init",
        "--from",
        path,
        "--name",
        f"suite-{tag}",
        "--domain",
        f"suite-{tag}.{zone}",
        "--auth-host",
        f"auth-{tag}.{zone}",
        "--livekit-host",
        f"livekit-{tag}.{zone}",
        "--meetings",
        "off",
    ]
    if args.dir:
        argv += ["--dir", args.dir]
    try:
        return setup_cli.main(argv, env=env, out=stream)
    finally:
        os.unlink(path)
        os.rmdir(work)


def _lsof(host, proto):
    if proto == "tcp":
        argv = ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"]
    else:
        argv = ["lsof", "-nP", "-iUDP"]
    result = host.run(argv, timeout=60)
    rows = set()
    for line in (result.stdout or "").splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9:
            continue
        port = parts[8].rsplit(":", 1)[-1]
        if port.isdigit():
            rows.add((int(port), parts[0]))
    return sorted(rows)


def fixed_container_names(proof):
    names = set()
    try:
        with open(proof.install.file("compose.yaml"), encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if stripped.startswith("container_name:"):
                    names.add(stripped.split(":", 1)[1].strip().strip('"'))
    except OSError:
        pass
    return names


def cmd_ports(proof, args):
    out = proof.out
    for proto in ("tcp", "udp"):
        rows = _lsof(proof.host, proto)
        out.line(f"ports.{proto}.count", len(rows))
        for port, command in rows:
            out.line(f"ports.{proto}", port, command)
        for want_proto, port in MEDIA_PORTS:
            if want_proto == proto:
                users = sorted({c for p, c in rows if p == port})
                ours = all(
                    u.startswith(("com.docke", "OrbStack", "vpnkit", "docker")) for u in users
                )
                out.expect(
                    not users or ours,
                    f"media_port {proto}/{port}",
                    "free" if not users else "held-by " + ",".join(users),
                )
    existing = proof.host.run(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=60)
    names = set((existing.stdout or "").split())
    wanted = fixed_container_names(proof)
    mine = set()
    for row in _compose_ps(proof) or []:
        mine.add(row.get("Name") or "")
    clash = sorted((names & wanted) - mine)
    out.line("containers.existing", len(names))
    out.expect(not clash, "container_name_collisions", ",".join(clash) or "none")
    return out.result("ports")


def _compose_ps(proof):
    if not os.path.exists(proof.install.file("compose.yaml")):
        return []
    return compose_ps(proof.ctx)


def cmd_ram(proof, args):
    out = proof.out
    label = args.label
    stats = proof.host.run(
        ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.MemUsage}}"], timeout=120
    )
    for line in (stats.stdout or "").splitlines():
        name, _, usage = line.partition("\t")
        if name:
            out.line(f"ram.{label}.container", name, usage.replace(" ", ""))
    info = proof.host.run(["docker", "info", "--format", "{{.MemTotal}}"], timeout=60)
    vm = (info.stdout or "").strip()
    out.line(f"ram.{label}.runtime_vm_bytes", vm or "unknown")
    mem = proof.host.run(["sysctl", "-n", "hw.memsize"], timeout=30)
    out.line(f"ram.{label}.host_bytes", (mem.stdout or "").strip() or "unknown")
    pressure = proof.host.run(["memory_pressure"], timeout=60)
    free = "unknown"
    for line in (pressure.stdout or "").splitlines():
        if "free percentage" in line:
            free = line.rsplit(":", 1)[-1].strip()
    out.line(f"ram.{label}.memory_pressure_free", free)
    out.check = True
    return out.result("ram")


def cmd_arch(proof, args):
    out = proof.out
    rows = [r for r in (_compose_ps(proof) or []) if r.get("State") == "running"]
    out.expect(bool(rows), "running_services", len(rows))
    for row in sorted(rows, key=lambda r: r.get("Service", "")):
        image = row.get("Image", "")
        arch = proof.host.run(
            ["docker", "image", "inspect", "--format", "{{.Architecture}}", image], timeout=60
        )
        value = (arch.stdout or "").strip() or "unknown"
        out.expect(value == "arm64", "image_arch", row.get("Service"), image, value)
    running = {r.get("Service") for r in rows}
    for service in ARM_SERVICES:
        if service not in running:
            out.expect(False, "uname", service, "not-running")
            continue
        result = proof.compose("exec", "-T", service, "uname", "-m", timeout=60)
        value = (result.stdout or "").strip() or "unknown"
        out.expect(value == "aarch64", "uname", service, value)
    return out.result("arch")


def cmd_memory(proof, args):
    out = proof.out
    width = proof.compose(
        "exec",
        "-T",
        "core-postgres",
        "psql",
        "-U",
        args.pg_user,
        "-d",
        args.memory_db,
        "-Atc",
        "select atttypmod from pg_attribute where attrelid = to_regclass('embeddings') "
        "and attname = 'embedding'",
        timeout=60,
    )
    value = (width.stdout or "").strip() or "none"
    out.expect(value == str(args.expect_dim), "memory.atttypmod", value)

    nonce = pysecrets.token_hex(3)
    canary = CANARY.format(tag=args.tag, nonce=nonce)
    control = CONTROL.format(tag=args.tag, nonce=nonce)
    date = time.strftime("%Y-%m-%d", time.gmtime())
    written = parse_kv(
        proof.rpc(ex_memory_create(date, [("canary", canary), ("control", control)]))
    )
    canary_id, control_id = written.get("canary_id"), written.get("control_id")
    out.line("memory.nonce", nonce)
    out.expect(bool(canary_id), "memory.canary_id", canary_id or written.get("canary_error"))
    out.expect(bool(control_id), "memory.control_id", control_id or written.get("control_error"))
    if not (canary_id and control_id):
        return out.result("memory")

    deadline = time.monotonic() + args.wait
    started = time.monotonic()
    status, hits = None, []
    while True:
        status, hits = parse_hits(proof.rpc(ex_memory_search(CANARY_QUERY)))
        both = {h["id"]: h for h in hits if h["sem"] is not None}
        if canary_id in both and control_id in both:
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(args.poll)
    out.line("memory.ingest_wait_seconds", int(time.monotonic() - started))

    for name, query, first, second in (
        ("canary_query", CANARY_QUERY, canary_id, control_id),
        ("control_query", CONTROL_QUERY, control_id, canary_id),
    ):
        if name == "control_query":
            status, hits = parse_hits(proof.rpc(ex_memory_search(query)))
        out.expect(status == "ok", f"memory.{name}.retrieval_status", status)
        for h in hits[:5]:
            out.line(
                f"memory.{name}.hit",
                h["rank"],
                h["id"],
                h["sem"] or "-",
                h["lex"] or "-",
                h["score"],
            )
        ok, facts = judge_order(hits, first, second)
        out.expect(
            ok,
            f"memory.{name}.order",
            " ".join(f"{k}={v}" for k, v in facts.items()),
        )
    return out.result("memory")


def _write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, 0o600)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http(method, url, body=None, headers=None, timeout=120):
    """``(status, headers, body bytes)``; never follows a redirect."""
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("User-Agent", USER_AGENT)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers or {}), exc.read() if exc.fp else b""


def mcp_call(base, token, name, arguments, http_fn=None):
    http_fn = http_fn or http
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    status, _h, body = http_fn(
        "POST",
        base + "/mcp",
        json.dumps(payload).encode(),
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    if status != 200:
        return status, None
    doc = json.loads(body)
    result = doc.get("result") or {}
    content = result.get("content") or []
    if result.get("isError") or not content:
        return status, None
    return status, json.loads(content[0]["text"])


def denied(status, headers):
    if status in (401, 403):
        return True
    location = headers.get("Location") or headers.get("location") or ""
    return 300 <= status < 400 and "/auth/login" in location


def _files_exchange(proof, args, base, space_id, bearer, http_fn):
    """Upload, download, compare, and the unauthenticated GET. Returns the URL."""
    out = proof.out
    data = os.urandom(args.size)
    digest = hashlib.sha256(data).hexdigest()
    out.line("files.upload_bytes", len(data))
    out.line("files.upload_sha256", digest)
    status, started = mcp_call(
        base,
        bearer(),
        "attachment.upload_start",
        {
            "space_id": space_id,
            "filename": f"proof-{args.tag}.bin",
            "content_type": "application/octet-stream",
            "byte_size": len(data),
        },
        http_fn,
    )
    out.expect(bool(started), "files.upload_start_status", status)
    if not started:
        return None
    upload_url = started["upload_url"]
    if upload_url.startswith("/"):
        upload_url = base + upload_url
    # The presigned path is an upload credential until it is used.
    proof.extra_secrets["PROOF_UPLOAD_TOKEN"] = upload_url.rsplit("/", 1)[-1]
    status, _h, body = http_fn(
        "POST", upload_url, data, {"Content-Type": "application/octet-stream"}
    )
    out.expect(status == 200, "files.upload_post_status", status)
    final = json.loads(body) if status == 200 else {}
    url = final.get("url") or started["url"]
    out.line("files.attachment_id", final.get("id") or started["id"])
    out.line("files.server_content_hash", final.get("content_hash", "unknown"))

    status, _h, got = http_fn("GET", base + url, None, {"Authorization": f"Bearer {bearer()}"})
    out.expect(status == 200, "files.download_status", status)
    got_digest = hashlib.sha256(got).hexdigest()
    out.expect(got_digest == digest, "files.download_sha256", got_digest)
    with tempfile.TemporaryDirectory(prefix=f"proof-{args.tag}-") as work:
        sent, back = os.path.join(work, "sent.bin"), os.path.join(work, "got.bin")
        with open(sent, "wb") as handle:
            handle.write(data)
        with open(back, "wb") as handle:
            handle.write(got)
        cmp = proof.host.run(["cmp", sent, back], timeout=60)
        out.expect(cmp.ok, "files.cmp", "identical" if cmp.ok else "differ")

    status, headers, _b = http_fn("GET", base + url, None, {})
    out.expect(denied(status, headers), "files.unauthenticated_get_status", status)
    return url


def _cleanup(proof, runtime_id):
    done = parse_kv(proof.rpc(ex_revoke(runtime_id)))
    status = done.get("runtime_status", "unknown")
    proof.out.expect(status.startswith("revoked"), "files.runtime_status", status)
    proof.out.line("files.agent_status", done.get("agent_status", "unknown"))
    proof.out.line("files.space_status", done.get("space_status", "unknown"))


def cmd_files(proof, args, http_fn=None):
    http_fn = http_fn or http
    out = proof.out
    base = (args.url or f"https://{proof.primary()}").rstrip("/")
    runtime_id = f"proof-{args.tag}-{pysecrets.token_hex(3)}"
    token_file = proof.install.file(".setup", f"proof-token-{args.tag}-{os.getpid()}")
    proof.install.setup_dir()

    minted = parse_kv(proof.rpc(ex_mint(runtime_id)))
    token = minted.pop("token", "")
    if token:
        proof.extra_secrets["PROOF_RUNTIME_TOKEN"] = token
        _write_private(token_file, token + "\n")
    mode = oct(os.stat(token_file).st_mode & 0o777) if token else "none"
    out.expect(mode == "0o600", "files.token_file_mode", mode)
    for key in ("runtime_id", "owner_user_id", "agent_id", "space_id"):
        out.line(f"files.{key}", minted.get(key, "missing"))
    if not token:
        out.expect(False, "files.mint", minted.get("error", "no token"))
        _cleanup(proof, runtime_id)
        return out.result("files")
    del token  # from here on the token is read back from the 0600 file

    def bearer():
        with open(token_file, encoding="utf-8") as handle:
            return handle.read().strip()

    url = None
    try:
        url = _files_exchange(proof, args, base, minted["space_id"], bearer, http_fn)
    finally:
        _cleanup(proof, runtime_id)
        if url:
            # Negative control for the revoke: the same token, the same URL.
            status, _h, _b = http_fn(
                "GET", base + url, None, {"Authorization": f"Bearer {bearer()}"}
            )
            out.expect(status == 401, "files.revoked_token_get_status", status)
        os.unlink(token_file)
        out.expect(not os.path.exists(token_file), "files.token_file", "deleted")
    return out.result("files")


def cmd_meetings(proof, args):
    out = proof.out
    rows = _compose_ps(proof) or []
    services = sorted({r.get("Service", "") for r in rows if r.get("State") == "running"})
    out.line("meetings.running_services", ",".join(services))
    present = "livekit" in services
    want = args.expect == "on"
    out.expect(present == want, "meetings.livekit_running", "yes" if present else "no")
    envs = proof.compose("exec", "-T", "core-platform", "env", timeout=60)
    names = [line.split("=", 1)[0] for line in (envs.stdout or "").splitlines() if "=" in line]
    count = sum(1 for n in names if n.startswith("LIVEKIT_"))
    out.expect((count > 0) == want, "meetings.core_livekit_env_count", count)
    return out.result("meetings")


def cmd_livekit(proof, args, popen=subprocess.Popen, run=subprocess.run, sleep=time.sleep):
    out = proof.out
    manifest = proof.ctx.manifest
    host = manifest["domain"].get("livekit_host")
    secret = proof.ctx.rendered_secret("LIVEKIT_API_SECRET")
    key = proof.compose("exec", "-T", "core-platform", "printenv", "LIVEKIT_API_KEY", timeout=60)
    api_key = (key.stdout or "").strip()
    if not (host and secret and api_key):
        out.expect(False, "livekit.config", "meetings are off or not rendered")
        return out.result("livekit")
    env = dict(os.environ)
    env.update(
        {"LIVEKIT_URL": f"wss://{host}", "LIVEKIT_API_KEY": api_key, "LIVEKIT_API_SECRET": secret}
    )
    room = args.room or f"proof-{args.tag}"
    out.line("livekit.url", f"wss://{host}")
    out.line("livekit.room", room)
    load = popen(
        [
            "lk",
            "load-test",
            "--room",
            room,
            "--video-publishers",
            "2",
            "--duration",
            f"{args.seconds}s",
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    sleep(min(args.list_after, args.seconds))
    listing = run(
        ["lk", "room", "participants", "list", room],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    for line in (listing.stdout or "").splitlines():
        out.line("livekit.participants", line.strip())
    try:
        tail, _ = load.communicate(timeout=args.seconds + 60)
    except subprocess.TimeoutExpired:
        load.kill()
        tail, _ = load.communicate()
    for line in (tail or "").splitlines()[-15:]:
        out.line("livekit.load_test", line.strip())
    out.expect(load.returncode == 0, "livekit.load_test_exit", load.returncode)
    out.check = True
    return out.result("livekit")


def transcript_secrets(proof, key_files):
    """``{label: value}`` of every secret to look for; labels are names, never values."""
    values = dict(proof.ctx.secret_values())
    unresolved = []
    from .setup import inputs as inputs_mod

    declared = inputs_mod.declared(proof.ctx.manifest)
    for name in sorted(proof.ctx.state.get("inputs", {})):
        item = declared.get(name)
        if item is None or not item.secret:
            continue
        try:
            value = proof.ctx.value(name)
        except SetupError:
            unresolved.append(name)
            continue
        values[f"input:{name}"] = value
        if name == inputs_mod.REGISTRY_AUTH:
            try:
                auths = json.loads(value).get("auths", {})
            except ValueError:
                auths = {}
            for registry, entry in sorted(auths.items()):
                auth = (entry or {}).get("auth")
                if not auth:
                    continue
                values[f"input:{name}:auth:{registry}"] = auth
                try:
                    _user, _, token = base64.b64decode(auth).decode().partition(":")
                except (ValueError, UnicodeDecodeError):
                    token = ""
                if token:
                    values[f"input:{name}:token:{registry}"] = token
    link = proof.install.file(".setup", "login-link")
    if os.path.exists(link):
        with open(link, encoding="utf-8") as handle:
            values["setup:login-link"] = handle.read().strip()
    for path in key_files:
        with open(os.path.expanduser(path), encoding="utf-8") as handle:
            values[f"key-file:{os.path.basename(path)}"] = handle.read().strip()
    return {k: v for k, v in values.items() if v and len(v) >= 8}, unresolved


def count_forms(haystack, value):
    """Occurrences of ``value`` raw, or as it appears inside a JSON string."""
    forms = {value, json.dumps(value)[1:-1], json.dumps(value, ensure_ascii=False)[1:-1]}
    return sum(haystack.count(form) for form in forms)


# Text a harness injects as a user message; none of it was typed by a human.
_INJECTED_PREFIXES = ("<task-notification", "<local-command-", "<system-reminder")


def _turn_text(content):
    """The human-typed text of a user message's content, or None (tool results only)."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
    return "\n".join(texts) if texts else None


def human_turns(lines):
    """Turns a human typed, from a Claude Code transcript, in order.

    Two transcript shapes carry the same ``{"type": "user", "message":
    {"content": ...}}`` records:

    - ``claude -p --input-format stream-json --output-format stream-json
      --verbose --replay-user-messages`` output. Each message the human fed on
      stdin is re-emitted with ``isReplay: true``; tool results come back as
      ``user`` records whose content is ``tool_result`` blocks; a subagent's
      prompt carries a non-null ``parent_tool_use_id``. (Shape measured with
      claude on hive, 2026-10-05, task 01a0d6ab stage 6.)
    - an interactive session's ``~/.claude/projects/<cwd>/<session>.jsonl``.
      Records carry ``origin.kind`` ("human" for typed turns,
      "task-notification" for harness ones); ``isMeta``, ``isSidechain`` and
      ``isCompactSummary`` mark injected, subagent and summary records.

    A record counts when it is a user message with text content and none of
    those markers say otherwise; when ``origin`` is present its kind decides.
    Returns ``(turns, non_json_line_count)``.
    """
    turns, bad = [], 0
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
        except ValueError:
            bad += 1
            continue
        if not isinstance(rec, dict) or rec.get("type") != "user":
            continue
        if rec.get("parent_tool_use_id") or rec.get("isSidechain"):
            continue
        if rec.get("isMeta") or rec.get("isCompactSummary") or rec.get("isSynthetic"):
            continue
        origin = rec.get("origin")
        if isinstance(origin, dict) and origin.get("kind") != "human":
            continue
        text = _turn_text((rec.get("message") or {}).get("content"))
        if text is None or text.lstrip().startswith(_INJECTED_PREFIXES):
            continue
        turns.append(text)
    return turns, bad


def cmd_grep_transcript(proof, args):
    out = proof.out
    with open(os.path.expanduser(args.transcript), encoding="utf-8", errors="replace") as handle:
        haystack = handle.read()
    out.line("transcript.bytes", len(haystack.encode()))
    values, unresolved = transcript_secrets(proof, args.key_file or [])
    for name in unresolved:
        out.line("transcript.unresolved_input", name)
    total = 0
    for label in sorted(values):
        n = count_forms(haystack, values[label])
        total += n
        out.line("transcript.count", label, n)
    out.line("transcript.secrets_checked", len(values))
    out.expect(total == 0, "transcript.secret_occurrences", total)
    marker = haystack.count(args.marker)
    out.expect(marker >= 1, "transcript.marker_count", marker)
    if args.human_turns or args.expect_human_turns is not None:
        turns, bad = human_turns(haystack.splitlines())
        out.line("transcript.non_json_lines", bad)
        for n, text in enumerate(turns, 1):
            out.line("transcript.human_turn", n, json.dumps(text[:300]))
        if args.expect_human_turns is None:
            out.line("transcript.human_turns", len(turns))
            out.check = True
        else:
            out.expect(
                len(turns) == args.expect_human_turns,
                "transcript.human_turns",
                len(turns),
                "expected",
                args.expect_human_turns,
            )
    return out.result("grep-transcript")


# ---------------------------------------------------------------------------


def parser():
    p = argparse.ArgumentParser(prog="suite-install proof", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)

    def add(name, **kw):
        c = sub.add_parser(name, **kw)
        c.add_argument("--dir")
        c.add_argument("--tag", default=DEFAULT_TAG)
        return c

    c = add("init")
    c.add_argument("--zone", required=True)
    c.add_argument("--core-image", default=DEFAULT_CORE_IMAGE)
    c.add_argument("--embed-url", help="embeddings base_url, no /v1 (default: hosted OpenAI)")
    c.add_argument("--embed-model", help="embeddings model (default: text-embedding-3-small)")
    c.add_argument("--stt-url", help="speech-to-text endpoint base_url ending at /v1")
    c.add_argument("--stt-model", help="the transcriber's STT_MODEL (default: whisper-1)")
    c.add_argument("--no-transcription", action="store_true")
    add("ports")
    c = add("ram")
    c.add_argument("--label", required=True)
    add("arch")
    c = add("memory")
    c.add_argument("--expect-dim", type=int, default=1536)
    c.add_argument("--wait", type=int, default=240)
    c.add_argument("--poll", type=int, default=5)
    c.add_argument("--pg-user", default="core_platform")
    c.add_argument("--memory-db", default="memory")
    c = add("files")
    c.add_argument("--url")
    c.add_argument("--size", type=int, default=1024 * 1024)
    c = add("meetings")
    c.add_argument("--expect", choices=("on", "off"), required=True)
    c = add("livekit")
    c.add_argument("--room")
    c.add_argument("--seconds", type=int, default=45)
    c.add_argument("--list-after", type=int, default=15)
    c = add("grep-transcript")
    c.add_argument("--transcript", required=True)
    c.add_argument("--marker", required=True)
    c.add_argument("--key-file", action="append")
    c.add_argument("--human-turns", action="store_true", help="list the turns a human typed")
    c.add_argument("--expect-human-turns", type=int, help="fail unless exactly N human turns")
    return p


COMMANDS = {
    "ports": cmd_ports,
    "ram": cmd_ram,
    "arch": cmd_arch,
    "memory": cmd_memory,
    "files": cmd_files,
    "meetings": cmd_meetings,
    "livekit": cmd_livekit,
    "grep-transcript": cmd_grep_transcript,
}


def main(argv=None, env=None, out=None):
    out = out or sys.stdout
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "--grep-transcript":
        argv[0] = "grep-transcript"
    args = parser().parse_args(argv)
    env = env or setup_cli.Env()
    if args.command == "init":
        return cmd_init(args, env, out)
    try:
        try:
            path = resolve_dir(args.dir, env.environ)
        except SetupError:
            if args.command not in ("ports", "ram"):
                raise
            # Before install: no install dir yet, host-level readings only.
            path = os.path.join(tempfile.gettempdir(), f"suite-proof-{args.tag}-none")
        install = Install(path)
        if not install.exists() and args.command not in ("ports", "ram"):
            raise SetupError("install_dir_missing", f"no install at {path}", "run `proof init`")
        proof = Proof(install, env, out)
        return COMMANDS[args.command](proof, args)
    except SetupError as exc:
        print(f"RESULT FAIL {args.command} {exc.code}: {exc.message}", file=out)
        return 1
