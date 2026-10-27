defmodule PlatformWeb.TerminalRelayTest do
  @moduledoc """
  The remote terminal relay (task 01a17b17 stage 2): refusals, read-only
  default, audit rows, no persistence, no logging, and the crypto vectors the
  fake CLI shares with the real CLI.
  """
  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  import Platform.TenancyFixtures

  alias Phoenix.Socket.Message
  alias Platform.Agents.Agent
  alias Platform.Audit.Event
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Terminal.Audit, as: TerminalAudit
  alias PlatformWeb.TerminalFakeCli, as: Fake

  @vectors Path.expand("../../fixtures/terminal_crypto_v1.json", __DIR__)

  setup do
    owner = root_admin!()
    other = root_admin!()
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "term-agent-#{n}", name: "Term Agent", status: "active"})
      |> Repo.insert()

    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "term-rt-#{n}"})
    {:ok, active, token} = Federation.activate_runtime(runtime)
    {:ok, _} = Federation.link_agent(active, agent)
    on_exit(fn -> RuntimePresence.untrack("term-rt-#{n}") end)

    %{owner: owner, other: other, runtime_id: "term-rt-#{n}", token: token}
  end

  # ── helpers ──

  defp online!(ctx), do: RuntimePresence.track(ctx.runtime_id)

  defp join_cli(ctx) do
    {:ok, sock} =
      connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => ctx.runtime_id, "token" => ctx.token})

    {:ok, _, cli} = subscribe_and_join(sock, "terminal:" <> ctx.runtime_id, %{})
    cli
  end

  defp view_socket(user) do
    {:ok, sock} =
      connect(PlatformWeb.TerminalSocket, %{
        "token" => PlatformWeb.TerminalSocket.mint_token(user.id)
      })

    sock
  end

  defp join_view(ctx, user),
    do: subscribe_and_join(view_socket(user), "terminal_view:" <> ctx.runtime_id, %{})

  defp rows(user, like \\ "terminal.session.%") do
    Repo.all(
      from(e in Event,
        where: e.actor_id == ^user.id and like(e.event_type, ^like),
        order_by: e.id
      )
    )
  end

  defp types(user), do: user |> rows() |> Enum.map(& &1.event_type)

  # A message pushed to the CLI side or the view side. Both channels share the
  # test process as their transport, so tell them apart by topic.
  defp assert_cli_push(event, timeout \\ 500) do
    assert_receive %Message{topic: "terminal:" <> _, event: ^event, payload: payload}, timeout
    payload
  end

  defp assert_view_push(event, timeout \\ 500) do
    assert_receive %Message{topic: "terminal_view:" <> _, event: ^event, payload: payload},
                   timeout

    payload
  end

  defp refute_cli_push(event, timeout \\ 150) do
    refute_receive %Message{topic: "terminal:" <> _, event: ^event}, timeout
  end

  # Full handshake. Returns the browser-side keys.
  defp handshake(cli, view) do
    %{"session_id" => sid} = assert_cli_push("open")

    {fake, [{:push, "hello", cli_hello}]} =
      Fake.handle_event(Fake.new(), "open", %{"session_id" => sid})

    push(cli, "hello", cli_hello)
    %{"pub" => cli_pub} = assert_view_push("hello")

    browser = Fake.generate_keypair()

    {send_key, recv_key} =
      Fake.derive_keys(:browser, browser.private, Base.decode64!(cli_pub), sid)

    push(view, "hello", %{"pub" => Base.encode64(browser.public)})
    browser_hello = assert_cli_push("hello")
    {fake, actions} = Fake.handle_event(fake, "hello", browser_hello)
    fake = pump_out(cli, fake, actions)

    # first `out` is the kind-1 cwd record, then the ready banner
    {:ok, 0, <<1, cwd_json::binary>>} = Fake.open(recv_key, 1, bin!(assert_view_push("out")))
    assert %{"cwd" => _} = Jason.decode!(cwd_json)
    {:ok, 1, <<0, "fake-cli ready">>} = Fake.open(recv_key, 1, bin!(assert_view_push("out")))

    %{fake: fake, send_key: send_key, recv_key: recv_key, counter: 0, sid: sid}
  end

  defp leave_view(view) do
    Process.unlink(view.channel_pid)
    ref = Process.monitor(view.channel_pid)
    leave(view)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  defp bin!({:binary, b}), do: b

  defp pump_out(cli, fake, actions) do
    Enum.each(actions, fn
      {:push_binary, ev, b} -> push(cli, ev, {:binary, b})
      _ -> :ok
    end)

    fake
  end

  defp browser_in(hs, view, text) do
    frame = Fake.seal(hs.send_key, 2, hs.counter, <<0, text::binary>>)
    push(view, "in", {:binary, frame})
    %{hs | counter: hs.counter + 1}
  end

  # ── refusals ──

  test "a non-owner is refused forbidden: one refused row, zero opened rows", ctx do
    online!(ctx)
    join_cli(ctx)

    assert {:error, %{reason: "forbidden"}} = join_view(ctx, ctx.other)

    assert types(ctx.other) == ["terminal.session.refused"]
    assert [%{metadata: meta}] = rows(ctx.other)
    assert meta["reason"] == "forbidden"
    assert meta["runtime_id"] == ctx.runtime_id
    assert meta["actor_id"] == ctx.other.id
    assert rows(ctx.other, "terminal.session.opened") == []
    assert rows(ctx.owner, "terminal.session.opened") == []
  end

  test "an unknown runtime is forbidden too", ctx do
    {:error, %{reason: "forbidden"}} =
      subscribe_and_join(view_socket(ctx.owner), "terminal_view:no-such-runtime", %{})

    assert types(ctx.owner) == ["terminal.session.refused"]
  end

  test "flag off: runtime present, no terminal CLI -> flag_off", ctx do
    online!(ctx)
    assert {:error, %{reason: "flag_off"}} = join_view(ctx, ctx.owner)
    assert types(ctx.owner) == ["terminal.session.refused"]
    assert [%{metadata: %{"reason" => "flag_off"}}] = rows(ctx.owner)
  end

  test "offline: runtime not online -> offline, even with a terminal CLI joined", ctx do
    join_cli(ctx)

    refute RuntimePresence.online?(ctx.runtime_id),
           "joining the terminal topic must not mark presence"

    assert {:error, %{reason: "offline"}} = join_view(ctx, ctx.owner)
    assert types(ctx.owner) == ["terminal.session.refused"]
    assert [%{metadata: %{"reason" => "offline"}}] = rows(ctx.owner)
  end

  test "a bad or expired token cannot connect" do
    assert :error = connect(PlatformWeb.TerminalSocket, %{"token" => "junk"})
    assert :error = connect(PlatformWeb.TerminalSocket, %{})

    old = System.system_time(:second) - 61

    stale =
      Phoenix.Token.sign(PlatformWeb.Endpoint, "terminal socket v1", Ecto.UUID.generate(),
        signed_at: old
      )

    assert :error = connect(PlatformWeb.TerminalSocket, %{"token" => stale})
    assert PlatformWeb.TerminalSocket.max_age() == 60
  end

  test "the CLI can only join its own runtime's terminal topic", ctx do
    {:ok, sock} =
      connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => ctx.runtime_id, "token" => ctx.token})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(sock, "terminal:someone-else", %{})
  end

  # ── the session ──

  test "ro drops in frames; after mode rw they are delivered; mode_changed is audited", ctx do
    online!(ctx)
    cli = join_cli(ctx)
    {:ok, %{mode: "ro"}, view} = join_view(ctx, ctx.owner)
    hs = handshake(cli, view)

    hs = browser_in(hs, view, "ls\r")
    refute_cli_push("in")

    ref = push(view, "mode", %{"mode" => "rw"})
    assert_reply ref, :ok, %{mode: "rw"}
    assert %{"mode" => "rw"} = assert_cli_push("mode")

    browser_in(hs, view, "ls\r")

    assert %Message{payload: {:binary, frame}} =
             assert_receive(%Message{topic: "terminal:" <> _, event: "in"})

    {fake, actions} = Fake.handle_binary(hs.fake, "in", frame)
    assert {:print, "in frames received: 1"} in actions
    pump_out(cli, fake, actions)
    {:ok, _, <<0, "echo:ls\r">>} = Fake.open(hs.recv_key, 1, bin!(assert_view_push("out")))

    assert "terminal.session.mode_changed" in types(ctx.owner)
    assert [%{metadata: %{"mode" => "rw"}}] = rows(ctx.owner, "terminal.session.mode_changed")
  end

  test "open and close audit rows exist and their metadata is within the allowlist", ctx do
    online!(ctx)
    cli = join_cli(ctx)
    {:ok, _, view} = join_view(ctx, ctx.owner)
    _hs = handshake(cli, view)

    leave_view(view)

    assert types(ctx.owner) == ["terminal.session.opened", "terminal.session.closed"]
    allowed = Enum.map(TerminalAudit.allowed_keys(), &Atom.to_string/1)

    for e <- rows(ctx.owner) do
      assert Enum.all?(Map.keys(e.metadata), &(&1 in allowed)),
             "unexpected keys in #{inspect(e.metadata)}"
    end

    [opened, closed] = rows(ctx.owner)
    assert opened.metadata["mode"] == "ro"
    assert closed.metadata["mode"] == "ro"
    assert is_binary(closed.metadata["opened_at"]) and is_binary(closed.metadata["closed_at"])
    # leaving tells the CLI to detach
    assert_cli_push("detach")
  end

  test "a CLI drop closes the session once", ctx do
    online!(ctx)
    cli = join_cli(ctx)
    {:ok, _, view} = join_view(ctx, ctx.owner)
    _ = handshake(cli, view)

    ref = Process.monitor(view.channel_pid)
    Process.unlink(cli.channel_pid)
    GenServer.stop(cli.channel_pid, :shutdown)
    assert %{"reason" => "cli_gone"} = assert_view_push("closed")
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert types(ctx.owner) == ["terminal.session.opened", "terminal.session.closed"]
  end

  # ── no persistence, no logging ──

  def count_insert(_event, _measure, %{query: query}, pid) do
    if String.starts_with?(query, "INSERT"), do: send(pid, {:insert, query})
  end

  test "a 100-frame session inserts nothing but audit events", ctx do
    online!(ctx)
    cli = join_cli(ctx)
    {:ok, _, view} = join_view(ctx, ctx.owner)
    hs = handshake(cli, view)
    push(view, "mode", %{"mode" => "rw"})
    assert_cli_push("mode")

    id = "terminal-insert-count-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, [:platform, :repo, :query], &__MODULE__.count_insert/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    hs =
      Enum.reduce(1..100, hs, fn i, acc ->
        push(cli, "out", {:binary, "frame-#{i}"})
        assert_view_push("out")
        acc = browser_in(acc, view, "k#{i}")
        assert_cli_push("in")
        acc
      end)

    assert hs.counter == 100
    leave_view(view)

    inserts = drain_inserts([])

    assert inserts != [],
           "the closed audit row should have been counted: the handler is not vacuous"

    assert Enum.all?(inserts, &String.contains?(&1, ~s("audit_events"))), inspect(inserts)
    assert length(inserts) == 1
  end

  defp drain_inserts(acc) do
    receive do
      {:insert, q} -> drain_inserts([q | acc])
    after
      100 -> acc
    end
  end

  test "nothing logs a frame at :debug, raw or Base64", ctx do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)

    online!(ctx)
    canary = "CANARY-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    log =
      capture_log([level: :debug], fn ->
        require Logger
        Logger.debug("debug-marker")
        cli = join_cli(ctx)
        {:ok, _, view} = join_view(ctx, ctx.owner)
        hs = handshake(cli, view)
        push(view, "mode", %{"mode" => "rw"})
        assert_cli_push("mode")

        Enum.reduce(1..100, hs, fn _i, acc ->
          push(cli, "out", {:binary, canary})
          assert_view_push("out")
          acc = browser_in(acc, view, canary)
          assert_cli_push("in")
          acc
        end)

        push(view, "in", {:binary, canary})
        push(cli, "out", {:binary, canary})
        Process.sleep(50)
        leave_view(view)
      end)

    refute log =~ canary
    refute log =~ Base.encode64(canary)
    refute log =~ Base.encode64(canary, padding: false)
    refute log =~ Base.url_encode64(canary)
    # not vacuous: the capture runs at :debug and sees this session's own work
    assert log =~ "debug-marker"
  end

  # ── the shared vectors ──

  test "the fake CLI reproduces the shared protocol vectors" do
    v = @vectors |> File.read!() |> Jason.decode!()
    hex = fn s -> Base.decode16!(s, case: :lower) end

    assert Fake.public_of(hex.(v["cli_private_hex"])) == hex.(v["cli_public_hex"])
    assert Fake.public_of(hex.(v["browser_private_hex"])) == hex.(v["browser_public_hex"])

    {c_send, c_recv} =
      Fake.derive_keys(
        :cli,
        hex.(v["cli_private_hex"]),
        hex.(v["browser_public_hex"]),
        v["session_id"]
      )

    {b_send, b_recv} =
      Fake.derive_keys(
        :browser,
        hex.(v["browser_private_hex"]),
        hex.(v["cli_public_hex"]),
        v["session_id"]
      )

    assert c_send == hex.(v["key_cli_to_browser_hex"])
    assert c_recv == hex.(v["key_browser_to_cli_hex"])
    assert b_send == c_recv and b_recv == c_send

    # `plaintext_hex` is the body; the sealed plaintext is `kind || body`.
    for f <- v["out_frames"] do
      plain = <<f["kind"], hex.(f["plaintext_hex"])::binary>>

      assert Fake.seal(c_send, v["direction_ids"]["cli_to_browser"], f["counter"], plain) ==
               hex.(f["frame_hex"])

      assert {:ok, c, ^plain} = Fake.open(b_recv, 1, hex.(f["frame_hex"]))
      assert c == f["counter"]
    end

    for f <- v["in_frames"] do
      plain = <<f["kind"], hex.(f["plaintext_hex"])::binary>>

      assert Fake.seal(b_send, v["direction_ids"]["browser_to_cli"], f["counter"], plain) ==
               hex.(f["frame_hex"])

      assert {:ok, _, ^plain} = Fake.open(c_recv, 2, hex.(f["frame_hex"]))
    end

    # a flipped bit does not open
    [f | _] = v["out_frames"]
    <<head::binary-size(10), b, rest::binary>> = hex.(f["frame_hex"])
    assert :error = Fake.open(b_recv, 1, <<head::binary, Bitwise.bxor(b, 1), rest::binary>>)
  end
end
