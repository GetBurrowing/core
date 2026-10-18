defmodule Platform.Tasks.Feedback do
  @moduledoc """
  Pushes feedback from any source into a run's ETS context session.

  Feedback items are run-scoped context items with kind `:feedback`. They are
  automatically evicted when the run session ends. Broadcast happens via the
  context plane's PubSub — no extra wiring needed.

  ## Usage

      Platform.Tasks.Feedback.push(run_id, %{
        source: :chat,
        author: "user:alex",
        content: "Use postgres instead of sqlite",
        timestamp: DateTime.utc_now()
      })

      Platform.Tasks.Feedback.list_feedback(run_id)
  """

  alias Platform.Context
  alias Platform.Execution

  @doc """
  Pushes a feedback item into the run's context session.

  `attrs` must include:
    - `:source`    — `:chat | :review | :ui`
    - `:author`    — string identifying the author
    - `:content`   — the feedback text
    - `:timestamp` — `DateTime.t()` (defaults to now if omitted)

  Returns `{:ok, version}` where version is the new context version,
  or `{:error, reason}` if the run cannot be found.
  """
  @spec push(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def push(run_id, attrs) do
    with {:ok, run} <- safe_get_run(run_id) do
      timestamp = Map.get(attrs, :timestamp) || Map.get(attrs, "timestamp") || DateTime.utc_now()
      ts_ms = DateTime.to_unix(timestamp, :millisecond)
      unique_suffix = System.unique_integer([:positive, :monotonic])

      scope = run_scope(run)
      key = "feedback.#{ts_ms}.#{unique_suffix}"

      value =
        %{
          source: to_string(Map.get(attrs, :source) || Map.get(attrs, "source", "chat")),
          author: Map.get(attrs, :author) || Map.get(attrs, "author", "unknown"),
          content: Map.get(attrs, :content) || Map.get(attrs, "content", ""),
          timestamp: DateTime.to_iso8601(timestamp)
        }
        |> Jason.encode!()

      result = Context.put_item(scope, key, value, kind: :feedback)

      case result do
        {:ok, version} ->
          emit_telemetry(run_id, key)
          {:ok, version}

        error ->
          error
      end
    end
  end

  @doc """
  Lists all feedback items for a run's context session.

  Returns a list of decoded feedback maps, sorted by timestamp.
  """
  @spec list_feedback(String.t()) :: [map()]
  def list_feedback(run_id) do
    case safe_get_run(run_id) do
      {:ok, run} ->
        scope = run_scope(run)

        case Context.snapshot(scope) do
          {:ok, %{items: items}} ->
            items
            |> Enum.filter(&(&1.kind == :feedback))
            |> Enum.map(fn item ->
              case Jason.decode(item.value) do
                {:ok, decoded} -> decoded
                _ -> %{"raw" => item.value}
              end
            end)
            |> Enum.sort_by(& &1["timestamp"])

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp safe_get_run(run_id) do
    Execution.get_run(run_id)
  catch
    :exit, _ -> {:error, :run_not_found}
  end

  defp run_scope(run) do
    %{
      project_id: run.project_id,
      epic_id: run.epic_id,
      task_id: run.task_id,
      run_id: run.id
    }
  end

  defp emit_telemetry(run_id, key) do
    :telemetry.execute(
      [:platform, :tasks, :feedback_pushed],
      %{system_time: System.system_time()},
      %{run_id: run_id, key: key}
    )
  end
end
