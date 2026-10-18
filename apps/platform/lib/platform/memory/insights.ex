defmodule Platform.Memory.Insights do
  @moduledoc """
  Context for dreaming synthesis as INSIGHTS: things a dreaming run thinks
  should happen (a page edit, a briefing line, a question, a task), held
  briefly and then forgotten. Task `01a13867-3213-7001-a128-6b4c6b34283f`,
  stage 1; replaces the approve-or-reject queue of the retired
  `Platform.Memory.Proposals` (removed in stage 5 with its UI; the
  `memory_proposals` table stays until a separate one-way drop).

  ## Two tables, two lifetimes

      journal write ─► ingest_from_journal/3 ─► memory_insights (open)
                                                   │
                         record_outcome :acted ────┼─► done  ─► Signal "accepted"
                         reject (reason)       ────┼─► dismissed + verdict "rejected"
                         flag   (reason)       ────┼─► verdict "flagged"
                                                   │
                         expires_at passes     ────┴─► row DELETED (Purger)

  `memory_insights` is ephemeral: `Platform.Memory.Insights.Purger`
  hard-deletes every row past `expires_at`, whatever its state, and
  `list_open/1` hides an expired row even before the purge runs.
  `memory_insight_verdicts` is durable: verdicts feed `exemplars/1` and the
  ingest dedup, and are never purged.

  ## Dedup

  A block is skipped when its `block_hash` already exists for the workspace
  in `memory_insights` OR in `memory_insight_verdicts`. The second half is
  what keeps a rejected insight from re-ingesting after its row is purged.

  ## Run id

  `run_id/2` derives a uuid-shaped id from `(workspace_id, journal date)`,
  so the dreaming dispatch (which resolves the `memory.insight_synthesis`
  experiment surface for that run) and this ingest (which reads the same
  arm's `min_confidence`) agree on the subject without the model copying an
  id into its output.

  ## Signals

  When the run was assigned to an experiment on `memory.insight_synthesis`,
  every outcome records an `experiment_signals` row (`source_type`
  `"memory_insight"`, `source_id` the insight id, label `accepted`,
  `rejected` or `flagged`). A signal carries the id, the label and, for a
  rejection or a flag only, the reason. It NEVER carries the insight body:
  signals are durable and the body is not.

  ## PubSub

  Every change broadcasts `{:memory_insights, event, payload}` on topic
  `"memory_insights"`.
  """

  import Ecto.Query

  require Logger

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Signals
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.InsightSynthesis
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Actions
  alias Platform.Memory.Insights.Grounding
  alias Platform.Memory.Insights.Parser
  alias Platform.Memory.Insights.Routing
  alias Platform.Memory.Insights.Tier
  alias Platform.Memory.InsightVerdict
  alias Platform.Repo

  @topic "memory_insights"
  @default_open_limit 50
  @default_exemplars_limit 3
  @signal_source_type "memory_insight"

  @journal_path_regex ~r/^(org|project\/[^\/]+|space\/[^\/]+)\/journal\/(\d{4}-\d{2}-\d{2})\.md$/

  @doc "The PubSub topic every change is broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "True when `file_key` is a journal path the ingest sweep should read."
  @spec journal_path?(term()) :: boolean()
  def journal_path?(file_key) when is_binary(file_key),
    do: Regex.match?(@journal_path_regex, file_key)

  def journal_path?(_), do: false

  @doc """
  The dreaming run id for `workspace_id` on `date`: uuid-shaped and
  deterministic (see the moduledoc).
  """
  @spec run_id(binary() | nil, Date.t() | String.t()) :: String.t()
  def run_id(workspace_id, %Date{} = date), do: run_id(workspace_id, Date.to_iso8601(date))

  def run_id(workspace_id, date) when is_binary(date),
    do: Platform.UUID.deterministic("memory_insight_run:#{workspace_id || "org"}:#{date}")

  # ── Ingest ───────────────────────────────────────────────────────────

  @doc """
  Parse `content` for `<synthesis-insight>` blocks and insert one open
  insight per new, well-formed block. Returns `{:ok, inserted_count}`.

  `<synthesis-proposal>` blocks are not read here.
  """
  @spec ingest_from_journal(binary() | nil, String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()}
  def ingest_from_journal(workspace_id, journal_path, content) when is_binary(journal_path) do
    case Parser.parse(content) do
      [] ->
        {:ok, 0}

      blocks ->
        run_id = run_id(workspace_id, journal_date(journal_path))
        min_confidence = min_confidence(run_id)

        inserted =
          blocks
          |> Enum.map(&insert_block(&1, workspace_id, journal_path, run_id, min_confidence))
          |> Enum.filter(&match?({:ok, _}, &1))

        Enum.each(inserted, fn {:ok, insight} -> broadcast(:ingested, insight) end)
        {:ok, length(inserted)}
    end
  end

  defp journal_date(journal_path) do
    case Regex.run(@journal_path_regex, journal_path) do
      [_, _ns, date] -> date
      _ -> Date.to_iso8601(Date.utc_today())
    end
  end

  defp insert_block(parsed, workspace_id, journal_path, run_id, min_confidence) do
    if duplicate?(workspace_id, parsed.block_hash) do
      {:conflict, :duplicate}
    else
      attrs =
        parsed
        |> Map.merge(%{
          workspace_id: workspace_id,
          org_id: ingest_org_id(journal_path),
          journal_path: journal_path,
          run_id: run_id,
          origin: "dreaming",
          disseminable: meets?(parsed.confidence, min_confidence)
        })
        |> Grounding.ground()
        |> route_and_tier()

      %Insight{}
      |> Insight.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, insight} ->
          {:ok, insight}

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if Keyword.has_key?(errors, :workspace_id),
            do: {:conflict, :duplicate},
            else: {:error, changeset}
      end
    end
  end

  # Stage 2: route (unless grounding already addressed a downgraded
  # question to the fact's owner), then classify on the routed insight.
  defp route_and_tier(attrs) do
    attrs =
      if Map.has_key?(attrs, :addressee_reason) do
        attrs
      else
        {user_id, reason} = Routing.resolve(attrs)
        Map.merge(attrs, %{addressee_user_id: user_id, addressee_reason: reason})
      end

    Map.put(attrs, :tier, Tier.label(Tier.classify(struct(Insight, attrs))))
  end

  # The org a journal's insights belong to: a project namespace's project
  # org, else the install's root org (which is also `Tier.org_id/1`'s
  # fallback for a row with none).
  defp ingest_org_id("project/" <> rest) do
    with [project_id | _] <- String.split(rest, "/", parts: 2),
         true <- Platform.UUID.valid?(project_id),
         org_id when is_binary(org_id) <-
           Repo.one(
             from(p in Platform.Tasks.Project, where: p.id == ^project_id, select: p.org_id)
           ) do
      org_id
    else
      _ -> root_org_id()
    end
  end

  defp ingest_org_id(_journal_path), do: root_org_id()

  defp root_org_id do
    case Platform.Tenancy.get_root_org() do
      %{id: id} -> id
      nil -> nil
    end
  end

  # Strict on workspace: nil matches IS NULL, mirroring the unique index
  # (and the retired `Proposals.duplicate?/2`).
  defp duplicate?(workspace_id, block_hash) do
    in_insights =
      Insight
      |> where([i], i.block_hash == ^block_hash)
      |> strict_workspace(workspace_id)
      |> Repo.exists?()

    in_insights or
      InsightVerdict
      |> where([v], v.block_hash == ^block_hash)
      |> strict_workspace(workspace_id)
      |> Repo.exists?()
  end

  @confidence_rank %{"high" => 3, "medium" => 2, "low" => 1}

  defp meets?(confidence, min_confidence),
    do: Map.get(@confidence_rank, confidence, 0) >= Map.get(@confidence_rank, min_confidence, 3)

  # The arm's `min_confidence` for this run, or the control's. Never raises.
  defp min_confidence(run_id) do
    payload = synthesis_payload(run_id)
    Map.get(payload, "min_confidence") || "high"
  end

  @doc """
  The `memory.insight_synthesis` payload for `run_id`: the assigned arm's,
  else the surface default, else the control. Never raises.
  """
  @spec synthesis_payload(String.t()) :: map()
  def synthesis_payload(run_id) when is_binary(run_id) do
    subject = Subject.new(InsightSynthesis.subject_type(), run_id)

    case Surfaces.resolve(InsightSynthesis.key(), InsightSynthesis.target(), subject) do
      {:variant, _experiment, _slug, %{} = payload} -> payload
      {:default, %{} = payload} -> payload
      _ -> InsightSynthesis.control()
    end
  rescue
    _ -> InsightSynthesis.control()
  end

  @doc """
  The experiment-directive block for the dreaming run of `workspace_id` on
  `date`, or `""` when the arm renders no directive (the control does not).
  Appended to the dreaming prompt by both dreaming render paths.
  """
  @spec directive_block(binary() | nil, Date.t() | String.t()) :: String.t()
  def directive_block(workspace_id, date) do
    case InsightSynthesis.render_directive(synthesis_payload(run_id(workspace_id, date))) do
      text when is_binary(text) and text != "" ->
        "\n\n## Experiment directive (#{InsightSynthesis.key()})\n\n" <> text <> "\n"

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  # ── Read ─────────────────────────────────────────────────────────────

  @doc """
  Open insights newest first, excluding any whose `expires_at` has passed
  (so an expired row is hidden even before the purge deletes it).

  Options: `:workspace_id` (nil = no filter), `:limit` (default 50),
  `:now`.
  """
  @spec list_open(keyword()) :: [Insight.t()]
  def list_open(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Insight
    |> where([i], i.state == "open" and i.expires_at > ^now)
    |> loose_workspace(Keyword.get(opts, :workspace_id))
    |> order_by([i], desc: i.inserted_at, desc: i.id)
    |> limit(^Keyword.get(opts, :limit, @default_open_limit))
    |> Repo.all()
  end

  @doc """
  Acted (`done`) insights whose row still lives, most recently acted
  first: the Insights tab's "Already done" section (task 01a13867 stage 5).
  Expired rows are hidden even before the purge.

  Options: `:workspace_id` (nil = no filter), `:limit` (default 50),
  `:now`.
  """
  @spec list_done(keyword()) :: [Insight.t()]
  def list_done(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Insight
    |> where([i], i.state == "done" and i.expires_at > ^now)
    |> loose_workspace(Keyword.get(opts, :workspace_id))
    |> order_by([i], desc: i.acted_at, desc: i.id)
    |> limit(^Keyword.get(opts, :limit, @default_open_limit))
    |> Repo.all()
  end

  @doc "Fetch an insight by id; nil for a missing row or a non-UUID id."
  @spec get(term()) :: Insight.t() | nil
  def get(id) when is_binary(id) do
    # `id` arrives as a LiveView / canvas param. Platform.UUID.valid?/1 rather
    # than a bare Ecto.UUID.cast/1, as the retired Proposals.get/1 did.
    if Platform.UUID.valid?(id), do: Repo.get(Insight, id), else: nil
  end

  def get(_), do: nil

  # ── Outcomes ─────────────────────────────────────────────────────────

  @doc """
  Reject an insight with a reason: writes a durable `rejected` verdict and
  marks the insight `dismissed`. A blank or nil reason is refused with
  `{:error, changeset}` and nothing is written.

  Options: `:actor_id`.
  """
  @spec reject(Insight.t(), String.t() | nil, keyword()) ::
          {:ok, Insight.t()} | {:error, Ecto.Changeset.t()}
  def reject(%Insight{} = insight, reason, opts \\ []) do
    verdict(insight, "rejected", reason, opts, %{state: "dismissed"})
  end

  @doc """
  Flag an insight with a reason: writes a durable `flagged` verdict (an
  exemplar for the next dreaming run, and it survives the TTL purge), then
  undoes what can be undone (task 01a13867 stage 4):

    * an acted `page_edit` whose row still holds its pre-image is restored
      through `Platform.Memory.Insights.Actions.revert/3` as the `:scope`
      given, then dismissed so it does not sit open again. A revert that is
      refused (no scope, `:stale`, not permitted) leaves the page as it is;
      the verdict stands either way;
    * every delivered briefing line or question is retracted on its canvas:
      the line reads `"Retracted: <reason>"` and its buttons are removed
      (`Platform.Memory.Insights.Briefings.retract/2`).

  A blank or nil reason is refused with `{:error, changeset}` and nothing is
  written or undone. The row is re-read first: a purged or expired insight
  is `{:error, :expired}`. Otherwise the insight's state is left as it is.

  Options: `:actor_id`, `:scope` (the clicker's re-loaded
  `%Platform.Access.Scope{}`; its actor is the verdict's actor when
  `:actor_id` is absent), `:now`.
  """
  @spec flag(Insight.t() | binary(), String.t() | nil, keyword()) ::
          {:ok, Insight.t()} | {:error, :expired | Ecto.Changeset.t()}
  def flag(insight_or_id, reason, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    scope = Keyword.get(opts, :scope)
    actor_id = Keyword.get(opts, :actor_id) || Actions.scope_actor_id(scope)

    with {:ok, insight} <- Actions.fetch_live(insight_or_id, now),
         {:ok, flagged} <- verdict(insight, "flagged", reason, [actor_id: actor_id], nil) do
      flagged = undo_flagged(flagged, scope)
      Platform.Memory.Insights.Briefings.retract(flagged.id, reason)
      {:ok, flagged}
    end
  end

  defp undo_flagged(
         %Insight{action_type: "page_edit", state: "done", pre_image: %{}} = insight,
         %Platform.Access.Scope{} = scope
       ) do
    with {:ok, reopened} <- Actions.revert(insight, scope),
         {:ok, dismissed} <- record_outcome(reopened, :dismissed) do
      dismissed
    else
      other ->
        Logger.warning(
          "[memory.insights] flagged page_edit #{insight.id} not reverted: " <>
            inspect(other, limit: 3)
        )

        insight
    end
  end

  defp undo_flagged(insight, _scope), do: insight

  defp verdict(%Insight{} = insight, kind, reason, opts, state_change) do
    actor_id = Keyword.get(opts, :actor_id)

    verdict_changeset =
      InsightVerdict.changeset(%InsightVerdict{}, %{
        block_hash: insight.block_hash,
        kind: kind,
        reason: reason,
        body: insight.body,
        action_type: insight.action_type,
        evidence: insight.evidence,
        actor_id: actor_id,
        workspace_id: insight.workspace_id,
        origin: insight.origin
      })

    Repo.transaction(fn ->
      with {:ok, verdict} <- Repo.insert(verdict_changeset),
           {:ok, updated} <- maybe_update_state(insight, state_change, actor_id) do
        {updated, verdict}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {updated, verdict}} ->
        record_signal(updated, kind, verdict.reason)
        broadcast(verdict_event(kind), updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp verdict_event("rejected"), do: :rejected
  defp verdict_event("flagged"), do: :flagged

  defp maybe_update_state(insight, nil, _actor_id), do: {:ok, insight}

  defp maybe_update_state(insight, attrs, _actor_id) do
    insight |> Insight.outcome_changeset(attrs) |> Repo.update()
  end

  @doc """
  Record what happened to an insight.

    * `:acted` marks it `done` with `acted_by` / `acted_at` /
      `artefact_ref` / `pre_image` (options `:actor_id`, `:artefact_ref`,
      `:pre_image`, `:now`) and records an `accepted` signal. It broadcasts
      `:acted` unless `broadcast: false`: a caller inside `Repo.transaction`
      passes that and broadcasts after the commit, because a subscriber
      re-reads the row from another process and must not do so before the
      row is committed (task 01a13867 stage 6).
    * `:dismissed` marks it `dismissed` and records no signal: a dismissal
      without a reason is not a verdict.

  The row still expires on schedule either way.
  """
  @spec record_outcome(Insight.t(), :acted | :dismissed, keyword()) ::
          {:ok, Insight.t()} | {:error, Ecto.Changeset.t()}
  def record_outcome(insight, outcome, opts \\ [])

  def record_outcome(%Insight{} = insight, :acted, opts) do
    attrs = %{
      state: "done",
      acted_by: Keyword.get(opts, :actor_id),
      acted_at: Keyword.get(opts, :now, DateTime.utc_now()),
      artefact_ref: Keyword.get(opts, :artefact_ref),
      pre_image: Keyword.get(opts, :pre_image)
    }

    with {:ok, updated} <- insight |> Insight.outcome_changeset(attrs) |> Repo.update() do
      record_signal(updated, "accepted", nil)
      if Keyword.get(opts, :broadcast, true), do: broadcast(:acted, updated)
      {:ok, updated}
    end
  end

  def record_outcome(%Insight{} = insight, :dismissed, _opts) do
    with {:ok, updated} <-
           insight |> Insight.outcome_changeset(%{state: "dismissed"}) |> Repo.update() do
      broadcast(:dismissed, updated)
      {:ok, updated}
    end
  end

  @doc """
  Stamp an insight as delivered in a daily briefing (task 01a13867 stage 3)
  and record a `delivered` signal when its run is in an experiment. The
  signal is not a verdict: `InsightAcceptanceRate` counts only `accepted`,
  `rejected` and `flagged`. An insight already delivered is left as it is.

  Options: `:now`.
  """
  @spec mark_delivered(Insight.t(), keyword()) :: {:ok, Insight.t()} | {:error, term()}
  def mark_delivered(insight, opts \\ [])

  def mark_delivered(%Insight{delivered_at: %DateTime{}} = insight, _opts), do: {:ok, insight}

  def mark_delivered(%Insight{} = insight, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, updated} <-
           insight |> Insight.delivery_changeset(%{delivered_at: now}) |> Repo.update() do
      record_signal(updated, "delivered", nil)
      broadcast(:delivered, updated)
      {:ok, updated}
    end
  end

  # ── Clicker actions (stage 2) ────────────────────────────────────────

  @doc """
  Execute an insight as the clicker `scope` (a `%Platform.Access.Scope{}`
  the caller re-loads for the click). See `Platform.Memory.Insights.Actions`
  for the rules: an expired or purged row is `{:error, :expired}` and runs
  nothing; a `needs_call` insight needs `Access.authorize_install/1`.

  Options: `:now`.
  """
  @spec act(Insight.t() | binary(), Platform.Access.Scope.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def act(insight_or_id, scope, opts \\ []), do: Actions.act(insight_or_id, scope, opts)

  @doc """
  The recipient of a delivered briefing line confirms it ("Looks right"):
  marks it acted and records the `accepted` signal. See
  `Actions.looks_right/3`.
  """
  @spec looks_right(Insight.t() | binary(), Platform.Access.Scope.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def looks_right(insight_or_id, scope, opts \\ []),
    do: Actions.looks_right(insight_or_id, scope, opts)

  @doc """
  Answer a delivered question: a cited org journal entry authored by the
  answerer, then the insight is done with `artefact_ref` `journal:<id>`.
  See `Actions.answer/4`. Options: `:canvas_id` (the briefing canvas the
  answer came from), `:now`.
  """
  @spec answer(Insight.t() | binary(), Platform.Access.Scope.t(), String.t() | nil, keyword()) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def answer(insight_or_id, scope, answer, opts \\ []),
    do: Actions.answer(insight_or_id, scope, answer, opts)

  @doc "Send an open insight to `addressee` (email, user id or agent slug). See `Actions.reroute/4`."
  @spec reroute(Insight.t() | binary(), Platform.Access.Scope.t(), String.t()) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def reroute(insight_or_id, scope, addressee),
    do: Actions.reroute(insight_or_id, scope, addressee)

  @doc """
  Reject an open insight as the clicker `scope`, with a required reason.
  See `Actions.reject/4`. (`reject/3` is the unscoped verdict writer this
  calls once the clicker is allowed.)
  """
  @spec reject_as(Insight.t() | binary(), Platform.Access.Scope.t(), String.t() | nil) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def reject_as(insight_or_id, scope, reason), do: Actions.reject(insight_or_id, scope, reason)

  @doc "Whether `scope` may press an insight's buttons. See `Actions.may_handle?/2`."
  @spec may_handle?(Insight.t(), Platform.Access.Scope.t()) :: boolean()
  def may_handle?(insight, scope), do: Actions.may_handle?(insight, scope)

  @doc "Dismiss an open insight without a reason. See `Actions.dismiss/3`."
  @spec dismiss(Insight.t() | binary(), Platform.Access.Scope.t()) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def dismiss(insight_or_id, scope), do: Actions.dismiss(insight_or_id, scope)

  @doc "Write an acted page_edit's pre-image back while the row lives. See `Actions.revert/3`."
  @spec revert(Insight.t() | binary(), Platform.Access.Scope.t()) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def revert(insight_or_id, scope), do: Actions.revert(insight_or_id, scope)

  @doc "Change an open insight's body or hunks before acting. See `Actions.edit/4`."
  @spec edit(Insight.t() | binary(), Platform.Access.Scope.t(), map()) ::
          {:ok, Insight.t()} | {:error, atom() | Ecto.Changeset.t()}
  def edit(insight_or_id, scope, attrs), do: Actions.edit(insight_or_id, scope, attrs)

  # ── Exemplars ────────────────────────────────────────────────────────

  @doc """
  The most recent verdicts as few-shot exemplars for the next dreaming
  prompt, newest first: `%{body, reason, kind, action_type}`.

  Options: `:workspace_id` (nil = no filter), `:limit` (default 3).
  """
  @spec exemplars(keyword()) :: [
          %{
            body: String.t() | nil,
            reason: String.t(),
            kind: String.t(),
            action_type: String.t() | nil
          }
        ]
  def exemplars(opts \\ []) when is_list(opts) do
    InsightVerdict
    |> loose_workspace(Keyword.get(opts, :workspace_id))
    |> order_by([v], desc: v.inserted_at, desc: v.id)
    |> limit(^Keyword.get(opts, :limit, @default_exemplars_limit))
    |> Repo.all()
    |> Enum.map(fn v ->
      %{body: v.body, reason: v.reason, kind: v.kind, action_type: v.action_type}
    end)
  end

  @doc """
  Render `exemplars/1` as the bulleted text the dreaming prompt's
  `{{rejected_exemplars}}` placeholder carries. Shared by both dreaming
  render paths so they cannot drift. Never raises.
  """
  @spec render_exemplars(keyword()) :: String.t()
  def render_exemplars(opts \\ []) do
    case safe_exemplars(opts) do
      [] ->
        "(no prior rejections in the recent window)"

      rows ->
        Enum.map_join(rows, "\n", fn %{body: body, reason: reason, kind: kind} = row ->
          "- [#{kind} #{row.action_type || "insight"}] #{body}\n  - Reason: #{reason}"
        end)
    end
  end

  defp safe_exemplars(opts) do
    exemplars(opts)
  rescue
    error ->
      Logger.warning("[memory.insights] exemplars/1 raised: " <> Exception.message(error))
      []
  end

  # ── Signals ──────────────────────────────────────────────────────────

  # A signal only exists for a run an experiment on this surface assigned.
  # Id + label (+ reason for a verdict). Never the body.
  defp record_signal(%Insight{run_id: run_id} = insight, label, reason) when is_binary(run_id) do
    subject_type = InsightSynthesis.subject_type()

    experiment_ids =
      Repo.all(
        from(a in Assignment,
          join: e in Experiment,
          on: e.id == a.experiment_id,
          where:
            a.subject_type == ^subject_type and a.subject_id == ^run_id and
              e.surface_key == ^InsightSynthesis.key() and is_nil(a.excluded_reason),
          select: a.experiment_id
        )
      )

    Enum.each(experiment_ids, fn experiment_id ->
      Signals.record(%{
        experiment_id: experiment_id,
        subject_type: subject_type,
        subject_id: run_id,
        label: label,
        reason: if(label in ["rejected", "flagged"], do: reason),
        source_type: @signal_source_type,
        source_id: "#{insight.id}:#{label}",
        labeler: "memory.insights",
        status: "labelled"
      })
    end)
  rescue
    error ->
      Logger.warning("[memory.insights] signal record failed: " <> Exception.message(error))
      :ok
  end

  defp record_signal(_insight, _label, _reason), do: :ok

  @doc "The signal `source_type` insight outcomes are recorded under."
  @spec signal_source_type() :: String.t()
  def signal_source_type, do: @signal_source_type

  # ── Helpers ──────────────────────────────────────────────────────────

  @doc false
  # Public for `Platform.Memory.Insights.Actions`, which broadcasts its own
  # events (`:rerouted`, `:edited`, `:reverted`) on this topic.
  #
  # Every broadcast also emits `[:platform, :memory_insights, :broadcast]`
  # with `%{event: event, insight_id: id | nil, in_transaction?:
  # Repo.in_transaction?()}` (the handler runs in the broadcasting process).
  # A broadcast from inside a transaction reaches subscribers before the
  # change they will re-read is committed; the stage-6 tests assert
  # `in_transaction?: false`.
  def broadcast(event, payload) do
    :telemetry.execute(
      [:platform, :memory_insights, :broadcast],
      %{count: 1},
      %{
        event: event,
        insight_id: if(is_map(payload), do: Map.get(payload, :id)),
        in_transaction?: Repo.in_transaction?()
      }
    )

    Phoenix.PubSub.broadcast(Platform.PubSub, @topic, {:memory_insights, event, payload})
  rescue
    _ -> :ok
  end

  defp strict_workspace(query, nil), do: where(query, [r], is_nil(r.workspace_id))

  defp strict_workspace(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [r], r.workspace_id == ^workspace_id)

  defp loose_workspace(query, nil), do: query

  defp loose_workspace(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [r], r.workspace_id == ^workspace_id)
end
