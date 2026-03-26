defmodule Platform.Tasks.DeployStageBuilder do
  @moduledoc """
  Builds deploy stage definitions from a resolved deploy strategy.

  Converts a strategy map (e.g. `%{"type" => "pr_merge", "config" => %{...}}`)
  into a stage definition suitable for insertion by PlanEngine as the final
  stage of a plan.
  """

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

    %{
      name: "Deploy: PR merge",
      description: pr_merge_description(config),
      position: position,
      validations: [%{kind: "test_pass"}, %{kind: "manual_approval"}]
    }
  end

  def build_stage(%{"type" => "docker_deploy"} = strategy, position) do
    config = Map.get(strategy, "config", %{})

    %{
      name: "Deploy: Docker deploy",
      description: docker_deploy_description(config),
      position: position,
      validations: [%{kind: "test_pass"}, %{kind: "manual_approval"}]
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

  # ── Private helpers ────────────────────────────────────────────────────────

  defp pr_merge_description(config) do
    require_ci = Map.get(config, "require_ci_pass", true)
    auto_merge = Map.get(config, "auto_merge", false)
    require_review = Map.get(config, "require_review_approval", false)

    parts = [
      "Deploy via PR merge flow.",
      "Push the task branch and open a PR against the default branch.",
      if(require_ci, do: "CI must pass before merge (test_pass validation).", else: nil),
      if(require_review,
        do: "PR review approval is required.",
        else: "PR review approval is not required."
      ),
      if(auto_merge,
        do: "Auto-merge is enabled — PR will be merged automatically when checks pass.",
        else: "Auto-merge is disabled — a human must merge the PR (manual_approval validation)."
      )
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp docker_deploy_description(config) do
    parts = [
      "Deploy via Docker.",
      "Execute the deployment (pull image, compose up, health check).",
      "test_pass validation covers deploy execution and health check.",
      "manual_approval confirms the deploy is healthy in production."
    ]

    host = Map.get(config, "host")
    image = Map.get(config, "image")

    extra = [
      if(host, do: "Target host: #{host}.", else: nil),
      if(image, do: "Image: #{image}.", else: nil)
    ]

    (parts ++ extra) |> Enum.reject(&is_nil/1) |> Enum.join(" ")
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
