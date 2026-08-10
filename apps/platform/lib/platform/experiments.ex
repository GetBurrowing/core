defmodule Platform.Experiments do
  @moduledoc """
  Context for prompt experiments: create, add variants, activate, stop,
  conclude. Task 019fe6b9, ADR-0048.

  Scope is the tables and the writes against them. No metric computation, no
  policy resolution, no promotion logic, and nothing that resolves a variant
  at the dispatch read point — those are later members of this stack.

  ## Activation is the moment the control is snapshotted

  `activate/2` copies the CURRENT `prompt_templates.content` into a variant
  row with slug `"control"`, inside the same transaction that flips the
  experiment to `running`. From that point nothing reads the live template
  on this experiment's behalf; the stored blob is what the experiment
  compares against.

  The failure this prevents: without the snapshot, an edit made through
  `PlatformWeb.AdminPromptsLive` mid-experiment would silently mutate the
  control. Every number collected before the edit and every number collected
  after would be compared against different baselines, the comparison would
  become meaningless, and NOTHING anywhere would raise. A result that is
  quietly wrong is worse than one that fails, because it still gets acted on.

  ## The control guard is a changeset guard, not a convention here

  An experiment cannot reach `running` without a control variant row, and
  that is enforced in `Platform.Experiments.Experiment.changeset/2` rather
  than by this module being careful. `activate/2` therefore returns
  `{:error, %Ecto.Changeset{}}` — it does not raise and does not succeed —
  when the source template is missing or the snapshot step is bypassed.
  Calling the changeset directly, without this context, gets the same
  refusal.

  ## `stopped` and `concluded` are different, and both stay visible

  `stop/2` and `conclude/2` write DIFFERENT terminal statuses.
  `list_experiments/0` returns both. Nothing here filters `stopped` out or
  maps it onto `concluded`: an experiment that made things worse is a row
  worth keeping.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Repo

  @control_slug "control"

  @doc "List every experiment, newest first. Filters nothing — see the moduledoc."
  @spec list_experiments() :: [Experiment.t()]
  def list_experiments do
    Repo.all(from(e in Experiment, order_by: [desc: e.inserted_at]))
  end

  @doc "Fetch an experiment by id, or nil."
  @spec get_experiment(String.t()) :: Experiment.t() | nil
  def get_experiment(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Experiment, id), else: nil
  end

  @doc "Fetch an experiment by slug, or nil."
  @spec get_experiment_by_slug(String.t()) :: Experiment.t() | nil
  def get_experiment_by_slug(slug), do: Repo.get_by(Experiment, slug: slug)

  @doc "List an experiment's variants."
  @spec list_variants(Experiment.t()) :: [Variant.t()]
  def list_variants(%Experiment{id: id}) do
    Repo.all(from(v in Variant, where: v.experiment_id == ^id, order_by: [asc: v.slug]))
  end

  @doc """
  Creates an experiment in `draft`.

  The status is forced rather than taken from `attrs`: a new experiment that
  could be born `running` would skip activation, and skipping activation is
  exactly how an experiment ends up with no control snapshot.
  """
  @spec create_experiment(map()) :: {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def create_experiment(attrs) do
    %Experiment{}
    |> Experiment.changeset(normalize(attrs, "draft"))
    |> Repo.insert()
  end

  @doc """
  Adds a variant carrying the FULL prompt blob.

  The blob (rather than a structured overlay) is deliberate and the reason is
  recorded in `Platform.Experiments.Variant`'s moduledoc; it is not
  re-litigated here.
  """
  @spec add_variant(Experiment.t(), map()) :: {:ok, Variant.t()} | {:error, Ecto.Changeset.t()}
  def add_variant(%Experiment{id: id}, attrs) do
    %Variant{}
    |> Variant.changeset(attrs |> stringify() |> Map.put("experiment_id", id))
    |> Repo.insert()
  end

  @doc """
  Activates an experiment against a source prompt template.

  Takes the template struct or its slug. In ONE transaction: reads the
  template's current content, copies it into the `control` variant row, then
  flips the experiment to `running` through the stage-1 changeset.

  Returns `{:error, %Ecto.Changeset{}}` when the source template does not
  exist. It does not raise: a missing template is a caller error to be
  handled, not a crash, and the changeset carries the reason.
  """
  @spec activate(Experiment.t(), PromptTemplate.t() | String.t()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def activate(%Experiment{} = experiment, %PromptTemplate{id: template_id}) do
    activate_with_template_id(experiment, template_id)
  end

  def activate(%Experiment{} = experiment, template_slug) when is_binary(template_slug) do
    case Repo.get_by(PromptTemplate, slug: template_slug) do
      nil -> {:error, missing_template_changeset(experiment, template_slug)}
      %PromptTemplate{id: id} -> activate_with_template_id(experiment, id)
    end
  end

  defp activate_with_template_id(experiment, template_id) do
    Multi.new()
    # Re-read the template INSIDE the transaction. Reading it earlier and
    # trusting the struct would leave a window in which the snapshot records
    # content the template no longer had.
    |> Multi.run(:template, fn repo, _changes ->
      case repo.get(PromptTemplate, template_id) do
        nil -> {:error, :template_not_found}
        template -> {:ok, template}
      end
    end)
    |> Multi.insert(:control, fn %{template: template} ->
      Variant.changeset(%Variant{}, %{
        experiment_id: experiment.id,
        slug: @control_slug,
        # The snapshot. A COPY of the content, not a reference to the
        # template row — see the moduledoc.
        content: template.content,
        weight: 1
      })
    end)
    # Re-fetch the experiment rather than reusing the caller's struct: if the
    # caller preloaded :variants before the control existed, that stale list
    # is what the changeset guard would consult, and activation would be
    # refused for a control that was just inserted two steps above.
    |> Multi.update(:experiment, fn _changes ->
      Experiment
      |> Repo.get!(experiment.id)
      |> Experiment.changeset(%{status: "running"})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{experiment: activated}} ->
        {:ok, activated}

      {:error, :template, :template_not_found, _changes} ->
        {:error, missing_template_changeset(experiment, template_id)}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp missing_template_changeset(experiment, reference) do
    experiment
    |> Experiment.changeset(%{})
    |> Ecto.Changeset.add_error(
      :status,
      "cannot activate: no prompt template #{inspect(reference)} to snapshot as the control"
    )
  end

  @doc """
  Moves an experiment to `stopped` — halted, for any reason.

  Distinct from `conclude/2` and NOT a synonym for it. A stopped experiment
  stays visible in `list_experiments/0`.
  """
  @spec stop(Experiment.t(), map()) :: {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def stop(%Experiment{} = experiment, attrs \\ %{}) do
    update_status(experiment, "stopped", attrs)
  end

  @doc """
  Moves an experiment to `concluded` — run to its end and decided.

  Distinct from `stop/2`. Both terminal statuses stay visible.
  """
  @spec conclude(Experiment.t(), map()) :: {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def conclude(%Experiment{} = experiment, attrs \\ %{}) do
    update_status(experiment, "concluded", attrs)
  end

  defp update_status(experiment, status, attrs) do
    experiment
    |> Experiment.changeset(normalize(attrs, status))
    |> Repo.update()
  end

  # Callers pass either string or atom keys; the status is set by the function
  # that was called, never taken from the caller's map.
  defp normalize(attrs, status), do: attrs |> stringify() |> Map.put("status", status)

  defp stringify(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
