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

  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Inbox
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewItem, ReviewRequest, Validation}

  # ── PubSub ─────────────────────────────────────────────────────────────

  @doc """
  Build the per-task review-request PubSub topic.

  Subscribers get `{:review_request_pending, payload}` whenever a new
  manual-approval review request is created for the task and
  `{:review_request_resolved, payload}` whenever one is dispositioned.
  """
  @spec topic_for_task(String.t()) :: String.t()
  def topic_for_task(task_id), do: "review_requests:" <> to_string(task_id)

  @doc "Subscribe the calling process to the review-request topic for `task_id`."
  @spec subscribe_for_task(String.t()) :: :ok | {:error, term()}
  def subscribe_for_task(task_id) do
    Phoenix.PubSub.subscribe(Platform.PubSub, topic_for_task(task_id))
  end

  @doc "Unsubscribe the calling process from the review-request topic for `task_id`."
  @spec unsubscribe_for_task(String.t()) :: :ok
  def unsubscribe_for_task(task_id) do
    Phoenix.PubSub.unsubscribe(Platform.PubSub, topic_for_task(task_id))
  end

  defp broadcast_for_task(task_id, message) do
    Phoenix.PubSub.broadcast(Platform.PubSub, topic_for_task(task_id), message)
  end

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
      result =
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

      case result do
        {:ok, request} = ok ->
          broadcast_for_task(request.task_id, {
            :review_request_pending,
            %{
              task_id: request.task_id,
              validation_id: request.validation_id,
              request_id: request.id,
              execution_space_id: request.execution_space_id
            }
          })

          maybe_emit_reviewer_inbox(request)

          ok

        other ->
          other
      end
    end
  end

  # ── Read ────────────────────────────────────────────────────────────────

  @doc "Fetch a review request by ID with items preloaded."
  @spec get_review_request(binary()) :: ReviewRequest.t() | nil
  def get_review_request(id) do
    # `id` is a `phx-value-` param off the review UI. Platform.UUID.valid?/1,
    # not a bare Ecto.UUID.cast/1 — a bare cast accepts any 16-byte binary and
    # the raise lands inside Repo regardless.
    if Platform.UUID.valid?(id) do
      ReviewRequest
      |> Repo.get(id)
      |> Repo.preload(:items)
    end
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

  # `item_id` is a `phx-value-` param off the review-approval event.
  defp fetch_item(item_id) do
    item = if Platform.UUID.valid?(item_id), do: Repo.get(ReviewItem, item_id)

    case item do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  defp maybe_reopen_manual_approval(nil), do: :ok

  defp maybe_reopen_manual_approval(validation_id) do
    validation =
      if Platform.UUID.valid?(validation_id), do: Repo.get(Validation, validation_id)

    case validation do
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

    outcome = if Enum.all?(request.items, &(&1.status == "approved")), do: :passed, else: :failed

    broadcast_for_task(request.task_id, {
      :review_request_resolved,
      %{
        task_id: request.task_id,
        validation_id: request.validation_id,
        request_id: request.id,
        outcome: outcome
      }
    })

    maybe_dismiss_reviewer_inbox(request)

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

  # ── Inbox producer (task-SPONSOR review-attention rows) ──────────────────

  @doc """
  Whether `task_id` has ANY pending review request.

  The predicate behind both the per-task inbox rollup (leave the row while work
  remains) and `Platform.Inbox.reconcile_for_user/1` (dismiss the row once no
  pending review remains). One indexed EXISTS.
  """
  @spec task_has_pending_reviews?(binary()) :: boolean()
  def task_has_pending_reviews?(task_id) when is_binary(task_id) do
    Repo.exists?(
      from(rr in ReviewRequest, where: rr.task_id == ^task_id and rr.status == "pending")
    )
  end

  def task_has_pending_reviews?(_), do: false

  @doc "Resolve the owning task id for a review-request id, or nil if it's gone."
  @spec task_id_for_request(binary()) :: binary() | nil
  def task_id_for_request(request_id) when is_binary(request_id) do
    Repo.one(from(rr in ReviewRequest, where: rr.id == ^request_id, select: rr.task_id))
  end

  def task_id_for_request(_), do: nil

  # Post-commit, best-effort: surface a review gate to the human who OWNS the
  # task — its ADR-0042 SPONSOR — not the review-phase technical assignee
  # (which is an agent on agent-run tasks, so the old routing emitted nothing).
  #
  # Rolled up PER TASK: at most ONE live `(sponsor, "task_review", task.id)`
  # row regardless of how many review gates the task fans out. The row means
  # "this task has review(s) awaiting you" and deep-links to the task detail
  # (where every review lives), not a per-request anchor.
  #
  # A failure here must never roll back or error the already-created request.
  defp maybe_emit_reviewer_inbox(request) do
    with %{} = task <- Tasks.get_task_detail(request.task_id),
         {:user, sponsor_uid} <- sponsor_user_id(task),
         # Never self-notify the human who filed the review.
         false <- sponsor_uid == request.submitted_by,
         # Only PENDING human decisions surface; auto-resolved requests emit none.
         "pending" <- request.status,
         # Per-task rollup: if a live row already exists for this (sponsor,
         # task), fold into it — no duplicate insert.
         false <- Inbox.active_source_row?(sponsor_uid, "task_review", task.id) do
      requester = requester_display_name(request.submitted_by)

      Inbox.emit(%{
        user_id: sponsor_uid,
        kind: "review_request_pending",
        source_type: "task_review",
        source_id: task.id,
        title: "Review awaiting you: #{task.title}",
        body: "Requested by #{requester}",
        url: "/tasks/#{task.id}"
      })

      :ok
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning(
        "[ReviewRequests] failed to emit sponsor inbox row for request #{request.id}: #{inspect(error)}"
      )

      :ok
  end

  # Post-resolution, best-effort: clear the rolled-up (sponsor, task) row ONLY
  # when the task has NO remaining pending review requests. `resolve_request/1`
  # has already marked this request (and same-validation siblings) resolved in
  # the DB before this runs, so the pending check reflects the post-resolution
  # state. If other review gates on the task remain pending, the row stays.
  defp maybe_dismiss_reviewer_inbox(request) do
    with %{} = task <- Tasks.get_task_detail(request.task_id),
         {:user, sponsor_uid} <- sponsor_user_id(task),
         false <- task_has_pending_reviews?(task.id) do
      Inbox.dismiss_by_source(sponsor_uid, "task_review", task.id)
      :ok
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning(
        "[ReviewRequests] failed to dismiss sponsor inbox row for request #{request.id}: #{inspect(error)}"
      )

      :ok
  end

  # Resolve the task SPONSOR to a human user id, or `:skip`. Rowan's directive:
  # review items route to the sponsor (the human who owns the task), never fan
  # out to a separate review-phase assignee.
  defp sponsor_user_id(%{sponsor_user_id: uid}) when is_binary(uid), do: {:user, uid}
  defp sponsor_user_id(_), do: :skip

  # Best-effort human-readable name for whoever submitted the request: a user's
  # name/email, else an agent's name/slug, else the raw id. Handles nil.
  #
  # Both arms are now TOTAL, so this carries no `rescue`. It used to end in a
  # bare `rescue _ -> submitted_by`, and that clause was not merely defensive:
  # `submitted_by` at an agent boundary is an agent slug or "system" /
  # "system:auto" far more often than a user UUID, so `Repo.get(Agent, "higgins")`
  # raised `Ecto.Query.CastError` on the COMMON path and the rescue returned the
  # raw slug. A review filed by agent `higgins` rendered as "Requested by
  # higgins" rather than the agent's display name — a behaviour bug the rescue
  # hid, not just a crash it absorbed. Guarding the arm is what makes the slug
  # branch reachable at all. (Task 019fa129 stage 5.)
  defp requester_display_name(nil), do: "Unknown"

  defp requester_display_name(submitted_by) when is_binary(submitted_by) do
    cond do
      user = Accounts.get_user(submitted_by) ->
        user.name || user.email || submitted_by

      agent = fetch_agent_for_display(submitted_by) ->
        agent.name || agent.slug || submitted_by

      true ->
        submitted_by
    end
  end

  defp requester_display_name(submitted_by), do: to_string(submitted_by)

  # Mirrors the SHAPE of `Platform.Agents.Orchestration.fetch_agent/1` — UUID
  # branch, then a `slug:` fallback — but the predicate is `Platform.UUID.valid?/1`,
  # NOT the bare `Ecto.UUID.cast/1` all three `fetch_agent/1` copies carried
  # before stage 4 of this task. A bare cast hex-encodes any 16-byte binary and
  # returns `{:ok, _}`, so a 16-character slug clears it, takes the UUID branch,
  # and `Repo` raises against `Agent`'s strict `Platform.Types.UUIDv7` PK anyway.
  # See `Platform.UUID`'s moduledoc.
  #
  # `slug` is a plain string column, so the fallback cannot raise whatever it is
  # handed: `"system:auto"` simply misses and falls through to the raw-id arm.
  defp fetch_agent_for_display(value) do
    if Platform.UUID.valid?(value) do
      Repo.get(Agent, value)
    else
      Repo.get_by(Agent, slug: value)
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
