defmodule Platform.GameStream.TurnTest do
  @moduledoc """
  TURN for game streams (task 01a0db5f stage 5): `GameStream.ice_servers/0`
  with the TURN config set and unset, the boot-time read of
  `GAME_STREAM_TURN_CREDENTIAL_FILE` by `Platform.GameStream.RuntimeConfig`,
  and the credential staying out of every log this code can write.

  The boot-read cases call `RuntimeConfig.read/1` on the real OS environment,
  the function `Platform.GameStream.Application.start/2` calls, so they prove
  the boot read, not a copy of it. (Until task 01a0ee08 stage 3 the read was a
  block of core's `config/runtime.exs`, evaluated here with `Config.Reader`.)
  NOT async: they set OS env vars and `:game_stream, :turn` /
  `:game_stream, :enabled` (global state).

  ## Every "never logged" refute has a positive control

  A `refute log =~ secret` passes on an empty log. Each such case also
  asserts that the log it searched holds the event it is about (the stderr
  line, the crash report), so the refute is over a log that was written.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Phoenix.Socket.Broadcast
  alias Platform.Accounts.User
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.GameStream
  alias Platform.Repo
  alias Platform.Tasks

  @env ~w(GAME_STREAM_TURN_URLS GAME_STREAM_TURN_USERNAME GAME_STREAM_TURN_CREDENTIAL_FILE)
  @sha "0123456789abcdef0123456789abcdef01234567"

  defmodule StubRunner do
    @moduledoc false
    def branch_head_sha(_args), do: {:ok, "0123456789abcdef0123456789abcdef01234567"}
  end

  defmodule Forward do
    @moduledoc false
    # A :logger handler that hands every event to the test process.
    def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
  end

  setup do
    saved_env = Map.new(@env, &{&1, System.get_env(&1)})
    saved_turn = Application.get_env(:game_stream, :turn)
    saved_flag = Application.get_env(:game_stream, :enabled)

    on_exit(fn ->
      for {k, v} <- saved_env, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      restore(:turn, saved_turn)
      restore(:enabled, saved_flag)

      sup = Platform.GameStream.Supervisor.sessions()

      for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        DynamicSupervisor.terminate_child(sup, pid)
      end
    end)

    Enum.each(@env, &System.delete_env/1)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:game_stream, key)
  defp restore(key, value), do: Application.put_env(:game_stream, key, value)

  # A distinctive credential, so a substring hit cannot be a coincidence.
  defp secret, do: "gs-turn-secret-" <> Base.encode16(:crypto.strong_rand_bytes(12))

  defp credential_file!(body) do
    path =
      Path.join(System.tmp_dir!(), "gs-turn-#{System.unique_integer([:positive])}.credential")

    File.write!(path, body)
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Runs the boot read over the real OS environment and returns its :turn
  # keyword, with everything it wrote to stderr and to the Logger.
  defp read_boot_config do
    parent = self()

    log =
      capture_log(fn ->
        stderr =
          capture_io(:stderr, fn ->
            config = Platform.GameStream.RuntimeConfig.read(System.get_env())
            send(parent, {:turn, Keyword.fetch!(config, :turn)})
          end)

        send(parent, {:stderr, stderr})
      end)

    assert_received {:turn, turn}
    assert_received {:stderr, stderr}
    {turn, stderr, log}
  end

  describe "ice_servers/0" do
    test "unset: [] — no STUN, no TURN, host candidates only" do
      Application.delete_env(:game_stream, :turn)
      assert GameStream.ice_servers() == []

      Application.put_env(:game_stream, :turn, urls: [], username: nil, credential: nil)
      assert GameStream.ice_servers() == []
    end

    test "any one of the three missing is still []" do
      full = [urls: ["turn:turn.example:3479?transport=udp"], username: "gs", credential: "c"]

      for key <- [:urls, :username, :credential], empty <- [nil, "", []] do
        Application.put_env(:game_stream, :turn, Keyword.put(full, key, empty))
        assert GameStream.ice_servers() == [], "#{key}=#{inspect(empty)}"
      end
    end

    test "set: one RTCIceServer with every url, the username and the credential" do
      urls = ["turn:turn.example:3479?transport=udp", "turn:192.0.2.234:3479?transport=tcp"]

      Application.put_env(:game_stream, :turn,
        urls: urls,
        username: "gs",
        credential: "c"
      )

      assert GameStream.ice_servers() == [%{urls: urls, username: "gs", credential: "c"}]
    end
  end

  describe "the boot read (RuntimeConfig.read/1)" do
    test "with no TURN env the config is empty and ice_servers/0 is []" do
      {turn, stderr, _log} = read_boot_config()
      assert turn == [urls: [], username: nil, credential: nil]
      refute stderr =~ "GAME_STREAM_TURN"

      Application.put_env(:game_stream, :turn, turn)
      assert GameStream.ice_servers() == []
    end

    test "reads the credential FILE at boot and writes it to no log" do
      s = secret()
      System.put_env("GAME_STREAM_TURN_URLS", " turn:a.example:3479 , turn:b.example:3479,,")
      System.put_env("GAME_STREAM_TURN_USERNAME", "game_stream")
      System.put_env("GAME_STREAM_TURN_CREDENTIAL_FILE", credential_file!(s <> "\n"))

      {turn, stderr, log} = read_boot_config()

      assert turn[:urls] == ["turn:a.example:3479", "turn:b.example:3479"]
      assert turn[:username] == "game_stream"
      # Trimmed: the trailing newline a shell `echo >` leaves is not part of it.
      assert turn[:credential] == s
      refute stderr =~ s
      refute log =~ s

      Application.put_env(:game_stream, :turn, turn)

      assert [%{urls: ["turn:a.example:3479", "turn:b.example:3479"], credential: ^s}] =
               GameStream.ice_servers()
    end

    test "an unreadable file turns TURN off and names the path, never a body" do
      missing = Path.join(System.tmp_dir!(), "gs-turn-missing-#{System.unique_integer()}")
      System.put_env("GAME_STREAM_TURN_URLS", "turn:a.example:3479")
      System.put_env("GAME_STREAM_TURN_USERNAME", "game_stream")
      System.put_env("GAME_STREAM_TURN_CREDENTIAL_FILE", missing)

      {turn, stderr, _log} = read_boot_config()

      assert turn[:credential] == nil
      # Positive control: the failure IS reported.
      assert stderr =~ "GAME_STREAM_TURN_CREDENTIAL_FILE #{missing} unreadable"

      Application.put_env(:game_stream, :turn, turn)
      assert GameStream.ice_servers() == []
    end
  end

  describe "a session" do
    setup do
      Application.put_env(:game_stream, :enabled, true)
      s = secret()

      Application.put_env(:game_stream, :turn,
        urls: ["turn:turn.example:3479?transport=udp"],
        username: "game_stream",
        credential: s
      )

      user =
        Repo.insert!(%User{
          email: "gs-turn-#{System.unique_integer([:positive])}@example.com",
          name: "GS",
          oidc_sub: "gs-turn-#{System.unique_integer([:positive])}"
        })

      runtime_id = "play-host-#{System.unique_integer([:positive])}"

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: runtime_id,
          allowed_bundles: [],
          metadata: %{"client_info" => %{"features" => ["game_stream_host"]}}
        })

      {:ok, _runtime, _token} = Federation.activate_runtime(runtime)
      RuntimePresence.track(runtime_id)
      on_exit(fn -> RuntimePresence.untrack(runtime_id) end)
      :ok = PlatformWeb.Endpoint.subscribe("runtime:" <> runtime_id)

      {:ok, project} =
        Tasks.create_project(%{
          name: "Voltron #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/rowanellis/voltron"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Relay"})
      task = task |> Ecto.Changeset.change(status: "in_review") |> Repo.update!()

      %{secret: s, task: task}
    end

    test "play_session_start carries the TURN server to the host", ctx do
      assert {:ok, status} = GameStream.start_session(ctx.task.id, runner: StubRunner)
      assert status.force_relay == false

      assert_receive %Broadcast{event: "play_session_start", payload: payload}
      assert payload.sha == @sha

      assert payload.ice_servers == [
               %{
                 urls: ["turn:turn.example:3479?transport=udp"],
                 username: "game_stream",
                 credential: ctx.secret
               }
             ]
    end

    test "force_relay is recorded on the session; the default is false", ctx do
      assert {:ok, status} =
               GameStream.start_session(ctx.task.id, runner: StubRunner, force_relay: true)

      assert status.force_relay == true
      assert GameStream.ice_transport_policy(status) == "relay"
      assert GameStream.ice_transport_policy(%{force_relay: false}) == "all"
      assert GameStream.ice_transport_policy(%{}) == "all"
    end

    test "a session crash report and :sys.get_status redact the credential", ctx do
      assert {:ok, status} = GameStream.start_session(ctx.task.id, runner: StubRunner)
      [{pid, _}] = Registry.lookup(Platform.GameStream.Registry, {:session, status.session_id})

      refute inspect(:sys.get_status(pid)) =~ ctx.secret
      # Positive control: the state really holds it, so the redaction is doing work.
      assert inspect(:sys.get_state(pid)) =~ ctx.secret

      # The formatted console line omits the state; the RAW report every
      # :logger handler receives carries it. Read that.
      handler = :"gs_turn_#{System.unique_integer([:positive])}"
      :ok = :logger.add_handler(handler, __MODULE__.Forward, %{config: %{pid: self()}})
      on_exit(fn -> :logger.remove_handler(handler) end)
      ref = Process.monitor(pid)

      log =
        capture_log([level: :error], fn ->
          # `use GenServer`'s default handle_cast raises: a real crash report.
          GenServer.cast(pid, :not_a_session_message)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
        end)

      :logger.remove_handler(handler)

      assert_receive {:log_event,
                      %{msg: {:report, %{label: {:gen_server, :terminate}} = report}}},
                     2_000

      # Positive control: the report was written and carries the state.
      assert log =~ "terminating"
      assert %{ice_servers: [%{credential: :redacted, username: "game_stream"}]} = report.state
      refute inspect(report, limit: :infinity, printable_limit: :infinity) =~ ctx.secret
      refute log =~ ctx.secret
    end
  end
end
