defmodule Platform.Deploy.Email do
  @moduledoc """
  Deploy handler for the `email` strategy (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 6): the task's deliverable is
  mailed from a named org mail account and sender.

  ## Runs inside the plan engine's transaction

  `Platform.Deploy.dispatch/3` is called from
  `PlanEngine.inject_deploy_stage/4`, inside `PlanEngine.advance/2`'s
  `Repo.transaction`. This handler therefore never touches SMTP. It writes a
  system draft and calls `Platform.Mail.Dispatch.enqueue/3`, which runs the
  same policy as every other send and records the delivery as `queued` in
  the SAME transaction. `Platform.Mail.Outbox` delivers it after commit and
  resolves this stage's `test_pass`. If the plan engine's transaction rolls
  back, there is no draft, no delivery and no audit event, so nothing is
  sent.

  ## Config

  `task.deploy_target_config`:

      %{"strategy" => "email",
        "account_id" => uuid, "sender_key" => str,
        "recipients" => [address], "recipient_user_ids" => [uuid],
        "subject" => str | nil, "deliverable_canvas_id" => uuid | nil}

  The body is the deliverable canvas exported to Markdown — the configured
  canvas, else the newest canvas in the task's execution space, as
  `Platform.Deploy.ProjectFiles` resolves it — or, with no canvas, the task
  title and a link to it.

  ## Fail closed

  Every failure fails `test_pass` at once with a named `"reason"` and sends
  nothing: `mail_disabled`, `invalid_deploy_target_config`,
  `task_has_no_org`, `account_not_found`, `account_wrong_org`,
  `account_archived`, `sender_key_not_found`, a draft refusal (e.g.
  `invalid_addresses`, `on_behalf_of_not_member`), and the policy refusals
  `send_disabled`, `external_recipients`, `rate_limited` (whose refused
  delivery row is kept). Nothing falls back to another account, the
  account's first sender, or `project.deploy_config`; this handler never
  reads `deploy_targets` and never calls `DeployResolver`.

  The deploy draft is dispatched without a hold for human editing in v1.
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.{Canvas, Space}
  alias Platform.Mail
  alias Platform.Mail.{Config, Dispatch, Drafts, Outbox}
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Task, Validation}

  @responsibility "task_deploy"
  @evaluated_by "platform.deploy.email"

  @doc """
  Queue the email deploy for `task` on `deploy_stage`. On any failure the
  stage's `test_pass` is failed here; on success it stays `pending` until
  the Outbox reports the SMTP outcome.

  Returns `{:ok, delivery}` (queued) or `{:error, reason}`.
  """
  @spec execute(Task.t(), Stage.t()) :: {:ok, Mail.Delivery.t()} | {:error, term()}
  def execute(%Task{} = task, %Stage{} = deploy_stage) do
    task = Tasks.ensure_project_loaded(task)

    with :ok <- enabled(),
         {:ok, config} <- read_config(task),
         {:ok, org_id} <- task_org(task),
         {:ok, {_account, _sender}} <-
           Mail.resolve_sender(org_id, config["account_id"], config["sender_key"]),
         {:ok, draft} <- create_draft(task, deploy_stage, org_id, config),
         {:ok, delivery} <- Dispatch.enqueue(draft.id, {:system, nil}) do
      Outbox.nudge()
      {:ok, delivery}
    else
      {:error, {:refused, reason, delivery}} ->
        report_failure(deploy_stage, task, refusal_code(reason), %{
          "delivery_id" => delivery.id,
          "refusal" => delivery.refusal_reason
        })

        {:error, {:refused, reason}}

      {:error, reason} ->
        report_failure(deploy_stage, task, reason_code(reason), %{})
        {:error, reason}
    end
  end

  # ── Steps ───────────────────────────────────────────────────────────────

  defp enabled do
    if Config.enabled?(), do: :ok, else: {:error, :mail_disabled}
  end

  defp read_config(%Task{deploy_target_config: %{"strategy" => "email"} = cfg}) do
    if valid_config?(cfg), do: {:ok, cfg}, else: {:error, :invalid_deploy_target_config}
  end

  defp read_config(%Task{}), do: {:error, :invalid_deploy_target_config}

  @doc """
  The shape check `Platform.Tasks.Task`'s changeset applies to an email
  `deploy_target_config`: a non-blank `account_id` and `sender_key`, and at
  least one recipient across `recipients` and `recipient_user_ids`, each a
  list of strings. Pure: no database.
  """
  @spec valid_config?(map()) :: boolean()
  def valid_config?(cfg) when is_map(cfg) do
    present?(cfg["account_id"]) and present?(cfg["sender_key"]) and
      string_list?(Map.get(cfg, "recipients", [])) and
      string_list?(Map.get(cfg, "recipient_user_ids", [])) and
      recipient_count(cfg) > 0 and
      (is_nil(cfg["subject"]) or is_binary(cfg["subject"]))
  end

  def valid_config?(_), do: false

  @doc "Number of recipients an email config names (addresses + user ids)."
  @spec recipient_count(map()) :: non_neg_integer()
  def recipient_count(cfg) when is_map(cfg) do
    count = fn key ->
      case Map.get(cfg, key) do
        list when is_list(list) -> Enum.count(list, &present?/1)
        _ -> 0
      end
    end

    count.("recipients") + count.("recipient_user_ids")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp string_list?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp string_list?(_), do: false

  defp task_org(%Task{project: %{org_id: org_id}}) when is_binary(org_id), do: {:ok, org_id}
  defp task_org(%Task{}), do: {:error, :task_has_no_org}

  defp create_draft(%Task{} = task, %Stage{} = stage, org_id, config) do
    Drafts.create_system(org_id, %{
      account_id: config["account_id"],
      sender_key: config["sender_key"],
      to_addresses: Map.get(config, "recipients", []),
      to_user_ids: Map.get(config, "recipient_user_ids", []),
      subject: subject(task, config),
      body: body(task, config),
      on_behalf_of_user_id: task.sponsor_user_id,
      responsibility: @responsibility,
      task_id: task.id,
      stage_id: stage.id
    })
  end

  defp subject(%Task{} = task, config) do
    case config["subject"] do
      s when is_binary(s) and s != "" -> s
      _ -> task.title || "Task deliverable"
    end
  end

  # ── Body: the deliverable canvas, as ProjectFiles resolves it ───────────

  defp body(%Task{} = task, config) do
    with {:ok, canvas} <- resolve_canvas(task, config),
         {:ok, md} when is_binary(md) <- Canvas.export_markdown(canvas) do
      md
    else
      _ -> fallback_body(task)
    end
  end

  defp resolve_canvas(%Task{} = task, config) do
    case Map.get(config, "deliverable_canvas_id") do
      id when is_binary(id) and id != "" ->
        case Chat.get_canvas(id) do
          %Canvas{} = canvas -> {:ok, canvas}
          nil -> fallback_canvas(task)
        end

      _ ->
        fallback_canvas(task)
    end
  end

  defp fallback_canvas(%Task{} = task) do
    with %Space{id: space_id} <- ExecutionSpace.find_by_task_id(task.id),
         [_ | _] = canvases <- Chat.list_canvases(space_id) do
      {:ok, Enum.max_by(canvases, & &1.inserted_at, DateTime)}
    else
      _ -> {:error, :no_deliverable_canvas}
    end
  end

  defp fallback_body(%Task{} = task) do
    "#{task.title || "Task"}\n\n#{task_url(task)}\n"
  end

  defp task_url(%Task{id: id}) do
    base =
      try do
        PlatformWeb.Endpoint.url()
      rescue
        _ -> ""
      end

    "#{base}/tasks/#{id}"
  end

  # ── Validation reporting ────────────────────────────────────────────────

  defp report_failure(%Stage{} = stage, %Task{} = task, reason, extra) do
    case test_pass_validation(stage.id) do
      %Validation{id: vid} ->
        _ =
          PlanEngine.evaluate_validation(vid, %{
            status: "failed",
            evidence: Map.merge(%{"reason" => reason, "source_task_id" => task.id}, extra),
            evaluated_by: @evaluated_by
          })

        :ok

      nil ->
        Logger.error(
          "[Deploy.Email] deploy stage #{stage.id} has no test_pass validation " <>
            "to record failure (#{reason}) against"
        )

        :ok
    end
  end

  defp test_pass_validation(stage_id) do
    from(v in Validation,
      where: v.stage_id == ^stage_id and v.kind == "test_pass",
      limit: 1
    )
    |> Repo.one()
  end

  defp refusal_code(:send_disabled), do: "send_disabled"
  defp refusal_code(:rate_limited), do: "rate_limited"
  defp refusal_code({:external_recipients, _}), do: "external_recipients"
  defp refusal_code(other), do: "refused: #{inspect(other)}"

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp reason_code(%Ecto.Changeset{}), do: "invalid_draft"
  defp reason_code(other), do: inspect(other)
end
