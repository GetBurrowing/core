defmodule PlatformWeb.ConnectAiPanelLeakTest.Sink do
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

defmodule PlatformWeb.ConnectAiPanelLeakTest.RecordingHost do
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
  alias PlatformWeb.ConnectAiPanelLeakTest.Sink

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

defmodule PlatformWeb.ConnectAiPanelLeakTest do
  @moduledoc """
  The per-agent Connect AI panel's Claude path, scanned for the pasted code
  (task 01a1b84b stage 1): the sibling of `ConnectAiClaudeLoginLeakTest`, for
  a NON-Burrow agent the character builder made and the panel adopted.

  It drives `PlatformWeb.ConnectAi.Panel` end to end, hosted the way the
  builder step and the agent page host it (`PlatformWeb.ConnectAiPanelHostLive`),
  against a stand-in host with a unique sentinel code, then scans every sink:

    * logs: `capture_log` at `:debug` around the whole flow;
    * the LiveView process (the panel's state lives there), flattened, and the
      rendered HTML; the reconciler's state too;
    * PubSub and events: the agent host status topic, every login reply topic,
      the agent's runtime topics, and the metadata of
      `[:phoenix, :live_view, :handle_event, :stop]`,
      `[:phoenix, :live_component, :handle_event, :stop]` (the panel's own
      events) and `[:phoenix, :channel_handled_in]`;
    * the database: every text, varchar, array, json(b) and bytea column.

  The stand-in host's record is the one allowed destination. A positive
  control of the same shape is put through the same flow into each sink, and
  the same scanner must find it there.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.AgentHost.{LoginCode, Reconciler}
  alias Platform.Agents.{Agent, Character, NativeAgents}
  alias Platform.Repo
  alias Platform.VaultFixtures
  alias PlatformWeb.ConnectAiPanelHostLive
  alias PlatformWeb.ConnectAiPanelLeakTest.{RecordingHost, Sink}

  @telemetry_events [
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_component, :handle_event, :stop],
    [:phoenix, :channel_handled_in]
  ]

  defp sentinel(prefix),
    do: prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp forms(value),
    do: Enum.uniq([value, URI.encode_www_form(value), URI.encode(value), Base.encode64(value)])

  defp found?(text, value) when is_binary(text),
    do: Enum.any?(forms(value), &String.contains?(text, &1))

  # The submit event's own params, the one carrier LiveView owns (see the
  # end of the test), dropped from the scan; only for claude_submit.
  defp submit_params_dropped(%{event: "claude_submit"} = meta), do: Map.delete(meta, :params)
  defp submit_params_dropped(meta), do: meta

  defp flat(term),
    do: inspect(term, limit: :infinity, printable_limit: :infinity, structs: false)

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

  defp character!(creator) do
    b =
      Character.new("scout")
      |> Map.merge(%{
        n: "Tester #{System.unique_integer([:positive])}",
        color: "indigo",
        portrait: "fox",
        sl: %{"chatty" => 20, "bold" => 80, "playful" => 10, "collab" => 90},
        traits: ["skeptic", "tidy", "night owl"],
        vc: %{p: 3, ov: %{"emoji" => 1}, q: "pr", free: nil}
      })

    {:ok, %{agent: agent}} = Character.create(b, creator)
    agent
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

    handler = "connect-ai-panel-leak-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler, @telemetry_events, &Sink.handle_telemetry/4, sink)

    previous_level = Logger.level()

    on_exit(fn ->
      :telemetry.detach(handler)
      Logger.configure(level: previous_level)
    end)

    owner = VaultFixtures.admin!()

    %{
      conn: conn,
      owner: owner,
      agent: character!(owner),
      code: code,
      control: control,
      sink: sink,
      host: host,
      handler: handler
    }
  end

  test "the pasted code reaches the agent host and nothing else, for an adopted builder agent",
       %{
         conn: conn,
         owner: owner,
         agent: agent,
         code: code,
         control: control,
         sink: sink,
         host: host,
         handler: handler
       } do
    refute NativeAgents.managed?(Repo.reload!(agent))
    level = Logger.level()
    Logger.configure(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        {:ok, view, _html} =
          live_isolated(conn, ConnectAiPanelHostLive,
            session: %{"agent_id" => agent.id, "user_id" => owner.id}
          )

        view
        |> form("#agent-ai-options")
        |> render_change(%{"provider" => "claude_subscription"})

        assert_eventually(fn -> has_element?(view, "a#agent-ai-claude-open") end, 3_000)
        assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).harness == "claude_code"
        agent = Repo.reload!(agent)

        runtime_topics = [
          "agents:runtime:#{agent.id}",
          "agent:#{agent.id}",
          "runtime:#{agent.runtime_id}"
        ]

        Enum.each(runtime_topics, &(:ok = Sink.watch(sink, &1)))

        view |> element("a#agent-ai-claude-open") |> render_click()

        html =
          view
          |> form("#agent-ai-claude-form", %{"code" => code})
          |> render_submit()

        assert html =~ "Connecting…"
        state_at_submit = flat(:sys.get_state(view.pid))

        assert_eventually(
          fn ->
            has_element?(view, "#agent-ai-claude-connected", "Connected as owner@example.com")
          end,
          3_000
        )

        # Positive controls, through the same flow: an unknown event's NAME,
        # sent to the panel and to its page, is logged by each catch-all and
        # reaches that surface's handle_event telemetry.
        render_hook(with_target(view, "#agent-ai-panel"), control, %{})
        render_hook(view, control, %{})

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
          [Ecto.UUID.bingenerate(), Ecto.UUID.dump!(owner.id), control]
        )

        send(self(), {:flow, view, html, state_at_submit})
      end)

    Logger.configure(level: level)
    assert_received {:flow, view, html_at_submit, state_at_submit}

    # The one allowed destination holds the code, so it went all the way, and
    # the display summary (never the code) is on THIS agent's runtime.
    pushes = RecordingHost.received(host)

    assert [%LoginCode{} = sent] =
             for({"agent.claude_login_code", %{"code" => c}} <- pushes, do: c)

    assert LoginCode.reveal(sent) == code

    assert NativeAgents.ai_login(Repo.reload!(agent)) ==
             %{"provider" => "claude", "account" => "owner@example.com", "plan" => "max"}

    sinks = %{
      log: log,
      view_state: state_at_submit <> flat(:sys.get_state(view.pid)),
      rendered_html: html_at_submit <> render(view),
      agent_host_state: RecordingHost.midflight(host) <> RecordingHost.agent_host_state_text(),
      pubsub: flat(for {:pubsub, msg} <- Sink.received(sink), do: msg),
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

    assert log =~ ~s([ConnectAi.Panel] refused unknown event "#{control}")
    assert log =~ ~s([ConnectAiPanelHostLive] refused unknown event "#{control}")

    received = Sink.received(sink)

    for event <- @telemetry_events do
      assert Enum.any?(received, fn
               {{:telemetry, ^event}, meta} -> found?(flat(meta), control)
               _ -> false
             end),
             "no #{inspect(event)} telemetry carried the control"
    end

    assert Enum.any?(received, fn
             {:pubsub, {:agent_host_claude_login, _ref, %{"url" => url}}} -> found?(url, control)
             _ -> false
           end)

    # The submit event's own params: the panel's events are component events,
    # so the code is in `[:phoenix, :live_component, :handle_event, :stop]`
    # metadata, in exactly that one place, and in no live_view event.
    assert [%{"code" => ^code}] =
             for(
               {{:telemetry, [:phoenix, :live_component, :handle_event, :stop]},
                %{event: "claude_submit", params: params}} <- received,
               do: params
             )

    assert [] ==
             for(
               {{:telemetry, [:phoenix, :live_view, :handle_event, :stop]},
                %{event: "claude_submit"} = meta} <- received,
               do: meta
             )

    expected_readers = %{
      [:phoenix, :live_view, :handle_event, :stop] => [
        {Phoenix.LiveView.Logger, [:phoenix, :live_view, :handle_event, :stop]}
      ],
      [:phoenix, :live_component, :handle_event, :stop] => [
        {Phoenix.LiveView.Logger, [:phoenix, :live_component, :handle_event, :stop]}
      ],
      [:phoenix, :channel_handled_in] => [{Phoenix.Logger, [:phoenix, :channel_handled_in]}]
    }

    for event <- @telemetry_events do
      ids = for(%{id: id} <- :telemetry.list_handlers(event), do: id) -- [handler]

      assert ids == Map.fetch!(expected_readers, event),
             "a new handler reads #{inspect(event)}, and so the submitted code: #{inspect(ids)}"
    end

    assert db_hits(code) == []

    control_hits = db_hits(control)
    assert "agents.name" in control_hits
    assert "agents.metadata" in control_hits
    assert "calendar_subscriptions.url" in control_hits
  end
end
