defmodule Platform.Experiments.Experiment do
  @moduledoc """
  A prompt experiment: a hypothesis, the metric that decides it, and a
  lifecycle. Task 019fe6b9, ADR-0048.

  ## Status is a real lifecycle, and `stopped` is not `concluded`

  The four statuses are `draft | running | stopped | concluded`, and
  **`stopped` and `concluded` are DIFFERENT statuses that both stay
  visible.** Nothing — no query, no changeset, no default, no listing —
  may collapse one onto the other or filter `stopped` out.

  An experiment that made things worse is a row worth keeping; it is often
  the most instructive one on the page. A codebase that quietly drops its
  failures keeps only the results that flattered it, and the record stops
  being evidence.

  ## The control-variant guard lives here, not in the context

  `changeset/2` REFUSES a transition to `running` unless a variant row with
  slug `"control"` already exists for the experiment. This is enforced in
  Elixir at the changeset rather than by convention in
  `Platform.Experiments`, so that calling the changeset directly and
  inserting via `Repo` cannot produce a running experiment without a
  control.

  The reason it must hold at this level: per ADR-0048 the control is a
  variant ROW carrying a snapshot of the prompt, not an implicit pointer at
  the live `prompt_templates.content`. A running experiment with no control
  row has nothing to compare against, and the comparison degrades with no
  error anywhere — exactly the failure this guard exists to make loud.

  ## Tenancy is two COLUMNS, not a scope blob (task 01a0d415)

  `org_id` and `project_id` say who the experiment is for. NULL means wider:
  a null org is install-wide, a null project is org-wide. They are real FK
  columns (restrict on delete) rather than keys inside a JSON map because
  tenancy must be ONE key shape across experiments and the tables around them
  — indexable, FK-checked and joinable. Epic lists, cohorts and time windows
  are not tenancy; they stay in `assignment_policy`, where the policy modules
  read them.

  When `project_id` is set and `org_id` is absent, the org is DERIVED from the
  project. When both are set and disagree the changeset refuses with
  `project does not belong to org` — an experiment whose two scope columns
  name different tenants has no coherent audience.

  ## The surface binding

  `surface_key` / `surface_target` name the decision point the experiment is
  on (see `Platform.Experiments.Surfaces`). For prompt experiments they are
  derived from `target_template_slug` when it is bound, so every existing
  caller of `Platform.Experiments.activate/2` binds the surface without
  knowing it exists.

  ## Stop-with-feedback fields only move WITH a stop

  `stop_feedback`, `stopped_by_user_id` and `stopped_at` are accepted only by
  a changeset that transitions the experiment INTO `stopped`. Feedback
  attached to a running experiment would read, to the Scientist, as the
  reason for a stop that never happened.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Platform.Experiments.MetricKind
  alias Platform.Experiments.PolicySpec
  alias Platform.Experiments.Variant

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft running stopped concluded)
  @approval_states ~w(not_required pending approved)
  @control_slug "control"
  @prompt_surface "dispatch.prompt"
  @stop_fields [:stop_feedback, :stopped_by_user_id, :stopped_at]

  @type t :: %__MODULE__{}

  schema "experiments" do
    field(:slug, :string)
    field(:name, :string)
    field(:hypothesis, :string)
    field(:primary_metric, :string)
    field(:status, :string, default: "draft")
    field(:stop_rule, :map, default: %{})

    # WHICH prompt template this experiment is an experiment ON. A slug, not
    # an id and not an FK — see the migration's moduledoc. Nil on a draft
    # that has not been activated yet; `Platform.Experiments.activate/2` is
    # what binds it, in the same transaction that snapshots the control.
    field(:target_template_slug, :string)

    # Opt-in automatic promotion. False by default and never inferred: an
    # experiment that did not ask for automation must not rewrite a live
    # prompt template unattended. The flag gates WHO may call
    # `Platform.Experiments.Promotion.promote/2` with `trigger: :auto`; it
    # does not change what that call does.
    field(:auto_promote, :boolean, default: false)

    # Tenancy (task 01a0d415). null org = install-wide; null project =
    # org-wide. See the moduledoc.
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:project, Platform.Tasks.Project)

    field(:surface_key, :string)
    field(:surface_target, :string)
    field(:metric_spec, :map, default: %{})
    field(:assignment_policy, :map, default: %{})
    field(:signal_source, :map)
    field(:observation_window_days, :integer)
    belongs_to(:goal, Platform.Experiments.Goal)
    field(:proposed_by_agent_id, Ecto.UUID)
    field(:approval_state, :string, default: "not_required")

    field(:stop_feedback, :string)
    field(:stopped_by_user_id, Ecto.UUID)
    field(:stopped_at, :utc_datetime_usec)

    has_many(:variants, Variant, foreign_key: :experiment_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All four valid statuses, in lifecycle order."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "All valid approval states."
  @spec approval_states() :: [String.t()]
  def approval_states, do: @approval_states

  @doc "The slug that identifies the control variant."
  @spec control_slug() :: String.t()
  def control_slug, do: @control_slug

  @doc """
  Builds a changeset for an experiment.

  Refuses a transition to `running` when the experiment has no `control`
  variant row. See the moduledoc for why that guard lives here.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(experiment, attrs) do
    experiment
    |> cast(attrs, [
      :slug,
      :name,
      :hypothesis,
      :primary_metric,
      :status,
      :stop_rule,
      :target_template_slug,
      :auto_promote,
      :org_id,
      :project_id,
      :surface_key,
      :surface_target,
      :metric_spec,
      :assignment_policy,
      :signal_source,
      :observation_window_days,
      :goal_id,
      :proposed_by_agent_id,
      :approval_state
      | @stop_fields
    ])
    |> validate_required([:slug, :name, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:approval_state, @approval_states)
    |> validate_number(:observation_window_days, greater_than: 0)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:goal_id)
    |> derive_prompt_surface()
    |> derive_org_from_project()
    |> validate_spec(:metric_spec, &MetricKind.validate_spec/1)
    |> validate_spec(:assignment_policy, &PolicySpec.validate/1)
    |> validate_stop_fields()
    |> validate_control_variant_for_running()
  end

  # Binding a prompt template binds the `dispatch.prompt` surface. Only fills
  # a surface that is unset or already the prompt surface: an experiment on
  # another surface that happens to carry a template slug is not rewritten.
  defp derive_prompt_surface(changeset) do
    case get_change(changeset, :target_template_slug) do
      slug when is_binary(slug) ->
        if get_field(changeset, :surface_key) in [nil, @prompt_surface] do
          changeset
          |> put_change(:surface_key, @prompt_surface)
          |> put_change(:surface_target, slug)
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp derive_org_from_project(changeset) do
    project_id = get_field(changeset, :project_id)

    touched? =
      Map.has_key?(changeset.changes, :project_id) or Map.has_key?(changeset.changes, :org_id)

    if touched? and is_binary(project_id) and Platform.UUID.valid?(project_id) do
      case Platform.Repo.get(Platform.Tasks.Project, project_id) do
        # A missing project is the FK constraint's error to report on write.
        nil ->
          changeset

        %{org_id: project_org} ->
          case get_field(changeset, :org_id) do
            nil -> put_change(changeset, :org_id, project_org)
            ^project_org -> changeset
            _other -> add_error(changeset, :project_id, "project does not belong to org")
          end
      end
    else
      changeset
    end
  end

  # Spec maps are validated when they are written, so an unknown kind or a
  # bad parameter is a changeset error rather than a runtime surprise.
  defp validate_spec(changeset, field, validator) do
    case get_change(changeset, field) do
      nil ->
        changeset

      spec ->
        case validator.(spec) do
          :ok -> changeset
          {:error, reasons} -> Enum.reduce(reasons, changeset, &add_error(&2, field, &1))
        end
    end
  end

  defp validate_stop_fields(changeset) do
    stopping? = get_change(changeset, :status) == "stopped"
    touched = Enum.filter(@stop_fields, &Map.has_key?(changeset.changes, &1))

    cond do
      stopping? and is_nil(get_field(changeset, :stopped_at)) ->
        put_change(changeset, :stopped_at, DateTime.utc_now())

      stopping? ->
        changeset

      true ->
        Enum.reduce(touched, changeset, fn field, acc ->
          add_error(acc, field, "can only be set by the transition that stops the experiment")
        end)
    end
  end

  # The guard. Fires only when this changeset is the thing that moves the
  # experiment INTO `running`; re-saving an already-running experiment for an
  # unrelated field change is not a transition and is not blocked.
  defp validate_control_variant_for_running(changeset) do
    if get_change(changeset, :status) == "running" do
      if has_control_variant?(changeset.data) do
        changeset
      else
        add_error(
          changeset,
          :status,
          "cannot move to running without a control variant; " <>
            "activation must snapshot the current prompt into a #{@control_slug} variant first"
        )
      end
    else
      changeset
    end
  end

  # Prefers an already-loaded association so a caller that preloaded pays no
  # second query; falls back to a direct count so the guard still holds when
  # the changeset is built from an unloaded struct. An experiment with no id
  # has not been inserted and therefore cannot have variants.
  defp has_control_variant?(%__MODULE__{variants: variants}) when is_list(variants) do
    Enum.any?(variants, &(&1.slug == @control_slug))
  end

  defp has_control_variant?(%__MODULE__{id: nil}), do: false

  defp has_control_variant?(%__MODULE__{id: id}) do
    Platform.Repo.exists?(
      from(v in Variant, where: v.experiment_id == ^id and v.slug == ^@control_slug)
    )
  end
end
