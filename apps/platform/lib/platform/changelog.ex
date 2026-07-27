defmodule Platform.Changelog do
  @moduledoc """
  Context for the Changelog domain.

  Manages changelog entries sourced from merged GitHub PRs.
  Provides listing with date-grouping, tag filtering, and pagination.
  """

  import Ecto.Query
  require Logger

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

  @doc """
  Get a single changelog entry by ID. Returns `nil` for an absent id AND for a
  malformed one — `Platform.UUID.valid?/1`, not a bare `Ecto.UUID.cast/1`,
  because a bare cast accepts any 16-byte binary and the raise happens inside
  `Repo`. Keep the guard: a public getter whose `@spec` says `| nil` must be
  total over its input.
  """
  @spec get_entry(term()) :: ChangelogEntry.t() | nil
  def get_entry(id) do
    if Platform.UUID.valid?(id), do: Repo.get(ChangelogEntry, id), else: nil
  end

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

  # Full 8-4-4-4-12 UUID directly after a `task/` / `task-` / `pr/` marker.
  @branch_full_uuid ~r/(?:task|pr)[\/\-]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i

  # Fallback: the *longest* hex-and-dash run after the marker.
  #
  # This deliberately captures more than the 8-char prefix the original
  # implementation took. Task ids are UUIDv7 and therefore time-ordered, so
  # tasks filed seconds apart routinely share their first 8 hex characters —
  # `task/019f9b11-97d7` and `task/019f9b11-3bde` are two different tasks.
  # Truncating to 8 chars threw away the disambiguator that the branch name
  # was carrying on purpose, and the lookup then picked an arbitrary twin.
  #
  # The trailing `(?:-[0-9a-f]+)*` stops at the first non-hex segment, so a
  # descriptive suffix (`task/019f9b11-97d7-runtime-channel`) still yields
  # `019f9b11-97d7`. A suffix that happens to be all-hex (`...-fed`) is
  # captured too and simply resolves to no task — no attribution, which is
  # the safe outcome. See `find_task_by_prefix/1`.
  @branch_prefix ~r/(?:task|pr)[\/\-]([0-9a-f]{8}(?:-[0-9a-f]+)*)/i

  @doc """
  Extract a task ID from a PR branch name.

  Looks for patterns like `task/019d219a`, `task/019d219a-67a8`, `pr-019d219a`,
  or raw UUIDs. Returns the full task_id if exactly one matching task exists,
  otherwise nil.

  Partial prefixes that match more than one task resolve to `nil` rather than
  to an arbitrary match — see `find_task_by_prefix/1`.

  ## Examples

      iex> Platform.Changelog.extract_task_id_from_branch("feat/changelog")
      nil

      iex> Platform.Changelog.extract_task_id_from_branch("task/019d219a-67a8-7698-a7d1-0018603d3910")
      "019d219a-67a8-7698-a7d1-0018603d3910"
  """
  def extract_task_id_from_branch(nil), do: nil

  def extract_task_id_from_branch(branch) when is_binary(branch) do
    # Try full UUID first
    case Regex.run(@branch_full_uuid, branch) do
      [_, uuid] ->
        if task_exists?(uuid), do: uuid, else: nil

      _ ->
        # Try prefix match (e.g. task/019d219a, task/019d219a-67a8)
        case Regex.run(@branch_prefix, branch) do
          [_, prefix] -> find_task_by_prefix(prefix)
          _ -> nil
        end
    end
  end

  # Same longest-hex-run rule as `@branch_prefix`, after a `Task:` /
  # `Closes #task/` marker. Captures a full UUID when one is present.
  @body_task_ref ~r/(?:task[:\s]+|closes\s+#?task[\/\-])([0-9a-f]{8}(?:-[0-9a-f]+)*)/i

  @doc """
  Extract a task ID from PR body text.

  Looks for patterns like `Task: 019d219a...` or `Closes #task/019d219a...`.

  Shares `find_task_by_prefix/1` with the branch path, so partial references
  that match more than one task resolve to `nil` rather than to an arbitrary
  match.
  """
  def extract_task_id_from_body(nil), do: nil

  def extract_task_id_from_body(body) when is_binary(body) do
    # Look for task UUID patterns in the body
    case Regex.run(@body_task_ref, body) do
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

  # Resolve a partial task id, failing closed when it is ambiguous.
  #
  # This used to run `limit: 1` with no `order_by` and no ambiguity check, so a
  # prefix shared by several tasks returned an arbitrary row *as a success*.
  # That is not a cosmetic mis-attribution: the caller in
  # `PlatformWeb.GithubWebhookController` uses the resolved id to auto-pass the
  # task's `pr_merged` validation, so one merge silently satisfied a different
  # task's deploy gate and marked unmerged code as shipped.
  #
  # A wrong attribution is strictly worse than no attribution, so on more than
  # one match we return `nil` and log. Fetching `limit: 2` is enough to tell
  # "exactly one" from "more than one" without counting the whole table.
  defp find_task_by_prefix(prefix) do
    import Ecto.Query

    # Use LIKE on the text representation of the UUID. `prefix` comes from a
    # `[0-9a-f-]` capture, so it cannot carry LIKE wildcards.
    pattern = "#{prefix}%"

    matches =
      Repo.all(
        from(t in Platform.Tasks.Task,
          where: fragment("CAST(? AS text) LIKE ?", t.id, ^pattern),
          limit: 2,
          select: t.id
        )
      )

    case matches do
      [id] ->
        id

      [] ->
        nil

      [_, _] = ids ->
        Logger.warning(
          "Changelog: task-id prefix #{inspect(prefix)} is ambiguous " <>
            "(matches at least #{inspect(ids)}); refusing to attribute"
        )

        nil
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
