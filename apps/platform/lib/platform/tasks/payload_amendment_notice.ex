defmodule Platform.Tasks.PayloadAmendmentNotice do
  @moduledoc """
  Posts one log message into a task's execution space for every committed
  `Platform.Tasks.amend_validation_payload/4` (task 01a0e266 stage 2).

  Mirrors `Platform.Tasks.PlanRejection.post_feedback/3`: find the space,
  skip when there is none, always return `:ok`, log on failure. The body is
  built by the pure `compose_message/4`, whose exact shape is pinned by an
  exact-string test.

  ## Why `post_log`, not `post_engagement`

  The notice is a record for the humans reading the space. An engagement
  message routes attention to the task's assignee, which is the executor
  this very case grades, woken mid-stage by a change it may not act on
  (stage 1 refuses it). The next gate agent already receives the amendment
  inside its e2e dispatch (`HeartbeatScheduler.put_payload_amendments/2`).

  What makes `post_log` non-routing is `AttentionRouter`'s execution-space
  `log_only` exit in `do_route/1`. Until task 01a0e266's remediation stage
  that exit was a bare `if` whose value Elixir discarded, so this notice DID
  add the assignee to the space and wake it (the task-level review measured
  it). The exit is now a `cond` branch, pinned in `attention_router_test.exs`:
  a `post_log` into an execution space leaves its participants unchanged and
  dispatches nothing, while a non-log post in the same space still routes to
  the assignee.

  ## Mention tokens are neutralised

  `reason` is caller-supplied text. The system participant that posts this
  has no `author_user_id`, so `Chat.mention_summon_authorized?/2` already
  refuses to summon anyone from it, but the body must still carry no
  bracketed mention token: that refusal is one guard, and a quoted token
  would sit in the space's history for any later reader or forwarder to
  re-parse. Every at-sign immediately followed by an open bracket in the
  composed body gets a space inserted between the two, which is the
  smallest change that `AttentionRouter.extract_mention_tokens/1`'s pattern
  cannot match.

  ## Failure is swallowed, deliberately

  This runs after the amendment has committed. The durable record is the
  row's `payload_amendments` and the audit event; this post is a
  best-effort notice on top of them and must never change
  `amend_validation_payload/4`'s return value, so it rescues everything.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks.{PayloadAmendmentChanges, Plan, Validation}

  @system_amender PayloadAmendmentChanges.system_amender()

  # Built at compile time from two halves so the source itself carries no
  # literal token.
  @token_open "@" <> "["
  @token_open_neutralised "@" <> " ["

  @doc """
  Post the notice for the amendment `entry` just appended to `validation`
  (the UPDATED row) on `plan`. `agent_id` is the amending agent's UUID, or
  nil on the operator path.

  Always returns `:ok`. A task with no execution space posts nothing.
  """
  @spec post(Validation.t(), Plan.t(), map(), Ecto.UUID.t() | nil) :: :ok
  def post(%Validation{} = validation, %Plan{} = plan, entry, agent_id \\ nil) do
    case ExecutionSpace.find_by_task_id(plan.task_id) do
      nil ->
        Logger.info(
          "PayloadAmendmentNotice: task #{plan.task_id} has no execution space; " <>
            "amendment of validation #{validation.id} not posted"
        )

        :ok

      space ->
        n = length(validation.payload_amendments || [])
        body = compose_message(validation, entry, n, amender_display(entry, agent_id))

        metadata = %{
          "reason" => "validation_payload_amended",
          "validation_id" => validation.id,
          "amendment_number" => n
        }

        case ExecutionSpace.post_log(space.id, body, metadata: metadata) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "PayloadAmendmentNotice: failed to post amendment of validation " <>
                "#{validation.id}: #{inspect(reason)}"
            )

            :ok
        end
    end
  rescue
    error ->
      Logger.warning(
        "PayloadAmendmentNotice: raised posting amendment of validation " <>
          "#{validation.id}: #{Exception.message(error)}"
      )

      :ok
  end

  @doc """
  The message body. Pure; the exact shape is a contract asserted by exact
  string equality in tests.

  `validation` is the UPDATED row (its `evaluation_payload` is the new
  text), `entry` the history entry just appended (its `prior_payload` is the
  replaced text, its `reason` the caller's reason), `amendment_number` the
  1-based position of `entry`, and `amender` the display name from
  `amender_display/2`.
  """
  @spec compose_message(Validation.t(), map(), pos_integer(), String.t()) :: String.t()
  def compose_message(%Validation{} = validation, entry, amendment_number, amender) do
    fields =
      case changed_fields(entry["prior_payload"], validation.evaluation_payload) do
        [] -> "none of setup/actions/expected"
        list -> Enum.join(list, ", ")
      end

    ("E2E case amended: #{validation.id} (amendment #{amendment_number}, changed: #{fields}). " <>
       "Amended by #{amender}. Reason: #{entry["reason"]}")
    |> neutralise_mentions()
  end

  @doc """
  Which of `setup`, `actions`, `expected` differ between two payloads, in
  that order. Delegates to `Platform.Tasks.PayloadAmendmentChanges`, which
  the task page's amendment marker also reads, so the notice and the page
  cannot disagree about what changed (task 01a0e266 stage 3).
  """
  @spec changed_fields(map() | nil, map() | nil) :: [String.t()]
  defdelegate changed_fields(prior, current), to: PayloadAmendmentChanges

  @doc """
  The amender as the space should name it: `system (no agent)` for an
  actor_type `system` entry; else the agent's `name` when an agent id was
  carried and resolves to a named agent; else the entry's `amended_by`
  label.
  """
  @spec amender_display(map(), Ecto.UUID.t() | nil) :: String.t()
  def amender_display(%{"actor_type" => "system"}, _agent_id), do: @system_amender

  def amender_display(entry, agent_id) do
    agent_name(agent_id) || to_string(entry["amended_by"] || @system_amender)
  end

  @doc """
  Break every bracketed mention opener in `text` so no mention parser reads
  a token out of it. Only the at-sign-bracket pair is touched.
  """
  @spec neutralise_mentions(String.t()) :: String.t()
  def neutralise_mentions(text) when is_binary(text),
    do: String.replace(text, @token_open, @token_open_neutralised)

  defp agent_name(agent_id) when is_binary(agent_id) do
    if Platform.UUID.valid?(agent_id) do
      case Repo.get(Agent, agent_id) do
        %Agent{name: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end
    end
  end

  defp agent_name(_agent_id), do: nil
end
