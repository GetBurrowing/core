defmodule Platform.Tasks.DeployStageBuilder do
  @moduledoc """
  Builds deploy stage definitions from a resolved deploy strategy.

  Converts a strategy map (e.g. `%{"type" => "pr_merge", "config" => %{...}}`)
  into a stage definition suitable for insertion by PlanEngine as the final
  stage of a plan.

  ## CI & Merge Validations

  For `pr_merge` strategy, the builder uses a single validation:
  - `pr_merged` — auto-evaluated by the GitHub `pull_request.closed` webhook
    when the PR is merged. CI is implied because GitHub branch protection
    (and the auto-merge wait-for-CI behavior) prevent a merge before checks
    pass. Whether the merge is performed by a human or by the AutoMerger,
    the validation is satisfied the same way: the webhook marks `pr_merged`
    as passed.

  For `docker_deploy` strategy:
  - `ci_passed` — auto-evaluated by webhook
  - `test_pass` — deploy health check (agent evaluates)

  For `fly` strategy:
  - Same as `docker_deploy`
  """

  @valid_strategy_types ~w(none pr_merge docker_deploy fly skill_driven manual)
  @valid_merge_methods ~w(squash merge rebase)

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Build a deploy stage definition from a resolved strategy map.

  Returns a map with `:name`, `:description`, `:position`, and `:validations`,
  or `:skip` if the strategy type is `"none"`.

  ## Examples

      iex> DeployStageBuilder.build_stage(%{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}}, 3)
      %{name: "Deploy: PR merge", description: "...", position: 3, validations: [...]}

      iex> DeployStageBuilder.build_stage(%{"type" => "none"}, 3)
      :skip
  """
  @spec build_stage(map(), pos_integer()) :: map() | :skip
  def build_stage(%{"type" => "none"}, _position), do: :skip

  def build_stage(%{"type" => "pr_merge"} = strategy, position) do
    config = Map.get(strategy, "config", %{})

    # Single pr_merged validation auto-evaluated by the GitHub
    # pull_request.closed webhook. CI is implied via branch protection
    # / auto-merge wait-for-CI — no separate ci_passed gate is needed
    # at the deploy stage.
    %{
      name: "Deploy: PR merge",
      description: pr_merge_description(config),
      position: position,
      validations: [%{kind: "pr_merged"}]
    }
  end

  def build_stage(%{"type" => "docker_deploy"} = strategy, position) do
    config = Map.get(strategy, "config", %{})

    %{
      name: "Deploy: Docker deploy",
      description: docker_deploy_description(config),
      position: position,
      validations: [%{kind: "ci_passed"}, %{kind: "test_pass"}]
    }
  end

  def build_stage(%{"type" => "fly"} = strategy, position) do
    config = Map.get(strategy, "config", %{})

    %{
      name: "Deploy: Fly deploy",
      description: fly_description(config),
      position: position,
      validations: [%{kind: "ci_passed"}, %{kind: "test_pass"}]
    }
  end

  def build_stage(%{"type" => "skill_driven"} = strategy, position) do
    config = Map.get(strategy, "config", %{})
    skill_id = Map.get(strategy, "skill_id")

    %{
      name: "Deploy: Skill execution",
      description: skill_driven_description(config, skill_id),
      position: position,
      validations: [%{kind: "manual_approval"}]
    }
  end

  def build_stage(%{"type" => "manual"} = _strategy, position) do
    %{
      name: "Deploy: Manual",
      description:
        "Manual deployment required. A human or agent should perform the deploy " <>
          "and confirm completion via manual approval.",
      position: position,
      validations: [%{kind: "manual_approval"}]
    }
  end

  # ── Strategy Validation ────────────────────────────────────────────────

  @doc """
  Validate a deploy strategy map shape.

  Returns `:ok` if the strategy is valid, or `{:error, reason}` if not.
  Used by `Project.changeset/2` to validate `deploy_config["default_strategy"]`.

  ## Valid shapes

      %{"type" => "pr_merge", "config" => %{"auto_merge" => bool, "merge_method" => "squash"|"merge"|"rebase", ...}}
      %{"type" => "docker_deploy", "config" => %{"host" => str, "image" => str, ...}}
      %{"type" => "fly", "config" => %{"app" => str, ...}}
      %{"type" => "skill_driven", "skill_id" => str, "config" => %{...}}
      %{"type" => "manual"}
      %{"type" => "none"}
  """
  @spec validate_strategy(map()) :: :ok | {:error, String.t()}
  def validate_strategy(%{"type" => type}) when type in @valid_strategy_types do
    :ok
  end

  def validate_strategy(%{"type" => type}) do
    {:error,
     "unknown strategy type: #{type}. Valid types: #{Enum.join(@valid_strategy_types, ", ")}"}
  end

  def validate_strategy(_), do: {:error, "strategy must have a \"type\" key"}

  @doc """
  Validate the merge method value.
  """
  @spec valid_merge_method?(String.t()) :: boolean()
  def valid_merge_method?(method), do: method in @valid_merge_methods

  @doc "List valid strategy types."
  @spec valid_strategy_types() :: [String.t()]
  def valid_strategy_types, do: @valid_strategy_types

  # ── Private helpers ────────────────────────────────────────────────────

  defp pr_merge_description(config) do
    auto_merge = Map.get(config, "auto_merge", false)
    require_review = Map.get(config, "require_review_approval", false)
    merge_method = Map.get(config, "merge_method", "squash")

    parts = [
      "Deploy via PR merge flow.",
      "Push the task branch and open a PR against the default branch.",
      "Stage completes when the PR is merged " <>
        "(pr_merged validation, auto-evaluated by the GitHub pull_request.closed webhook).",
      "CI is enforced by GitHub branch protection / auto-merge wait-for-CI " <>
        "before the merge is allowed; no separate CI gate is tracked here.",
      if(require_review,
        do: "PR review approval is required.",
        else: "PR review approval is not required."
      ),
      if(auto_merge,
        do:
          "Auto-merge is enabled — PR will be merged automatically when CI passes " <>
            "(merge method: #{merge_method}).",
        else: "Auto-merge is disabled — a human merges the PR via GitHub."
      )
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp docker_deploy_description(config) do
    parts = [
      "Deploy via Docker.",
      "CI must pass (ci_passed validation, auto-evaluated by webhook).",
      "Execute the deployment (pull image, compose up, health check).",
      "test_pass validation covers deploy execution and health check."
    ]

    host = Map.get(config, "host")
    image = Map.get(config, "image")

    extra = [
      if(host, do: "Target host: #{host}.", else: nil),
      if(image, do: "Image: #{image}.", else: nil)
    ]

    (parts ++ extra) |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp fly_description(config) do
    app = Map.get(config, "app")

    parts = [
      "Deploy via Fly.io.",
      "CI must pass (ci_passed validation, auto-evaluated by webhook).",
      "Execute fly deploy and verify health check.",
      "test_pass validation covers deploy execution and health check.",
      if(app, do: "Fly app: #{app}.", else: nil)
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp skill_driven_description(config, skill_id) do
    parts = [
      "Deploy via skill execution.",
      if(skill_id, do: "Skill ID: #{skill_id}.", else: "No skill ID specified."),
      "The attached skill defines the deploy procedure.",
      "manual_approval confirms successful execution."
    ]

    extra_context = Map.get(config, "context")

    extra = [
      if(extra_context, do: "Additional context: #{extra_context}", else: nil)
    ]

    (parts ++ extra) |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end
end
