defmodule Platform.Changelog do
  @moduledoc """
  Context for the Changelog domain.

  Manages changelog entries sourced from merged GitHub PRs.
  Provides listing with date-grouping, tag filtering, and pagination.
  """

  import Ecto.Query

  alias Platform.Changelog.ChangelogEntry
  alias Platform.Repo

  @pubsub_topic "changelog:feed"

  # ── PubSub ───────────────────────────────────────────────────────────────

  @doc "Subscribe to real-time changelog updates."
  def subscribe do
    Phoenix.PubSub.subscribe(Platform.PubSub, @pubsub_topic)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Platform.PubSub, @pubsub_topic, event)
  end

  # ── CRUD ─────────────────────────────────────────────────────────────────

  @doc "Create a changelog entry and broadcast the new entry."
  def create_entry(attrs) do
    result =
      %ChangelogEntry{}
      |> ChangelogEntry.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        entry = Repo.preload(entry, :task)
        broadcast({:new_changelog_entry, entry})
        {:ok, entry}

      error ->
        error
    end
  end

  @doc "Get a single changelog entry by ID."
  def get_entry(id), do: Repo.get(ChangelogEntry, id)

  @doc """
  List changelog entries with optional filters.

  Options:
    - `:tag` — filter to entries containing this tag
    - `:limit` — max entries (default 50)
    - `:before` — cursor for pagination (merged_at datetime)
  """
  def list_entries(opts \\ []) do
    tag = Keyword.get(opts, :tag)
    limit = Keyword.get(opts, :limit, 50)
    before = Keyword.get(opts, :before)

    ChangelogEntry
    |> order_by([e], desc: e.merged_at, desc: e.id)
    |> limit(^limit)
    |> maybe_filter_tag(tag)
    |> maybe_filter_before(before)
    |> preload(:task)
    |> Repo.all()
  end

  @doc """
  Group a list of entries by date for display.

  Returns `[{label, [entries]}]` sorted newest-first.
  Labels: "Today", "Yesterday", or formatted date.
  """
  def group_by_date(entries) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    entries
    |> Enum.group_by(fn e -> DateTime.to_date(e.merged_at) end)
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
    |> Enum.map(fn {date, group} ->
      label =
        cond do
          date == today -> "Today"
          date == yesterday -> "Yesterday"
          true -> Calendar.strftime(date, "%B %-d, %Y")
        end

      {label, Enum.sort_by(group, & &1.merged_at, {:desc, DateTime})}
    end)
  end

  # ── Tag parsing ──────────────────────────────────────────────────────────

  @conventional_prefixes %{
    "feat" => "feature",
    "fix" => "fix",
    "chore" => "chore",
    "docs" => "docs",
    "refactor" => "improvement",
    "perf" => "improvement",
    "test" => "chore",
    "ci" => "chore",
    "style" => "chore",
    "build" => "chore"
  }

  @doc """
  Parse conventional commit prefix from a PR title.

  Returns `{cleaned_title, tags}`.

  ## Examples

      iex> Platform.Changelog.parse_title("feat: add changelog module")
      {"add changelog module", ["feature"]}

      iex> Platform.Changelog.parse_title("fix(chat): resolve crash")
      {"resolve crash", ["fix"]}

      iex> Platform.Changelog.parse_title("Update README")
      {"Update README", []}
  """
  def parse_title(title) when is_binary(title) do
    case Regex.run(~r/^(\w+)(?:\(.+?\))?:\s*(.+)$/, title) do
      [_, prefix, rest] ->
        tag = Map.get(@conventional_prefixes, String.downcase(prefix))
        tags = if tag, do: [tag], else: []
        {String.trim(rest), tags}

      _ ->
        {title, []}
    end
  end

  # ── Task ID extraction ──────────────────────────────────────────────────

  @doc """
  Extract a task ID from a PR branch name.

  Looks for patterns like `task/019d219a`, `pr-019d219a`, or raw UUIDs.
  Returns the full task_id if a matching task exists, otherwise nil.

  ## Examples

      iex> Platform.Changelog.extract_task_id_from_branch("feat/changelog")
      nil

      iex> Platform.Changelog.extract_task_id_from_branch("task/019d219a-67a8-7698-a7d1-0018603d3910")
      "019d219a-67a8-7698-a7d1-0018603d3910"
  """
  def extract_task_id_from_branch(nil), do: nil

  def extract_task_id_from_branch(branch) when is_binary(branch) do
    # Try full UUID first
    full_uuid =
      ~r/(?:task|pr)[\/\-]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i

    case Regex.run(full_uuid, branch) do
      [_, uuid] ->
        if task_exists?(uuid), do: uuid, else: nil

      _ ->
        # Try prefix match (e.g. task/019d219a)
        case Regex.run(~r/(?:task|pr)[\/\-]([0-9a-f]{8})/i, branch) do
          [_, prefix] -> find_task_by_prefix(prefix)
          _ -> nil
        end
    end
  end

  @doc """
  Extract a task ID from PR body text.

  Looks for patterns like `Task: 019d219a...` or `Closes #task/019d219a...`.
  """
  def extract_task_id_from_body(nil), do: nil

  def extract_task_id_from_body(body) when is_binary(body) do
    # Look for task UUID patterns in the body
    case Regex.run(
           ~r/(?:task[:\s]+|closes\s+#?task[\/\-])([0-9a-f]{8}(?:-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?)/i,
           body
         ) do
      [_, match] ->
        if String.length(match) == 36 do
          if task_exists?(match), do: match, else: nil
        else
          find_task_by_prefix(match)
        end

      _ ->
        nil
    end
  end

  defp task_exists?(id) do
    import Ecto.Query
    Repo.exists?(from(t in Platform.Tasks.Task, where: t.id == ^id))
  rescue
    _ -> false
  end

  defp find_task_by_prefix(prefix) do
    import Ecto.Query

    # Use LIKE on the text representation of the UUID
    pattern = "#{prefix}%"

    case Repo.one(
           from(t in Platform.Tasks.Task,
             where: fragment("CAST(? AS text) LIKE ?", t.id, ^pattern),
             limit: 1,
             select: t.id
           )
         ) do
      nil -> nil
      id -> id
    end
  rescue
    _ -> nil
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp maybe_filter_tag(query, nil), do: query

  defp maybe_filter_tag(query, tag) do
    where(query, [e], ^tag in e.tags)
  end

  defp maybe_filter_before(query, nil), do: query

  defp maybe_filter_before(query, %DateTime{} = before) do
    where(query, [e], e.merged_at < ^before)
  end
end
