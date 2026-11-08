defmodule PlatformWeb.ControlCenter.AgentPageData do
  @moduledoc """
  What the living agent page (task 01a1b6ad stages 3 and 4) shows, read
  from the contexts that own it. The comp's `profile()` (burrow-agents.js)
  seeded most of these from a name hash; here every field is a row, or "—"
  where no source exists.

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

  Stage 4 reads only for the tab that shows them (`:tab`), nil otherwise:

    * `:graph` (Connections): one node per channel it is in (sub = mode),
      per project it has tasks in, and per person who shares its spaces
      plus its creator (the human in its first DM). Edge weight `w` is
      bucketed 1-3 from its message count in that space, its task count in
      that project, or the spaces shared with that person. No source
      records an agent-to-agent hand-off, so there are no agent nodes.
    * `:remembers`, `:pages`, `:files` (Memory & notes): its memories with a
      source label; the org-memory pages whose last write was its own
      (nothing records a read); its workspace files.
    * `:stats` (Stats): done tasks, tasks with a merged PR
      (`Tasks.merged_pr_url/1`), meeting participant rows, authored
      messages, the streak of consecutive days with a done task, and done
      tasks per day over the last 14 days (`Tasks.done_dates/1`).
  """

  alias Platform.Accounts
  alias Platform.Agents.{Agent, Character, MemoryContext}
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Org.Wiki
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

  # The comp's per-file line on the Memory tab (profile().files).
  @file_lines %{
    "SOUL.md" => "personality",
    "IDENTITY.md" => "name, class, portrait, colour",
    "USER.md" => "what it knows about you",
    "TOOLS.md" => "toolkit",
    "HEARTBEAT.md" => "check-in schedule"
  }

  # The comp lists the workspace in this order; anything else follows, by key.
  @file_order ~w(SOUL.md IDENTITY.md USER.md MEMORY.md TOOLS.md HEARTBEAT.md)

  @memory_type_labels %{
    "long_term" => "long-term memory",
    "daily" => "daily note",
    "snapshot" => "snapshot"
  }

  # How many people the graph draws at most; the creator is always one.
  @people_cap 6

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
  `:federation_online?`, `:native` (the managed header or nil),
  `:agents` (the directory, for the card number) and `:tab` (the open tab,
  for the stage 4 reads).
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
    all_spaces = Chat.list_spaces_for_agent(agent.id)
    spaces = spaces(agent, all_spaces)

    %{
      character: Character.from_agent(agent),
      status: status,
      doing: doing,
      spaces: spaces,
      now: Enum.map(open, &now_row(&1, projects(open))),
      shipped: Enum.count(tasks, &(&1.status == "done")),
      memories: MemoryContext.count_memories(agent.id),
      first_reply: "—",
      today: today(agent, visible, tasks, today_start, status, doing),
      said: Chat.latest_agent_message(agent.id, visible),
      hear: provider(agent),
      number: number(agent, Keyword.get(opts, :agents, [])),
      graph: nil,
      remembers: nil,
      pages: nil,
      files: nil,
      stats: nil
    }
    |> Map.merge(tab_data(Keyword.get(opts, :tab), agent, tasks, spaces, all_spaces, scope))
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

  defp spaces(agent, all_spaces) do
    all_spaces
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

  # ── Stage 4: the tab that is open ─────────────────────────────────

  defp tab_data("connections", agent, tasks, spaces, all_spaces, _scope),
    do: %{graph: graph(agent, tasks, spaces, all_spaces)}

  defp tab_data("memory", agent, _tasks, _spaces, _all_spaces, scope) do
    %{
      remembers: remembers(agent),
      pages: pages(agent, scope),
      files: files(agent)
    }
  end

  defp tab_data("stats", agent, tasks, _spaces, _all_spaces, _scope),
    do: %{stats: stats(agent, tasks)}

  defp tab_data(_tab, _agent, _tasks, _spaces, _all_spaces, _scope), do: %{}

  # ── Connections ───────────────────────────────────────────────────

  @doc """
  The comp's node kinds (`KIND`): glyph and label, in its draw order.
  """
  def kinds do
    [
      {"channel", "#", "Channel"},
      {"project", "◆", "Project"},
      {"repo", "⑂", "Repo"},
      {"tool", "⚙", "Tool"},
      {"person", "☺", "Person"},
      {"agent", "✦", "Agent"}
    ]
  end

  @doc "The chip label for a kind filter: Everything, People, or `<Kind>s`."
  def filter_label("all"), do: "Everything"
  def filter_label("person"), do: "People"

  def filter_label(k) do
    case Enum.find(kinds(), &(elem(&1, 0) == k)) do
      {_, _, label} -> label <> "s"
      nil -> k
    end
  end

  defp graph(agent, tasks, spaces, all_spaces) do
    space_ids = Enum.map(spaces, & &1.space_id)
    counts = Chat.agent_message_counts_by_space(agent.id)
    last = Chat.last_message_excerpts(space_ids)

    channels =
      Enum.map(spaces, fn sp ->
        n = Map.get(counts, sp.space_id, 0)

        %{
          id: "c-" <> sp.space_id,
          k: "channel",
          l: sp.name,
          sub: mode_short(sp.mode),
          w: bucket(n, 1, 10),
          space_id: sp.space_id,
          slug: sp.slug,
          lines: [
            {"last message", last_at(last[sp.space_id])},
            {"mode", mode_short(sp.mode)}
          ]
        }
      end)

    projects =
      tasks
      |> Enum.reject(&is_nil(&1.project_id))
      |> Enum.group_by(& &1.project_id)
      |> Enum.flat_map(fn {id, ts} ->
        case Tasks.get_project(id) do
          nil ->
            []

          project ->
            open = Enum.count(ts, &(&1.status not in @open_excluded))

            [
              %{
                id: "p-" <> id,
                k: "project",
                l: project.name || "project",
                sub: "#{length(ts)} #{if length(ts) == 1, do: "task", else: "tasks"}",
                w: bucket(length(ts), 2, 5),
                project_id: id,
                lines: [{"open tasks", Integer.to_string(open)}, {"role", "contributor"}]
              }
            ]
        end
      end)
      |> Enum.sort_by(& &1.l)

    channels ++ projects ++ people(agent, space_ids, all_spaces)
  end

  # The people it works with: whoever shares its channels, the creator (the
  # human in its first DM) first. Capped so the graph stays legible.
  defp people(agent, space_ids, all_spaces) do
    creator = creator_id(agent, all_spaces)
    shared = Chat.user_participant_counts(space_ids)

    ids =
      shared
      |> Map.keys()
      |> Enum.reject(&(&1 == creator))
      |> Enum.sort_by(&{-Map.fetch!(shared, &1), &1})

    ids = if creator, do: [creator | ids], else: ids

    ids
    |> Enum.take(@people_cap)
    |> Enum.flat_map(fn id ->
      case Accounts.get_user(id) do
        nil ->
          []

        user ->
          n = Map.get(shared, id, 0)
          creator? = id == creator
          sub = if creator?, do: "works with you", else: "same spaces"

          [
            %{
              id: "h-" <> id,
              k: "person",
              l: display_name(user),
              sub: sub,
              w: if(creator?, do: max(2, bucket(n, 2, 4)), else: bucket(n, 2, 4)),
              user_id: id,
              lines: [{"together", sub}]
            }
          ]
      end
    end)
  end

  defp creator_id(agent, all_spaces) do
    all_spaces
    |> Enum.filter(&(&1.kind == "dm"))
    # UUIDv7 ids sort in creation order: the first DM is the one
    # Character.create opened with the creator.
    |> Enum.sort_by(& &1.id)
    |> Enum.find_value(fn dm ->
      dm.id
      |> Chat.list_participants(participant_type: "user")
      |> Enum.reject(&(&1.participant_id == agent.id))
      |> List.first()
      |> case do
        nil -> nil
        p -> p.participant_id
      end
    end)
  end

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}) when is_binary(email), do: email |> String.split("@") |> hd()
  defp display_name(_), do: "someone"

  # 1 below `two`, 2 below `three`, else 3.
  defp bucket(n, two, three) do
    cond do
      n >= three -> 3
      n >= two -> 2
      true -> 1
    end
  end

  defp last_at(%{inserted_at: %DateTime{} = at}), do: ago(at)
  defp last_at(_), do: "—"

  @doc "A short relative time: just now, 5m ago, 3h ago, 2d ago."
  def ago(%DateTime{} = at, now \\ DateTime.utc_now()) do
    s = DateTime.diff(now, at, :second)

    cond do
      s < 60 -> "just now"
      s < 3600 -> "#{div(s, 60)}m ago"
      s < 86_400 -> "#{div(s, 3600)}h ago"
      true -> "#{div(s, 86_400)}d ago"
    end
  end

  defp mode_short(mode) do
    case mode(mode) do
      nil -> mode
      m -> m.short
    end
  end

  # ── Memory & notes ────────────────────────────────────────────────

  defp remembers(agent) do
    agent.id
    |> MemoryContext.list_memories()
    |> Enum.map(fn m ->
      src = (is_map(m.metadata) && m.metadata["source"]) || @memory_type_labels[m.memory_type]
      day = m.inserted_at && Calendar.strftime(m.inserted_at, "%b %-d")
      %{id: m.id, t: m.content, src: Enum.join(Enum.reject([src, day], &is_nil/1), " · ")}
    end)
  end

  defp pages(agent, scope) do
    opts = if scope, do: [access_scope: scope], else: []

    agent.id
    |> Wiki.list_pages_updated_by(opts)
    |> Enum.map(fn page ->
      %{
        file_key: page.file_key,
        title: page_title(page),
        sub: "#{page.file_key} · v#{page.version}"
      }
    end)
  end

  defp page_title(%{frontmatter: %{"title" => t}}) when is_binary(t) and t != "", do: t

  defp page_title(%{file_key: key}),
    do: key |> Path.basename() |> String.replace_suffix(".md", "")

  defp files(agent) do
    memories = MemoryContext.count_memories(agent.id)

    agent.id
    |> MemoryContext.list_workspace_files()
    |> Enum.sort_by(fn f ->
      {Enum.find_index(@file_order, &(&1 == f.file_key)) || length(@file_order), f.file_key}
    end)
    |> Enum.map(fn f ->
      desc =
        case f.file_key do
          "MEMORY.md" -> "#{memories} memories"
          key -> @file_lines[key] || "v#{f.version}"
        end

      %{key: f.file_key, desc: desc}
    end)
  end

  # ── Stats ─────────────────────────────────────────────────────────

  defp stats(agent, tasks) do
    today = Date.utc_today()
    per_day = tasks |> Tasks.done_dates() |> Map.values() |> Enum.frequencies()

    %{
      tasks: Enum.count(tasks, &(&1.status == "done")),
      prs: Enum.count(tasks, &Tasks.merged_pr_url/1),
      meetings: Meetings.count_agent_participations(agent.id),
      resp: "—",
      msgs: Chat.count_agent_messages(agent.id),
      streak: streak(per_day, today),
      spark: Enum.map(13..0//-1, &Map.get(per_day, Date.add(today, -&1), 0)),
      since: agent.inserted_at
    }
  end

  # Consecutive days with a done task, counted back from today, or from
  # yesterday when nothing has shipped yet today.
  defp streak(per_day, today) do
    start = if Map.has_key?(per_day, today), do: today, else: Date.add(today, -1)

    start
    |> Stream.iterate(&Date.add(&1, -1))
    |> Enum.take_while(&Map.has_key?(per_day, &1))
    |> length()
  end
end
