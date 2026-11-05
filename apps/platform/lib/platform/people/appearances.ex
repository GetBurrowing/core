defmodule Platform.People.Appearances do
  @moduledoc """
  Who appeared in a window, and where. Deterministic — no model call.

  `collect/3` gathers one appearance per sighting from four sources:

    * `:chat_author` — the author of a digest-eligible message
      (`Platform.Chat.digest_eligible_messages_query/1`, so the same kinds,
      content types and `:scope` partition the Historian digest uses);
    * `:chat_mention` — every `@[Name]` inside those messages;
    * `:meeting_participant` — `Platform.Meetings.list_participants_between/3`
      (attendance only; never a segment, never a summary);
    * `:task_assignee` — the human assignee and sponsor of tasks updated in
      the window (`Platform.Tasks.list_tasks_updated_since/2`).

  Each appearance is
  `%{raw_name, kind, user_id, agent_id, source, space_id, meeting_id,
  project_id, task_id, at, citation}` with `kind` `:human | :agent`. Agents
  are kept and flagged, not dropped. The citation is `chat:<space_id>:<message_id>`,
  `meeting:<meeting_id>` (or `meeting:space:<space_id>` for a room with no
  meeting row) or `task:<task_id>`.

  Nothing here reads transcript text: the only meeting input is the
  participant row.
  """

  import Ecto.Query

  alias Platform.{Accounts, Chat, Meetings, Repo, Tasks}

  @mention_re ~r/@\[([^\[\]]+)\]/u

  @type appearance :: %{
          raw_name: String.t(),
          kind: :human | :agent,
          user_id: String.t() | nil,
          agent_id: String.t() | nil,
          source: :chat_author | :chat_mention | :meeting_participant | :task_assignee,
          space_id: String.t() | nil,
          meeting_id: String.t() | nil,
          project_id: String.t() | nil,
          task_id: String.t() | nil,
          at: DateTime.t() | nil,
          citation: String.t()
        }

  @doc """
  Appearances in `[window_start, window_end)`.

  Options:

    * `:scope` — `:internal` (default) or `{:external_spaces, ids}`, threaded
      to the chat and meeting seams unchanged.
  """
  @spec collect(DateTime.t(), DateTime.t(), keyword()) :: [appearance()]
  def collect(%DateTime{} = window_start, %DateTime{} = window_end, opts \\ []) do
    scope = Keyword.get(opts, :scope, :internal)
    messages = messages_between(window_start, window_end, scope)

    Enum.concat([
      Enum.flat_map(messages, &author_appearance/1),
      Enum.flat_map(messages, &mention_appearances/1),
      meeting_appearances(window_start, window_end, scope),
      task_appearances(window_start, window_end)
    ])
    |> Enum.sort_by(& &1.at, {:asc, DateTime})
  end

  # ── chat ─────────────────────────────────────────────────────────────────

  defp messages_between(window_start, window_end, scope) do
    [scope: scope]
    |> Chat.digest_eligible_messages_query()
    |> where([m], m.inserted_at >= ^window_start and m.inserted_at < ^window_end)
    |> order_by([m], asc: m.inserted_at)
    |> select([m, s], %{
      id: m.id,
      space_id: m.space_id,
      content: m.content,
      inserted_at: m.inserted_at,
      author_display_name: m.author_display_name,
      author_user_id: m.author_user_id,
      author_agent_id: m.author_agent_id,
      author_participant_type: m.author_participant_type
    })
    |> Repo.all()
  end

  defp author_appearance(%{author_display_name: name} = m) when is_binary(name) and name != "" do
    agent? = m.author_participant_type == "agent" or not is_nil(m.author_agent_id)

    [
      appearance(name, if(agent?, do: :agent, else: :human), :chat_author, m.inserted_at,
        user_id: m.author_user_id,
        agent_id: m.author_agent_id,
        space_id: m.space_id,
        citation: "chat:#{m.space_id}:#{m.id}"
      )
    ]
  end

  defp author_appearance(_), do: []

  defp mention_appearances(%{content: content} = m) when is_binary(content) do
    @mention_re
    |> Regex.scan(content)
    |> Enum.map(fn [_, name] -> String.trim(name) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(fn name ->
      appearance(name, :human, :chat_mention, m.inserted_at,
        space_id: m.space_id,
        citation: "chat:#{m.space_id}:#{m.id}"
      )
    end)
  end

  defp mention_appearances(_), do: []

  # ── meetings ─────────────────────────────────────────────────────────────

  defp meeting_appearances(window_start, window_end, scope) do
    window_start
    |> Meetings.list_participants_between(window_end, scope: scope)
    |> Enum.flat_map(fn
      %{display_name: name} = row when is_binary(name) and name != "" ->
        [
          appearance(
            name,
            if(row.agent_id, do: :agent, else: :human),
            :meeting_participant,
            row.joined_at,
            user_id: row.user_id,
            agent_id: row.agent_id,
            space_id: row.space_id,
            meeting_id: row.meeting_id,
            project_id: row.project_id,
            citation: meeting_citation(row)
          )
        ]

      _ ->
        []
    end)
  end

  defp meeting_citation(%{meeting_id: id}) when is_binary(id), do: "meeting:#{id}"
  defp meeting_citation(%{space_id: id}), do: "meeting:space:#{id}"

  # ── tasks ────────────────────────────────────────────────────────────────

  defp task_appearances(window_start, window_end) do
    window_start
    |> Tasks.list_tasks_updated_since(window_end: window_end)
    |> Enum.flat_map(fn task ->
      [task_user(task, task.sponsor_user_id), task_user(task, current_user_assignee(task))]
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp current_user_assignee(%{assignee_type: "user", assignee_id: id}) when is_binary(id), do: id
  defp current_user_assignee(_), do: nil

  defp task_user(_task, nil), do: nil

  defp task_user(task, user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" ->
        appearance(name, :human, :task_assignee, task.updated_at,
          user_id: user_id,
          project_id: task.project_id,
          task_id: task.id,
          citation: "task:#{task.id}"
        )

      _ ->
        nil
    end
  end

  # ── shape ────────────────────────────────────────────────────────────────

  defp appearance(raw_name, kind, source, at, fields) do
    %{
      raw_name: raw_name,
      kind: kind,
      user_id: Keyword.get(fields, :user_id),
      agent_id: Keyword.get(fields, :agent_id),
      source: source,
      space_id: Keyword.get(fields, :space_id),
      meeting_id: Keyword.get(fields, :meeting_id),
      project_id: Keyword.get(fields, :project_id),
      task_id: Keyword.get(fields, :task_id),
      at: at,
      citation: Keyword.fetch!(fields, :citation)
    }
  end
end
