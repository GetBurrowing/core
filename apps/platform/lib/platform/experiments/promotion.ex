defmodule Platform.Experiments.Promotion do
  @moduledoc """
  Promotes a winning experiment variant into the live prompt template, and
  reverts a promotion from its snapshot. Task 019fe6ba, ADR-0048.

  ## One entry point

  `promote/2` is the ONLY function in the codebase that writes
  `prompt_templates.content` on an experiment's behalf. Manual promotion
  from the UI and automatic promotion call the identical function; they
  differ only in who calls it, in the `actor` recorded on the audit event,
  and in the `:trigger` option. There is deliberately no second function
  that reaches the content update: a manual path that skips the checks is
  the failure this module exists to prevent, and the cheapest way to
  guarantee it cannot exist is for there to be nowhere else to write.

  Automatic promotion is opt-in per experiment (`experiments.auto_promote`,
  default false). The flag is checked HERE, inside the single entry point,
  not by whatever scheduler happens to call it.

  ## The snapshot is in the same transaction as the update

  `promote/2` builds ONE `Ecto.Multi` and runs it through a single
  `Repo.transaction/1`, in this order:

    1. insert the CURRENT template content into `prompt_template_history`,
    2. update `prompt_templates.content` to the winning variant's blob,
    3. record the `prompt_template_promoted` audit event.

  The history row is never written by a separate `Repo.insert` before or
  after the transaction. A snapshot written outside the transaction is
  missing at precisely the moment it matters — a promotion that fails
  partway — and present only when nothing went wrong. Recording the audit
  event inside the multi likewise means the event dies with a rollback,
  so the stream never claims a promotion that did not land.

  The template row is re-read INSIDE the transaction rather than trusted
  from the caller's struct, so the snapshot records what the template
  actually said at the instant it was overwritten.

  ## The audit payload is named, not vague

  The event metadata carries the template slug, the experiment id, the
  winning variant slug, the observed effect and the sample size `n`. An
  event that says only "a prompt changed" is an unreviewable change to how
  every agent behaves; the five fields are what makes a promotion
  auditable after the fact.
  """

  alias Ecto.Multi
  alias Platform.Audit
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.PromptTemplateHistory
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Repo

  @promoted_event_type "platform.experiments.prompt_template_promoted"
  @reverted_event_type "platform.experiments.prompt_template_reverted"
  @promoted_action "prompt_template_promoted"
  @reverted_action "prompt_template_reverted"

  @type promotion :: %{
          template: PromptTemplate.t(),
          history: PromptTemplateHistory.t(),
          event: Platform.Audit.Event.t()
        }

  @doc "The audit event type written by a successful `promote/2`."
  @spec promoted_event_type() :: String.t()
  def promoted_event_type, do: @promoted_event_type

  @doc "The audit event type written by a successful `revert/2`."
  @spec reverted_event_type() :: String.t()
  def reverted_event_type, do: @reverted_event_type

  @doc """
  Promotes a variant of `experiment` into its target prompt template.

  ## Options

    * `:variant` — the winning variant, as a `%Variant{}` or its slug.
      Required.
    * `:trigger` — `:manual` (default) or `:auto`. `:auto` is refused with
      `{:error, :auto_promotion_disabled}` unless the experiment carries
      `auto_promote: true`.
    * `:actor_id`, `:actor_type` — recorded on the audit event.
      `actor_type` defaults to `"user"` for a manual trigger and
      `"system"` for an automatic one.
    * `:result` — a `%Platform.Experiments.Metric.Result{}` for the primary
      metric; its `value` becomes the observed effect and its `n` the
      sample size. `:effect` and `:n` may be passed directly instead.
    * `:metadata` — extra map merged UNDER the five required keys, so no
      caller can overwrite them.

  Returns `{:ok, %{template:, history:, event:}}`, or `{:error, reason}`
  where reason is an atom for a caller error or an `%Ecto.Changeset{}` from
  the failing step.
  """
  @spec promote(Experiment.t(), keyword()) :: {:ok, promotion()} | {:error, term()}
  def promote(%Experiment{} = experiment, opts \\ []) do
    trigger = Keyword.get(opts, :trigger, :manual)

    with :ok <- check_trigger(experiment, trigger),
         {:ok, template} <- fetch_template(experiment),
         {:ok, variant} <- fetch_variant(experiment, Keyword.get(opts, :variant)) do
      run_promotion(experiment, template, variant, trigger, opts)
    end
  end

  @doc """
  Restores `prompt_templates.content` from a history row, byte for byte.

  The stored blob is written back verbatim — nothing reconstructs what the
  template used to say. Runs in one transaction with its own audit event.
  """
  @spec revert(PromptTemplateHistory.t(), keyword()) ::
          {:ok, PromptTemplate.t()} | {:error, term()}
  def revert(%PromptTemplateHistory{} = history, opts \\ []) do
    Multi.new()
    |> Multi.run(:template_row, fn repo, _changes ->
      case repo.get(PromptTemplate, history.template_id) do
        nil -> {:error, :template_not_found}
        template -> {:ok, template}
      end
    end)
    |> Multi.update(:template, fn %{template_row: template} ->
      PromptTemplate.changeset(template, %{
        content: history.content,
        updated_by: actor_label(opts)
      })
    end)
    |> Multi.run(:event, fn _repo, %{template: template} ->
      Audit.record(%{
        event_type: @reverted_event_type,
        action: @reverted_action,
        actor_id: Keyword.get(opts, :actor_id),
        actor_type: Keyword.get(opts, :actor_type, "user"),
        resource_type: "prompt_template",
        resource_id: template.id,
        metadata: %{
          "template_slug" => template.slug,
          "history_id" => history.id,
          "experiment_id" => history.promotion_experiment_id
        }
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{template: template}} -> {:ok, template}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # -- internals --

  defp run_promotion(experiment, template, variant, trigger, opts) do
    {effect, n} = effect_and_n(opts)
    actor = actor_label(opts)

    Multi.new()
    # Re-read inside the transaction. Snapshotting the caller's struct would
    # leave a window in which the history row records content the template
    # no longer had.
    |> Multi.run(:template_row, fn repo, _changes ->
      case repo.get(PromptTemplate, template.id) do
        nil -> {:error, :template_not_found}
        row -> {:ok, row}
      end
    end)
    # (a) snapshot BEFORE the update, in this transaction. Not a separate
    # Repo.insert — see the moduledoc.
    |> Multi.insert(:history, fn %{template_row: row} ->
      PromptTemplateHistory.changeset(%PromptTemplateHistory{}, %{
        template_id: row.id,
        content: row.content,
        captured_at: DateTime.utc_now(),
        captured_by: actor,
        promotion_experiment_id: experiment.id
      })
    end)
    # (b) the content update.
    |> Multi.update(:template, fn %{template_row: row} ->
      PromptTemplate.changeset(row, %{content: variant.content, updated_by: actor})
    end)
    # (c) the audit event, inside the multi so it dies with a rollback.
    |> Multi.run(:event, fn _repo, %{template: updated} ->
      Audit.record(%{
        event_type: @promoted_event_type,
        action: @promoted_action,
        actor_id: Keyword.get(opts, :actor_id),
        actor_type: Keyword.get(opts, :actor_type, default_actor_type(trigger)),
        resource_type: "prompt_template",
        resource_id: updated.id,
        metadata:
          opts
          |> Keyword.get(:metadata, %{})
          |> stringify()
          |> Map.merge(%{
            "template_slug" => updated.slug,
            "experiment_id" => experiment.id,
            "winning_variant" => variant.slug,
            "effect" => effect,
            "n" => n,
            "trigger" => to_string(trigger)
          })
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{template: template, history: history, event: event}} ->
        {:ok, %{template: template, history: history, event: event}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp check_trigger(_experiment, :manual), do: :ok
  defp check_trigger(%Experiment{auto_promote: true}, :auto), do: :ok
  defp check_trigger(%Experiment{}, :auto), do: {:error, :auto_promotion_disabled}
  defp check_trigger(_experiment, _other), do: {:error, :unknown_trigger}

  defp fetch_template(%Experiment{target_template_slug: nil}), do: {:error, :no_target_template}

  defp fetch_template(%Experiment{target_template_slug: slug}) do
    case Repo.get_by(PromptTemplate, slug: slug) do
      nil -> {:error, :template_not_found}
      template -> {:ok, template}
    end
  end

  defp fetch_variant(_experiment, nil), do: {:error, :no_winning_variant}
  defp fetch_variant(_experiment, %Variant{} = variant), do: {:ok, variant}

  defp fetch_variant(%Experiment{} = experiment, slug) when is_binary(slug) do
    case Platform.Experiments.get_variant(experiment, slug) do
      nil -> {:error, :variant_not_found}
      variant -> {:ok, variant}
    end
  end

  defp effect_and_n(opts) do
    case Keyword.get(opts, :result) do
      %Result{value: value, n: n} -> {value, n}
      _ -> {Keyword.get(opts, :effect), Keyword.get(opts, :n)}
    end
  end

  defp default_actor_type(:auto), do: "system"
  defp default_actor_type(_), do: "user"

  defp actor_label(opts) do
    Keyword.get(opts, :actor) || Keyword.get(opts, :actor_id) ||
      to_string(Keyword.get(opts, :trigger, :manual))
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
