defmodule Platform.Mail.Triage do
  @moduledoc """
  Mail triage for the morning briefing (task 01a1f426 stage 1, Level 1
  backend): for one reader, which of today's emails need something from
  them, and one line on why.

  `Platform.Mail.Digest` stays what it is (metadata only, the admin
  cross-mailbox view). This module reads bodies, so its permission rule is
  narrower and is applied in every query it makes.

  ## Which mailboxes a reader's triage covers

  `eligible_account_ids/2`: the non-archived accounts of the org that the
  reader may read (`Ownership.readable_account_ids_query/2`: personal ones
  they own, shared ones they hold a grant on) INTERSECTED with the accounts
  that have an ACTIVE flag-important agent
  (`Ownership.flag_important_account_ids_query/1`). Both are subqueries of
  the one account query. An ordinary access grant alone makes no mailbox
  eligible, and a reader sees triage only of mail they may read. Org admin
  status confers nothing here, and `digest_opt_in` (which governs the
  cross-mailbox Digest only) is not consulted.

  ## Which agent

  The agent is chosen PER MAILBOX (task 01a1f5cc): the active agent holding
  the account's flag-important grant (`agent_for_account/1`), set by the
  mailbox's owner (or a shared mailbox's org admins) through
  `Ownership.set_flag_important_agent/3`. One reader's two mailboxes may
  name different agents; each email is classified, notified and drafted by
  its own mailbox's agent. A mailbox with no flag agent (Off) or whose flag
  agent is not active triages nothing. The `mail.triage` responsibility's
  assignee (`Platform.Roles`) is NOT read: there is no fallback, so Off is
  true whatever other grants an agent holds.

  ## What leaves the mailbox

  Nothing of the mail. Logger lines carry ids and outcome codes; the
  `[:platform, :mail, :triage, :classified]` telemetry event carries ids,
  the tier and the outcome; there is no PubSub broadcast and no audit row.
  Every write that carries `why` (model output about the mail) uses
  `quiet_opts/0`, which keeps the statement and its params out of Ecto's
  query log AND out of the `[:platform, :repo, :query]` telemetry event
  (whose metadata carries the params even when the log line is suppressed).

  ## Idempotency

  One item per (inbound message, reader), enforced by the unique index:
  `run_for_reader/3` only ever selects inbound with no item for that reader,
  and `classify_for_reader/3` returns the existing item. A provider failure
  stores nothing, so the next run retries it.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Mail.{Account, InboundMessage, Ownership}
  alias Platform.Mail.Triage.{Classifier, Context, Drafter, Feedback, Item}
  alias Platform.Repo

  @responsibility_key "mail.triage"
  @called_out_tiers ~w(top action)
  @default_max_model_calls 40
  @candidate_cap 500

  @rule_why %{
    "list_unsubscribe" => "Bulk mail: it carries an unsubscribe header.",
    "precedence_bulk" => "Bulk or list mail, by its Precedence header.",
    "noreply_sender" => "An automated notice from a no-reply address.",
    "feedback_not_important" => "You marked mail from this sender as not important."
  }

  @doc """
  The responsibility key triage is registered and filed under (drafts carry
  it). Its assignee is NOT read: the agent is chosen per mailbox
  (`agent_for_account/1`).
  """
  @spec responsibility_key() :: String.t()
  def responsibility_key, do: @responsibility_key

  @doc """
  `Repo` options for a write that carries model output or mail-derived
  text: no query log line, no `[:platform, :repo, :query]` telemetry event.
  """
  @spec quiet_opts() :: keyword()
  def quiet_opts, do: [log: false, telemetry_event: nil]

  @doc """
  The ACTIVE agent holding `account_id`'s flag-important grant, or nil (no
  grant, an inactive agent, an unassigned or archived account, or a
  malformed id). Reads grants, never mail.
  """
  @spec agent_for_account(any()) :: Agent.t() | nil
  def agent_for_account(account_id) do
    if Platform.UUID.valid?(account_id) do
      account_id
      |> List.wrap()
      |> Ownership.flag_important_agents_query()
      |> exclude(:select)
      |> select([agent: ag], ag)
      |> Repo.one()
    end
  end

  # `%{account_id => %Agent{}}`: the active flag agent of each of
  # `account_ids` that has one. One query.
  defp agents_for_accounts([]), do: %{}

  defp agents_for_accounts(account_ids) do
    account_ids
    |> Ownership.flag_important_agents_query()
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  `%{account_id => %{last_at: DateTime.t(), count: n}}`: for each of
  `account_ids` with any, the latest `inserted_at` and the number of
  `user`'s OWN items on that account during today's briefing day. Ids and
  timestamps only; reads no mail text.
  """
  @spec reader_activity(any(), [binary()], keyword()) :: %{binary() => map()}
  def reader_activity(user, account_ids, opts \\ [])

  def reader_activity(%{id: user_id}, account_ids, opts)
      when is_binary(user_id) and is_list(account_ids) do
    ids = Enum.filter(account_ids, &Platform.UUID.valid?/1)

    if ids == [] do
      %{}
    else
      date = Keyword.get_lazy(opts, :date, &briefing_today/0)
      {start, finish} = day_bounds(date)

      from(i in Item,
        where: i.user_id == ^user_id and i.account_id in ^ids,
        where: i.inserted_at >= ^start and i.inserted_at < ^finish,
        group_by: i.account_id,
        select: {i.account_id, %{last_at: max(i.inserted_at), count: count(i.id)}}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  def reader_activity(_user, _account_ids, _opts), do: %{}

  # ── Permission ──────────────────────────────────────────────────────────

  @doc """
  Ids of the accounts of `org_id` this reader's triage covers: readable by
  the reader AND with an active flag-important agent. See the moduledoc.
  `[]` for a malformed id.
  """
  @spec eligible_account_ids(any(), any()) :: [binary()]
  def eligible_account_ids(user, org_id) do
    user |> eligible_accounts_query(org_id) |> Repo.all()
  end

  @doc "`eligible_account_ids/2` as a query selecting account ids."
  @spec eligible_accounts_query(any(), any()) :: Ecto.Query.t()
  def eligible_accounts_query(user, org_id) do
    if Platform.UUID.valid?(org_id) do
      readable = Ownership.readable_account_ids_query(user, org_id)
      flagged = Ownership.flag_important_account_ids_query(org_id)

      from(a in Account,
        where: a.org_id == ^org_id and is_nil(a.archived_at),
        where: a.id in subquery(readable),
        where: a.id in subquery(flagged),
        select: a.id
      )
    else
      none_query()
    end
  end

  defp none_query, do: from(a in Account, where: false, select: a.id)

  # ── Classify ────────────────────────────────────────────────────────────

  @doc """
  Triage `inbound` for `user`, with the agent of the inbound's own mailbox
  (`agent_for_account/1`). Returns `{:ok, item}` (new or existing),
  `{:error, :no_triage_agent}` (the mailbox has no active flag agent),
  `{:error, :not_eligible}` (the mailbox is not readable by the reader AND
  flagged: no provider call, no write) or `{:error, :provider_failed}`
  (nothing stored).

  Options: `:roster` (a pre-read People roster), `:now`.
  """
  @spec classify_for_reader(map(), InboundMessage.t(), keyword()) ::
          {:ok, Item.t()} | {:error, atom()}
  def classify_for_reader(user, inbound, opts \\ [])

  def classify_for_reader(%{id: user_id} = user, %InboundMessage{} = inbound, opts)
      when is_binary(user_id) do
    classify_with(user, inbound, agent_for_account(inbound.account_id), opts)
  end

  def classify_for_reader(_user, _inbound, _opts), do: {:error, :not_eligible}

  # `agent` is the inbound's own mailbox's agent, resolved by the caller
  # from `inbound.account_id` (never chosen by a caller of the public API).
  defp classify_with(user, inbound, %Agent{} = agent, opts) do
    cond do
      not eligible_inbound?(user, inbound) ->
        {:error, :not_eligible}

      item = get_item(user.id, inbound.id) ->
        {:ok, item}

      true ->
        do_classify(user, inbound, agent, opts)
    end
  end

  defp classify_with(_user, _inbound, _agent, _opts), do: {:error, :no_triage_agent}

  defp eligible_inbound?(user, %InboundMessage{id: id, org_id: org_id}) do
    eligible = eligible_accounts_query(user, org_id)

    from(m in InboundMessage,
      where: m.id == ^id and m.account_id in subquery(eligible)
    )
    |> Repo.exists?()
  end

  defp do_classify(user, inbound, agent, opts) do
    ctx = Context.build(user, inbound, Keyword.take(opts, [:roster, :now]))
    signals = Context.signals(ctx)

    case Classifier.prefilter(inbound, ctx) do
      {:rule, tier, rule} ->
        store(user, inbound, %{
          tier: tier,
          needs: "none",
          why: Map.fetch!(@rule_why, rule),
          signals: signals,
          classifier: "rule:" <> rule,
          outcome: "rule"
        })

      :model ->
        label = Classifier.classifier_label(agent)

        case Classifier.classify(agent, inbound, ctx) do
          {:ok, verdict} ->
            store(user, inbound, %{
              tier: verdict.tier,
              needs: verdict.needs,
              why: verdict.why,
              signals: signals,
              classifier: label,
              outcome: "model"
            })

          {:rejected, defect} ->
            Logger.warning(
              "[Mail.Triage] rejected_output inbound=#{inbound.id} user=#{user.id} defect=#{inspect(defect)}"
            )

            floor = Classifier.apply_floors(%{tier: "routine"}, ctx).tier

            store(user, inbound, %{
              tier: floor,
              needs: "none",
              why: nil,
              signals: signals ++ [%{"kind" => "rejected_output"}],
              classifier: label,
              outcome: "rejected_output"
            })

          :error ->
            Logger.warning(
              "[Mail.Triage] provider_failed inbound=#{inbound.id} user=#{user.id} (nothing stored)"
            )

            {:error, :provider_failed}
        end
    end
  end

  defp store(user, inbound, attrs) do
    {outcome, attrs} = Map.pop(attrs, :outcome)

    changeset =
      Item.create_changeset(
        Map.merge(attrs, %{
          org_id: inbound.org_id,
          account_id: inbound.account_id,
          inbound_message_id: inbound.id,
          user_id: user.id
        })
      )

    case Repo.insert(
           changeset,
           [on_conflict: :nothing, conflict_target: [:inbound_message_id, :user_id]] ++
             quiet_opts()
         ) do
      {:ok, _} ->
        item = get_item(user.id, inbound.id)
        if item, do: emit(item, outcome)
        if item, do: {:ok, item}, else: {:error, :not_stored}

      {:error, _changeset} ->
        Logger.warning("[Mail.Triage] store_failed inbound=#{inbound.id} user=#{user.id}")
        {:error, :not_stored}
    end
  end

  defp emit(%Item{} = item, outcome) do
    Logger.info(
      "[Mail.Triage] classified inbound=#{item.inbound_message_id} user=#{item.user_id} " <>
        "tier=#{item.tier} outcome=#{outcome}"
    )

    :telemetry.execute(
      [:platform, :mail, :triage, :classified],
      %{count: 1},
      %{
        org_id: item.org_id,
        account_id: item.account_id,
        inbound_id: item.inbound_message_id,
        user_id: item.user_id,
        tier: item.tier,
        outcome: outcome,
        classifier: item.classifier
      }
    )
  end

  defp get_item(user_id, inbound_id) do
    from(i in Item, where: i.inbound_message_id == ^inbound_id and i.user_id == ^user_id)
    |> Repo.one(quiet_opts())
  end

  # ── Run ─────────────────────────────────────────────────────────────────

  @doc """
  Triage every eligible email received on briefing date `date`
  (`day_bounds/1`) that has no item for `user` yet, across every org the
  reader is an internal member of.
  Backfilled imports (`ingest_source == "backfill"`) are skipped. At most
  `:max_model_calls` (default #{@default_max_model_calls}) provider calls
  per run; the rest wait for the next run.

  Each email is classified by its own mailbox's agent: the candidates are
  grouped by account, and each account's agent is read once.

  Returns `{:ok, summary}` with `:status` (`:ok`, or `:no_triage_agent`
  when no mailbox the reader may read has an active flag agent),
  `:classified`, `:model_calls`, `:failed` and `:deferred` counts.

  Options: `:since` / `:until` (DateTimes replacing the date's bounds),
  `:max_model_calls`, `:now`.
  """
  @spec run_for_reader(map(), Date.t(), keyword()) :: {:ok, map()}
  def run_for_reader(user, date, opts \\ [])

  def run_for_reader(%{id: user_id} = user, %Date{} = date, opts) when is_binary(user_id) do
    empty = %{status: :ok, classified: 0, model_calls: 0, failed: 0, deferred: 0}
    orgs = org_ids(user)

    if Enum.any?(orgs, &(eligible_account_ids(user, &1) != [])) do
      {from, to} = window(date, opts)
      max_calls = Keyword.get(opts, :max_model_calls, @default_max_model_calls)
      roster = Context.roster()
      candidates = Enum.flat_map(orgs, &candidates(user, &1, from, to))

      agents =
        candidates |> Enum.map(& &1.account_id) |> Enum.uniq() |> agents_for_accounts()

      summary =
        candidates
        |> Enum.reduce(empty, fn inbound, acc ->
          if acc.model_calls >= max_calls and needs_model?(user, inbound) do
            %{acc | deferred: acc.deferred + 1}
          else
            run_one(user, inbound, Map.get(agents, inbound.account_id), roster, opts, acc)
          end
        end)

      {:ok, summary}
    else
      {:ok, %{empty | status: :no_triage_agent}}
    end
  end

  def run_for_reader(_user, _date, _opts),
    do: {:ok, %{status: :ok, classified: 0, model_calls: 0, failed: 0, deferred: 0}}

  defp run_one(user, inbound, agent, roster, opts, acc) do
    result =
      classify_with(user, inbound, agent,
        roster: roster,
        now: Keyword.get(opts, :now, DateTime.utc_now())
      )

    case result do
      {:ok, %Item{classifier: "rule:" <> _}} ->
        %{acc | classified: acc.classified + 1}

      {:ok, %Item{}} ->
        %{acc | classified: acc.classified + 1, model_calls: acc.model_calls + 1}

      {:error, :provider_failed} ->
        %{acc | failed: acc.failed + 1, model_calls: acc.model_calls + 1}

      {:error, _} ->
        %{acc | failed: acc.failed + 1}
    end
  end

  # Once the budget is spent, only an email the pre-filter answers can still
  # run: building the context is cheap, and it costs no model call.
  defp needs_model?(user, inbound) do
    Classifier.prefilter(inbound, Context.build(user, inbound, roster: [])) == :model
  end

  defp window(date, opts) do
    {start, finish} = day_bounds(date)
    {Keyword.get(opts, :since, start), Keyword.get(opts, :until, finish)}
  end

  # ── The briefing day ────────────────────────────────────────────────────

  @doc """
  The briefing date an instant belongs to: the calendar date, in the zone
  the daily briefing's `digest_date` is written in
  (`Platform.Memory.Insights.Disseminator.local_date/1`). Items are
  bucketed by THIS date, never the UTC one: an email at 20:00 local is in
  that evening's briefing, not in the next UTC day's (which has no
  briefing row yet, so its link would render nothing).
  """
  @spec briefing_date(DateTime.t() | NaiveDateTime.t()) :: Date.t()
  def briefing_date(%DateTime{} = at), do: Platform.Memory.Insights.Disseminator.local_date(at)

  def briefing_date(%NaiveDateTime{} = at),
    do: briefing_date(DateTime.from_naive!(at, "Etc/UTC"))

  @doc "Today's briefing date (`briefing_date/1` of now)."
  @spec briefing_today() :: Date.t()
  def briefing_today, do: briefing_date(DateTime.utc_now())

  @doc """
  `{start, finish}` (UTC DateTimes, finish exclusive) of briefing date
  `date`: local midnight to the next local midnight in the briefing zone,
  so a DST day is 23 or 25 hours long.
  """
  @spec day_bounds(Date.t()) :: {DateTime.t(), DateTime.t()}
  def day_bounds(%Date{} = date) do
    zone = Platform.Memory.Insights.Disseminator.timezone()
    {local_midnight(date, zone), local_midnight(Date.add(date, 1), zone)}
  end

  defp local_midnight(date, zone) do
    local =
      case DateTime.new(date, ~T[00:00:00], zone) do
        {:ok, at} -> at
        {:ambiguous, first, _second} -> first
        {:gap, _before, just_after} -> just_after
        {:error, _} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      end

    DateTime.shift_zone!(local, "Etc/UTC")
  end

  @doc """
  Has `user_id`'s briefing for `date` been delivered: a `memory_briefings`
  row for the date AND its Inbox `briefing` row? A row created only so a
  between-briefings link renders (`notify_top/2`) is not a delivery.
  """
  @spec briefing_delivered?(binary(), Date.t()) :: boolean()
  def briefing_delivered?(user_id, %Date{} = date) when is_binary(user_id) do
    case Platform.Memory.Insights.Briefings.for_user_on(user_id, date) do
      %Platform.Memory.Briefing{id: briefing_id} ->
        from(i in Platform.Inbox.Item,
          where:
            i.user_id == ^user_id and i.source_type == "briefing" and
              i.source_id == ^briefing_id
        )
        |> Repo.exists?()

      _ ->
        false
    end
  end

  defp candidates(%{id: user_id} = user, org_id, from, to) do
    eligible = eligible_accounts_query(user, org_id)

    from(m in InboundMessage,
      left_join: i in Item,
      on: i.inbound_message_id == m.id and i.user_id == ^user_id,
      where: m.org_id == ^org_id and m.account_id in subquery(eligible),
      where: is_nil(i.id),
      where: m.ingest_source != "backfill",
      where: coalesce(m.received_at, m.inserted_at) >= ^from,
      where: coalesce(m.received_at, m.inserted_at) < ^to,
      order_by: [asc: coalesce(m.received_at, m.inserted_at), asc: m.id],
      limit: @candidate_cap
    )
    |> Repo.all(quiet_opts())
  end

  defp org_ids(user) do
    user
    |> Platform.Tenancy.list_user_memberships()
    |> Enum.reject(&(&1.external or is_nil(&1.org) or Map.get(&1.org, :archived_at)))
    |> Enum.map(& &1.org_id)
    |> Enum.uniq()
  end

  # ── Read ────────────────────────────────────────────────────────────────

  @doc """
  The called-out items (`top` and `action`) created for `user` on `date`
  (the briefing day, `day_bounds/1`), most important first, then newest.
  Only items whose mailbox is STILL eligible now (readable by the reader
  and with an active flag agent): a revoked grant or a mailbox set to Off
  hides its items at once. Preloads `:inbound_message` and `:account`.

  Options: `:tiers` (default `["top", "action"]`).
  """
  @spec called_out(map(), Date.t(), keyword()) :: [Item.t()]
  def called_out(user, date, opts \\ [])

  def called_out(%{id: user_id} = user, %Date{} = date, opts) when is_binary(user_id) do
    {from, to} = window(date, [])
    tiers = Keyword.get(opts, :tiers, @called_out_tiers)

    user
    |> org_ids()
    |> Enum.flat_map(fn org_id ->
      eligible = eligible_accounts_query(user, org_id)

      from(i in Item,
        where: i.user_id == ^user_id and i.org_id == ^org_id,
        where: i.account_id in subquery(eligible),
        where: i.tier in ^tiers,
        where: i.inserted_at >= ^from and i.inserted_at < ^to
      )
      |> Repo.all(quiet_opts())
    end)
    |> Enum.sort_by(fn i ->
      {tier_rank(i.tier), -DateTime.to_unix(i.inserted_at, :microsecond)}
    end)
    |> Repo.preload([:inbound_message, :account], quiet_opts())
  end

  def called_out(_user, _date, _opts), do: []

  defp tier_rank(tier), do: Enum.find_index(Item.tiers(), &(&1 == tier)) || 99

  # ── Briefing surface (task 01a1f426 stage 2) ────────────────────────────

  @doc """
  What the briefing's `mail_priority` section shows `user` for `date`: a
  pure read. Returns

    * `:agents_by_account` — `%{account_id => %{id, name}}`: the active flag
      agent of each eligible mailbox (empty: no readable mailbox has one).
      There is no single agent: each mailbox has its own;
    * `:readable?` — whether the reader may read any non-archived mailbox
      (no mailbox at all means the section is absent);
    * `:called_out` — the reader's `top` / `action` items of `date` whose
      mailbox is still eligible: open ones first, then by tier, then newest
      received;
    * `:quiet` — `%{id, name}` of the eligible mailboxes (readable AND with
      an active flag agent) with no called-out item for `date`, in name
      order; empty when no mailbox is eligible;
    * `:ungranted` — `%{id, name}` of the mailboxes the reader may read that
      have NO active flag agent (metadata only: the name).

  Each row is a plain map of display fields only (`id`, `inbound_id`,
  `account_id`, `tier`, `status`, `acted_how`, `why`, `from`, `subject`,
  `mailbox`, `received_at`, `plan` and `draft`). The inbound body is never
  selected.

  Low-tier (`routine` / `promo`) items are never selected here: the query
  filters on the called-out tiers, so no routine or promo email reaches the
  briefing in any form (task 01a1f66a). They are still classified and
  stored; Email's message pane is where a reader says one of them needed
  them.

  `:plan` is `%{summary, steps}` when the drafter produced a fulfilment
  plan, else nil. `:draft` (task 01a1f426 stage 5) is `%{id, status,
  preview}` only for a draft that is the item's `draft_id` AND in the
  item's own mailbox AND written on behalf of THIS reader AND visible to
  the reader (`Platform.Mail.Drafts.visible_query/2`) AND not discarded;
  anything else (a forged or stale id, another reader's draft, a draft of
  another mailbox) is nil, so it renders nothing and links nowhere.
  `preview` is at most the first two non-blank lines of the draft's body,
  each capped at 160 characters, read with `quiet_opts/0`.

  Takes no options (the agent is never chosen by the caller).
  """
  @spec section_view(map(), Date.t(), keyword()) :: map()
  def section_view(user, date, opts \\ [])

  def section_view(%{id: user_id} = user, %Date{} = date, _opts) when is_binary(user_id) do
    readable =
      user
      |> org_ids()
      |> Enum.flat_map(fn org_id ->
        readable = Ownership.readable_account_ids_query(user, org_id)

        from(a in Account,
          where: a.org_id == ^org_id and is_nil(a.archived_at) and a.id in subquery(readable),
          order_by: [asc: a.name],
          select: %{id: a.id, org_id: a.org_id, name: a.name}
        )
        |> Repo.all()
      end)

    agents_by_account =
      readable
      |> Enum.map(& &1.id)
      |> agents_for_accounts()
      |> Map.new(fn {account_id, agent} -> {account_id, %{id: agent.id, name: agent.name}} end)

    # Eligible = readable AND an active flag agent, by the same rule as
    # `eligible_accounts_query/2` (both terms were read just above).
    eligible = agents_by_account |> Map.keys() |> MapSet.new()

    called_out =
      if MapSet.size(eligible) > 0, do: section_rows(user_id, date, eligible), else: []

    flagged = MapSet.new(called_out, & &1.account_id)

    %{
      agents_by_account: agents_by_account,
      readable?: readable != [],
      called_out: called_out,
      quiet:
        readable
        |> Enum.filter(&(MapSet.member?(eligible, &1.id) and not MapSet.member?(flagged, &1.id)))
        |> Enum.map(&Map.take(&1, [:id, :name])),
      ungranted:
        readable
        |> Enum.reject(&MapSet.member?(eligible, &1.id))
        |> Enum.map(&Map.take(&1, [:id, :name]))
    }
  end

  def section_view(_user, _date, _opts),
    do: %{
      agents_by_account: %{},
      readable?: false,
      called_out: [],
      quiet: [],
      ungranted: []
    }

  defp section_rows(user_id, date, eligible) do
    {from, to} = window(date, [])
    eligible = MapSet.to_list(eligible)

    from(i in Item,
      join: m in InboundMessage,
      on: m.id == i.inbound_message_id,
      join: a in Account,
      on: a.id == i.account_id,
      where: i.user_id == ^user_id and i.account_id in ^eligible,
      where: i.tier in ^@called_out_tiers,
      where: i.inserted_at >= ^from and i.inserted_at < ^to,
      select: %{
        id: i.id,
        org_id: i.org_id,
        inbound_id: i.inbound_message_id,
        account_id: i.account_id,
        tier: i.tier,
        status: i.status,
        acted_how: i.acted_how,
        why: i.why,
        draft_id: i.draft_id,
        plan_summary: i.plan_summary,
        plan_steps: i.plan_steps,
        inserted_at: i.inserted_at,
        from: m.from_address,
        subject: m.subject,
        received_at: coalesce(m.received_at, m.inserted_at),
        mailbox: a.name
      }
    )
    |> Repo.all(quiet_opts())
    |> with_drafts(user_id)
    |> Enum.sort_by(fn row ->
      {row.status != "open", tier_rank(row.tier),
       -DateTime.to_unix(row.received_at, :microsecond)}
    end)
  end

  @preview_line_cap 160

  # Each row's own draft, read in ONE query per org through the draft
  # visibility rule, pinned to the row's mailbox and to this reader as the
  # on-behalf person; the body is read only to cut the preview.
  defp with_drafts(rows, user_id) do
    drafts =
      rows
      |> Enum.filter(& &1.draft_id)
      |> Enum.group_by(&org_of/1, & &1.draft_id)
      |> Enum.flat_map(fn {org_id, ids} ->
        %{id: user_id}
        |> Platform.Mail.Drafts.visible_query(org_id)
        |> where([d], d.id in ^ids and d.on_behalf_of_user_id == ^user_id)
        |> where([d], d.status in ["draft", "dispatched"])
        |> select([d], %{id: d.id, account_id: d.account_id, status: d.status, body: d.body})
        |> Repo.all(quiet_opts())
      end)
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn row ->
      draft =
        case Map.get(drafts, row.draft_id) do
          %{account_id: account_id} = d when account_id == row.account_id ->
            %{id: d.id, status: d.status, preview: preview(d.body)}

          _ ->
            nil
        end

      plan =
        case row.plan_steps do
          steps when is_list(steps) and steps != [] ->
            %{summary: row.plan_summary, steps: Enum.filter(steps, &is_binary/1)}

          _ ->
            nil
        end

      row
      |> Map.drop([:draft_id, :plan_summary, :plan_steps, :org_id])
      |> Map.merge(%{draft: draft, plan: plan})
    end)
  end

  defp org_of(row), do: row.org_id

  defp preview(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(2)
    |> Enum.map(&String.slice(&1, 0, @preview_line_cap))
  end

  defp preview(_), do: []

  @doc """
  The reader's OWN item `item_id`, whatever its mailbox's eligibility now
  (the caller decides that with `eligible?/2`). nil for a malformed id, an
  unknown one, or another reader's item.
  """
  @spec reader_item(map(), any()) :: Item.t() | nil
  def reader_item(%{id: user_id}, item_id) when is_binary(user_id) and is_binary(item_id) do
    if Platform.UUID.valid?(item_id) and Platform.UUID.valid?(user_id) do
      Repo.one(from(i in Item, where: i.id == ^item_id and i.user_id == ^user_id), quiet_opts())
    end
  end

  def reader_item(_user, _item_id), do: nil

  @doc """
  Is the mailbox of `target` (an item or an inbound message: anything with
  `org_id` and `account_id`) eligible for `user` NOW: readable by the
  reader AND with an active flag agent (`eligible_account_ids/2`).
  """
  @spec eligible?(map(), map()) :: boolean()
  def eligible?(user, %{org_id: org_id, account_id: account_id})
      when is_binary(account_id) do
    account_id in eligible_account_ids(user, org_id)
  end

  def eligible?(_user, _target), do: false

  @doc """
  The reader marks their called-out item done: status `acted`, `acted_how`
  `"manual"`. Only the reader's own open item; `{:error, :not_found}`
  otherwise. Writes ids and a status only; logs ids only.
  """
  @spec mark_done(map(), Item.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def mark_done(%{id: user_id}, %Item{user_id: user_id, status: "open"} = item)
      when is_binary(user_id) do
    {:ok, updated} =
      item
      |> Item.update_changeset(%{
        status: "acted",
        acted_at: DateTime.utc_now(),
        acted_how: "manual"
      })
      |> Repo.update(quiet_opts())

    Logger.info("[Mail.Triage] done item=#{item.id} user=#{user_id}")
    Platform.Mail.Triage.Metrics.emit(updated, "acted_manual")
    {:ok, updated}
  end

  def mark_done(_user, _item), do: {:error, :not_found}

  # ── Between briefings (task 01a1f426 stage 3) ───────────────────────────

  @doc """
  A newly ingested email `inbound_id`, triaged by its own mailbox's agent
  (`agent_for_account/1`; no agent means no work) for every reader of the
  mailbox for whom it is eligible (`eligible?/2`), and a `top` result
  notified at once (`notify_top/2`), and a called-out one handed to
  `Platform.Mail.Triage.Drafter` (a draft reply or a plan, never a send).
  Driven by `Platform.Mail.Triage.Subscriber`.

  A backfilled import (`ingest_source == "backfill"`) is skipped: a quiet
  import must not page anyone. Calls no send path. Returns `:ok`.

  Options: `:now`.
  """
  @spec on_inbound(binary(), keyword()) :: :ok
  def on_inbound(inbound_id, opts \\ []) when is_binary(inbound_id) do
    with true <- Platform.UUID.valid?(inbound_id),
         %InboundMessage{ingest_source: source} = inbound when source != "backfill" <-
           Repo.get(InboundMessage, inbound_id, quiet_opts()),
         %Agent{} = agent <- agent_for_account(inbound.account_id) do
      for user <- reader_candidates(inbound.account_id) do
        triage_and_notify(user, inbound, agent, opts)
      end
    end

    :ok
  end

  @doc """
  The start-up pass of `Platform.Mail.Triage.Subscriber`: every live
  (non-backfill) email of the last 24 hours in a mailbox WITH an active
  flag agent goes through `on_inbound/2`. At most #{@candidate_cap} emails
  per pass. Returns the number of emails visited.

  Options: `:now`.
  """
  @spec reconcile(keyword()) :: non_neg_integer()
  def reconcile(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -86_400, :second)

    flagged =
      Ownership.flag_important_agents_query(:all)
      |> exclude(:select)
      |> select([account: a], a.id)

    ids =
      from(m in InboundMessage,
        where: m.account_id in subquery(flagged),
        where: m.ingest_source != "backfill",
        where: coalesce(m.received_at, m.inserted_at) >= ^since,
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: @candidate_cap,
        select: m.id
      )
      |> Repo.all()

    Enum.each(ids, &on_inbound(&1, opts))
    length(ids)
  end

  # The people who may read an account by its ownership: the owner of a
  # personal one, the user-grant holders of a shared one. A CANDIDATE list
  # only: `classify_for_reader/3` decides eligibility for each (readable
  # AND flagged), so this list is never the permission.
  defp reader_candidates(account_id) do
    owner =
      from(a in Account,
        where: a.id == ^account_id and a.owner_kind == "personal",
        where: not is_nil(a.owner_user_id),
        select: a.owner_user_id
      )

    ids = Repo.all(owner) ++ Ownership.shared_member_ids(account_id)

    if ids == [] do
      []
    else
      from(u in Platform.Accounts.User,
        where: u.id in ^Enum.uniq(ids) and is_nil(u.archived_at)
      )
      |> Repo.all()
    end
  end

  # Classify, notify a `top` item, then start the work on a called-out one
  # (`Platform.Mail.Triage.Drafter`, task 01a1f426 stage 4: drafts only,
  # capped per reader per day).
  defp triage_and_notify(user, inbound, agent, opts) do
    now = opts[:now] || DateTime.utc_now()

    case classify_with(user, inbound, agent, now: now) do
      {:ok, %Item{} = item} ->
        if item.tier == "top", do: notify_top(item, opts)
        if Drafter.draftable?(item), do: Drafter.draft(user, item, now: now)
        :ok

      _ ->
        :ok
    end
  end

  @push_cap_per_day 3

  @doc "At most this many between-briefing pushes per reader per (UTC) day."
  @spec push_cap_per_day() :: pos_integer()
  def push_cap_per_day, do: @push_cap_per_day

  @doc """
  Tell the reader a `top` item landed between briefings. Only an item whose
  `notified_at` is nil: the same `UPDATE` sets it, so a second event, a
  reconcile or a concurrent task notifies nothing (the dedupe). The
  mailbox must still be eligible for the reader now (`eligible?/2`: still
  readable, and still with an active flag agent).

  Options: `:now`.

    * an Inbox row of kind `mail_priority` (`source_type`
      `mail_triage_item`): title "An email needs you", body
      "In <mailbox name>. Open the briefing to see why.";
    * a push, the same text, through `Platform.Notifications.fan_out_to_user/3`
      (`:notifications_module` in tests). Skipped when the reader's
      notification level is `"direct"` (only direct mentions may interrupt
      them, `Platform.Accounts.notification_level/1`) and once
      #{@push_cap_per_day} items were notified for the reader that UTC day:
      the rest wait for the briefing (their Inbox row is still written).

  Neither carries the subject, the why line, the sender or the body. Both
  open the briefing of the item's day (`Platform.Inbox.briefing_url/1`).

  Returns `{:ok, :notified | :row_only}` or `{:ok, :skipped}`.
  """
  @spec notify_top(Item.t(), keyword()) :: {:ok, :notified | :row_only | :skipped}
  def notify_top(item, opts \\ [])

  def notify_top(%Item{tier: "top", notified_at: nil} = item, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    user = Repo.get(Platform.Accounts.User, item.user_id)

    with %Platform.Accounts.User{} <- user,
         true <- eligible?(user, item),
         {:ok, {:claimed, earlier}} <- claim_notification(item, now) do
      deliver_notification(user, item, earlier, now)
    else
      _ -> {:ok, :skipped}
    end
  end

  def notify_top(_item, _opts), do: {:ok, :skipped}

  # Set `notified_at` iff it is still nil, under a per-reader transaction
  # lock so the day's count and the claim are one step. Returns how many of
  # the reader's items were notified earlier that UTC day.
  defp claim_notification(%Item{id: id, user_id: user_id}, now) do
    {:ok, day_start} = DateTime.new(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")

    Repo.transaction(fn ->
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        ["mail_triage_notify:" <> user_id],
        quiet_opts()
      )

      earlier =
        from(i in Item,
          where: i.user_id == ^user_id and i.notified_at >= ^day_start,
          select: count(i.id)
        )
        |> Repo.one()

      case from(i in Item, where: i.id == ^id and is_nil(i.notified_at) and i.tier == "top")
           |> Repo.update_all([set: [notified_at: now, updated_at: now]], quiet_opts()) do
        {1, _} -> {:claimed, earlier}
        _ -> Repo.rollback(:already_notified)
      end
    end)
  end

  defp deliver_notification(user, item, earlier, now) do
    mailbox =
      Repo.one(from(a in Account, where: a.id == ^item.account_id, select: a.name)) ||
        "your mailbox"

    # The item's own briefing date, and a briefing row for it, so the link
    # renders the item even when no briefing was delivered that day yet.
    date = briefing_date(item.inserted_at || now)
    ensure_briefing_row(user.id, date)
    url = Platform.Inbox.briefing_url(date)
    title = "An email needs you"
    body = "In #{mailbox}. Open the briefing to see why."

    _ =
      Platform.Inbox.emit(%{
        user_id: user.id,
        kind: "mail_priority",
        source_type: "mail_triage_item",
        source_id: item.id,
        title: title,
        body: body,
        url: url
      })

    pushed? =
      earlier < @push_cap_per_day and Platform.Accounts.notification_level(user) != "direct"

    if pushed?, do: push(user.id, %{title: title, body: body, url: url})

    Platform.Mail.Triage.Metrics.emit(item, "notified")

    Logger.info(
      "[Mail.Triage] notified item=#{item.id} user=#{user.id} push=#{pushed?} earlier_today=#{earlier}"
    )

    {:ok, if(pushed?, do: :notified, else: :row_only)}
  end

  defp ensure_briefing_row(user_id, date) do
    %Platform.Memory.Briefing{}
    |> Platform.Memory.Briefing.changeset(%{user_id: user_id, digest_date: date, items: %{}})
    |> Repo.insert(on_conflict: :nothing)

    :ok
  end

  defp push(user_id, payload) do
    notifications = Application.get_env(:platform, :notifications_module, Platform.Notifications)
    notifications.fan_out_to_user(user_id, payload)
  rescue
    e -> Logger.warning("[Mail.Triage] push raised: #{inspect(e.__struct__)}")
  end

  # ── Feedback ────────────────────────────────────────────────────────────

  @doc """
  Record `user`'s verdict (`"not_important"` or `"missed"`) on a triage
  item or an inbound message (struct or id). The reader must be able to
  read the mailbox NOW; an item must be their own. `"not_important"`
  dismisses the reader's item for that email; `"missed"` raises its tier to
  at least `action`. Both are stored in `mail_triage_feedback` against the
  sender's domain and used by the next run (`Context` priors and the
  pre-filter).

  Returns `{:ok, %Feedback{}}`, `{:error, :not_found}` (no such item or
  inbound, or not the reader's to give feedback on), or
  `{:error, :invalid_verdict}`.
  """
  @spec record_feedback(map(), Item.t() | InboundMessage.t() | binary(), String.t()) ::
          {:ok, Feedback.t()} | {:error, atom()}
  def record_feedback(user, target, verdict)

  def record_feedback(_user, _target, verdict) when verdict not in ["not_important", "missed"],
    do: {:error, :invalid_verdict}

  def record_feedback(%{id: user_id} = user, %Item{id: item_id}, verdict)
      when is_binary(user_id) do
    with true <- Platform.UUID.valid?(item_id) and Platform.UUID.valid?(user_id),
         %Item{} = item <-
           Repo.one(
             from(i in Item, where: i.id == ^item_id and i.user_id == ^user_id),
             quiet_opts()
           ),
         %InboundMessage{} = inbound <- readable_inbound(user, item.inbound_message_id) do
      write_feedback(user, inbound, item, verdict)
    else
      _ -> {:error, :not_found}
    end
  end

  def record_feedback(user, %InboundMessage{id: id}, verdict),
    do: record_feedback(user, id, verdict)

  def record_feedback(%{id: user_id} = user, inbound_id, verdict)
      when is_binary(user_id) and is_binary(inbound_id) do
    with true <- Platform.UUID.valid?(inbound_id) and Platform.UUID.valid?(user_id),
         %InboundMessage{} = inbound <- readable_inbound(user, inbound_id) do
      write_feedback(user, inbound, get_item(user_id, inbound.id), verdict)
    else
      _ -> {:error, :not_found}
    end
  end

  def record_feedback(_user, _target, _verdict), do: {:error, :not_found}

  # The inbound's sender, account and org, ONLY if the reader may read its
  # mailbox now. Selects no subject or body.
  defp readable_inbound(user, inbound_id) do
    with %{org_id: org_id} <-
           Repo.one(
             from(m in InboundMessage, where: m.id == ^inbound_id, select: %{org_id: m.org_id})
           ) do
      readable = Ownership.readable_account_ids_query(user, org_id)

      from(m in InboundMessage,
        where: m.id == ^inbound_id and m.account_id in subquery(readable),
        select: struct(m, [:id, :org_id, :account_id, :from_address])
      )
      |> Repo.one()
    end
  end

  defp write_feedback(user, inbound, item, verdict) do
    address = Context.address(inbound.from_address)
    domain = Context.domain(address)

    if is_nil(domain) do
      {:error, :not_found}
    else
      Repo.transaction(fn ->
        feedback =
          %{
            org_id: inbound.org_id,
            user_id: user.id,
            account_id: inbound.account_id,
            inbound_message_id: inbound.id,
            sender_address: address,
            sender_domain: domain,
            verdict: verdict
          }
          |> Feedback.changeset()
          |> Repo.insert!(quiet_opts())

        if item, do: apply_verdict(item, verdict)

        Logger.info(
          "[Mail.Triage] feedback inbound=#{inbound.id} user=#{user.id} verdict=#{verdict}"
        )

        feedback
      end)
    end
  end

  defp apply_verdict(item, "not_important") do
    updated =
      item |> Item.update_changeset(%{status: "dismissed"}) |> Repo.update!(quiet_opts())

    Platform.Mail.Triage.Metrics.emit(updated, "dismissed")
    updated
  end

  defp apply_verdict(item, "missed") do
    item
    |> Item.update_changeset(%{tier: Classifier.at_least(item.tier, "action")})
    |> Repo.update!(quiet_opts())
  end
end
