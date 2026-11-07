defmodule PlatformWeb.ConnectAiClaudeLoginLeakTest.Sink do
  @moduledoc false
  # Collects everything a leak could land in that is not a log line or a
  # process's state: every message on the PubSub topics it is told to watch,
  # and the metadata of the telemetry events the test attaches to it.
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

  @doc "Subscribe the sink to `topic` (synchronous, so nothing is missed)."
  def watch(sink, topic), do: GenServer.call(sink, {:watch, topic})

  @doc "Every `{topic | :telemetry, message}` the sink has received, oldest first."
  def received(sink), do: GenServer.call(sink, :received)

  @doc false
  def handle_telemetry(event, _measurements, metadata, sink),
    do: send(sink, {:telemetry_event, event, metadata})

  @impl true
  def init(:ok), do: {:ok, %{topics: [], got: []}}

  @impl true
  def handle_call({:watch, topic}, _from, s) do
    if topic in s.topics do
      {:reply, :ok, s}
    else
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, topic)
      {:reply, :ok, %{s | topics: [topic | s.topics]}}
    end
  end

  def handle_call(:received, _from, s), do: {:reply, Enum.reverse(s.got), s}

  @impl true
  def handle_info({:telemetry_event, event, metadata}, s),
    do: {:noreply, %{s | got: [{{:telemetry, event}, metadata} | s.got]}}

  def handle_info(msg, s), do: {:noreply, %{s | got: [{:pubsub, msg} | s.got]}}
end

defmodule PlatformWeb.ConnectAiClaudeLoginLeakTest.RecordingHost do
  @moduledoc false
  # A stand-in agent host that joins the real reconciler and answers the
  # Claude login like the dev stand-in (`Platform.AgentHost.FakeHost`), but
  # accepts the test's own sentinel code, hands out a sign-in URL carrying the
  # test's positive-control value, and keeps a record of every push it
  # received. That record is the one place the code may reach. Before it
  # answers a ref'd login push it has the sink watch that ref's reply topic.
  use GenServer

  alias Platform.AgentHost
  alias Platform.AgentHost.{LoginCode, Reconciler, State}
  alias PlatformWeb.ConnectAiClaudeLoginLeakTest.Sink

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Every `{event, payload}` pushed to this host, oldest first."
  def received(host), do: GenServer.call(host, :received)

  @doc """
  The reconciler's process state and the agent host state table, flattened,
  as they stood when the code arrived here: the login pending, mid-flight.
  """
  def midflight(host), do: GenServer.call(host, :midflight)

  @doc false
  def agent_host_state_text do
    inspect({:sys.get_state(Reconciler), :ets.tab2list(State.table())},
      limit: :infinity,
      printable_limit: :infinity,
      structs: false
    )
  end

  @impl true
  def init(opts) do
    :ok = Reconciler.host_joined(self(), %{"profile" => "fake"})
    :ok = Reconciler.inventory(self(), %{"profile" => "fake", "agents" => []})

    {:ok,
     %{
       code: Keyword.fetch!(opts, :code),
       url: Keyword.fetch!(opts, :url),
       sink: Keyword.fetch!(opts, :sink),
       detail: Keyword.fetch!(opts, :detail),
       midflight: nil,
       got: []
     }}
  end

  @impl true
  def handle_call(:received, _from, s), do: {:reply, Enum.reverse(s.got), s}
  def handle_call(:midflight, _from, s), do: {:reply, s.midflight, s}

  @impl true
  def handle_info({:agent_host_push, event, payload}, s) do
    s = %{s | got: [{event, payload} | s.got]}
    {:noreply, answer(event, payload, s)}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp answer(event, %{"agent_id" => id}, s) when event in ["agent.start", "agent.restart"] do
    report(%{
      "agent_id" => id,
      "state" => "needs_login",
      "detail" => s.detail,
      "login" => %{"step" => "login"}
    })

    s
  end

  defp answer("agent.stop", %{"agent_id" => id}, s) do
    report(%{"agent_id" => id, "state" => "stopped"})
    s
  end

  defp answer("agent.claude_login_start", %{"agent_id" => id, "ref" => ref}, s) do
    reply(s, id, ref, %{"result" => "url", "url" => s.url})
  end

  defp answer("agent.claude_login_code", %{"agent_id" => id, "ref" => ref} = payload, s) do
    s = %{s | midflight: agent_host_state_text()}

    case payload["code"] do
      %LoginCode{} = code ->
        if LoginCode.reveal(code) == s.code do
          reply(s, id, ref, %{"result" => "ok", "account" => "owner@example.com", "plan" => "max"})

          report(%{"agent_id" => id, "state" => "running"})
          s
        else
          reply(s, id, ref, %{"result" => "bad_code"})
        end

      _ ->
        reply(s, id, ref, %{"result" => "bad_code"})
    end
  end

  defp answer("agent.claude_logout", %{"agent_id" => id, "ref" => ref}, s),
    do: reply(s, id, ref, %{"result" => "ok"})

  defp answer(_event, _payload, s), do: s

  defp reply(s, id, ref, result) do
    :ok = Sink.watch(s.sink, AgentHost.reply_topic(ref))

    # Through the real channel handler's sanitising, as the host's reply would be.
    PlatformWeb.AgentHostChannel.handle_in(
      "agent.claude_login",
      Map.merge(%{"ref" => ref, "agent_id" => id}, result),
      %Phoenix.Socket{}
    )

    s
  end

  defp report(payload), do: Reconciler.agent_state(self(), payload)
