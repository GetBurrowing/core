defmodule PlatformWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PlatformWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo

  using do
    quote do
      # The default endpoint for testing
      @endpoint PlatformWeb.Endpoint

      use PlatformWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PlatformWeb.ConnCase

      # Deliberately NOT `import Platform.AsyncAssertions` here, unlike
      # `ChannelCase`. `tasks_live_planning_step_test.exs:724` defines a local
      # `eventually/2,3` with a different shape — `(view, selector, attempts)`,
      # a LiveView element poller rather than a predicate poller — and an
      # import would be a hard compile error ("conflicts with local function"),
      # not a shadowing warning. A ConnCase test that wants the shared helper
      # should `import Platform.AsyncAssertions` itself.
    end
  end

  setup tags do
    # The sandbox connection is owned by a SEPARATE agent process, not by the
    # test process. This mirrors `Platform.DataCase`, which moved to the same
    # shape for the same measured reason (`test/support/data_case.ex:24-41`).
    #
    # With the previous `Sandbox.checkout(Repo)` form the TEST process was the
    # owner, and ExUnit runs `on_exit` callbacks in a different process *after*
    # the test process has already terminated — so the connection went away
    # with its owner and every connection-dependent `on_exit` under ConnCase
    # was a silent no-op. `conn_case_owner_lifecycle_test.exs` pins that.
    #
    # The sharing policy is UNCHANGED: `shared: not tags[:async]` sets
    # `{:shared, owner}` for non-async cases and leaves async ones in manual
    # mode, exactly as the old `unless tags[:async]` gate did. The only
    # difference is which process is the owner — and the owner is the thing
    # that must survive.
    owner = Sandbox.start_owner!(Repo, shared: not tags[:async])

    # `start_owner!/2` allows the calling process ONLY on its `shared: false`
    # branch (`deps/ecto_sql/.../sandbox.ex`, `start_owner!/2`); the shared
    # branch just sets `{:shared, owner}`, which lets the test process USE the
    # connection but leaves it neither owner nor allowed. Any test that calls
    # `Sandbox.allow(Repo, self(), pid)` itself needs `self()` to be a valid
    # `owner_or_allowed` parent — `test/security/external_attachment_scope_test.exs:55`
    # is the one such ConnCase call site today. Explicitly allowing the test
    # process keeps `self()` a valid parent in both modes.
    if not tags[:async], do: Sandbox.allow(Repo, owner, self())

    shared_mode? = not tags[:async]

    # `on_exit` runs in a DIFFERENT process, after the test process is already
    # dead, so `self()` inside the callback is not the test. The scoped drain
    # below needs the test's own pid as the ownership key, so capture it here.
    test_pid = self()

    # Per-test escape hatch for the drain deadline. Its ONLY purpose is to let
    # a test force the timeout branch — a case that constructs a supervised
    # orphan on purpose (`conn_case_supervised_orphan_test.exs`) needs the drain
    # to give up so the orphan is still in flight when `stop_owner/1` runs, and
    # a characterisation of the un-drained defect is otherwise impossible to
    # write once the drain exists. Absent the tag the helper's own default
    # applies; nothing here re-states it, so there is one number.
    drain_opts =
      case tags[:sandbox_drain_timeout] do
        nil -> []
        timeout_ms -> [timeout: timeout_ms]
      end

    on_exit(fn ->
      # Task 01a0d4d6 stage 1: settle the Repo-using singletons (incl.
      # DeadLetterReplay's cast-driven drain) FIRST, in both modes, exactly as
      # `Platform.DataCase` does. Waits only; never terminates.
      Platform.SandboxHelpers.settle_singletons()

      # Task 01a0d4d6 stage 2: no TaskRouter may outlive the owner. Supervised
      # routers are stopped through the production path; routers a test
      # start_link'ed are already exiting with it and are waited for. Either
      # way `TaskRouter.terminate/2`'s log write lands on a live connection.
      # Before the drain, which then waits for the settle watch a stopped
      # router ends. Shared mode only, for the same reason as
      # `drain_or_warn/1`; see `Platform.SandboxHelpers.stop_task_routers_or_warn/1`.
      if shared_mode?, do: Platform.SandboxHelpers.stop_task_routers_or_warn()

      # TWO drains, because ownership is what separates them — NOT one drain
      # widened to cover both modes.
      #
      # The UNCONDITIONAL drain stays shared-mode ONLY, and it must stay that
      # way. `Platform.SandboxHelpers`' moduledoc records why: in `async: true`
      # modules run concurrently, so `Platform.TaskSupervisor`'s child set
      # belongs to OTHER modules as much as to this one, and draining all of it
      # would be waiting on an unrelated test. That objection is about the SET
      # being drained, not about draining, and it is unchanged.
      #
      # What closes the async residual is therefore a drain SCOPED to this
      # test's own children. `Task.Supervisor.start_child/2` seeds the child's
      # `:"$callers"`, which is why such a child reaches the sandbox connection
      # at all (`DBConnection.Ownership.Manager.proxy_for/2` walks that chain),
      # and the same entry identifies whose child it is —
      # `Platform.SandboxHelpersScopedDrainTest` pins both directions of that
      # discrimination, including that a foreign child is NOT waited for.
      #
      # HISTORY, because the previous version of this comment asserted the
      # opposite and was right at the time: before task 01a08b49 stage 2 the
      # 16 `async: true` ConnCase files (18 on this branch) were covered by
      # nothing here, and a supervised orphan they spawned had its in-flight
      # audit write arrive as a process exit, detaching
      # `"platform-audit-telemetry"` for the whole VM. Stage 1's
      # `Platform.Telemetry.HandlerGuardian` bounded that blast radius but did
      # not save the write. This drain removes the orphan instead, so there is
      # nothing to kill and no audit row lost. See
      # `notes/2026-09-10-conncase-sandbox-owner.md` §4 for the
      # `:telemetry.list_handlers/1` readings that established the residual, and
      # `conn_case_supervised_orphan_test.exs` for the construction — which since
      # task 01a08b49 stage 3 exercises BOTH branches of the deadline from one
      # construction: a QUEUED-DRAINED case whose orphan this drain waits for
      # (its write COMPLETES, and `:telemetry` never detaches anything) and a
      # QUEUED-BEYOND-DRAIN case that forces the timeout branch via `@tag
      # sandbox_drain_timeout:` so the un-drained shape is still measured. The
      # pair is what shows this call is load-bearing: delete it and the drained
      # case goes red with the owner gone from under the write.
      #
      # NOT covered, by construction: bare-`spawn` children (task 01a06638 /
      # PR #965). They carry no `$callers`, never resolve an owner, and no
      # ownership-scoped drain can see them. Do not "fix" that here.
      #
      # Task 01a0d265 stage 2: the async branch now calls the QUIESCE, not the
      # bare drain, and the shared branch runs the quiesce after the
      # unconditional drain. Same ownership scope, one added step: children of
      # THIS test still alive when the drain deadline passes are terminated
      # while the owner is still alive, because a wait-only drain provably
      # cannot quiesce a fire-and-forget lifecycle edge —
      # `run_architect_edge`'s runner parks in a `receive` on a 30-minute
      # budget, so the scoped drain below already ran, gave up, and the owner
      # still exited under a live client: 14 "owner exited, client still
      # using a connection" events in the baseline full-suite log. A client
      # that dies BEFORE its owner returns the connection instead of leaking
      # it. The termination is gated on the owner being alive, which is what
      # keeps the beyond-drain construction (owner stopped in the body,
      # orphans parked on the proxy) byte-for-byte what it was. See
      # `Platform.SandboxHelpers.quiesce_own_or_warn/3`.
      if shared_mode? do
        Platform.SandboxHelpers.drain_or_warn()
        Platform.SandboxHelpers.quiesce_own_or_warn(test_pid, owner, drain_opts)
      else
        Platform.SandboxHelpers.quiesce_own_or_warn(test_pid, owner, drain_opts)
      end

      # LAST. Everything above needs a live connection.
      #
      # Conditional since task 01a0d0fc-4d92-7001-83a2-94b3316e4603 stage 2
      # (2026-09-24). `Sandbox.stop_owner/1` is `GenServer.stop(pid)` (ecto_sql
      # `lib/ecto/adapters/sql/sandbox.ex`), and `GenServer.stop/1` on an
      # already-dead target EXITS `:noproc` — stopping an already-stopped owner
      # is NOT a tolerated no-op. Verified with an isolated ExUnit probe: a test
      # whose body stopped its own owner and whose `on_exit` then called
      # `Sandbox.stop_owner/1` again failed with `** (EXIT) no process: the
      # process is not alive...`.
      #
      # The supervised-orphan beyond-drain case
      # (`conn_case_supervised_orphan_beyond_drain_test.exs`) now stops its
      # owner IN THE TEST BODY, within milliseconds of the rendezvous that
      # proves its orphans are parked on the ownership proxy's wait queue, so
      # the proxy's disconnect — and therefore the queued orphans' exits —
      # cannot be beaten by queue backpressure the way the loaded teardown's
      # stop could (main-push CI run 35935904608: a parked checkout dropped as
      # `{:raise, DBConnection.ConnectionError, "...request was dropped from
      # queue after 125ms"}` before `stop_owner/1` ran). This teardown reaches
      # that test's owner already dead. For every other test the owner is alive
      # here and the guard changes nothing.
      if Process.alive?(owner), do: Sandbox.stop_owner(owner)
    end)

    # `sandbox_owner` is the pid the test's writes resolve ownership through,
    # exposed so a test that constructs a supervised orphan on purpose
    # (`conn_case_supervised_orphan_beyond_drain_test.exs`) can assert it is
    # alive as a positive control. Task 01a08d5d measured that its `:DOWN` is
    # NOT the moment ownership is gone (the ownership proxy outlives it), so do
    # not gate anything on this pid's exit.
    {:ok, conn: Phoenix.ConnTest.build_conn(), sandbox_owner: owner}
  end

  @doc """
  POST a GitHub webhook payload with a real `X-Hub-Signature-256` over the
  real raw request body.

  `Plug.Test` encodes a map body as `multipart/mixed; boundary=plug_conn_test`
  with the literal body `"--plug_conn_test--"`, so `conn.assigns[:raw_body]`
  never holds the JSON GitHub actually signs. Encoding the payload ourselves
  and sending it as `application/json` routes the request through
  `Plug.Parsers` -> `PlatformWeb.Plugs.CacheBodyReader`, which is what makes
  `raw_body` real and the HMAC meaningful.

  Options:

    * `:secret` — sign with this secret instead of the app-level
      `:github_webhook_secret` (used to exercise the mismatch path).
    * `:signature` — send this exact header value verbatim (used to exercise
      malformed headers and body-tamper cases). Pass `nil` to send no
      signature header at all.
    * `:body` — send these exact bytes instead of `Jason.encode!(payload)`.
      The signature is still computed over `payload`, which is how a
      body-tamper test is expressed.
  """
  def signed_github_post(conn, path, payload, opts \\ []) do
    signed_body = Keyword.get_lazy(opts, :signed_body, fn -> Jason.encode!(payload) end)
    body = Keyword.get(opts, :body, signed_body)
    secret = Keyword.get(opts, :secret) || Application.get_env(:platform, :github_webhook_secret)

    signature =
      case Keyword.fetch(opts, :signature) do
        {:ok, value} -> value
        :error -> "sha256=" <> github_hmac(signed_body, secret)
      end

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> maybe_put_signature(signature)
    |> Phoenix.ConnTest.dispatch(PlatformWeb.Endpoint, :post, path, body)
  end

  @doc """
  POST a GitHub webhook payload as real JSON bytes with NO signature header.
  """
  def unsigned_github_post(conn, path, payload) do
    signed_github_post(conn, path, payload, signature: nil)
  end

  @doc """
  Lowercase hex HMAC-SHA256 of `body` under `secret` — the digest half of a
  GitHub `X-Hub-Signature-256` header.
  """
  def github_hmac(body, secret) do
    :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp maybe_put_signature(conn, nil), do: conn

  defp maybe_put_signature(conn, signature),
    do: Plug.Conn.put_req_header(conn, "x-hub-signature-256", signature)
end
