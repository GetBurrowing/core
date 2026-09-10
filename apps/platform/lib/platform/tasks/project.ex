defmodule Platform.Tasks.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field(:workspace_id, :binary_id)
    field(:name, :string)
    field(:slug, :string)
    field(:repo_url, :string)
    field(:default_branch, :string, default: "main")
    field(:tech_stack, :map, default: %{})
    field(:deploy_config, :map, default: %{})
    field(:config, :map, default: %{})
    # Task 01a08c1e stage 3: a paused project is invisible to the
    # TaskRouterWatcher (both `should_run?/1` and `list_should_run_tasks/0`),
    # so none of its tasks is ever dispatched. Written via `project_update`.
    field(:dispatch_paused, :boolean, default: false)
    field(:archived_at, :utc_datetime_usec)
    field(:deletion_scheduled_at, :utc_datetime_usec)
    field(:archived_cascade_org_id, :binary_id)

    belongs_to(:org, Platform.Tenancy.Org)

    has_many(:epics, Platform.Tasks.Epic)
    has_many(:tasks, Platform.Tasks.Task)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(workspace_id name slug repo_url default_branch tech_stack deploy_config config dispatch_paused org_id archived_at deletion_scheduled_at archived_cascade_org_id)a

  def changeset(project, attrs) do
    project
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :org_id])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:org_id)
    |> validate_deploy_strategy()
    |> validate_lifecycle_pipeline()
    |> validate_plan_auto_approve()
  end

  # Project-level plan auto-approval policy (task 01a08c1e stage 2).
  #
  # `config["plan_auto_approve"]` arms `Platform.Tasks.maybe_auto_approve/1`
  # for every task in the project whose submitted plan fits the policy:
  # `%{"enabled" => boolean, "max_stages" => pos_integer,
  # "allow_manual_approval" => boolean (optional, default false)}`.
  # Validated at write time for the same reason `lifecycle_pipeline` is: a
  # malformed policy discovered at plan-submit time would be a silent
  # "not armed" inside somebody else's task. Same shape as
  # `validate_lifecycle_pipeline/1`; absence is not a failure.
  defp validate_plan_auto_approve(changeset) do
    case get_change(changeset, :config) do
      nil ->
        changeset

      config when is_map(config) ->
        case Map.get(config, "plan_auto_approve") do
          nil ->
            changeset

          policy when is_map(policy) ->
            case plan_auto_approve_error(policy) do
              nil -> changeset
              reason -> add_error(changeset, :config, reason)
            end

          _ ->
            add_error(changeset, :config, "plan_auto_approve must be a map")
        end

      _ ->
        changeset
    end
  end

  defp plan_auto_approve_error(policy) do
    cond do
      not is_boolean(Map.get(policy, "enabled")) ->
        "plan_auto_approve.enabled must be a boolean"

      not (is_integer(Map.get(policy, "max_stages")) and Map.get(policy, "max_stages") > 0) ->
        "plan_auto_approve.max_stages must be a positive integer"

      not is_boolean(Map.get(policy, "allow_manual_approval", false)) ->
        "plan_auto_approve.allow_manual_approval must be a boolean"

      true ->
        nil
    end
  end

  # Lifecycle hook pipelines (ADR-0046 Amendment 1, task 019fe1b6 stage 3).
  #
  # Validated at WRITE time, not at fire time. A malformed pipeline
  # discovered when a phase boundary is crossed is a runtime failure
  # inside somebody else's task, attributed to that task; discovered on
  # save it is a form error for the person who just typed it. That is
  # the same argument `deploy_config` already makes, which is why this
  # mirrors `validate_deploy_strategy/1` rather than inventing a
  # parallel path.
  #
  # `PipelineConfig.validate/1` resolves step names against
  # `StepRegistry.server/0` — the boot singleton in prod, a per-case
  # instance under test. A changeset has nowhere to thread a server
  # argument through, so that indirection is the thing that makes this
  # callable from here at all.
  defp validate_lifecycle_pipeline(changeset) do
    case get_change(changeset, :config) do
      nil ->
        changeset

      config when is_map(config) ->
        case Map.get(config, "lifecycle_pipeline") do
          # A project may carry unrelated `config` keys and must still
          # save. Absence is not a validation failure.
          nil ->
            changeset

          pipeline when is_map(pipeline) ->
            case Platform.Lifecycle.PipelineConfig.validate(pipeline) do
              :ok -> changeset
              {:error, reason} -> add_error(changeset, :config, reason)
            end

          _ ->
            add_error(changeset, :config, "lifecycle_pipeline must be a map")
        end

      _ ->
        changeset
    end
  end

  defp validate_deploy_strategy(changeset) do
    case get_change(changeset, :deploy_config) do
      nil ->
        changeset

      deploy_config when is_map(deploy_config) ->
        case Map.get(deploy_config, "default_strategy") do
          nil ->
            changeset

          strategy when is_map(strategy) ->
            case Platform.Tasks.DeployStageBuilder.validate_strategy(strategy) do
              :ok -> changeset
              {:error, reason} -> add_error(changeset, :deploy_config, reason)
            end

          _ ->
            add_error(changeset, :deploy_config, "default_strategy must be a map")
        end

      _ ->
        changeset
    end
  end

  defp maybe_generate_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.trim("-")
  end
end
