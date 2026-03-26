defmodule Platform.Tasks.ReviewRequests do
  @moduledoc """
  Context module for the human-review gate.

  When an agent reaches a `manual_approval` validation, it submits a
  `ReviewRequest` containing one or more labelled `ReviewItem`s (screenshots,
  canvases, text evidence).  A human dispositions each item independently:

  * **approve** – marks the item as approved
  * **reject** – marks the item as `needs_revision` with feedback text

  Once every item in a request is dispositioned, `maybe_resolve_request/1`
  auto-evaluates the validation gate:

  * all approved → validation passes, gate clears
  * any needs_revision → validation fails, consolidated feedback posted to the
    task's execution space so the attention router delivers it to the agent
  """

  import Ecto.Query

  require Logger

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewItem, ReviewRequest, Validation}

  # ── Create ──────────────────────────────────────────────────────────────

  @doc """
  Create a review request with its items in a single transaction.

  `attrs` must include:
    * `:validation_id` – the manual_approval validation this review is for
    * `:task_id` – the task owning the validation
    * `:items` – list of `%{label: string, canvas_id: string?, content: string?}`

  Optional:
    * `:execution_space_id` – the execution space for feedback posting
    * `:submitted_by` – agent or user ID that submitted the request
  """
  @spec create_review_request(map()) :: {:ok, ReviewRequest.t()} | {:error, term()}
  def create_review_request(attrs) do
    items_input = Map.get(attrs, :items) || Map.get(attrs, "items", [])

    request_attrs =
      attrs
      |> Map.drop([:items, "items"])

    validation_id =
      Map.get(request_attrs, :validation_id) || Map.get(request_attrs, "validation_id")

    task_id = Map.get(request_attrs, :task_id) || Map.get(request_attrs, "task_id")

    with :ok <- maybe_reopen_manual_approval(validation_id),
         :ok <- maybe_transition_task_to_in_review(task_id) do
      Repo.transaction(fn ->
        case %ReviewRequest{} |> ReviewRequest.changeset(request_attrs) |> Repo.insert() do
          {:ok, request} ->
            items =
              Enum.map(items_input, fn item_attrs ->
                item_attrs =
                  item_attrs
                  |> normalize_string_keys()
                  |> Map.put(:review_request_id, request.id)

                case %ReviewItem{} |> ReviewItem.changeset(item_attrs) |> Repo.insert() do
                  {:ok, item} -> item
                  {:error, changeset} -> Repo.rollback(changeset)
                end
              end)

            %{request | items: items}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  # ── Read ────────────────────────────────────────────────────────────────

  @doc "Fetch a review request by ID with items preloaded."
  @spec get_review_request(binary()) :: ReviewRequest.t() | nil
  def get_review_request(id) do
    ReviewRequest
    |> Repo.get(id)
    |> Repo.preload(:items)
  end

  @doc "List all pending review requests for a task, newest first."
  @spec list_pending_for_task(binary()) :: [ReviewRequest.t()]
  def list_pending_for_task(task_id) do
    ReviewRequest
    |> where([rr], rr.task_id == ^task_id and rr.status == "pending")
    |> order_by([rr], desc: rr.inserted_at)
    |> preload(:items)
    |> Repo.all()
  end

  # ── Item disposition ────────────────────────────────────────────────────

  @doc "Approve a review item and check if the request can be resolved."
  @spec approve_item(binary(), String.t()) :: {:ok, ReviewItem.t()} | {:error, term()}
  def approve_item(item_id, reviewed_by) do
    with {:ok, item} <- fetch_item(item_id),
         {:ok, updated} <- update_item_status(item, "approved", reviewed_by, nil) do
      maybe_resolve_request(updated.review_request_id)
      {:ok, updated}
    end
  end

  @doc "Reject a review item with feedback and check if the request can be resolved."
  @spec reject_item(binary(), String.t(), String.t()) ::
          {:ok, ReviewItem.t()} | {:error, term()}
  def reject_item(item_id, reviewed_by, feedback) do
    with {:ok, item} <- fetch_item(item_id),
         {:ok, updated} <- update_item_status(item, "needs_revision", reviewed_by, feedback) do
      maybe_resolve_request(updated.review_request_id)
      {:ok, updated}
    end
  end

  # ── Resolution ──────────────────────────────────────────────────────────

  @doc """
  Check whether a review request can be resolved.

  Resolution rules:
  * any `needs_revision` item → resolve immediately and fail the validation
  * all items approved → resolve and pass the validation
  * otherwise → keep waiting

  Returns `:resolved` or `:not_yet`.
  """
  @spec maybe_resolve_request(binary()) :: :resolved | :not_yet
  def maybe_resolve_request(request_id) do
    request = get_review_request(request_id)

    if request == nil do
      :not_yet
    else
      cond do
        Enum.any?(request.items, &(&1.status == "needs_revision")) ->
          resolve_request(request)

        Enum.all?(request.items, &(&1.status == "approved")) ->
          resolve_request(request)

        true ->
          :not_yet
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp fetch_item(item_id) do
    case Repo.get(ReviewItem, item_id) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  defp maybe_reopen_manual_approval(nil), do: :ok

  defp maybe_reopen_manual_approval(validation_id) do
    case Repo.get(Validation, validation_id) do
      %Validation{kind: "manual_approval", status: "failed"} ->
        case PlanEngine.reopen_manual_approval(validation_id) do
          {:ok, _validation} -> :ok
          {:error, :already_passed} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp maybe_transition_task_to_in_review(nil), do: :ok

  defp maybe_transition_task_to_in_review(task_id) do
    case Tasks.get_task_detail(task_id) do
      %{status: "in_progress"} = task ->
        case Tasks.transition_task(task, "in_review") do
          {:ok, _updated} -> :ok
          {:error, :invalid_transition} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp update_item_status(item, status, reviewed_by, feedback) do
    item
    |> ReviewItem.changeset(%{
      status: status,
      reviewed_by: reviewed_by,
      reviewed_at: DateTime.utc_now(),
      feedback: feedback
    })
    |> Repo.update()
  end

  defp resolve_request(request) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Mark the request itself as resolved
      request
      |> ReviewRequest.changeset(%{status: "resolved", resolved_at: now})
      |> Repo.update!()

      # Clear any sibling pending requests for the same validation so the UI
      # only reflects the currently active manual-review gate.
      resolve_sibling_requests(request, now)

      all_approved? = Enum.all?(request.items, &(&1.status == "approved"))

      if all_approved? do
        PlanEngine.evaluate_validation(request.validation_id, %{
          status: "passed",
          evidence: %{review_request_id: request.id},
          evaluated_by: "review_gate"
        })
      else
        # Collect feedback from rejected items
        feedback_lines =
          request.items
          |> Enum.filter(&(&1.status == "needs_revision"))
          |> Enum.map(fn item ->
            feedback = item.feedback || "(no feedback provided)"
            "**#{item.label}**: #{feedback}"
          end)

        consolidated =
          "## Review Feedback\n\n" <>
            "The following items need revision:\n\n" <>
            Enum.join(feedback_lines, "\n\n")

        PlanEngine.evaluate_validation(request.validation_id, %{
          status: "failed",
          evidence: %{review_request_id: request.id, feedback: consolidated},
          evaluated_by: "review_gate"
        })

        # Post consolidated feedback to execution space if available
        if request.execution_space_id do
          Platform.Orchestration.ExecutionSpace.post_engagement(
            request.execution_space_id,
            consolidated
          )
        end

        maybe_return_task_to_in_progress(request.task_id)
      end
    end)

    :resolved
  end

  defp resolve_sibling_requests(request, now) do
    from(rr in ReviewRequest,
      where:
        rr.validation_id == ^request.validation_id and rr.status == "pending" and
          rr.id != ^request.id
    )
    |> Repo.update_all(set: [status: "resolved", resolved_at: now, updated_at: now])
  end

  defp maybe_return_task_to_in_progress(task_id) do
    case Tasks.get_task_detail(task_id) do
      %{status: "in_review"} = task ->
        case Tasks.transition_task(task, "in_progress") do
          {:ok, _updated} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[ReviewRequests] failed to return task #{task_id} to in_progress after rejected review: #{inspect(reason)}"
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  defp normalize_string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, val} when is_binary(key) ->
        {String.to_existing_atom(key), val}

      {key, val} when is_atom(key) ->
        {key, val}
    end)
  rescue
    ArgumentError -> map
  end
end
