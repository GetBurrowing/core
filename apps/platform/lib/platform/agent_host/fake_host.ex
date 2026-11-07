defmodule Platform.AgentHost.FakeHost do
  @moduledoc """
  A stand-in agent host for dev (task 01a10315 stage 4), started only when
  `BURROW_FAKE_AGENT_HOST=1` in dev (`config/runtime.exs` sets
  `config :platform, :fake_agent_host, true`; `Platform.Application` reads
  it). Nothing here runs in prod or test unless a test starts it itself.

  It joins `Platform.AgentHost.Reconciler` exactly as the real host's channel
  process does (`host_joined/2`, then an empty `inventory/2`), so the
  reconciler converges native agents to it and every screen sees a connected
  host. Then, for each `agent.start` / `agent.restart` it receives:

    * a `codex` agent reports `needs_login` at Codex's device login, with
      `login: {step: "device_code", url: "https://auth.openai.com/codex/device",
      code: "FAKE-1234"}`, until `complete/1` (dev route
      `POST /dev/fake-agent-host/<agent_id>/complete`) marks it logged in;
      after that it reports `running`;
    * a `claude_code` agent reports `running` when its start carried an API
      key (`env["ANTHROPIC_API_KEY"]`, which is never kept or logged here),
      and otherwise `needs_login` at step `login`. Never a Claude login URL or
      code in an observation (task 01a17b10).

  A stubbed Claude subscription login (task 01a1b365 stage 2,
  `claude_login_reply/3`): `agent.claude_login_start` is answered with a fake
  claude.com URL; `agent.claude_login_code` with `ok`, account
  `owner@example.com`, plan `max`, for the one known-good code
  (`claude_login_code/0`), and `bad_code` for anything else. The switch
  `set_claude_login/2` (dev route
  `POST /dev/fake-agent-host/claude-login/<mode>`) makes a good code answer
  `no_subscription`, or makes the fake host answer nothing (`timeout`). On
  `ok` the agent then reports `running`, as the real host's restart would.
  The code is compared here and dropped; it is never kept or logged.

  It joins only once `PlatformWeb.Endpoint` is running: it starts before the
  Endpoint in the supervision tree, so it waits and retries every second
  (`join/1`).

  A deterministic `agent.oneshot` (task 01a1b721 stage 2,
  `oneshot_reply/3`, `oneshot_answer/1`): the secretary's tool-less
  question is answered from the prompt's machine-readable INPUTS block
  (`Platform.Secretary.Model.Host.inputs_open/0`), never by a model. The
  fixed mapping, by the item's kind (an `inbox:` / `chat:` prefix dropped):

    * `task_plan_review`, `review_request_pending` -> `decide`;
    * `task_sponsor_assigned`, `lifecycle_step_failed`, `social_*` and any
      kind not named here -> `waiting`;
    * `chat_mention`, a DM (`chat:dm`), and any chat message that mentions
      the person -> `waiting`; other chat in a space they are in -> `fyi`;
    * `meeting_starting` -> `waiting`, deadline = its start (`deadline_at`);
    * `meeting_invited`, `meeting_cancelled`, `briefing`,
      `meeting_briefing` -> `fyi`; a chat message in an open channel the
      person is not in (`member: false`) -> `not_in_space`;
    * a calendar event (`calendar:event`) flagged `family` -> `waiting` with
      `family: true`; any other calendar event -> `fyi`;
    * a meeting action item addressed to the person (`meeting:action_item`)
      -> `suggested`, and a to-do suggestion from it; the person's own
      to-dos (`todo:*`) -> `todo`.

  Rank: deadline ascending (none last), then kind order (decide, waiting,
  not_in_space, todo, suggested, fyi), then ref. Reason `"Fake: <kind> from
  <source>"`. Brief: the top `brief_max_lines` ranked items that are not
  FYI, `needs_you_now` for a `decide` item due on the block's `today`.
  Group `"none"`. Usage: input = prompt bytes / 4, output = answer bytes / 4.
  The same prompt gives the same answer, byte for byte.

  `set_oneshot_mode/2` (dev route `POST /dev/fake-secretary/mode/<mode>`):
  `ok` (the default), `slow` (the answer comes after 20 s) or
  `not_logged_in` (refused `not_logged_in`). Like the real host, an agent
  with a saved API key (`Platform.Agents.NativeLogin.put_api_key/3`) is
  refused `api_key_login`, and an agent not running `not_running`. The
  prompt is read here and dropped; it is never kept or logged.

  `agent.stop` reports `stopped`. Logs, pane, file and auth requests get no
  answer; their callers time out as they would against a host that is slow.

  No real CLI runs and nothing leaves the BEAM.
  """

  use GenServer

  require Logger

  alias Platform.AgentHost.{LoginCode, OneshotPrompt, Reconciler}

  @device_url "https://auth.openai.com/codex/device"
  @device_code "FAKE-1234"
  @claude_url "https://claude.com/cai/oauth/authorize?code=true&state=fake-agent-host"
  @claude_code "fake-claude-login-code#fake-state"
  @claude_account "owner@example.com"
  @claude_plan "max"
  @claude_modes [:ok, :no_subscription, :timeout]
  @oneshot_modes [:ok, :slow, :not_logged_in]
  @slow_ms 20_000
  @report_after_ms 500
  @rejoin_after_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The device code a fake codex login shows."
  def device_code, do: @device_code

  @doc "The device URL a fake codex login shows."
  def device_url, do: @device_url

  @doc "The one code a fake Claude login accepts."
  def claude_login_code, do: @claude_code

  @doc "The account and plan a fake Claude login reports."
  def claude_login_account, do: %{account: @claude_account, plan: @claude_plan}

  @doc "Every mode of the fake Claude login, the default first."
  def claude_login_modes, do: @claude_modes

  @doc """
  The fake host's `agent.claude_login` reply to a Claude login command, before
  the channel's sanitising, or nil for no reply at all. Pure; shared with the
  test stand-in (`Platform.FakeAgentHost`). `mode` is one of
  `claude_login_modes/0`.
  """
  @spec claude_login_reply(String.t(), map(), atom()) :: map() | nil
  def claude_login_reply(_event, _payload, :timeout), do: nil

  def claude_login_reply("agent.claude_login_start", _payload, _mode),
    do: %{"result" => "url", "url" => @claude_url}

  def claude_login_reply("agent.claude_login_code", %{"code" => %LoginCode{} = code}, mode) do
    cond do
      LoginCode.reveal(code) != @claude_code -> %{"result" => "bad_code"}
      mode == :no_subscription -> %{"result" => "no_subscription"}
      true -> %{"result" => "ok", "account" => @claude_account, "plan" => @claude_plan}
    end
  end

  def claude_login_reply("agent.claude_login_code", _payload, _mode),
    do: %{"result" => "bad_code"}

  def claude_login_reply("agent.claude_logout", _payload, _mode), do: %{"result" => "ok"}

  @doc """
  Switch the fake Claude login (`claude_login_modes/0`). `:ok`, or
  `{:error, :unknown_mode | :not_running}`.
  """
  @spec set_claude_login(atom(), GenServer.server()) ::
          :ok | {:error, :unknown_mode | :not_running}
  def set_claude_login(mode, server \\ __MODULE__) do
    cond do
      mode not in @claude_modes -> {:error, :unknown_mode}
      GenServer.whereis(server) -> GenServer.call(server, {:claude_login_mode, mode})
      true -> {:error, :not_running}
    end
  end

  @doc "Every mode of the fake `agent.oneshot`, the default first."
  def oneshot_modes, do: @oneshot_modes

  @doc """
  Switch the fake `agent.oneshot` (`oneshot_modes/0`). `:ok`, or
  `{:error, :unknown_mode | :not_running}`.
  """
  @spec set_oneshot_mode(atom(), GenServer.server()) ::
          :ok | {:error, :unknown_mode | :not_running}
  def set_oneshot_mode(mode, server \\ __MODULE__) do
    cond do
      mode not in @oneshot_modes -> {:error, :unknown_mode}
      GenServer.whereis(server) -> GenServer.call(server, {:oneshot_mode, mode})
      true -> {:error, :not_running}
    end
  end

  @doc """
  The fake host's `agent.oneshot` reply, before the channel's sanitising.
  Pure; shared with the test stand-in (`Platform.FakeAgentHost`). `mode` is
  one of `oneshot_modes/0` (`:slow` answers like `:ok`; the delay is the
  server's); `facts` says whether the agent is `running` and has an API key
  saved (`api_key?`).
  """
  @spec oneshot_reply(map(), atom(), %{running?: boolean(), api_key?: boolean()}) :: map()
  def oneshot_reply(payload, mode, facts) do
    cond do
      not facts.running? -> %{"result" => "refused", "reason" => "not_running"}
      facts.api_key? -> %{"result" => "refused", "reason" => "api_key_login"}
      mode == :not_logged_in -> %{"result" => "refused", "reason" => "not_logged_in"}
      true -> answer_reply(payload["prompt"])
    end
  end

  defp answer_reply(%OneshotPrompt{} = prompt) do
    text = OneshotPrompt.reveal(prompt)

    case oneshot_answer(text) do
      {:ok, answer} ->
        %{
          "result" => "ok",
          "text" => answer,
          "usage" => %{
            "input_tokens" => div(byte_size(text), 4),
            "output_tokens" => div(byte_size(answer), 4),
            "cache_read_tokens" => 0,
            "cache_creation_tokens" => 0
          }
        }

      :error ->
        %{"result" => "failed", "reason" => "no_inputs_block"}
    end
  end

  defp answer_reply(_prompt), do: %{"result" => "refused", "reason" => "invalid"}

  @kind_order %{
    "decide" => 0,
    "waiting" => 1,
    "not_in_space" => 2,
    "todo" => 3,
    "suggested" => 4,
    "fyi" => 5
  }

  @doc """
  The deterministic answer JSON for a prompt carrying an INPUTS block
  (`Platform.Secretary.Model.Host.inputs_open/0`), or `:error` when it has
  none. Pure. The mapping is in the moduledoc.
  """
  @spec oneshot_answer(String.t()) :: {:ok, String.t()} | :error
  def oneshot_answer(prompt) when is_binary(prompt) do
    with {:ok, block} <- inputs_block(prompt) do
      items = Enum.filter(List.wrap(block["items"]), &is_map/1)
      today = block["today"]
      brief_max = if is_integer(block["brief_max_lines"]), do: block["brief_max_lines"], else: 5

      ranked =
        items
        |> Enum.map(&evaluate/1)
        |> Enum.sort_by(fn e ->
          {deadline_key(e["deadline_at"]), @kind_order[e["tag"]], e["ref_id"]}
        end)
        |> Enum.with_index(1)
        |> Enum.map(fn {e, rank} -> Map.put(e, "rank", rank) end)
        |> Enum.map(fn e -> Map.put(e, "needs_you_now", needs_you_now?(e, today)) end)

      brief =
        ranked
        |> Enum.reject(&(&1["tag"] == "fyi"))
        |> Enum.take(brief_max)
        |> Enum.map(fn e ->
          %{
            "ref_type" => e["ref_type"],
            "ref_id" => e["ref_id"],
            "line" => e["reason"],
            "action_label" => "Open",
            "tag" => if(e["family"], do: "family", else: nil),
            "needs_you_now" => e["needs_you_now"]
          }
        end)

      todos =
        for item <- items, kind(item) == "meeting:action_item" do
          %{
            "ref_type" => item["ref_type"],
            "ref_id" => item["ref_id"],
            "title" => item["title"] || item["text"] || "",
            "quote" => item["text"]
          }
        end

      {:ok,
       Jason.encode!(%{
         "evaluations" => ranked,
         "brief" => brief,
         "todos_suggested" => todos,
         "todos_done" => []
       })}
    end
  end

  defp inputs_block(prompt) do
    open = Platform.Secretary.Model.Host.inputs_open()
    close = Platform.Secretary.Model.Host.inputs_close()

    with [_, rest] <- String.split(prompt, open <> "\n", parts: 2),
         [json, _] <- String.split(rest, "\n" <> close, parts: 2),
         {:ok, %{} = block} <- Jason.decode(json) do
      {:ok, block}
    else
      _ -> :error
    end
  end

  defp kind(item), do: to_string(item["kind"] || "")

  defp short_kind(item) do
    k = kind(item)

    case String.split(k, ":", parts: 2) do
      ["inbox", rest] -> rest
      _ -> k
    end
  end

  defp evaluate(item) do
    {tag, family?} = tag_for(item)
    source = item["source"] || item["ref_type"] || "unknown"

    %{
      "ref_type" => item["ref_type"],
      "ref_id" => item["ref_id"],
      "tag" => tag,
      "group_key" => "none",
      "reason" => "Fake: #{short_kind(item)} from #{source}",
      "family" => family?,
      "deadline_at" => item["deadline_at"]
    }
  end

  defp tag_for(item) do
    k = short_kind(item)

    cond do
      k in ["task_plan_review", "review_request_pending"] ->
        {"decide", false}

      k == "meeting_starting" ->
        {"waiting", false}

      k in ["meeting_invited", "meeting_cancelled", "briefing", "meeting_briefing"] ->
        {"fyi", false}

      k == "chat_mention" ->
        {"waiting", false}

      String.starts_with?(k, "chat:") ->
        chat_tag(item)

      k == "calendar:event" and item["family"] == true ->
        {"waiting", true}

      k == "calendar:event" ->
        {"fyi", false}

      k == "meeting:action_item" ->
        {"suggested", false}

      String.starts_with?(k, "todo:") ->
        {"todo", false}

      true ->
        {"waiting", false}
    end
  end

  defp chat_tag(item) do
    cond do
      item["member"] == false -> {"not_in_space", false}
      kind(item) == "chat:dm" -> {"waiting", false}
      item["mentioned"] == true -> {"waiting", false}
      true -> {"fyi", false}
    end
  end

  # nil deadlines sort last; ISO-8601 UTC strings sort as time.
  defp deadline_key(d) when is_binary(d), do: {0, d}
  defp deadline_key(_), do: {1, ""}

  defp needs_you_now?(%{"tag" => "decide", "deadline_at" => d}, today)
       when is_binary(d) and is_binary(today),
       do: String.starts_with?(d, today)

  defp needs_you_now?(_e, _today), do: false

  @doc """
  Finish `agent_id`'s fake Codex login, as if its owner approved the code on
  OpenAI's page. `:ok`, or `{:error, :unknown_agent}` for an agent this fake
  host was never asked to start, or `{:error, :not_device_login}` for a
  non-codex one.
  """
  @spec complete(binary(), GenServer.server()) ::
          :ok | {:error, :unknown_agent | :not_device_login | :not_running}
  def complete(agent_id, server \\ __MODULE__) when is_binary(agent_id) do
    if GenServer.whereis(server),
      do: GenServer.call(server, {:complete, agent_id}),
      else: {:error, :not_running}
  end

  # ── Server ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      agents: %{},
      completed: MapSet.new(),
      claude_login: :ok,
      oneshot: :ok,
      report_after_ms: Keyword.get(opts, :report_after_ms, @report_after_ms),
      endpoint: Keyword.get(opts, :endpoint, PlatformWeb.Endpoint),
      reconciler: nil
    }

    {:ok, state, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state), do: {:noreply, join(state)}

  @impl true
  def handle_call({:claude_login_mode, mode}, _from, state),
    do: {:reply, :ok, %{state | claude_login: mode}}

  def handle_call({:oneshot_mode, mode}, _from, state),
    do: {:reply, :ok, %{state | oneshot: mode}}

  def handle_call({:complete, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :unknown_agent}, state}

      %{harness: "codex"} = agent ->
        state = %{state | completed: MapSet.put(state.completed, agent_id)}
        if agent.started?, do: report(agent_id, observation(agent_id, agent, state))
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_device_login}, state}
    end
  end

  @impl true
  def handle_info({:agent_host_push, event, %{"agent_id" => id} = payload}, state)
      when event in ["agent.start", "agent.restart"] and is_binary(id) do
    env = if is_map(payload["env"]), do: payload["env"], else: %{}

    agent = %{
      harness: payload["harness"],
      api_key?: is_binary(env["ANTHROPIC_API_KEY"]),
      started?: true
    }

    Process.send_after(self(), {:report, id}, state.report_after_ms)
    {:noreply, put_in(state.agents[id], agent)}
  end

  def handle_info({:agent_host_push, "agent.stop", %{"agent_id" => id}}, state)
      when is_binary(id) do
    state =
      case Map.get(state.agents, id) do
        nil -> state
        agent -> put_in(state.agents[id], %{agent | started?: false})
      end

    report(id, %{"agent_id" => id, "state" => "stopped"})
    {:noreply, state}
  end

  def handle_info({:agent_host_push, event, %{"agent_id" => id, "ref" => ref} = payload}, state)
      when event in ["agent.claude_login_start", "agent.claude_login_code", "agent.claude_logout"] do
    case claude_login_reply(event, payload, state.claude_login) do
      nil ->
        :ok

      reply ->
        # Through the real channel handler's sanitising, as the host's reply would be.
        PlatformWeb.AgentHostChannel.handle_in(
          "agent.claude_login",
          Map.merge(%{"ref" => ref, "agent_id" => id}, reply),
          %Phoenix.Socket{}
        )

        if reply["result"] == "ok" and event == "agent.claude_login_code",
          do: report(id, %{"agent_id" => id, "state" => "running"})
    end

    {:noreply, state}
  end

  def handle_info(
        {:agent_host_push, "agent.oneshot", %{"agent_id" => id, "ref" => ref} = payload},
        state
      )
      when is_binary(id) and is_binary(ref) do
    reply =
      Map.merge(
        %{"ref" => ref, "agent_id" => id},
        oneshot_reply(payload, state.oneshot, oneshot_facts(id))
      )

    if state.oneshot == :slow and reply["result"] == "ok",
      do: Process.send_after(self(), {:oneshot_reply, reply}, @slow_ms),
      else: send_oneshot(reply)

    {:noreply, state}
  end

  def handle_info({:agent_host_push, _event, _payload}, state), do: {:noreply, state}

  def handle_info({:oneshot_reply, reply}, state) do
    send_oneshot(reply)
    {:noreply, state}
  end

  def handle_info({:report, id}, state) do
    case Map.get(state.agents, id) do
      %{started?: true} = agent -> report(id, observation(id, agent, state))
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{reconciler: ref} = state) do
    Process.send_after(self(), :rejoin, @rejoin_after_ms)
    {:noreply, %{state | reconciler: nil}}
  end

  def handle_info(:rejoin, state), do: {:noreply, join(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ──────────────────────────────────────────────────────

  @doc false
  def observation(id, %{harness: "codex"}, state) do
    if MapSet.member?(state.completed, id) do
      %{"agent_id" => id, "state" => "running"}
    else
      %{
        "agent_id" => id,
        "state" => "needs_login",
        "detail" => "device_code",
        "login" => %{"step" => "device_code", "url" => @device_url, "code" => @device_code}
      }
    end
  end

  def observation(id, %{api_key?: true}, _state), do: %{"agent_id" => id, "state" => "running"}

  def observation(id, _agent, _state),
    do: %{
      "agent_id" => id,
      "state" => "needs_login",
      "detail" => "login",
      "login" => %{"step" => "login"}
    }

  # Through the real channel handler's sanitising, as the host's reply would be.
  defp send_oneshot(reply),
    do: PlatformWeb.AgentHostChannel.handle_in("agent.oneshot", reply, %Phoenix.Socket{})

  # `api_key_set?/1` reads only the id (the Vault metadata scope), so no row
  # is loaded here.
  defp oneshot_facts(id) do
    %{
      running?: match?(%{state: :running}, Platform.AgentHost.status(id)),
      api_key?: Platform.Agents.NativeLogin.api_key_set?(%Platform.Agents.Agent{id: id})
    }
  end

  defp report(id, payload) do
    case Reconciler.agent_state(self(), payload) do
      :ok -> :ok
      other -> Logger.warning("[FakeHost] agent=#{id} state not recorded: #{inspect(other)}")
    end
  end

  # It joins only once the Endpoint is up (task 01a10315 stage 6): joining
  # converges every native agent, and an `agent.start` broadcasts the runtime
  # disconnect through the Endpoint, which at boot is not started yet (the
  # reconciler crashed on it at every dev boot).
  defp join(state) do
    case {GenServer.whereis(Reconciler), Process.whereis(state.endpoint)} do
      {pid, endpoint} when is_nil(pid) or is_nil(endpoint) ->
        Process.send_after(self(), :rejoin, @rejoin_after_ms)
        state

      {pid, _endpoint} ->
        with :ok <- Reconciler.host_joined(self(), %{"profile" => "fake"}),
             :ok <- Reconciler.inventory(self(), %{"profile" => "fake", "agents" => []}) do
          %{state | reconciler: Process.monitor(pid)}
        else
          other ->
            Logger.warning("[FakeHost] could not join the reconciler: #{inspect(other)}")
            Process.send_after(self(), :rejoin, @rejoin_after_ms)
            state
        end
    end
  end
end
