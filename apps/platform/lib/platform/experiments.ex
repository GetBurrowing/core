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

  ## Starting under guardrails (task 01a0d415 stage 2)

  `start/2` is the guarded launch every agent path takes (the MCP tool
  `experiment_start`). Inside ONE transaction holding the start locks
  (`Platform.Experiments.Guardrails.with_start_lock/2`) it re-reads the
  experiment, runs `Guardrails.check(:start, …)`, and then either:

    * launches it — for `dispatch.prompt` through the same snapshot as
      `activate/2`; for any other surface by inserting the control variant
      from the surface's `control_payload/2` — returning
      `{:ok, %Experiment{status: "running"}}`; or
    * when the org's guardrails have `require_human_approval` on and the
      actor is an agent, sets `approval_state: "pending"`, leaves the status
      `draft`, and returns `{:ok, :pending_human_approval}`. It never returns
      `running` on that path.

  Launch approval is OPT-IN (product decision, 2026-09-24): under the built-in default an
  agent's start launches. `approve_launch/2` takes a `%User{}` — there is no
  agent-callable form and no MCP tool for it — and launches a pending
  experiment through the same locks and the same `max_live` / `surface_busy`
  checks: a human bypasses the approval, nothing else.

  ## Stopping with feedback

  `stop/3` records WHO stopped the experiment and WHY:
  `stop(experiment, %User{}, feedback)` writes `stop_feedback`,
  `stopped_by_user_id` and `stopped_at` in the same update that moves it to
  `stopped`. An agent stop (MCP) goes through `stop/2` with only
  `stop_feedback`, so `stopped_by_user_id` stays null and reads as "not a
  human". Either way the status is `stopped`, never `concluded`.

  ## Human writes are install-level, re-checked here (task 01a1386d-fb6e stage 2)

  Every write a HUMAN makes re-checks `Platform.Access.authorize_install/1`
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Root-admin carve-outs`:
  human launch, stop and conclude stay install-level). `ExperimentsLive`'s
  `admin_only/2` was the only gate before; a route gate is not an
  authorization boundary. A human write is one whose actor is a `%User{}`:

    * `start/2` and `approve_launch/2` with a `%User{}`;
    * `stop/2` with a `%User{}` and `stop/3`;
    * the actor forms `create_experiment/2`, `delete_experiment/2`,
      `add_variant/3`, `activate/3` and `conclude/2` with a `%User{}`, which
      `ExperimentsLive` calls. `Platform.Experiments.Guardrails.save/3` and
      `Platform.Experiments.Promotion.promote/2` with an `:actor` opt re-check
      the same way.

  A refused human write returns `{:error, :unauthorized}` before any read or
  lock, and writes nothing. The agent path is unchanged: `start/2` with an
  agent (MCP `experiment_start`) still answers `:pending_human_approval` under
  approval, and the actor-less forms (`create_experiment/1`,
  `add_variant/2`, `stop/2` with an attrs map, `conclude/1`) that the MCP
  tools and the system call are untouched, so every `experiment_*` tool result
  is the same as before.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Access
  alias Platform.Accounts.User
  alias Platform.Audit
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Guardrails
  alias Platform.Experiments.Surfaces
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

  @doc """
  Display names for the agents that proposed experiments, keyed by agent id.
  One query for the whole page; an id with no agent row is simply absent, so
  the caller renders "an agent" rather than a raw UUID.
  """
  @spec agent_names([Ecto.UUID.t() | nil]) :: %{Ecto.UUID.t() => String.t()}
  def agent_names(ids) when is_list(ids) do
    case ids |> Enum.filter(&Platform.UUID.valid?/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        from(a in Platform.Agents.Agent, where: a.id in ^ids, select: {a.id, a.name})
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc "List an experiment's variants."
  @spec list_variants(Experiment.t()) :: [Variant.t()]
  def list_variants(%Experiment{id: id}) do
    Repo.all(from(v in Variant, where: v.experiment_id == ^id, order_by: [asc: v.slug]))
  end

  @doc """
  Lists every experiment targeting a prompt template slug, oldest first.

  Filters on the TARGET only, deliberately not on status. The dispatch read
  point needs the terminal rows too: a subject assigned while an experiment
  ran keeps its variant after the experiment is stopped, so the resolver has
  to be able to find a `stopped` experiment in order to find that subject's
  existing assignment. A status filter here would make a stop silently
  re-render the live template for a subject mid-flight — which is exactly
  the re-assignment ADR-0048 forbids, arriving through the back door.

  Oldest first so that a slug carrying more than one experiment resolves
  deterministically rather than by whatever order the planner happened to
  return.
  """
  @spec list_experiments_for_template(String.t()) :: [Experiment.t()]
  def list_experiments_for_template(template_slug) when is_binary(template_slug) do
    Repo.all(
      from(e in Experiment,
        where: e.target_template_slug == ^template_slug,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  @doc """
  Fetches one variant of an experiment by slug, or nil.
  """
  @spec get_variant(Experiment.t(), String.t()) :: Variant.t() | nil
  def get_variant(%Experiment{id: experiment_id}, variant_slug) when is_binary(variant_slug) do
    Repo.one(
      from(v in Variant,
        where: v.experiment_id == ^experiment_id and v.slug == ^variant_slug
      )
    )
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

  @doc "`create_experiment/1` by a human, re-checked install-level (see the moduledoc)."
  @spec create_experiment(map(), User.t()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_experiment(attrs, %User{} = user) do
    with :ok <- Access.authorize_install(user), do: create_experiment(attrs)
  end

  @doc """
  Deletes an experiment, but only while it is a `draft`.

  Returns `{:error, :not_draft}` for any other status. Once an experiment
  has been activated its assignments and history ARE the evidence trail, and
  ADR-0048's posture is that a regression is the most instructive row on the
  page — `stop/2` and `conclude/2` exist so a finished experiment stays
  visible rather than disappearing. A draft has measured nothing, so
  deleting one destroys no evidence.

  The guard lives here rather than only in the view. Hiding a control is an
  affordance; the refusal has to hold for a caller that never rendered one.

  Takes the struct — the caller looks the experiment up with
  `get_experiment_by_slug/1`.
  """
  @spec delete_experiment(Experiment.t()) ::
          {:ok, Experiment.t()} | {:error, :not_draft | Ecto.Changeset.t()}
  def delete_experiment(%Experiment{status: "draft"} = experiment), do: Repo.delete(experiment)
  def delete_experiment(%Experiment{}), do: {:error, :not_draft}

  @doc "`delete_experiment/1` by a human, re-checked install-level (see the moduledoc)."
  @spec delete_experiment(Experiment.t(), User.t()) ::
          {:ok, Experiment.t()} | {:error, :not_draft | :unauthorized | Ecto.Changeset.t()}
  def delete_experiment(%Experiment{} = experiment, %User{} = user) do
    with :ok <- Access.authorize_install(user), do: delete_experiment(experiment)
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

  @doc "`add_variant/2` by a human, re-checked install-level (see the moduledoc)."
  @spec add_variant(Experiment.t(), map(), User.t()) ::
          {:ok, Variant.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def add_variant(%Experiment{} = experiment, attrs, %User{} = user) do
    with :ok <- Access.authorize_install(user), do: add_variant(experiment, attrs)
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
  def activate(experiment, template), do: activate_from(experiment, template, %{})

  @doc "`activate/2` by a human, re-checked install-level (see the moduledoc)."
  @spec activate(Experiment.t(), PromptTemplate.t() | String.t(), User.t()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def activate(experiment, template, %User{} = user) do
    with :ok <- Access.authorize_install(user), do: activate(experiment, template)
  end

  defp activate_from(%Experiment{} = experiment, %PromptTemplate{id: template_id}, extra) do
    activate_with_template_id(experiment, template_id, extra)
  end

  defp activate_from(%Experiment{} = experiment, template_slug, extra)
       when is_binary(template_slug) do
    case Repo.get_by(PromptTemplate, slug: template_slug) do
      nil -> {:error, missing_template_changeset(experiment, template_slug)}
      %PromptTemplate{id: id} -> activate_with_template_id(experiment, id, extra)
    end
  end

  # `extra` is merged into the running transition (stage 2's
  # `approval_state: "approved"`); it can never override the status or the
  # target, which are set after it.
  defp activate_with_template_id(experiment, template_id, extra) do
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
    |> Multi.update(:experiment, fn %{template: template} ->
      Experiment
      |> Repo.get!(experiment.id)
      # The target slug is bound HERE, in the same transaction as the
      # snapshot, and nowhere else. Activation is the only moment at which
      # both facts — which template, and what it said — are known together;
      # binding the target anywhere later would allow a running experiment
      # whose control is a snapshot of one template and whose target names
      # another.
      |> Experiment.changeset(
        Map.merge(extra, %{
          status: "running",
          target_template_slug: template.slug
        })
      )
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
  @spec stop(Experiment.t(), map() | User.t()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def stop(experiment, attrs \\ %{})

  def stop(%Experiment{} = experiment, %User{} = user), do: stop(experiment, user, nil)

  def stop(%Experiment{} = experiment, attrs) when is_map(attrs) do
    update_status(experiment, "stopped", attrs)
  end

  @doc """
  A HUMAN stop, with the reason in the human's words. Records
  `stop_feedback`, `stopped_by_user_id` and `stopped_at` in the transition
  itself. See the moduledoc.
  """
  @spec stop(Experiment.t(), User.t(), String.t() | nil) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def stop(%Experiment{} = experiment, %User{id: user_id} = user, feedback)
      when is_nil(feedback) or is_binary(feedback) do
    with :ok <- Access.authorize_install(user) do
      update_status(experiment, "stopped", %{
        stop_feedback: feedback,
        stopped_by_user_id: user_id
      })
    end
  end

  @doc """
  Launches a `draft` experiment under the guardrails. See the moduledoc.

  `actor` is a `%User{}` (a human launch: no approval step) or an agent
  (`%Platform.Agents.Agent{}` or `:agent`). Returns
  `{:ok, %Experiment{}}` when it is now running, `{:ok,
  :pending_human_approval}` when the org requires approval (idempotent: a
  second agent start of a pending experiment answers the same), or
  `{:error, %Guardrails.Refusal{} | :not_draft | :unknown_surface | term()}`.
  """
  @spec start(Experiment.t(), Guardrails.actor()) ::
          {:ok, Experiment.t() | :pending_human_approval} | {:error, term()}
  def start(%Experiment{} = experiment, actor) do
    with :ok <- authorize_human(actor), do: start_guarded(experiment, actor)
  end

  defp start_guarded(experiment, actor) do
    Guardrails.with_start_lock(experiment, fn ->
      fresh = Repo.get!(Experiment, experiment.id)

      with :ok <- ensure_draft(fresh),
           :ok <- Guardrails.check(:start, fresh, actor) do
        cond do
          human?(actor) ->
            extra =
              if fresh.approval_state == "pending", do: %{approval_state: "approved"}, else: %{}

            launch!(fresh, extra)

          fresh.approval_state == "pending" ->
            :pending_human_approval

          Guardrails.for_org(fresh.org_id).require_human_approval ->
            fresh
            |> Experiment.changeset(%{approval_state: "pending"})
            |> Repo.update()
            |> case do
              {:ok, _} -> :pending_human_approval
              {:error, changeset} -> Repo.rollback(changeset)
            end

          true ->
            launch!(fresh, %{})
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  A human approves a pending launch. Takes a `%User{}` and nothing else —
  there is no agent-callable form. Runs the same locks and `max_live` /
  `surface_busy` checks as `start/2`; records a
  `platform.experiments.launch_approved` audit event in the same
  transaction. Returns `{:error, :not_pending}` for an experiment that is not
  awaiting approval.
  """
  @spec approve_launch(Experiment.t(), User.t()) :: {:ok, Experiment.t()} | {:error, term()}
  def approve_launch(%Experiment{} = experiment, %User{} = user) do
    with :ok <- Access.authorize_install(user), do: approve_guarded(experiment, user)
  end

  defp approve_guarded(experiment, user) do
    Guardrails.with_start_lock(experiment, fn ->
      fresh = Repo.get!(Experiment, experiment.id)

      with :ok <- ensure_draft(fresh),
           :ok <- ensure_pending(fresh),
           :ok <- Guardrails.check(:start, fresh, user) do
        launched = launch!(fresh, %{approval_state: "approved"})

        case Audit.record(%{
               event_type: "platform.experiments.launch_approved",
               action: "experiment_launch_approved",
               actor_id: user.id,
               actor_type: "user",
               resource_type: "experiment",
               resource_id: launched.id,
               metadata: %{
                 "experiment_id" => launched.id,
                 "surface_key" => launched.surface_key,
                 "proposed_by_agent_id" => launched.proposed_by_agent_id
               }
             }) do
          {:ok, _event} -> launched
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp human?(%User{}), do: true
  defp human?(_actor), do: false

  # A human actor's write is install-level; an agent's is decided by the
  # guardrails, as before.
  defp authorize_human(%User{} = user), do: Access.authorize_install(user)
  defp authorize_human(_agent), do: :ok

  defp ensure_draft(%Experiment{status: "draft"}), do: :ok
  defp ensure_draft(%Experiment{}), do: {:error, :not_draft}

  defp ensure_pending(%Experiment{approval_state: "pending"}), do: :ok
  defp ensure_pending(%Experiment{}), do: {:error, :not_pending}

  # Runs inside the caller's transaction; a failure rolls the whole start
  # back with the reason.
  defp launch!(%Experiment{surface_key: "dispatch.prompt"} = experiment, extra) do
    case activate_from(experiment, experiment.surface_target || "", extra) do
      {:ok, running} -> running
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp launch!(%Experiment{} = experiment, extra) do
    with surface when not is_nil(surface) <- Surfaces.get(experiment.surface_key),
         {:ok, payload} <-
           surface.control_payload(experiment.surface_target, org_id: experiment.org_id),
         {:ok, _control} <-
           %Variant{}
           |> Variant.control_changeset(%{
             experiment_id: experiment.id,
             payload: payload,
             weight: 1
           })
           |> Repo.insert(),
         {:ok, running} <-
           experiment
           |> Experiment.changeset(Map.merge(extra, %{status: "running"}))
           |> Repo.update() do
      running
    else
      nil -> Repo.rollback(:unknown_surface)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Moves an experiment to `concluded` — run to its end and decided.

  Distinct from `stop/2`. Both terminal statuses stay visible.
  """
  @spec conclude(Experiment.t(), map() | User.t()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def conclude(experiment, attrs \\ %{})

  # A human conclude (`ExperimentsLive`), re-checked install-level.
  def conclude(%Experiment{} = experiment, %User{} = user) do
    with :ok <- Access.authorize_install(user), do: conclude(experiment, %{})
  end

  def conclude(%Experiment{} = experiment, attrs) when is_map(attrs) do
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