end

defmodule PlatformWeb.ConnectAiClaudeLoginLeakTest do
  @moduledoc """
  The whole Connect AI Claude path, scanned for the pasted code (task
  01a1b365 stage 4).

  It drives `/setup/connect-ai` end to end against a stand-in agent host with
  a unique sentinel code, then scans every sink the code could reach:

    * logs: `capture_log` at `:debug` around the whole flow;
    * the LiveView: `:sys.get_state` of the view (socket assigns, temporary
      ones included, structs flattened so a `LoginCode`'s redacted Inspect
      cannot hide one) and the rendered HTML; the reconciler's state too;
    * PubSub and events: the agent host status topic, every login reply
      topic, the agent's runtime topics, and the metadata of
      `[:phoenix, :live_view, :handle_event, :stop]` and
      `[:phoenix, :channel_handled_in]`;
    * the database: every text, varchar, array, json(b) and bytea column of
      every table in the schema (bytea also for the sentinel's SHA-256, the
      shape a hashed token takes).

  The stand-in host's own record of what it received is the one allowed
  destination: it must hold the code, which also proves the code went all
  the way through.

  Positive control: a second sentinel of the same shape is put, by the same
  flow, into a normal non-secret field that reaches each sink: the logged
  name of a refused event, the sign-in URL the page assigns and renders, the
  reply broadcast, a broadcast on each watched topic, a telemetry event, and
  a text, a jsonb and a bytea row. The SAME scanner must find it in every
  sink, so a green scan is not a blind one.

  Mutants this names: broadcast the code on the status topic in
  `AgentHost.claude_login_submit/4` -> the pubsub scan; `Logger.info` the
  code in the submit path -> the log scan; drop a positive-control injection
  -> that sink's control.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.AgentHost.{LoginCode, Reconciler}
  alias Platform.Agents.{Agent, Burrow}
  alias Platform.Repo
  alias Platform.VaultFixtures
  alias PlatformWeb.ConnectAiClaudeLoginLeakTest.{RecordingHost, Sink}

  @telemetry_events [
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :channel_handled_in]
  ]

  # Both sentinels share one shape: a fixed prefix and 32 random hex digits,
  # inside the code shape `LoginCode.new/1` accepts and safe in a URL.
  defp sentinel(prefix),
    do: prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  # The one scanner every sink goes through: the raw value, its URL and
  # form encodings, and its Base64.
  defp forms(value),
    do: Enum.uniq([value, URI.encode_www_form(value), URI.encode(value), Base.encode64(value)])

  defp found?(text, value) when is_binary(text),
    do: Enum.any?(forms(value), &String.contains?(text, &1))

  defp submit_params_dropped(%{event: "claude_submit"} = meta), do: Map.delete(meta, :params)
  defp submit_params_dropped(meta), do: meta

  defp flat(term),
    do: inspect(term, limit: :infinity, printable_limit: :infinity, structs: false)

  # Every scanned DB column holding `value`, as "table.column".
  defp db_hits(value) do
    %{rows: columns} =
      Repo.query!("""
      SELECT table_name, column_name, data_type
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND data_type IN ('text', 'character varying', 'character', 'json', 'jsonb', 'ARRAY', 'bytea', 'USER-DEFINED')
        AND table_name IN (SELECT table_name FROM information_schema.tables
                           WHERE table_schema = current_schema() AND table_type = 'BASE TABLE')
      ORDER BY table_name, column_name
      """)

    assert length(columns) > 100, "the column scan found only #{length(columns)} columns"

    patterns = Enum.map(forms(value), &("%" <> &1 <> "%"))
    digest = :crypto.hash(:sha256, value)

    for [table, column, type] <- columns,
        hit?(table, column, type, value, digest, patterns),
        do: "#{table}.#{column}"
  end

  defp hit?(table, column, "bytea", value, digest, _patterns) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s{SELECT count(*) FROM "#{table}" WHERE position($1::bytea in "#{column}") > 0 OR position($2::bytea in "#{column}") > 0},
        [value, digest]
      )

    n > 0
  end

  defp hit?(table, column, _type, _value, _digest, patterns) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s{SELECT count(*) FROM "#{table}" WHERE "#{column}"::text LIKE ANY($1)},
        [patterns]
      )

    n > 0
  end

  setup %{conn: conn} do
    code = sentinel("sntl")
    control = sentinel("sntl")
    url = "https://claude.com/cai/oauth/authorize?code=true&state=" <> control

    sink = start_supervised!(Sink)
    :ok = Sink.watch(sink, Reconciler.status_topic())

    host =
      start_supervised!({RecordingHost, code: code, url: url, sink: sink, detail: control})

    assert_eventually(fn -> Reconciler.host_pid() == host end, 3_000)

    handler = "connect-ai-claude-leak-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler, @telemetry_events, &Sink.handle_telemetry/4, sink)

    previous_level = Logger.level()

    on_exit(fn ->
      :telemetry.detach(handler)
      Logger.configure(level: previous_level)
    end)

    admin = VaultFixtures.admin!()

    %{
      conn: Plug.Test.init_test_session(conn, %{"current_user_id" => admin.id}),
      admin: admin,
      code: code,
      control: control,
      sink: sink,
      host: host,
      handler: handler
    }
  end

  test "the pasted code reaches the agent host and nothing else: logs, LiveView, PubSub, telemetry, database",
       %{
         conn: conn,
         admin: admin,
         code: code,
         control: control,
         sink: sink,
         host: host,
         handler: handler
       } do
    level = Logger.level()
    Logger.configure(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")

        view
        |> form("#connect-ai-options")
        |> render_change(%{"provider" => "claude_subscription"})

        assert_eventually(fn -> has_element?(view, "a#connect-ai-claude-open") end, 3_000)
        agent = Burrow.get()
        assert Burrow.harness(agent) == "claude_code"

        # The agent's runtime topics, watched before the code is sent.
        runtime_topics =
          ["agents:runtime:#{agent.id}", "agent:#{agent.id}"] ++
            if(agent.runtime_id, do: ["runtime:#{agent.runtime_id}"], else: [])

        Enum.each(runtime_topics, &(:ok = Sink.watch(sink, &1)))

        view |> element("a#connect-ai-claude-open") |> render_click()

        html =
          view
          |> form("#connect-ai-claude-form", %{"code" => code})
          |> render_submit()

        assert html =~ "Connecting…"
        state_at_submit = flat(:sys.get_state(view.pid))

        assert_eventually(
          fn ->
            has_element?(view, "#connect-ai-claude-connected", "Connected as owner@example.com")
          end,
          3_000
        )

        # Positive control, through the same flow: an unknown event's NAME is
        # logged by the page's catch-all and reaches handle_event telemetry.
        render_hook(view, control, %{})

        # A broadcast of the control on every watched topic, and an event
        # carrying it through the channel telemetry handler.
        for topic <- [Reconciler.status_topic() | runtime_topics],
            do: Phoenix.PubSub.broadcast(Platform.PubSub, topic, {:leak_control, control})

        # Shaped like the event Phoenix.Channel.Server emits, so Phoenix.Logger's

        # own handler takes it (an ill-shaped one raises there and :telemetry

        # detaches that handler VM-wide).

        :telemetry.execute([:phoenix, :channel_handled_in], %{duration: 0}, %{
          socket: %Phoenix.Socket{
            topic: "agent_host:control",
            channel: PlatformWeb.AgentHostChannel,
            private: %{log_handle_in: :debug}
          },
          event: control,
          params: %{},
          ref: nil
        })

        # A text, a jsonb and a bytea row.
        {1, _} =
          Repo.update_all(
            from(a in Agent, where: a.id == ^agent.id),
            set: [name: "Assistant " <> control, metadata: %{"note" => control}]
          )

        Repo.query!(
          """
          INSERT INTO calendar_subscriptions (id, owner_id, name, url, inserted_at, updated_at)
          VALUES ($1, $2, 'leak control', $3, now(), now())
          """,
          [Ecto.UUID.bingenerate(), Ecto.UUID.dump!(admin.id), control]
        )

        send(self(), {:flow, view, html, state_at_submit})
      end)

    Logger.configure(level: level)
    assert_received {:flow, view, html_at_submit, state_at_submit}

    # The one allowed destination holds the code, so it went all the way.
    pushes = RecordingHost.received(host)

    assert [%LoginCode{} = sent] =
             for({"agent.claude_login_code", %{"code" => c}} <- pushes, do: c)

    assert LoginCode.reveal(sent) == code

    # Every sink, the code then the control, through the same scanner.
    sinks = %{
      log: log,
      # At submit (Connecting…) and at the end (connected).
      view_state: state_at_submit <> flat(:sys.get_state(view.pid)),
      rendered_html: html_at_submit <> render(view),
      # The reconciler's state and the agent host state table, mid-flight
      # (the login pending, the code at the host) and at the end.
      agent_host_state: RecordingHost.midflight(host) <> RecordingHost.agent_host_state_text(),
      pubsub: flat(for {:pubsub, msg} <- Sink.received(sink), do: msg),
      # Every telemetry event's metadata, less the one carrier LiveView
      # owns (see "the submit event's own params" below).
      telemetry:
        flat(
          for {{:telemetry, event}, meta} <- Sink.received(sink),
              do: {event, submit_params_dropped(meta)}
        )
    }

    leaks = for {name, text} <- sinks, found?(text, code), do: name
    assert leaks == [], "the code reached #{inspect(leaks)}"

    blind = for {name, text} <- sinks, not found?(text, control), do: name
    assert blind == [], "the positive control was not found in #{inspect(blind)}"

    # The log's control came by the page's own path: the catch-all logged the
    # refused event's name.
    assert log =~ ~s(refused unknown event "#{control}")

    # Each watched topic and telemetry event carried the control.
    received = Sink.received(sink)

    for event <- @telemetry_events do
      assert Enum.any?(received, fn
               {{:telemetry, ^event}, meta} -> found?(flat(meta), control)
               _ -> false
             end),
             "no #{inspect(event)} telemetry carried the control"
    end

    # The reply topic got the URL (the control) on its own, not by injection.
    assert Enum.any?(received, fn
             {:pubsub, {:agent_host_claude_login, _ref, %{"url" => url}}} ->
               found?(url, control)

             _ ->
               false
           end)

    # The submit event's own params. LiveView puts an event's raw params in
    # its `[:phoenix, :live_view, :handle_event, :stop]` metadata, and a
    # phx-submit field reaches the server no other way, so the code is there,
    # in exactly that one place, for the length of the synchronous handler
    # calls. What may read it is pinned: Phoenix's own loggers (their output
    # is the log sink above, at :debug) and this test's handler.
    assert [%{"code" => ^code}] =
             for(
               {{:telemetry, [:phoenix, :live_view, :handle_event, :stop]},
                %{event: "claude_submit", params: params}} <- received,
               do: params
             )

    expected_readers = %{
      [:phoenix, :live_view, :handle_event, :stop] => [
        {Phoenix.LiveView.Logger, [:phoenix, :live_view, :handle_event, :stop]}
      ],
      [:phoenix, :channel_handled_in] => [{Phoenix.Logger, [:phoenix, :channel_handled_in]}]
    }

    for event <- @telemetry_events do
      ids = for(%{id: id} <- :telemetry.list_handlers(event), do: id) -- [handler]

      assert ids == Map.fetch!(expected_readers, event),
             "a new handler reads #{inspect(event)}, and so the submitted code: #{inspect(ids)}"
    end

    # The database.
    assert db_hits(code) == []

    control_hits = db_hits(control)
    assert "agents.name" in control_hits
    assert "agents.metadata" in control_hits
    assert "calendar_subscriptions.url" in control_hits
  end
end
