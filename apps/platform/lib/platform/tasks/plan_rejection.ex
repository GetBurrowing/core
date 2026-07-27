defmodule Platform.Tasks.PlanRejection do
  @moduledoc """
  Posts a plan rejection's feedback into the task's execution space.

  Hoisted VERBATIM out of `PlatformWeb.TasksLive`'s private scope (task
  019e30be v2 put it there) so that callers below the web layer can reach it.
  The human reviewer path and the architecture gate must compose the SAME
  message, from the SAME place.

  ## Why this post is load-bearing, and not a notification

  The execution-space post is the ONLY thing that actually causes a v2 to be
  authored. `TaskRouter` handles `{:plan_updated, status: "rejected"}` by
  going `:waiting_human` and clearing liveness — it does NOT re-dispatch the
  planner. The planner is woken by the CHAT MESSAGE:
  `ExecutionSpace.post_engagement/3` posts non-`log_only`, `AttentionRouter`
  rule 6 routes an execution-space message with no active agent to the task's
  assigned agent, and that is the re-dispatch.

  A rejection that persists `status: "rejected"` without this post is a stall
  in a different pose.

  Because the post is a wake-up rather than a record, it is `log_only: false`
  ON PURPOSE. A `log_only: true` message is deliberately skipped by
  `AttentionRouter` and would record the rejection without asking for a new
  version. Do not "tidy" the two into one.

  ## Failure is swallowed, deliberately

  By the time this runs the rejection is already persisted — the durable,
  user-visible truth is `plan.rejection_reason`, which
  `ContextAssembler.find_latest_rejected_reason/1` lifts into every dispatch
  context. This post is the best-effort signal on top of it. A missing
  execution space, or a failed post, is logged and returns `:ok`; it must
  never raise and never roll anything back.

  This is also why the side-effect does not live inside
  `Tasks.reject_plan/3`: that function is called from inside
  `Tasks.reopen_with_feedback/3`'s `Repo.transaction/1`, and wrapping a chat
  post in that transaction would risk rolling back the rejection if the post
  failed. Callers invoke this module explicitly, after the transaction.

  ## `Tasks.reject_plan/3` DISCARDS its `rejected_by` argument

  Worth stating because a reader will assume otherwise: the second argument
  of `Tasks.reject_plan/3` is matched as `_rejected_by` and is never
  persisted. Callers pass an actor id for symmetry with this module (which
  DOES use it, to name the rejector in the message) and for future audit, not
  because the plan row records it. Making it persist is a separate change
  with ~40 call sites; do not fold it in here.
  """

  require Logger

  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks.Plan

  @unknown_actor "the reviewer"

  @doc """
  Post `feedback` about a rejected `plan` into its task's execution space.

  Always returns `:ok`. Empty feedback posts nothing — a stub message would
  wake the planner with no actionable signal.
  """
  @spec post_feedback(Plan.t(), String.t() | nil, String.t()) :: :ok
  def post_feedback(_plan, _rejected_by, ""), do: :ok

  def post_feedback(%Plan{} = plan, rejected_by, feedback) do
    case ExecutionSpace.find_by_task_id(plan.task_id) do
      nil ->
        :ok

      space ->
        body = compose_message(plan, rejected_by, feedback)

        metadata = %{
          "reason" => "plan_rejected",
          "plan_id" => plan.id
        }

        case ExecutionSpace.post_engagement(space.id, body, metadata: metadata) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to post plan rejection feedback to execution space: #{inspect(reason)}"
            )

            :ok
        end
    end
  end

  @doc """
  The message body a planner agent reads.

  The exact shape is a contract: a whitespace change here is a silent break
  with no other guard, so it is asserted by exact string equality in tests.
  """
  @spec compose_message(Plan.t(), String.t() | nil, String.t()) :: String.t()
  def compose_message(%Plan{} = plan, rejected_by, feedback) do
    "Plan v#{plan.version} rejected by #{actor_display_name(rejected_by)}:\n\n#{feedback}"
  end

  @doc """
  Human-readable name for whoever rejected the plan.

  Resolution order mirrors `Platform.Tasks.ReviewRequests.requester_display_name/1`:
  a user's name, else an AGENT's name, else a fixed placeholder. The agent
  tier is the only semantic widening in the hoist — the architecture gate's
  actor is an agent, not a user, and inventing a third resolution order for
  it is how the two rejection messages would drift apart.

  Unlike the review-requests version this falls back to
  `#{inspect(@unknown_actor)}` rather than echoing the raw id: a UUID in a
  sentence addressed to a planner is noise, and echoing it would be a
  behaviour change on the human path.
  """
  @spec actor_display_name(String.t() | nil) :: String.t()
  def actor_display_name(actor_id) when is_binary(actor_id) do
    cond do
      name = user_name(actor_id) -> name
      name = agent_name(actor_id) -> name
      true -> @unknown_actor
    end
  rescue
    # A non-UUID actor id makes Repo.get/2 raise rather than return nil.
    #
    # WHICH lookup raises changed at the ADR-0046 merge, though the outcome
    # did not. `Accounts.get_user/1` used to raise here; main's 9b0d74d8 made
    # it TOTAL (nil for any non-UUID id), so a malformed actor now falls
    # THROUGH the user tier into `agent_name/1`. `Agent`'s primary key is also
    # `Platform.Types.UUIDv7`, so `Repo.get(Agent, "system:auto")` raises
    # exactly as the user lookup used to, and this rescue still lands on
    # `@unknown_actor`. Pinned by "a nil, blank-named, or non-UUID actor
    # renders the placeholder" in plan_rejection_test.exs.
    #
    # So the rescue is still load-bearing — do not delete it on the reasoning
    # that `Accounts.get_user/1` is total now. The agent tier is unguarded.
    _ -> @unknown_actor
  end

  def actor_display_name(_), do: @unknown_actor

  defp user_name(id) do
    case Accounts.get_user(id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp agent_name(id) do
    case Repo.get(Agent, id) do
      %Agent{name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end
end
