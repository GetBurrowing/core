defmodule Platform.LivekitStubPlug do
  @moduledoc """
  Static test-env stand-in for the LiveKit Twirp HTTP API.

  Installed as the default `:livekit_req_client` plug by
  `test/test_helper.exs`, so every CreateRoom / ListParticipants call the
  suite makes while a meeting test has poked `:livekit` credentials into
  app env resolves against THIS plug instead of the network. Before this
  existed, `Meetings.ensure_room/1`'s `wss://livekit.test` fixture URL did
  a REAL DNS lookup per call — ~300 real `Req.post`s per full run, each
  a musl/container DNS round-trip — flooding the logs with `:nxdomain`
  and adding seconds of concurrent IO that starves sibling LiveView
  child mounts past Phoenix's 5 s `child_mount` deadline
  (`PlatformWeb.MeetingLiveTest` child_mount timeouts, task 01a0d265
  stage 4).

  A plain plug module rather than a `Req.Test` stub on purpose: the calls
  come from test, LiveView AND background processes across `async: true`
  modules, so ownership-scoped `Req.Test` stubs cannot cover them. The
  response mirrors LiveKit's CreateRoom success shape closely enough for
  every caller (`{:ok, %{status: 200}}` is all any caller checks); tests
  that need a scripted response still override `:livekit_req_client` with
  their own `Req.Test` plug exactly as before.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{}))
  end

  @doc """
  Restore the run-wide default `:livekit_req_client` — the
  `LivekitStubPlug` client `test/test_helper.exs` arms at boot.

  Per-test LiveKit stubs used to end with
  `Application.delete_env(:platform, :livekit_req_client)` in `on_exit`.
  An ExUnit `on_exit` callback runs in its own process, concurrently with
  the NEXT test, so that delete could land between the next test's
  stub-arming and its LiveKit call: `Meetings.livekit_req_client/0` then
  fell through to the `:persistent_term` mirror, whose 200-with-empty-body
  answer parses as "no participants" — flipping the invite flash to the
  "does not see you" copy and failing
  `PlatformWeb.MeetingLiveAgentInviteTest` (seed 77, 2026-09-24 16:02Z
  sweep, task 01a0d265). Restoring the default client instead leaves the
  key never-absent, leaves no `Req.Test`-mode-dependent client behind for
  later callers, and is one assignment — a strictly smaller race window
  than delete + `set_req_test_to_private`.
  """
  def restore_default_req_client do
    Application.put_env(
      :platform,
      :livekit_req_client,
      :persistent_term.get(
        {:platform, :livekit_req_client_fallback},
        Req.new(plug: {__MODULE__, []}, retry: false)
      )
    )
  end
end
