defmodule Platform.Deploy.SkipNotice do
  @moduledoc """
  Posts one chat message when a CI run on the deploy branch concludes in
  anything other than `success`, i.e. when the production deploy hook will
  NOT fire for that run (task 01a0feff stage 2).

  ## Why this lives in core

  The production deploy hook (Startup-Suite/core-ops
  `targets/moon-production/scripts/deploy-hook.py`) deploys only on a
  `workflow_run` event with `action == "completed"`,
  `workflow_run.conclusion == "success"` and
  `workflow_run.head_branch == DEPLOY_HOOK_BRANCH` (default `main`) — see its
  `_should_trigger`. Any other conclusion is dropped there with a log line
  nobody reads. The hook holds no Burrow credential, but core already receives
  the same `workflow_run` delivery at `/api/webhooks/github`, and can post
  through the space's system participant with no token at all.

  ## The predicate, and how it relates to the hook's

  A notice is posted when ALL of these hold:

    * `action == "completed"`;
    * `repository.full_name` equals the configured repo;
    * `workflow_run.head_branch` equals the configured branch (default `main`);
    * `workflow_run.name` equals the configured workflow (default `CI`, the
      workflow whose `Build and push image` job produces the image the hook
      deploys);
    * `workflow_run.conclusion != "success"`.

  The branch and conclusion clauses are the NEGATION of the hook's
  `_should_trigger`. The repo and workflow clauses are NARROWER than the hook:
  the hook checks neither, so a success from any workflow delivered to it on
  the branch starts `podman auto-update` — which deploys nothing new unless an
  image was pushed. If you change the hook's predicate, change this one.

  ## Contract

    * Disabled (a no-op) unless BOTH `:space_id` and `:repo` are configured
      under `config :platform, :deploy_skip_notice` (set from
      `DEPLOY_SKIP_NOTICE_SPACE_ID` / `DEPLOY_SKIP_NOTICE_REPO` in
      `config/runtime.exs`). No repository is hardcoded here.
    * Idempotent per `(run_id, run_attempt)`: a GitHub redelivery finds the
      earlier message by its metadata and posts nothing. A re-run (a new
      `run_attempt`) is a new run outcome and gets its own message. Two
      deliveries racing each other are not serialised.
    * Never raises and never affects the caller: every failure is logged at
      `warning` and `maybe_post/1` returns a tagged tuple the webhook ignores.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.{Message, Space}
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo

  require Logger

  @source "deploy_skip_notice"
  @default_branch "main"
  @default_workflow "CI"

  @doc """
  Post the skip notice for one webhook `params` map if it qualifies.

  Returns `{:ok, message}` when posted, `{:skipped, reason}` when the event
  does not qualify (or was already posted), and `{:error, reason}` when it
  qualified but posting failed. Callers are expected to ignore the result.
  """
  @spec maybe_post(map()) :: {:ok, Message.t()} | {:skipped, atom()} | {:error, term()}
  def maybe_post(params) when is_map(params) do
    with {:ok, cfg} <- config(),
         :ok <- qualifies(params, cfg) do
      post(params, cfg)
    end
  rescue
    error ->
      Logger.warning("[DeploySkipNotice] crashed: #{Exception.message(error)}")
      {:error, :exception}
  end

  def maybe_post(_params), do: {:skipped, :not_a_map}

  defp config do
    cfg = Application.get_env(:platform, :deploy_skip_notice, [])
    space_id = cfg[:space_id]
    repo = cfg[:repo]

    if present?(space_id) and present?(repo) do
      {:ok,
       %{
         space_id: space_id,
         repo: repo,
         branch: blank_default(cfg[:branch], @default_branch),
         workflow: blank_default(cfg[:workflow], @default_workflow)
       }}
    else
      {:skipped, :disabled}
    end
  end

  defp qualifies(%{"action" => "completed", "workflow_run" => %{} = run} = params, cfg) do
    cond do
      get_in(params, ["repository", "full_name"]) != cfg.repo -> {:skipped, :other_repo}
      run["head_branch"] != cfg.branch -> {:skipped, :other_branch}
      run["name"] != cfg.workflow -> {:skipped, :other_workflow}
      run["conclusion"] == "success" -> {:skipped, :success}
      true -> :ok
    end
  end

  defp qualifies(_params, _cfg), do: {:skipped, :not_a_completed_workflow_run}

  defp post(params, cfg) do
    run = params["workflow_run"]
    run_id = to_string(run["id"])
    run_attempt = to_string(run["run_attempt"] || 1)

    cond do
      not space_exists?(cfg.space_id) ->
        Logger.warning(
          "[DeploySkipNotice] configured space #{cfg.space_id} not found; " <>
            "not posting for run #{run_id} attempt #{run_attempt}"
        )

        {:error, :space_not_found}

      already_posted?(cfg.space_id, run_id, run_attempt) ->
        {:skipped, :already_posted}

      true ->
        do_post(cfg, run, run_id, run_attempt)
    end
  end

  defp do_post(cfg, run, run_id, run_attempt) do
    metadata = %{
      "source" => @source,
      "run_id" => run_id,
      "run_attempt" => run_attempt,
      "head_sha" => run["head_sha"],
      "conclusion" => run["conclusion"]
    }

    with {:ok, participant} <- ExecutionSpace.ensure_system_participant(cfg.space_id),
         {:ok, message} <-
           Chat.post_message(%{
             space_id: cfg.space_id,
             participant_id: participant.id,
             content_type: "text",
             content: content(cfg, run, run_id, run_attempt),
             log_only: false,
             metadata: metadata
           }) do
      {:ok, message}
    else
      {:error, reason} = error ->
        Logger.warning(
          "[DeploySkipNotice] post failed for run #{run_id} attempt #{run_attempt}: " <>
            inspect(reason)
        )

        error
    end
  end

  @doc false
  def content(cfg, run, run_id, run_attempt) do
    short_sha = run["head_sha"] |> to_string() |> String.slice(0, 7)

    "Prod did NOT deploy: #{cfg.branch} #{cfg.workflow} run #{run_id} attempt #{run_attempt} " <>
      "concluded #{run["conclusion"] || "unknown"} at #{short_sha} (#{run["html_url"]}). " <>
      "moon's deploy hook deploys only on conclusion=success; a re-run that ends in " <>
      "success deploys. Otherwise run podman auto-update on moon."
  end

  # Platform.UUID.valid?/1, not a bare Ecto.UUID.cast/1: the bare cast accepts
  # any 16-byte binary, and `already_posted?/3` then puts the same value into a
  # `where` on a :binary_id column, which raises on a non-uuid.
  defp space_exists?(space_id) do
    Platform.UUID.valid?(space_id) and
      Repo.exists?(from(s in Space, where: s.id == ^space_id))
  end

  defp already_posted?(space_id, run_id, run_attempt) do
    from(m in Message,
      where: m.space_id == ^space_id,
      where: fragment("?->>'source' = ?", m.metadata, ^@source),
      where: fragment("?->>'run_id' = ?", m.metadata, ^run_id),
      where: fragment("?->>'run_attempt' = ?", m.metadata, ^run_attempt)
    )
    |> Repo.exists?()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp blank_default(value, default), do: if(present?(value), do: value, else: default)
end
