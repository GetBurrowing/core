defmodule PlatformWeb.ControlCenter.AgentPageData do
  @moduledoc """
  What the living agent page (task 01a1b6ad stage 3) shows, read from the
  contexts that own it. The comp's `profile()` (burrow-agents.js) seeded most
  of these from a name hash; here every field is a row, or "—" where no
  source exists.

    * `:character`: `Platform.Agents.Character.from_agent/1`, or nil for an
      agent built before characters.
    * `:status`: `"working"`, `"online"` or `"idle"`, from the runtime (an
      open session is working, a running runtime or a connected federated
      runtime is online), and `:doing`, what the header says it is doing.
    * `:spaces`: its chat participant rows outside DMs, each with the row's
      `attention_mode`.
    * `:now`: open tasks assigned to it. `:shipped`: its done tasks.
    * `:memories`: `MemoryContext.count_memories/1`. `:first_reply`: always
      "—", because nothing records a first-reply latency.
    * `:today`: its messages today (only in the viewer's spaces) and its
      tasks touched today, then a "now" row from its status.
    * `:said`: its latest message in the viewer's spaces, or nil.
    * `:hear`: the TTS provider in `voice_config`, or nil.
    * `:number`: its place in creation order, the trading card's №.
  """

  alias Platform.Agents.{Agent, Character, MemoryContext}
  alias Platform.Chat
  alias Platform.Tasks

  @open_excluded ~w(done cancelled)

  @modes [
    %{
      id: "mention",
      label: "On mention",
      short: "on-mention",
      line: "Only when you @mention it. Quiet otherwise."
    },
    %{
      id: "active",
      label: "Follows along",
      short: "follows along",
      line: "Reads along and chimes in when it can actually help."
    },
    %{
      id: "all",
      label: "Works with you",
      short: "works with you",
      line: "Works directly with you: every message is for it."
    }
  ]

  @doc """
  The comp's three space modes (burrow-data.js MODES) keyed on the
  participant `attention_mode` each one writes: on-mention is `mention`,
  follows along is `active`, works with you is `all`.
  """
  def modes, do: @modes

  @doc "The mode a participant `attention_mode` shows as, or nil (`heartbeat`)."
  def mode(id), do: Enum.find(@modes, &(&1.id == id))

  @doc "The participant `attention_mode` ids the page may write."
  def mode_ids, do: Enum.map(@modes, & &1.id)

  @doc """
  Build the page for `agent`. Options: `:viewer_id`, `:scope` (the viewer's
  access scope, which scopes the task reads), `:runtime`,
  `:federation_online?`, `:native` (the managed header or nil) and
  `:agents` (the directory, for the card number).
  """
  def build(%Agent{} = agent, opts) do
    viewer_id = Keyword.get(opts, :viewer_id)
    scope = Keyword.get(opts, :scope)

    visible =
      if is_binary(viewer_id), do: Chat.participant_space_ids_for_user(viewer_id), else: []

    tasks = assigned_tasks(agent, scope)
    open = Enum.reject(tasks, &(&1.status in @open_excluded))
    status = status(agent, opts)
    doing = doing(status, open)
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    %{
      character: Character.from_agent(agent),
      status: status,
      doing: doing,
      spaces: spaces(agent),
      now: Enum.map(open, &now_row(&1, projects(open))),
      shipped: Enum.count(tasks, &(&1.status == "done")),
      memories: MemoryContext.count_memories(agent.id),
      first_reply: "—",
      today: today(agent, visible, tasks, today_start, status, doing),
      said: Chat.latest_agent_message(agent.id, visible),
      hear: provider(agent),
      number: number(agent, Keyword.get(opts, :agents, []))
    }
  end

  defp assigned_tasks(agent, scope) do
    opts = [assignee_id: agent.id, assignee_type: "agent"]
    opts = if scope, do: Keyword.put(opts, :access_scope, scope), else: opts
    Tasks.list_tasks(opts)
  end

  @doc "working, online or idle, from what the runtime reports."
  def status(%Agent{} = agent, opts) do
    runtime = Keyword.get(opts, :runtime) || %{}
    native = Keyword.get(opts, :native)

    cond do
      Map.get(runtime, :active_session_ids, []) != [] -> "working"
      native && native.view.running? -> "online"
      agent.runtime_type == "external" and Keyword.get(opts, :federation_online?) -> "online"
      agent.runtime_type != "external" and Map.get(runtime, :running?) == true -> "online"
      true -> "idle"
    end
  end

  # The comp's `doing`: an idle agent "idle · wakes on @mention", a busy one
  # the task it is on.
  defp doing("idle", _open), do: "idle · wakes on @mention"

  defp doing(_status, open) do
    case Enum.find(open, &(&1.status == "in_progress")) do
      nil -> "awake · wakes on @mention"
      task -> task.title
    end
  end

  defp spaces(agent) do
    agent.id
    |> Chat.list_spaces_for_agent()
    |> Enum.reject(&(&1.kind == "dm"))
    |> Enum.flat_map(fn space ->
      case Chat.get_agent_participant(space.id, agent.id) do
        nil ->
          []

        participant ->
          [
            %{
              space_id: space.id,
              name: space_label(space),
              slug: space.slug || space.id,
              mode: participant.attention_mode
            }
          ]
      end
    end)
  end

  defp space_label(%{kind: "channel", name: name}) when is_binary(name), do: "#" <> name
  defp space_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp space_label(%{slug: slug}), do: slug

  defp projects(tasks) do
    tasks
    |> Enum.map(& &1.project_id)
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn id -> {id, Tasks.get_project(id)} end)
  end

  defp now_row(task, projects) do
    project = projects[task.project_id]

    %{
      id: task.id,
      title: task.title,
      status: String.replace(task.status, "_", " "),
      where: (project && project.name) || ""
    }
  end

  defp today(agent, visible, tasks, since, status, doing) do
    said =
      agent.id
      |> Chat.list_agent_messages_since(visible, since, limit: 6)
      |> Enum.map(fn m ->
        %{at: m.inserted_at, ic: "💬", t: "Replied in " <> message_space(m), live: false}
      end)

    worked =
      tasks
      |> Enum.filter(&(DateTime.compare(to_utc(&1.updated_at), since) != :lt))
      |> Enum.map(
        &%{at: to_utc(&1.updated_at), ic: "☑", t: "Worked on " <> &1.title, live: false}
      )

    events =
      (said ++ worked)
      |> Enum.sort_by(& &1.at, DateTime)
      |> Enum.take(-6)

    now =
      if status == "idle",
        do: %{at: nil, ic: "💤", t: "Idle — wakes on @mention", live: false},
        else: %{at: nil, ic: "✍️", t: doing, live: true}

    events ++ [now]
  end

  defp message_space(m),
    do: space_label(%{kind: m.space_kind, name: m.space_name, slug: m.space_slug})

  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  defp provider(%Agent{voice_config: %{"provider" => p}}) when is_binary(p) and p != "", do: p
  defp provider(_), do: nil

  defp number(agent, entries) do
    entries
    |> Enum.flat_map(fn
      %{agent: %Agent{} = a} -> [a]
      _ -> []
    end)
    # UUIDv7 ids sort in creation order.
    |> Enum.sort_by(& &1.id)
    |> Enum.find_index(&(&1.id == agent.id))
    |> case do
      nil -> 1
      i -> i + 1
    end
  end
end
