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

  ## The four guardrails, and where they run

  All four run inside THIS function, before the `Ecto.Multi` opens. There
  is no second, looser path: manual and automatic promotion traverse the
  identical code, so a guard cannot be true of one and false of the other.

    1. **Stop rule.** An experiment that has not reached its stop rule
       cannot be promoted, by a human or by automation. Reason
       `:insufficient_data` — the upstream atom from
       `Platform.Experiments.Metric`, not a new one.
    2. **Cooldown.** A template cannot be promoted twice within
       `@cooldown_days` days. Without it every promotion shifts the
       baseline before the next experiment can react, and a sequence of
       individually-significant "wins" compounds into drift that no single
       experiment could justify.
    3. **Multi-metric gate.** No promotion proceeds while a secondary
       metric regresses more than `@max_secondary_regression`, even when
       the primary metric wins — otherwise plan quality improves by making
       planning four times slower and it counts as a win because latency
       was not the metric.
    4. **Snapshot.** Enforced by the multi above. There is deliberately no
       second snapshot path here.

  ## Refusals are structs, not prose

  Every refusal is `{:error, %#{inspect(__MODULE__)}.Refusal{}}` with the
  numbers the caller needs in DISCRETE FIELDS. The UI that renders these
  must never parse the message string: a renderer that regexes an error
  sentence breaks the next time somebody improves the wording, and the
  breakage shows up as a blank panel rather than as a failing test.

  ## The override is narrow on purpose

  Only the stop-rule refusal is overridable, and only by an explicit
  `override: true` plus an actor. It is recorded AS an override on the
  audit event, with the acting user and the sample size at the time — not
  silently permitted because a button existed. `override: true` against a
  cooldown or metric-gate refusal is IGNORED and the refusal stands.
  Loosening later is cheap; an escape hatch on every guardrail makes the
  guardrails decorative on day one.

  ## The metric gate is n-aware, and the small-n regression is still recorded

  A regression measured over fewer than `@min_regression_n` subjects does
  not block. Below that n a 6% delta sits inside sampling noise, so
  blocking on it turns the Goodhart defence into a random refusal
  generator — which is worse than no gate at all, because people learn to
  route around a gate that fires at random. The ignored regression is NOT
  discarded: it goes onto the audit event under `ignored_regressions` with
  metric name, delta and n, so an override-by-small-sample is reviewable
  after the fact. Both branches read `n` off `%Metric.Result{}`; neither
  looks at the delta alone.

  ## Non-prompt surfaces append a default-history row (task 01a0d415 stage 2)

  For `dispatch.prompt` nothing above changed. For EVERY OTHER surface
  `promote/2` does not touch a template: in ONE `Ecto.Multi` it appends an
  `experiment_surface_defaults` row with `seq = current max + 1` for
  `(surface_key, surface_target, org_id)` carrying the winning arm's payload,
  and records a `platform.experiments.experiment_surface_promoted` audit
  event. The stop-rule, cooldown and multi-metric guards run for both paths,
  before the Multi; the cooldown for a surface reads that surface key's
  history rather than a template's.

  Two promotions racing to the same next `seq` collide on stage 1's NULLS
  NOT DISTINCT unique index; the loser gets `{:error, :concurrent_promotion}`
  and is NOT retried. A silent retry would promote a winner chosen against a
  default that is no longer current.

  `revert_surface_default/4` never updates a row either: it appends a
  `kind: "revert"` row whose payload is the effective payload BEFORE the
  latest row (nil when the latest row is the first — "use the control").

  The `:agent` trigger is how an agent's promotion (the MCP tool
  `experiment_promote`) is recorded. Whether an agent may promote at all is
  `Platform.Experiments.Guardrails.check(:promote, …)`'s decision, taken by
  the caller before it reaches this entry point.

  ## Promotion is sticky: it changes the default for NEW subjects only

  Nothing on this path updates or deletes an `experiment_assignments` row.
  A subject already in flight keeps the variant it was given. Retroactively
  reassigning live subjects would corrupt the very result that justified
  the promotion (ADR-0048).
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Platform.Access
  alias Platform.Audit
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.PromptTemplateHistory
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Repo

  defmodule Refusal do
    @moduledoc """
    A refused promotion, in fields rather than in a sentence.

    The `message` is for a log line and for a human reading a console. It
    is NOT the interface: every number a caller might want to render —
    observed and required subject counts, the absolute date a cooldown
    lifts, the offending metric's name, delta and sample size — is its own
    field. A UI that re-derives any of them from `message` is one wording
    change away from silently rendering nothing.

    `available_from` is a `Date`, not a remaining-days duration. A
    countdown makes the reader compute, and it goes stale the moment the
    page is left open; a date can go in a calendar and is still correct
    tomorrow.
    """

    @type t :: %__MODULE__{
            reason: atom(),
            message: String.t(),
            observed_subjects: non_neg_integer() | nil,
            required_subjects: pos_integer() | nil,
            last_promoted_at: DateTime.t() | nil,
            available_from: Date.t() | nil,
            cooldown_days: pos_integer() | nil,
            metric: String.t() | nil,
            delta: float() | nil,
            n: non_neg_integer() | nil,
            threshold: float() | nil
          }

    @enforce_keys [:reason, :message]
    defstruct [
      :reason,
      :message,
      :observed_subjects,
      :required_subjects,
      :last_promoted_at,
      :available_from,
      :cooldown_days,
      :metric,
      :delta,
      :n,
      :threshold
    ]
  end

  # Cooldown window, as ONE named value. Never a literal at a call site:
  # a policy number spelled twice is a policy number that will one day
  # disagree with itself.
  @cooldown_days 14

  # A secondary metric may not lose more than this fraction against
  # control, however well the primary metric did.
  @max_secondary_regression 0.05

  # Below this sample size a regression is noise, not a signal, and does
  # not block. See the moduledoc for why a randomly-firing gate is worse
  # than an absent one.
  @min_regression_n 30

  @surface_promoted_event_type "platform.experiments.experiment_surface_promoted"
  @surface_reverted_event_type "platform.experiments.experiment_surface_reverted"
  @prompt_surface "dispatch.prompt"
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

  @doc "The audit event type written by a successful non-prompt `promote/2`."
  @spec surface_promoted_event_type() :: String.t()
  def surface_promoted_event_type, do: @surface_promoted_event_type

  @doc "The audit event type written by `revert_surface_default/4`."
  @spec surface_reverted_event_type() :: String.t()
  def surface_reverted_event_type, do: @surface_reverted_event_type

  @doc "The audit event type written by a successful `revert/2`."
  @spec reverted_event_type() :: String.t()
  def reverted_event_type, do: @reverted_event_type

  @doc "Days a template must wait between promotions."
  @spec cooldown_days() :: pos_integer()
  def cooldown_days, do: @cooldown_days

  @doc "The largest secondary-metric regression a promotion may carry."
  @spec max_secondary_regression() :: float()
  def max_secondary_regression, do: @max_secondary_regression

  @doc "The sample size below which a regression is treated as noise."
  @spec min_regression_n() :: pos_integer()
  def min_regression_n, do: @min_regression_n

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
    * `:secondary_results` — the secondary metrics, as a list of
      `{metric_name, %Result{}}`. `value` is the SIGNED relative change
      against control, so a negative value is a regression and `-0.06`
      means "6% worse". `n` is the sample size the change was measured
      over, and the gate reads it.
    * `:override` — `true` promotes despite a stop-rule refusal, and ONLY
      a stop-rule refusal. Requires `:actor_id`. Recorded on the audit
      event as an override with the actor and the sample size at the time.
    * `:metadata` — extra map merged UNDER the five required keys, so no
      caller can overwrite them.
    * `:actor` — the acting `%Platform.Accounts.User{}` for a human promotion
      (`ExperimentsLive`). When given, the promotion re-checks
      `Platform.Access.authorize_install/1` first and returns
      `{:error, :unauthorized}` for anyone else, writing nothing (task
      01a1386d-fb6e stage 2). Absent, nothing changes: the MCP
      `experiment_promote` and automatic promotions pass none.

  Returns `{:ok, %{template:, history:, event:}}`, or `{:error, reason}`
  where reason is a `%#{inspect(__MODULE__)}.Refusal{}` for a guardrail, an
  atom for a caller error, or an `%Ecto.Changeset{}` from the failing step.
  """
  @spec promote(Experiment.t(), keyword()) :: {:ok, promotion() | map()} | {:error, term()}
  def promote(experiment, opts \\ [])

  def promote(%Experiment{} = experiment, opts) when is_list(opts) do
    case Keyword.pop(opts, :actor) do
      {nil, opts} ->
        promote_unchecked(experiment, opts)

      {actor, opts} ->
        with :ok <- Access.authorize_install(actor), do: promote_unchecked(experiment, opts)
    end
  end

  defp promote_unchecked(%Experiment{surface_key: key} = experiment, opts)
      when is_binary(key) and key != @prompt_surface do
    trigger = Keyword.get(opts, :trigger, :manual)

    with :ok <- check_trigger(experiment, trigger),
         {:ok, variant} <- fetch_variant(experiment, Keyword.get(opts, :variant)),
         {:ok, payload} <- variant_payload(experiment, variant),
         {:ok, stop_rule} <- check_stop_rule(experiment, opts),
         :ok <- check_surface_cooldown(experiment),
         {:ok, ignored} <- check_secondary_metrics(opts) do
      run_surface_promotion(experiment, variant, payload, trigger, stop_rule, ignored, opts)
    end
  end

  defp promote_unchecked(%Experiment{} = experiment, opts) do
    trigger = Keyword.get(opts, :trigger, :manual)

    with :ok <- check_trigger(experiment, trigger),
         {:ok, template} <- fetch_template(experiment),
         {:ok, variant} <- fetch_variant(experiment, Keyword.get(opts, :variant)),
         # The guardrails, all of them, before the transaction opens.
         {:ok, stop_rule} <- check_stop_rule(experiment, opts),
         :ok <- check_cooldown(template),
         {:ok, ignored} <- check_secondary_metrics(opts) do
      run_promotion(experiment, template, variant, trigger, stop_rule, ignored, opts)
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

  @doc """
  Reverts the latest default of a non-prompt surface by APPENDING a
  `kind: "revert"` row. See the moduledoc.

  Returns `{:ok, %{default: row, event: event}}`, `{:error, :nothing_to_revert}`
  when the key has no history, or `{:error, :concurrent_promotion}` on a
  `seq` collision.
  """
  @spec revert_surface_default(String.t(), String.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def revert_surface_default(surface_key, target, org_id, opts \\ []) do
    case default_rows(surface_key, target, org_id, 2) do
      [] ->
        {:error, :nothing_to_revert}

      [latest | rest] ->
        prior_payload =
          case rest do
            [%SurfaceDefault{payload: payload}] -> payload
            [] -> nil
          end

        Multi.new()
        |> Multi.insert(
          :default,
          SurfaceDefault.changeset(%SurfaceDefault{}, %{
            surface_key: surface_key,
            surface_target: target,
            org_id: org_id,
            seq: latest.seq + 1,
            kind: "revert",
            payload: prior_payload,
            reverts_seq: latest.seq,
            source_experiment_id: latest.source_experiment_id
          })
        )
        |> Multi.run(:event, fn _repo, %{default: row} ->
          Audit.record(%{
            event_type: @surface_reverted_event_type,
            action: "experiment_surface_reverted",
            actor_id: Keyword.get(opts, :actor_id),
            actor_type: Keyword.get(opts, :actor_type, "user"),
            resource_type: "experiment_surface_default",
            resource_id: row.id,
            metadata: %{
              "surface_key" => surface_key,
              "surface_target" => target,
              "org_id" => org_id,
              "seq" => row.seq,
              "reverts_seq" => latest.seq
            }
          })
        end)
        |> Repo.transaction()
        |> surface_result()
    end
  end

  # -- internals --

  # The newest `limit` history rows for a key, matching the org with IS NOT
  # DISTINCT FROM semantics (nil = the install-wide history).
  defp default_rows(surface_key, target, org_id, limit) do
    from(d in SurfaceDefault,
      where: d.surface_key == ^surface_key and d.surface_target == ^target,
      order_by: [desc: d.seq],
      limit: ^limit
    )
    |> default_org(org_id)
    |> Repo.all()
  end

  # IS NOT DISTINCT FROM, as two predicates the unique index can serve.
  defp default_org(query, nil), do: Ecto.Query.where(query, [d], is_nil(d.org_id))
  defp default_org(query, org_id), do: Ecto.Query.where(query, [d], d.org_id == ^org_id)

  defp variant_payload(%Experiment{surface_key: key}, %Variant{} = variant) do
    case Platform.Experiments.Surfaces.get(key) do
      nil ->
        {:ok, variant.payload}

      surface ->
        raw =
          if function_exported?(surface, :variant_payload, 1),
            do: surface.variant_payload(variant),
            else: variant.payload

        case surface.validate_payload(raw || %{}) do
          {:ok, payload} -> {:ok, payload}
          {:error, reasons} -> {:error, {:invalid_payload, reasons}}
        end
    end
  end

  # Guard 2 for a surface: the same window, read off the surface key's own
  # promotion history.
  defp check_surface_cooldown(%Experiment{} = experiment) do
    last =
      from(d in SurfaceDefault,
        where:
          d.surface_key == ^experiment.surface_key and
            d.surface_target == ^experiment.surface_target and d.kind == "promote",
        order_by: [desc: d.seq],
        limit: 1,
        select: d.inserted_at
      )
      |> default_org(experiment.org_id)
      |> Repo.one()

    cooldown_refusal(last)
  end

  defp cooldown_refusal(nil), do: :ok

  defp cooldown_refusal(last_promoted_at) do
    available_from = last_promoted_at |> DateTime.to_date() |> Date.add(@cooldown_days)

    if Date.compare(Date.utc_today(), available_from) == :lt do
      {:error,
       %Refusal{
         reason: :cooldown_active,
         message:
           "this surface was promoted on " <>
             "#{Date.to_iso8601(DateTime.to_date(last_promoted_at))}; " <>
             "the next promotion is available from #{Date.to_iso8601(available_from)}",
         last_promoted_at: last_promoted_at,
         available_from: available_from,
         cooldown_days: @cooldown_days
       }}
    else
      :ok
    end
  end

  defp run_surface_promotion(experiment, variant, payload, trigger, stop_rule, ignored, opts) do
    {effect, n} = effect_and_n(opts)

    Multi.new()
    |> Multi.run(:seq, fn _repo, _changes ->
      case default_rows(experiment.surface_key, experiment.surface_target, experiment.org_id, 1) do
        [%SurfaceDefault{seq: seq}] -> {:ok, seq + 1}
        [] -> {:ok, 1}
      end
    end)
    |> Multi.insert(:default, fn %{seq: seq} ->
      SurfaceDefault.changeset(%SurfaceDefault{}, %{
        surface_key: experiment.surface_key,
        surface_target: experiment.surface_target,
        org_id: experiment.org_id,
        seq: seq,
        kind: "promote",
        payload: payload,
        source_experiment_id: experiment.id
      })
    end)
    |> Multi.run(:event, fn _repo, %{default: row} ->
      Audit.record(%{
        event_type: @surface_promoted_event_type,
        action: "experiment_surface_promoted",
        actor_id: Keyword.get(opts, :actor_id),
        actor_type: Keyword.get(opts, :actor_type, default_actor_type(trigger)),
        resource_type: "experiment_surface_default",
        resource_id: row.id,
        metadata:
          opts
          |> Keyword.get(:metadata, %{})
          |> stringify()
          |> Map.merge(%{
            "surface_key" => row.surface_key,
            "surface_target" => row.surface_target,
            "org_id" => row.org_id,
            "seq" => row.seq,
            "experiment_id" => experiment.id,
            "winning_variant" => variant.slug,
            "effect" => effect,
            "n" => n,
            "trigger" => to_string(trigger)
          })
          |> Map.merge(override_metadata(stop_rule, opts))
          |> Map.merge(ignored_regressions_metadata(ignored))
      })
    end)
    |> Repo.transaction()
    |> surface_result()
  end

  defp surface_result({:ok, %{default: row, event: event}}),
    do: {:ok, %{default: row, event: event}}

  defp surface_result({:error, :default, %Ecto.Changeset{} = changeset, _changes}) do
    if Keyword.has_key?(changeset.errors, :seq),
      do: {:error, :concurrent_promotion},
      else: {:error, changeset}
  end

  defp surface_result({:error, _step, reason, _changes}), do: {:error, reason}

  # ── Guard 1: the stop rule ────────────────────────────────────────────
  #
  # Returns `{:ok, stop_rule_info}` where the info is nil when the
  # experiment declares no subject requirement, `{:reached, observed,
  # required}` when it met it, or `{:overridden, observed, required}` when
  # a human explicitly took responsibility for promoting early.
  defp check_stop_rule(%Experiment{} = experiment, opts) do
    case required_subjects(experiment) do
      nil ->
        {:ok, nil}

      required ->
        observed = observed_subjects(experiment)

        cond do
          observed >= required ->
            {:ok, {:reached, observed, required}}

          overriding?(opts) ->
            {:ok, {:overridden, observed, required}}

          true ->
            {:error,
             %Refusal{
               reason: :insufficient_data,
               message:
                 "the experiment has not reached its stop rule: " <>
                   "#{observed} of #{required} subjects",
               observed_subjects: observed,
               required_subjects: required
             }}
        end
    end
  end

  # An override is explicit or it is not an override. `override: true`
  # alone is a flag somebody could set by accident in a config; requiring
  # an actor is what makes the audit row answer "who".
  defp overriding?(opts) do
    Keyword.get(opts, :override) == true and not is_nil(Keyword.get(opts, :actor_id))
  end

  defp required_subjects(%Experiment{stop_rule: stop_rule}) when is_map(stop_rule) do
    case stop_rule["min_subjects"] || stop_rule[:min_subjects] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp required_subjects(_experiment), do: nil

  # Excluded subjects are not counted: the stop rule asks how much usable
  # data there is, and an excluded row is deliberately not usable. The
  # rows are only READ here — see the moduledoc on stickiness.
  defp observed_subjects(%Experiment{id: experiment_id}) do
    Repo.aggregate(
      from(a in Assignment,
        where: a.experiment_id == ^experiment_id and is_nil(a.excluded_reason)
      ),
      :count
    )
  end

  # ── Guard 2: the cooldown ─────────────────────────────────────────────
  #
  # Not overridable. Deliberately reads the promotion history rather than
  # a column on the template, so a template promoted by any path at all is
  # subject to the same window.
  defp check_cooldown(%PromptTemplate{id: template_id}) do
    case last_promoted_at(template_id) do
      nil ->
        :ok

      last_promoted_at ->
        available_from = last_promoted_at |> DateTime.to_date() |> Date.add(@cooldown_days)

        if Date.compare(Date.utc_today(), available_from) == :lt do
          {:error,
           %Refusal{
             reason: :cooldown_active,
             message:
               "this template was promoted on " <>
                 "#{Date.to_iso8601(DateTime.to_date(last_promoted_at))}; " <>
                 "the next promotion is available from #{Date.to_iso8601(available_from)}",
             last_promoted_at: last_promoted_at,
             available_from: available_from,
             cooldown_days: @cooldown_days
           }}
        else
          :ok
        end
    end
  end

  defp last_promoted_at(template_id) do
    Repo.one(
      from(h in PromptTemplateHistory,
        where: h.template_id == ^template_id,
        order_by: [desc: h.captured_at],
        limit: 1,
        select: h.captured_at
      )
    )
  end

  # ── Guard 3: the multi-metric gate, n-aware ───────────────────────────
  #
  # Returns `{:ok, ignored_regressions}` — the sub-threshold-n regressions
  # that did NOT block, which the caller records on the audit event.
  defp check_secondary_metrics(opts) do
    opts
    |> Keyword.get(:secondary_results, [])
    |> Enum.reduce_while({:ok, []}, fn {name, %Result{value: value, n: n}}, {:ok, ignored} ->
      cond do
        not regression?(value) ->
          {:cont, {:ok, ignored}}

        # The n branch, taken before any decision about the delta. A gate
        # that read the delta alone would refuse on five subjects.
        n < @min_regression_n ->
          {:cont,
           {:ok,
            ignored ++
              [%{"metric" => to_string(name), "delta" => value, "n" => n}]}}

        true ->
          {:halt,
           {:error,
            %Refusal{
              reason: :secondary_metric_regressed,
              message:
                "#{name} regressed #{format_percent(value)} over #{n} subjects, " <>
                  "past the #{format_percent(@max_secondary_regression)} limit",
              metric: to_string(name),
              delta: value,
              n: n,
              threshold: @max_secondary_regression
            }}}
      end
    end)
  end

  defp regression?(value) when is_number(value),
    do: value < 0 and abs(value) > @max_secondary_regression

  defp format_percent(value) do
    "#{Float.round(abs(value) * 100, 1)}%"
  end

  defp run_promotion(experiment, template, variant, trigger, stop_rule, ignored, opts) do
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
          |> Map.merge(override_metadata(stop_rule, opts))
          |> Map.merge(ignored_regressions_metadata(ignored))
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

  # An override that is not visibly an override is indistinguishable from a
  # promotion that met its stop rule — which is exactly the record somebody
  # would need six weeks later to explain why a prompt changed on twelve
  # subjects. The sample size is stamped AT THE TIME, because the
  # experiment keeps accruing subjects afterwards.
  defp override_metadata({:overridden, observed, required}, opts) do
    %{
      "override" => true,
      "override_actor_id" => Keyword.get(opts, :actor_id),
      "override_observed_subjects" => observed,
      "override_required_subjects" => required
    }
  end

  defp override_metadata(_stop_rule, _opts), do: %{}

  defp ignored_regressions_metadata([]), do: %{}
  defp ignored_regressions_metadata(ignored), do: %{"ignored_regressions" => ignored}

  defp check_trigger(_experiment, :manual), do: :ok
  defp check_trigger(%Experiment{auto_promote: true}, :auto), do: :ok
  defp check_trigger(%Experiment{}, :auto), do: {:error, :auto_promotion_disabled}
  # An agent's promotion. Gated by `Guardrails.check(:promote, …)` upstream.
  defp check_trigger(_experiment, :agent), do: :ok
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
  defp default_actor_type(:agent), do: "agent"
  defp default_actor_type(_), do: "user"

  defp actor_label(opts) do
    Keyword.get(opts, :actor) || Keyword.get(opts, :actor_id) ||
      to_string(Keyword.get(opts, :trigger, :manual))
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
