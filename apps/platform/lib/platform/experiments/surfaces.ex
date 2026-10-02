defmodule Platform.Experiments.Surfaces do
  @moduledoc """
  The registry of experiment surfaces, and the ONE resolver every surface's
  read point calls. Task 01a0d415, the experimentation-layer ADR-0052.

  The registry is a compile-time list of modules implementing
  `Platform.Experiments.Surface`, in the same shape as `BuiltIns.providers/0`.
  Adding a surface is a code change, once; every experiment on it afterwards
  is data.

  ## Resolution rules (moved here from `PromptTemplates`)

  `resolve_assignment/4` is the logic that used to live in
  `Platform.Orchestration.PromptTemplates` (`resolve_variant_slug/2`,
  `existing_assignment/2`, `assign_new/2`). It moved, it did not change, and
  the prompt read point now delegates here for the `dispatch.prompt` surface.
  The rules it carries:

    * **An EXISTING assignment wins, regardless of the experiment's status.**
      That status-blindness is what makes "stopping an experiment does not
      re-assign in-flight subjects" hold rather than merely appear to.
      Looking only at `running` experiments would make a stop silently flip
      every mid-flight subject back to the default — no new row written, so
      the assignment table looks untouched, while the subject's later reads
      came from a different arm than its earlier ones.
    * **Only a `running` experiment whose `approval_state` is not `pending`
      may CREATE an assignment.** Terminal experiments can be honoured, never
      joined; an experiment awaiting launch approval has not launched.
    * **Nothing here raises into the caller.** `resolve/4` rescues and
      catches, logs, and falls through to the default, mirroring
      `PromptTemplates.resolve_content/3`: an experiment that quietly loses a
      subject costs one data point; a read point that fails because the
      experimentation layer had a bad day costs the work it was serving.

  ## At most one running experiment per target is assumed, and warned about

  ADR-0048's risk register: with two running experiments on one target the
  assignment row stops being a unique description of what the subject saw.
  When more than one is running, the oldest that assigns the subject wins and
  a warning is logged. A scoped experiment that has no opinion about a
  subject (wrong project, outside its policy) is skipped, so the next running
  experiment is asked.
  """

  import Ecto.Query

  require Logger

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Subject
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Experiments.Variant
  alias Platform.Repo

  @surfaces [
    Platform.Experiments.Surfaces.DispatchPrompt,
    Platform.Experiments.Surfaces.MailDraftGenerator,
    Platform.Experiments.Surfaces.PlannerStageBudget,
    Platform.Experiments.Surfaces.ChatContextSummary,
    # Task 01a0e8b5: which program decides a meeting open_question. The
    # control is today's intent prompt; nothing is seeded, so production
    # stays on it until an experiment row says otherwise.
    Platform.Experiments.Surfaces.OpenQuestionClassifier
  ]

  @prompt_surface "dispatch.prompt"

  @type resolution ::
          {:variant, Experiment.t(), String.t(), map()} | {:default, map()} | :none

  @doc """
  Every registered surface module.

  The compile-time list, then every extension's surfaces
  (`Platform.Extensions.experiment_surfaces/0`, ADR 0055), then any modules
  in app env `:experiments_extra_surfaces` (default `[]`). That last key is a
  TEST SEAM, the same shape as `:experiments_labeler_provider`: it lets a
  test exercise a non-prompt surface before one ships. No config file sets
  it. All three are read per call.
  """
  @spec list() :: [module()]
  def list,
    do:
      @surfaces ++
        Platform.Extensions.experiment_surfaces() ++
        Application.get_env(:platform, :experiments_extra_surfaces, [])

  @doc "Core's own surface modules, without any extension's or the test seam's."
  @spec core_surfaces() :: [module()]
  def core_surfaces, do: @surfaces

  @doc "The surface module for a key, or nil."
  @spec get(String.t() | nil) :: module() | nil
  def get(key) when is_binary(key), do: Enum.find(list(), &(&1.key() == key))
  def get(_key), do: nil

  @doc """
  Resolves what `subject` gets on `surface_key` / `target`.

    * `{:variant, experiment, variant_slug, payload}` — an experiment applies;
      `payload` is the arm's validated payload.
    * `{:default, payload}` — no experiment applies and the surface has a
      promoted default (the MAX(`seq`) row of `experiment_surface_defaults`,
      org-specific first, then install-wide).
    * `:none` — neither; the caller uses its own control.

  Options: `:org_id` (the org whose default applies).

  Never raises.
  """
  @spec resolve(String.t(), String.t(), Subject.t(), keyword()) :: resolution()
  def resolve(surface_key, target, %Subject{} = subject, opts \\ []) do
    case get(surface_key) do
      nil ->
        :none

      surface ->
        case resolve_assignment(surface_key, target, subject, opts) do
          {:ok, experiment, variant_slug} ->
            variant_resolution(surface, experiment, variant_slug, surface_key, target, opts)

          :no_experiment ->
            default_resolution(surface_key, target, opts)

          {:error, reason} ->
            fall_through(surface_key, target, reason, opts)
        end
    end
  rescue
    error -> fall_through(surface_key, target, error, opts)
  catch
    kind, reason -> fall_through(surface_key, target, {kind, reason}, opts)
  end

  @doc """
  The assignment half of `resolve/4`: which experiment and variant slug the
  subject is in, creating the assignment if a running experiment takes it.

  Returns `{:ok, experiment, variant_slug}`, `:no_experiment`, or
  `{:error, reason}`. This is the function the prompt read point delegates
  to; see the moduledoc for the rules.
  """
  @spec resolve_assignment(String.t(), String.t(), Subject.t(), keyword()) ::
          {:ok, Experiment.t(), String.t()} | :no_experiment | {:error, term()}
  def resolve_assignment(surface_key, target, %Subject{} = subject, _opts \\ []) do
    experiments = experiments_on(surface_key, target)

    case existing_assignment(experiments, subject) do
      {experiment, variant_slug} -> {:ok, experiment, variant_slug}
      nil -> assign_new(surface_key, experiments, subject)
    end
  end

  @doc """
  The current promoted default payload for a surface key, or nil.

  The row with MAX(`seq`) for `(surface_key, target, org_id)`, matching the
  org with IS NOT DISTINCT FROM semantics (a nil `org_id` reads the
  install-wide history). A nil return means either no history or a latest
  row whose payload is nil ("no default — use the control").
  """
  @spec current_default(String.t(), String.t(), Ecto.UUID.t() | nil) :: map() | nil
  def current_default(surface_key, target, org_id) do
    case latest_default_row(surface_key, target, org_id) do
      %SurfaceDefault{payload: payload} -> payload
      nil -> nil
    end
  end

  # `org_id` is caller-supplied (resolve/4's `:org_id` option), and
  # `d.org_id == ^org_id` raises Ecto.Query.CastError on a malformed binary
  # exactly as Repo.get/2 does. A malformed org id has no history.
  defp latest_default_row(surface_key, target, org_id) do
    if is_nil(org_id) or Platform.UUID.valid?(org_id) do
      SurfaceDefault
      |> where([d], d.surface_key == ^surface_key and d.surface_target == ^target)
      |> where_org(org_id)
      |> order_by([d], desc: d.seq)
      |> limit(1)
      |> Repo.one()
    end
  end

  defp where_org(query, nil), do: where(query, [d], is_nil(d.org_id))
  defp where_org(query, org_id), do: where(query, [d], d.org_id == ^org_id)

  # Every experiment on the target, oldest first, STATUS-BLIND — terminal
  # rows are needed to find an in-flight subject's existing assignment. For
  # the prompt surface the pre-surface binding (`target_template_slug`) is
  # matched too, so a row the migration backfill or the changeset derivation
  # never saw is still found.
  defp experiments_on(surface_key, target) do
    query =
      from(e in Experiment,
        where: e.surface_key == ^surface_key and e.surface_target == ^target,
        order_by: [asc: e.inserted_at]
      )

    query =
      if surface_key == @prompt_surface do
        or_where(query, [e], e.target_template_slug == ^target)
      else
        query
      end

    Repo.all(query)
  end

  defp existing_assignment(experiments, subject) do
    Enum.find_value(experiments, fn experiment ->
      case Assignments.get_assignment(experiment, subject) do
        %Assignment{variant_slug: variant_slug} -> {experiment, variant_slug}
        nil -> nil
      end
    end)
  end

  defp assign_new(surface_key, experiments, subject) do
    case Enum.filter(experiments, &may_assign?/1) do
      [] ->
        :no_experiment

      [first | rest] = live ->
        if rest != [] do
          Logger.warning(
            "[Experiments.Surfaces] #{length(live)} running experiments target " <>
              "#{inspect(first.surface_target || first.target_template_slug)} on " <>
              "#{surface_key}; the oldest that takes the subject wins. " <>
              "Overlapping experiments on one target confound every per-subject metric."
          )
        end

        subject = with_attributes(surface_key, live, subject)
        first_assignment(live, subject)
    end
  end

  defp first_assignment([], _subject), do: :no_experiment

  defp first_assignment([experiment | rest], subject) do
    case Assignments.assign_once(experiment, subject, subject.attributes) do
      {:ok, %Assignment{variant_slug: variant_slug}} -> {:ok, experiment, variant_slug}
      :no_opinion -> first_assignment(rest, subject)
      other -> {:error, {:assign_once, other}}
    end
  end

  defp may_assign?(%Experiment{status: "running", approval_state: state}), do: state != "pending"
  defp may_assign?(_experiment), do: false

  # Hydrates the subject's attributes only when some live experiment needs
  # them (it is scoped, or carries a policy), and only when the caller did not
  # already supply them. An unscoped, policy-free experiment — every
  # experiment that existed before task 01a0d415 — costs no extra query.
  #
  # A caller that supplies attributes from data it has in hand (the dispatch
  # read points, task 01a0d415 stage 4) rarely has the org: a task carries
  # `project_id`, not `org_id`. An org-wide experiment reads `:org_id`, and a
  # missing one reads as out of scope, so the surface's lookup fills ONLY the
  # keys the caller left out; a caller-supplied key always wins.
  defp with_attributes(surface_key, experiments, %Subject{attributes: attrs} = subject) do
    surface = get(surface_key)

    if missing_attributes?(attrs) and Enum.any?(experiments, &needs_attributes?/1) and
         function_exported?(surface, :subject_attributes, 1) do
      %{subject | attributes: Map.merge(surface.subject_attributes(subject.id), attrs)}
    else
      subject
    end
  end

  defp missing_attributes?(attrs),
    do: attrs == %{} or not (Map.has_key?(attrs, :org_id) or Map.has_key?(attrs, "org_id"))

  defp needs_attributes?(%Experiment{} = e) do
    not is_nil(e.org_id) or not is_nil(e.project_id) or (e.assignment_policy || %{}) != %{}
  end

  defp variant_resolution(surface, experiment, variant_slug, surface_key, target, opts) do
    case Repo.one(
           from(v in Variant,
             where: v.experiment_id == ^experiment.id and v.slug == ^variant_slug
           )
         ) do
      nil ->
        fall_through(surface_key, target, {:variant_missing, variant_slug}, opts)

      %Variant{} = variant ->
        raw =
          if function_exported?(surface, :variant_payload, 1),
            do: surface.variant_payload(variant),
            else: variant.payload

        case surface.validate_payload(raw || %{}) do
          {:ok, payload} ->
            {:variant, experiment, variant_slug, payload}

          {:error, reasons} ->
            fall_through(surface_key, target, {:invalid_payload, variant_slug, reasons}, opts)
        end
    end
  end

  defp default_resolution(surface_key, target, opts) do
    # An org's own history, when it has one, wins outright — including a
    # latest row whose payload is nil, which means "this org reverted to the
    # control", not "ask the install-wide history".
    org_id = Keyword.get(opts, :org_id)

    row =
      (org_id && latest_default_row(surface_key, target, org_id)) ||
        latest_default_row(surface_key, target, nil)

    case row do
      %SurfaceDefault{payload: %{} = payload} -> {:default, payload}
      _ -> :none
    end
  end

  defp fall_through(surface_key, target, reason, opts) do
    Logger.error(
      "[Experiments.Surfaces] experiment resolution failed, using the default " <>
        "(surface=#{inspect(surface_key)}, target=#{inspect(target)}, reason=#{inspect(reason)})"
    )

    default_resolution(surface_key, target, opts)
  rescue
    _ -> :none
  end
end
