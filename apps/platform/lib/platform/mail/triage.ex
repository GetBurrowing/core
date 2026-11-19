defmodule Platform.Mail.Triage do
  @moduledoc """
  Mail triage for the morning briefing (task 01a1f426 stage 1, Level 1
  backend): for one reader, which of today's emails need something from
  them, and one line on why.

  `Platform.Mail.Digest` stays what it is (metadata only, the admin
  cross-mailbox view). This module reads bodies, so its permission rule is
  narrower and is applied in every query it makes.

  ## Which mailboxes a reader's triage covers

  `eligible_account_ids/3`: the non-archived accounts of the org that the
  reader may read (`Ownership.readable_account_ids_query/2`: personal ones
  they own, shared ones they hold a grant on) INTERSECTED with the accounts
  granted to the triage agent (`Ownership.agent_granted_account_ids_query/2`).
  Both are subqueries of the one account query. An agent uses only mail it
  has been granted, and a reader sees triage only of mail they may read.
  Org admin status confers nothing here, and `digest_opt_in` (which governs
  the cross-mailbox Digest only) is not consulted.

  The triage agent is `Platform.Roles.assignee_for("mail.triage")`
  (`Platform.Responsibilities.Handlers.MailTriage` registers the key). No
  assignee means nothing is classified and `run_for_reader/2` says so.

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
  `run_for_reader/2` only ever selects inbound with no item for that reader,
  and `classify_for_reader/2` returns the existing item. A provider failure
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

  @doc "The responsibility key whose assignee does the triage."
  @spec responsibility_key() :: String.t()
  def responsibility_key, do: @responsibility_key

  @doc """
  `Repo` options for a write that carries model output or mail-derived
  text: no query log line, no `[:platform, :repo, :query]` telemetry event.
  """
  @spec quiet_opts() :: keyword()
  def quiet_opts, do: [log: false, telemetry_event: nil]

  @doc "The agent assigned to `mail.triage`, or nil."
  @spec triage_agent() :: Agent.t() | nil
  def triage_agent do
    Platform.Roles.assignee_for(@responsibility_key)
  rescue
    _ -> nil
  end

  # ── Permission ──────────────────────────────────────────────────────────

  @doc """
  Ids of the accounts of `org_id` this reader's triage covers, with `agent`
  (an `%Agent{}` or an agent id) as the triage agent. See the moduledoc.
  `[]` for a nil agent or a malformed id.
  """
  @spec eligible_account_ids(any(), any(), Agent.t() | binary() | nil) :: [binary()]
  def eligible_account_ids(user, org_id, agent) do
    user |> eligible_accounts_query(org_id, agent) |> Repo.all()
  end

  @doc "`eligible_account_ids/3` as a query selecting account ids."
  @spec eligible_accounts_query(any(), any(), Agent.t() | binary() | nil) :: Ecto.Query.t()
  def eligible_accounts_query(user, org_id, %Agent{id: agent_id}),
    do: eligible_accounts_query(user, org_id, agent_id)

  def eligible_accounts_query(user, org_id, agent_id) when is_binary(agent_id) do
    if Platform.UUID.valid?(org_id) and Platform.UUID.valid?(agent_id) do
      readable = Ownership.readable_account_ids_query(user, org_id)
      granted = Ownership.agent_granted_account_ids_query(agent_id, org_id)

      from(a in Account,
        where: a.org_id == ^org_id and is_nil(a.archived_at),
        where: a.id in subquery(readable),
        where: a.id in subquery(granted),
        select: a.id
      )
    else
      none_query()
    end
  end

  def eligible_accounts_query(_user, _org_id, _agent), do: none_query()

  defp none_query, do: from(a in Account, where: false, select: a.id)

  # ── Classify ────────────────────────────────────────────────────────────

  @doc """
  Triage `inbound` for `user`. Returns `{:ok, item}` (new or existing),
  `{:error, :no_triage_agent}`, `{:error, :not_eligible}` (the mailbox is
  not readable by the reader AND granted to the agent: no provider call, no
  write) or `{:error, :provider_failed}` (nothing stored).

  Options: `:agent` (the triage agent, default `triage_agent/0`), `:roster`
  (a pre-read People roster), `:now`.
  """
  @spec classify_for_reader(map(), InboundMessage.t(), keyword()) ::
          {:ok, Item.t()} | {:error, atom()}
  def classify_for_reader(user, inbound, opts \\ [])

  def classify_for_reader(%{id: user_id} = user, %InboundMessage{} = inbound, opts)
      when is_binary(user_id) do
    case Keyword.get_lazy(opts, :agent, &triage_agent/0) do
      %Agent{} = agent ->
        cond do
          not eligible_inbound?(user, inbound, agent) ->
            {:error, :not_eligible}

          item = get_item(user_id, inbound.id) ->
            {:ok, item}

          true ->
            do_classify(user, inbound, agent, opts)
        end

      _ ->
        {:error, :no_triage_agent}
    end
  end

  def classify_for_reader(_user, _inbound, _opts), do: {:error, :not_eligible}

  defp eligible_inbound?(user, %InboundMessage{id: id, org_id: org_id}, agent) do
    eligible = eligible_accounts_query(user, org_id, agent)

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
    |> Repo.one()
  end

  # ── Run ─────────────────────────────────────────────────────────────────

  @doc """
  Triage every eligible email received on `date` (UTC) that has no item
  for `user` yet, across every org the reader is an internal member of.
  Backfilled imports (`ingest_source == "backfill"`) are skipped. At most
  `:max_model_calls` (default #{@default_max_model_calls}) provider calls
  per run; the rest wait for the next run.

  Returns `{:ok, summary}` with `:status` (`:ok` or `:no_triage_agent`),
  `:classified`, `:model_calls`, `:failed` and `:deferred` counts.

  Options: `:since` / `:until` (DateTimes replacing the date's bounds),
  `:max_model_calls`, `:agent`, `:now`.
  """
  @spec run_for_reader(map(), Date.t(), keyword()) :: {:ok, map()}
  def run_for_reader(user, date, opts \\ [])

  def run_for_reader(%{id: user_id} = user, %Date{} = date, opts) when is_binary(user_id) do
    empty = %{status: :ok, classified: 0, model_calls: 0, failed: 0, deferred: 0}

    case Keyword.get_lazy(opts, :agent, &triage_agent/0) do
      %Agent{} = agent ->
        {from, to} = window(date, opts)
        max_calls = Keyword.get(opts, :max_model_calls, @default_max_model_calls)
        roster = Context.roster()

        summary =
          user
          |> org_ids()
          |> Enum.flat_map(&candidates(user, &1, agent, from, to))
          |> Enum.reduce(empty, fn inbound, acc ->
            if acc.model_calls >= max_calls and needs_model?(user, inbound) do
              %{acc | deferred: acc.deferred + 1}
            else
              run_one(user, inbound, agent, roster, opts, acc)
            end
          end)

        {:ok, summary}

      _ ->
        {:ok, %{empty | status: :no_triage_agent}}
    end
  end

  def run_for_reader(_user, _date, _opts),
    do: {:ok, %{status: :ok, classified: 0, model_calls: 0, failed: 0, deferred: 0}}

  defp run_one(user, inbound, agent, roster, opts, acc) do
    result =
      classify_for_reader(user, inbound,
        agent: agent,
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
    {:ok, start} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    finish = DateTime.add(start, 86_400, :second)
    {Keyword.get(opts, :since, start), Keyword.get(opts, :until, finish)}
  end

  defp candidates(%{id: user_id} = user, org_id, agent, from, to) do
    eligible = eligible_accounts_query(user, org_id, agent)

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
    |> Repo.all()
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
  (UTC), most important first, then newest. Only items whose mailbox is
  STILL eligible now (readable by the reader and granted to the triage
  agent): a revoked grant hides its items at once. `[]` with no triage
  agent. Preloads `:inbound_message` and `:account`.

  Options: `:agent`, `:tiers` (default `["top", "action"]`).
  """
  @spec called_out(map(), Date.t(), keyword()) :: [Item.t()]
  def called_out(user, date, opts \\ [])

  def called_out(%{id: user_id} = user, %Date{} = date, opts) when is_binary(user_id) do
    case Keyword.get_lazy(opts, :agent, &triage_agent/0) do
      %Agent{} = agent ->
        {from, to} = window(date, [])
        tiers = Keyword.get(opts, :tiers, @called_out_tiers)

        user
        |> org_ids()
        |> Enum.flat_map(fn org_id ->
          eligible = eligible_accounts_query(user, org_id, agent)

          from(i in Item,
            where: i.user_id == ^user_id and i.org_id == ^org_id,
            where: i.account_id in subquery(eligible),
            where: i.tier in ^tiers,
            where: i.inserted_at >= ^from and i.inserted_at < ^to
          )
          |> Repo.all()
        end)
        |> Enum.sort_by(fn i ->
          {tier_rank(i.tier), -DateTime.to_unix(i.inserted_at, :microsecond)}
        end)
        |> Repo.preload([:inbound_message, :account])

      _ ->
        []
    end
  end

  def called_out(_user, _date, _opts), do: []

  defp tier_rank(tier), do: Enum.find_index(Item.tiers(), &(&1 == tier)) || 99

  # ── Briefing surface (task 01a1f426 stage 2) ────────────────────────────

  @doc """
  What the briefing's `mail_priority` section shows `user` for `date`: a
  pure read. Returns

    * `:agent` — the triage agent, or nil (the section says no agent is
      assigned);
    * `:readable?` — whether the reader may read any non-archived mailbox
      (no mailbox at all means the section is absent);
    * `:called_out` — the reader's `top` / `action` items of `date` whose
      mailbox is still eligible: open ones first, then by tier, then newest
      received;
    * `:others` — the reader's `routine` / `promo` items of `date`, same rule;
    * `:ungranted` — `%{id, name}` of the mailboxes the reader may read that
      are NOT granted to the triage agent (metadata only: the name).

  Each row is a plain map of display fields only (`id`, `inbound_id`,
  `account_id`, `tier`, `status`, `why`, `from`, `subject`, `mailbox`,
  `received_at`). The body is never selected.

  Options: `:agent` (default `triage_agent/0`).
  """
  @spec section_view(map(), Date.t(), keyword()) :: map()
  def section_view(user, date, opts \\ [])

  def section_view(%{id: user_id} = user, %Date{} = date, opts) when is_binary(user_id) do
    agent = Keyword.get_lazy(opts, :agent, &triage_agent/0)
    orgs = org_ids(user)

    readable =
      Enum.flat_map(orgs, fn org_id ->
        readable = Ownership.readable_account_ids_query(user, org_id)

        from(a in Account,
          where: a.org_id == ^org_id and is_nil(a.archived_at) and a.id in subquery(readable),
          order_by: [asc: a.name],
          select: %{id: a.id, org_id: a.org_id, name: a.name}
        )
        |> Repo.all()
      end)

    eligible =
      case agent do
        %Agent{} ->
          orgs |> Enum.flat_map(&eligible_account_ids(user, &1, agent)) |> MapSet.new()

        _ ->
          MapSet.new()
      end

    rows = if MapSet.size(eligible) > 0, do: section_rows(user_id, date, eligible), else: []
    {called_out, others} = Enum.split_with(rows, &(&1.tier in @called_out_tiers))

    %{
      agent: if(match?(%Agent{}, agent), do: agent),
      readable?: readable != [],
      called_out: called_out,
      others: others,
      ungranted:
        readable
        |> Enum.reject(&MapSet.member?(eligible, &1.id))
        |> Enum.map(&Map.take(&1, [:id, :name]))
    }
  end

  def section_view(_user, _date, _opts),
    do: %{agent: nil, readable?: false, called_out: [], others: [], ungranted: []}

  defp section_rows(user_id, date, eligible) do
    {from, to} = window(date, [])
    eligible = MapSet.to_list(eligible)

    from(i in Item,
      join: m in InboundMessage,
      on: m.id == i.inbound_message_id,
      join: a in Account,
      on: a.id == i.account_id,
      where: i.user_id == ^user_id and i.account_id in ^eligible,
      where: i.inserted_at >= ^from and i.inserted_at < ^to,
      select: %{
        id: i.id,
        inbound_id: i.inbound_message_id,
        account_id: i.account_id,
        tier: i.tier,
        status: i.status,
        why: i.why,
        inserted_at: i.inserted_at,
        from: m.from_address,
        subject: m.subject,
        received_at: coalesce(m.received_at, m.inserted_at),
        mailbox: a.name
      }
    )
    |> Repo.all(quiet_opts())
    |> Enum.sort_by(fn row ->
      {row.status != "open", tier_rank(row.tier),
       -DateTime.to_unix(row.received_at, :microsecond)}
    end)
  end

  @doc """
  The reader's OWN item `item_id`, whatever its mailbox's eligibility now
  (the caller decides that with `eligible?/3`). nil for a malformed id, an
  unknown one, or another reader's item.
  """
  @spec reader_item(map(), any()) :: Item.t() | nil
  def reader_item(%{id: user_id}, item_id) when is_binary(user_id) and is_binary(item_id) do
    if Platform.UUID.valid?(item_id) and Platform.UUID.valid?(user_id) do
      Repo.one(from(i in Item, where: i.id == ^item_id and i.user_id == ^user_id))
    end
  end

  def reader_item(_user, _item_id), do: nil

  @doc """
  Is the mailbox of `target` (an item or an inbound message: anything with
  `org_id` and `account_id`) eligible for `user` NOW, with `agent` as the
  triage agent: readable by the reader AND granted to the agent
  (`eligible_account_ids/3`). False with no agent.
  """
  @spec eligible?(map(), map(), Agent.t() | nil) :: boolean()
  def eligible?(user, %{org_id: org_id, account_id: account_id}, agent)
      when is_binary(account_id) do
    account_id in eligible_account_ids(user, org_id, agent)
  end

  def eligible?(_user, _target, _agent), do: false

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
  A newly ingested email `inbound_id`, triaged for every reader of its
  mailbox for whom the mailbox is eligible (`eligible?/3`: readable by them
  AND granted to the triage agent), and a `top` result notified at once
  (`notify_top/2`), and a called-out one handed to
  `Platform.Mail.Triage.Drafter` (a draft reply or a plan, never a send).
  Driven by `Platform.Mail.Triage.Subscriber`.

  A backfilled import (`ingest_source == "backfill"`) is skipped: a quiet
  import must not page anyone. Calls no send path. Returns `:ok`.

  Options: `:agent` (default `triage_agent/0`), `:now`.
  """
  @spec on_inbound(binary(), keyword()) :: :ok
  def on_inbound(inbound_id, opts \\ []) when is_binary(inbound_id) do
    with true <- Platform.UUID.valid?(inbound_id),
         %Agent{} = agent <- Keyword.get_lazy(opts, :agent, &triage_agent/0),
         %InboundMessage{ingest_source: source} = inbound when source != "backfill" <-
           Repo.get(InboundMessage, inbound_id) do
      for user <- reader_candidates(inbound.account_id) do
        triage_and_notify(user, inbound, agent, opts)
      end
    end

    :ok
  end

  @doc """
  The start-up pass of `Platform.Mail.Triage.Subscriber`: every live
  (non-backfill) email of the last 24 hours that has no item yet for some
  reader of its mailbox goes through `on_inbound/2`. At most
  #{@candidate_cap} emails per pass. Returns the number of emails visited.
  """
  @spec reconcile(keyword()) :: non_neg_integer()
  def reconcile(opts \\ []) do
    case Keyword.get_lazy(opts, :agent, &triage_agent/0) do
      %Agent{} = agent ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        since = DateTime.add(now, -86_400, :second)

        ids =
          from(m in InboundMessage,
            join: a in Account,
            on: a.id == m.account_id and is_nil(a.archived_at),
            where: m.ingest_source != "backfill",
            where: coalesce(m.received_at, m.inserted_at) >= ^since,
            order_by: [asc: m.inserted_at, asc: m.id],
            limit: @candidate_cap,
            select: m.id
          )
          |> Repo.all()

        Enum.each(ids, &on_inbound(&1, Keyword.put(opts, :agent, agent)))
        length(ids)

      _ ->
        0
    end
  end

  # The people who may read an account by its ownership: the owner of a
  # personal one, the user-grant holders of a shared one. A CANDIDATE list
  # only: `classify_for_reader/3` decides eligibility for each (readable
  # AND granted to the agent), so this list is never the permission.
  defp reader_candidates(account_id) do
    owner =
      from(a in Account,
        where: a.id == ^account_id and a.owner_kind == "personal",
        where: not is_nil(a.owner_user_id),
        select: a.owner_user_id
      )

    members =
      from(g in Platform.Mail.AccountGrant,
        join: a in Account,
        on: a.id == g.account_id and a.owner_kind == "shared",
        where: g.account_id == ^account_id and g.principal_type == "user",
        select: g.principal_id
      )

    ids = Repo.all(owner) ++ Repo.all(members)

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

    case classify_for_reader(user, inbound, agent: agent, now: now) do
      {:ok, %Item{} = item} ->
        if item.tier == "top", do: notify_top(item, Keyword.put(opts, :agent, agent))
        if Drafter.draftable?(item), do: Drafter.draft(user, item, agent: agent, now: now)
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
  mailbox must still be eligible for the reader now.

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
    agent = Keyword.get_lazy(opts, :agent, &triage_agent/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    user = Repo.get(Platform.Accounts.User, item.user_id)

    with %Platform.Accounts.User{} <- user,
         true <- eligible?(user, item, agent),
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

    url = Platform.Inbox.briefing_url(DateTime.to_date(item.inserted_at || now))
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
           Repo.one(from(i in Item, where: i.id == ^item_id and i.user_id == ^user_id)),
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
