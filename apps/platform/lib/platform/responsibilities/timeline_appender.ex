defmodule Platform.Responsibilities.TimelineAppender do
  @moduledoc """
  Append-only writer for `docs/architecture/timeline.md` (ADR-0044 stage 5,
  task `019f3da3`).

  Hooked from `Platform.Tasks.transition_task_status/2` on the `done`
  transition. When the task carries `metadata.adr_flag == true` (accepts
  both atom-keyed `true` and the JSON-round-tripped string
  `"true"`), one line is appended to the timeline doc:

      - <today> | ADR-<adr_number> | PR #<pr_number> | <task_id> | <title>

  Missing fields fall back to `-` so the line stays parseable.

  ## Guardrails

    * **Never stall the transition.** Every filesystem interaction is
      wrapped in `try/rescue` (and file operations return `{:error, _}`
      on failure). A raise or non-zero return still logs a warning and
      returns `:ok` so the caller's `Repo.update/1` result is untouched.
    * **Idempotent-enough.** We don't dedupe against existing lines —
      two `done` transitions of the same task (unusual but reachable via
      `done → planning → in_progress → in_review → deploying → done`
      dance) would append twice. That's tolerated for v1; the doc reads
      as a log, and duplicates surface as a "task shipped twice" audit
      signal rather than being silently swallowed.
    * **Repo-root discovery.** Walks up from `__ENV__.file` looking for a
      directory that contains `docs/architecture/`. In test builds the
      cwd is usually `apps/platform`; in prod release builds we look at
      the priv root and walk back. When we can't find it we log and
      return `:ok` — never crash.

  ## Called from

  `Platform.Tasks.transition_task_status/2` — the "done" transition
  branch of the status change. Not called from
  `drop_task_to_column/2` because that's a manual UI override and the
  ADR flag is typically set programmatically.
  """

  require Logger

  alias Platform.Tasks.Task, as: TaskSchema

  @timeline_path_from_repo_root "docs/architecture/timeline.md"

  @doc """
  Append a timeline entry for `task` when its metadata carries the ADR
  flag. Returns `:ok` unconditionally — the caller must not block on
  the result. Filesystem failures are logged but not propagated.
  """
  @spec maybe_append(TaskSchema.t()) :: :ok
  def maybe_append(%TaskSchema{} = task) do
    if adr_flag?(task.metadata) do
      do_append(task)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning(
        "[TimelineAppender] append raised: #{Exception.message(error)} — " <>
          "task transition unaffected"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("[TimelineAppender] append exited: #{inspect(reason)}")
      :ok
  end

  def maybe_append(_), do: :ok

  @doc """
  Build the timeline line for `task` without touching the filesystem.
  Public so tests can lock the format without carrying a fixture path.
  """
  @spec build_line(TaskSchema.t()) :: String.t()
  def build_line(%TaskSchema{} = task) do
    build_line(task, Date.utc_today())
  end

  @spec build_line(TaskSchema.t(), Date.t()) :: String.t()
  def build_line(%TaskSchema{} = task, %Date{} = today) do
    meta = task.metadata || %{}

    adr = meta_value(meta, "adr_number") || meta_value(meta, "adr") || "XXXX"
    pr = meta_value(meta, "pr_number") || meta_value(meta, "pr") || "-"
    title = task.title || "(untitled)"

    "- #{Date.to_iso8601(today)} | ADR-#{adr} | PR ##{pr} | #{task.id} | #{one_line(title)}"
  end

  @doc """
  Absolute path to the timeline file on disk, or `nil` if we can't find
  the repo root. Exposed so tests can assert the expected path.
  """
  @spec timeline_path() :: String.t() | nil
  def timeline_path do
    case repo_root() do
      nil -> nil
      root -> Path.join(root, @timeline_path_from_repo_root)
    end
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp do_append(%TaskSchema{} = task) do
    case timeline_path() do
      nil ->
        Logger.info(
          "[TimelineAppender] repo root not found — skipping append for task_id=#{task.id}"
        )

        :ok

      path ->
        line = build_line(task) <> "\n"

        case File.write(path, line, [:append]) do
          :ok ->
            Logger.info("[TimelineAppender] appended timeline entry task_id=#{task.id}")
            :ok

          {:error, reason} ->
            Logger.warning(
              "[TimelineAppender] File.write append failed path=#{path} reason=#{inspect(reason)}"
            )

            :ok
        end
    end
  end

  defp adr_flag?(nil), do: false

  defp adr_flag?(%{} = metadata) do
    val = Map.get(metadata, "adr_flag") || Map.get(metadata, :adr_flag)

    case val do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp adr_flag?(_), do: false

  defp meta_value(%{} = meta, key) when is_binary(key) do
    val = Map.get(meta, key) || safe_atom_get(meta, key)

    case val do
      v when is_binary(v) and v != "" -> v
      v when is_integer(v) -> Integer.to_string(v)
      _ -> nil
    end
  end

  defp safe_atom_get(meta, key) do
    Map.get(meta, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp one_line(str) when is_binary(str) do
    str
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp one_line(_), do: "(untitled)"

  # Walk up from this module's file looking for the docs/architecture/
  # directory. Mirrors the ADR-index walk pattern in
  # `Platform.Responsibilities.Handlers.ArchitectureReviewPlan`.
  defp repo_root do
    __ENV__.file
    |> Path.expand()
    |> find_ancestor_with_dir("docs/architecture", 8)
  end

  defp find_ancestor_with_dir(_path, _dir, 0), do: nil

  defp find_ancestor_with_dir(path, dir, depth) do
    parent = Path.dirname(path)

    cond do
      parent == path -> nil
      File.dir?(Path.join(parent, dir)) -> parent
      true -> find_ancestor_with_dir(parent, dir, depth - 1)
    end
  end
end
