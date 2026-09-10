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

    on_exit(fn ->
      # Shared mode ONLY, and it must stay that way. `Platform.SandboxHelpers`'
      # moduledoc records why: in `async: true` modules run concurrently, so
      # `Platform.TaskSupervisor`'s child set belongs to OTHER modules as much
      # as to this one, and draining it would be waiting on an unrelated test.
      # The consequence is that this drain does NOT cover `async: true`, so a
      # supervised orphan spawned by an async ConnCase test is still not waited
      # for. That residual is real and is not closed by this change: measured
      # on both the pre- and post-migration trees, such an orphan's in-flight
      # audit write still arrives as a process exit and still detaches
      # `"platform-audit-telemetry"` for the whole VM. The 16 `async: true`
      # files are therefore NOT covered by anything below, and they are a
      # DISJOINT set from the ones this on_exit protects. See
      # `notes/2026-09-10-conncase-sandbox-owner.md` §4 for the
      # `:telemetry.list_handlers/1` readings on both trees, and
      # `conn_case_supervised_orphan_test.exs` for the construction.
      if shared_mode?, do: Platform.SandboxHelpers.drain_or_warn()

      # LAST. Everything above needs a live connection.
      Sandbox.stop_owner(owner)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
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
