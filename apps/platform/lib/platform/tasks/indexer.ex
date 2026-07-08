defmodule Platform.Tasks.Indexer do
  @moduledoc """
  Pure payload shaper — translates `%Platform.Tasks.Task{}` rows into
  `Platform.Memory.Provider.entry/0` maps for semantic ingest.

  Mirrors the shape of `Platform.Org.Wiki.Indexer.Payload`. Stays pure so
  the write-path hooks in `Platform.Tasks.create_task/1` +
  `update_task/2` and the one-shot `Mix.Tasks.Platform.Tasks.Embed`
  backfill share the same corpus construction without a GenServer in
  between — the write path fires the entry through
  `Platform.Memory.ingest_async/1`, the backfill through
  `Platform.Memory.ingest/1`.

  ## `memory_type` corpus tag

  Entries carry `memory_type: "task"` so stage 3's `memory_search` corpus
  routing can tell task hits apart from page/journal/message hits without
  peeking at metadata. The memory-service payload accepts free-form
  strings, so no provider-side change is needed to introduce a new
  corpus label.

  ## Embed corpus

  The embedded text is `title || " — " || description || " — " ||
  feature_area`. `feature_area` lives under `metadata["feature_area"]`
  (it isn't a top-level column — see `Platform.Tasks.Task`). Missing
  pieces collapse to empty strings so the same shape survives partial
  tasks (title-only backlog items) without producing a "nil" literal
  inside the embed corpus.
  """

  alias Platform.Memory.Provider
  alias Platform.Tasks.Task

  @task_memory_type "task"

  @doc "Canonical `memory_type` value the indexer stamps on task entries."
  @spec task_memory_type() :: String.t()
  def task_memory_type, do: @task_memory_type

  @doc """
  Build a `Provider.entry/0` from a task row.

  `project_id` propagates as the tenancy scope key (ADR-0042). `epic_id`,
  `status`, `priority`, and `updated_at` flow through `metadata` so stage 3
  can hydrate task-hit response fields without a follow-up Repo pass.
  """
  @spec build_entry(Task.t()) :: Provider.entry()
  def build_entry(%Task{} = task) do
    feature_area = feature_area(task.metadata)

    %{
      id: to_string(task.id),
      content: build_content(task, feature_area),
      memory_type: @task_memory_type,
      date: date_from(task.inserted_at),
      project_id: nil_or_string(task.project_id),
      metadata: %{
        "status" => task.status,
        "priority" => task.priority,
        "project_id" => nil_or_string(task.project_id),
        "epic_id" => nil_or_string(task.epic_id),
        "feature_area" => feature_area,
        "updated_at" => datetime_iso(task.updated_at)
      }
    }
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp build_content(%Task{} = task, feature_area) do
    [task.title || "", task.description || "", feature_area || ""]
    |> Enum.join(" — ")
  end

  defp feature_area(nil), do: ""
  defp feature_area(%{} = metadata), do: Map.get(metadata, "feature_area") || ""
  defp feature_area(_), do: ""

  defp date_from(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
  defp date_from(_), do: Date.utc_today() |> Date.to_iso8601()

  defp datetime_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_iso(_), do: nil

  defp nil_or_string(nil), do: nil
  defp nil_or_string(v), do: to_string(v)
end
