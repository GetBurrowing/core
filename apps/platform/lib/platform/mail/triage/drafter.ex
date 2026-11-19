defmodule Platform.Mail.Triage.Drafter do
  @moduledoc """
  The work started for a called-out email (task 01a1f426 stage 4, Level 2
  backend): a first DRAFT of the reply, or a short fulfilment PLAN, for the
  reader to find in their briefing. Drafts only: nothing here sends, and
  no task is created.

  ## Which items

  A reader's own `top` / `action` item whose `needs` is reply, decision or
  plan, that the drafter has not taken yet (`drafted_at`, `draft_id` and
  `plan_steps` all nil), whose mailbox is eligible for the reader NOW
  (`Platform.Mail.Triage.eligible?/3`: readable by the reader AND granted
  to the triage agent). An ineligible mailbox costs no provider call and
  writes nothing. At most 15 items are taken per reader per UTC day
  (`daily_cap/0`); the claim and the count are one step under a per-reader
  advisory lock, so concurrent runs cannot overshoot.

  ## The injection boundary

  The same as `Platform.Mail.Triage.Classifier`: ONE tool-less
  `Platform.Agents.ToollessChat.call/4`, system prompt
  `mail.triage.draft.v1`. The user message holds the reader-visible context
  as JSON (the waiting-on flag, the relation keyword, and the TITLES of the
  reader's own open tasks and recent meetings that involve the sender, read
  by `Platform.Mail.Triage.Context` through the public Tasks and Meetings
  functions), then up to 3 earlier inbound and 3 earlier accepted
  outbound emails with that sender IN THAT MAILBOX ONLY, then the email
  itself. Every email is inside `Platform.Security.ExternalContent.wrap/2`,
  capped; the assembled message goes through `escape_mentions/1`.

  ## The closed output

  Exactly `{"kind": "reply", "subject", "body"}` or
  `{"kind": "plan", "summary", "steps"}` (1 to 8 non-empty strings).
  Anything else is rejected and stores no model text; the item stays taken
  (`drafted_at`), so a rejected answer is not paid for again. A provider
  failure releases the claim and stores nothing, so the next run retries.

    * reply — `Platform.Mail.Drafts.create({:agent, triage_agent_id}, ...)`,
      the agent path whose own scope refuses an account not GRANTED to the
      agent or not readable by the on-behalf reader. Sender: a sender of
      that account from `Drafts.sendable_senders(reader, org_id)` (the one
      the email was addressed to, else the first); none means no draft.
      To: the email's sender. Subject: `Re: <the email's subject>` (the
      model's `subject` is checked for shape but not used, so the draft
      always says truthfully what it answers). `in_reply_to_inbound_id`
      links the draft to the email, so the send threads. The item stores
      `draft_id` and `draft_original_body` (stage 5's edit ratio).
    * plan — `plan_summary` and `plan_steps` on the item. No task is made.

  ## What leaves the mailbox

  Nothing of the mail or of the model's text. Every read that takes the
  sender's address and every write carrying a body, a plan or a draft uses
  `Platform.Mail.Triage.quiet_opts/0` (no Ecto `:debug` line, no
  `[:platform, :repo, :query]` event), including the `Drafts.create/4`
  insert. Logger lines carry ids and outcome codes; the
  `[:platform, :mail, :triage, :drafted]` event carries ids, the kind and
  the outcome.

  ## Test seam

  `:mail_triage_provider`, shared with the classifier.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Agents.ToollessChat
  alias Platform.Mail.Drafts
  alias Platform.Mail.InboundMessage
  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.{Classifier, Context, Item}
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Security.ExternalContent

  @template_slug "mail.triage.draft.v1"
  @draft_tiers ~w(top action)
  @draft_needs ~w(reply decision plan)
  @daily_cap 15
  @history_per_side 3
  @history_body_cap 2_000
  @reply_body_cap 20_000
  @max_tokens 1_024
  @reply_keys ~w(body kind subject)
  @plan_keys ~w(kind steps summary)

  @type outcome ::
          {:ok, :reply | :plan, Item.t()}
          | {:skipped, atom()}
          | {:error, atom() | {:draft_refused, atom()}}

  @doc "The prompt template slug the system message is rendered from."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "At most this many items are drafted per reader per UTC day."
  @spec daily_cap() :: pos_integer()
  def daily_cap, do: @daily_cap

  @doc "Is `item` one the drafter would take (ignoring eligibility and the cap)?"
  @spec draftable?(Item.t()) :: boolean()
  def draftable?(%Item{} = item) do
    item.tier in @draft_tiers and item.needs in @draft_needs and is_nil(item.drafted_at) and
      is_nil(item.draft_id) and is_nil(item.plan_steps)
  end

  def draftable?(_item), do: false

  # ── Run ─────────────────────────────────────────────────────────────────

  @doc """
  Draft every draftable item of `user` created on `date` (UTC) whose
  mailbox is eligible now, until the daily cap. Returns `{:ok, summary}`
  with `:replies`, `:plans`, `:skipped`, `:failed` and `:capped` counts.

  Options: `:agent` (default `Triage.triage_agent/0`), `:since` / `:until`
  (DateTimes replacing the date's bounds), `:now`.
  """
  @spec run_for_reader(map(), Date.t(), keyword()) :: {:ok, map()}
  def run_for_reader(user, date, opts \\ [])

  def run_for_reader(%{id: user_id} = user, %Date{} = date, opts) when is_binary(user_id) do
    empty = %{replies: 0, plans: 0, skipped: 0, failed: 0, capped: 0}

    case Keyword.get_lazy(opts, :agent, &Triage.triage_agent/0) do
      %Agent{} = agent ->
        {:ok, start} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
        from = Keyword.get(opts, :since, start)
        to = Keyword.get(opts, :until, DateTime.add(start, 86_400, :second))
        opts = Keyword.put(opts, :agent, agent)

        summary =
          user
          |> candidates(agent, from, to)
          |> Enum.reduce_while(empty, fn item, acc ->
            case draft(user, item, opts) do
              {:ok, :reply, _} -> {:cont, %{acc | replies: acc.replies + 1}}
              {:ok, :plan, _} -> {:cont, %{acc | plans: acc.plans + 1}}
              {:skipped, :daily_cap} -> {:halt, %{acc | capped: acc.capped + 1}}
              {:skipped, _} -> {:cont, %{acc | skipped: acc.skipped + 1}}
              {:error, _} -> {:cont, %{acc | failed: acc.failed + 1}}
            end
          end)

        {:ok, summary}

      _ ->
        {:ok, empty}
    end
  end

  def run_for_reader(_user, _date, _opts),
    do: {:ok, %{replies: 0, plans: 0, skipped: 0, failed: 0, capped: 0}}

  defp candidates(%{id: user_id} = user, agent, from, to) do
    user
    |> Platform.Tenancy.list_user_memberships()
    |> Enum.reject(&(&1.external or is_nil(&1.org) or Map.get(&1.org, :archived_at)))
    |> Enum.map(& &1.org_id)
    |> Enum.uniq()
    |> Enum.flat_map(fn org_id ->
      eligible = Triage.eligible_accounts_query(user, org_id, agent)

      from(i in Item,
        where: i.user_id == ^user_id and i.org_id == ^org_id,
        where: i.account_id in subquery(eligible),
        where: i.tier in @draft_tiers and i.needs in @draft_needs,
        where: is_nil(i.drafted_at) and is_nil(i.draft_id) and is_nil(i.plan_steps),
        where: i.inserted_at >= ^from and i.inserted_at < ^to,
        order_by: [asc: i.inserted_at, asc: i.id]
      )
      |> Repo.all()
    end)
    |> Enum.sort_by(&{tier_rank(&1.tier), DateTime.to_unix(&1.inserted_at, :microsecond)})
  end

  defp tier_rank("top"), do: 0
  defp tier_rank(_), do: 1

  # ── One item ────────────────────────────────────────────────────────────

  @doc """
  Draft `item` for `user` (see the moduledoc). Returns `{:ok, :reply,
  item}`, `{:ok, :plan, item}`, `{:skipped, reason}` (`:no_triage_agent`,
  `:not_draftable`, `:not_eligible`, `:no_sender`, `:daily_cap`,
  `:already_drafted`) or `{:error, reason}` (`:provider_failed`,
  `:rejected_output`, `{:draft_refused, reason}`).

  Options: `:agent`, `:now`.
  """
  @spec draft(map(), Item.t(), keyword()) :: outcome()
  def draft(user, item, opts \\ [])

  def draft(%{id: user_id} = user, %Item{user_id: user_id} = item, opts)
      when is_binary(user_id) do
    agent = Keyword.get_lazy(opts, :agent, &Triage.triage_agent/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    result =
      with {:agent, %Agent{}} <- {:agent, agent},
           {:draftable, true} <- {:draftable, draftable?(item)},
           {:eligible, true} <- {:eligible, Triage.eligible?(user, item, agent)},
           %InboundMessage{} = inbound <- Repo.get(InboundMessage, item.inbound_message_id),
           {:sender, sender} when sender != :none or item.needs != "reply" <-
             {:sender, pick_sender(user, inbound)},
           :claimed <- claim(item, now) do
        run_model(user, item, inbound, agent, sender, now)
      else
        {:agent, _} -> {:skipped, :no_triage_agent}
        {:draftable, false} -> {:skipped, :not_draftable}
        {:eligible, false} -> {:skipped, :not_eligible}
        {:sender, :none} -> {:skipped, :no_sender}
        {:skipped, _} = skipped -> skipped
        nil -> {:skipped, :not_eligible}
      end

    emit(item, result)
    result
  end

  def draft(_user, _item, _opts), do: {:skipped, :not_eligible}

  defp run_model(user, item, inbound, agent, sender, now) do
    ctx = Context.build(user, inbound, now: now)
    history = thread_history(inbound, ctx.address)
    messages = build_messages(inbound, ctx, history)

    case ToollessChat.call(provider_module(), agent, messages,
           temperature: 0.2,
           max_tokens: @max_tokens,
           log_tag: "[Mail.Triage.Drafter]",
           log_context: "item=#{item.id}"
         ) do
      {:ok, content} ->
        case parse(content) do
          {:ok, %{kind: "plan"} = plan} ->
            store_plan(item, plan)

          {:ok, %{kind: "reply"} = reply} ->
            store_reply(user, item, inbound, agent, sender, ctx, reply)

          {:rejected, defect} ->
            Logger.warning(
              "[Mail.Triage.Drafter] rejected_output item=#{item.id} defect=#{inspect(defect)}"
            )

            {:error, :rejected_output}
        end

      :error ->
        release(item)
        {:error, :provider_failed}
    end
  end

  defp store_plan(item, plan) do
    item
    |> fresh()
    |> Item.drafter_changeset(%{plan_summary: plan.summary, plan_steps: plan.steps})
    |> Repo.update(Triage.quiet_opts())
    |> case do
      {:ok, updated} -> {:ok, :plan, updated}
      {:error, _} -> {:error, :not_stored}
    end
  end

  defp store_reply(_user, _item, _inbound, _agent, :none, _ctx, _reply),
    do: {:skipped, :no_sender}

  defp store_reply(_user, _item, _inbound, _agent, _sender, %{address: nil}, _reply),
    do: {:skipped, :no_sender}

  defp store_reply(user, item, inbound, agent, {account, sender}, ctx, reply) do
    attrs = %{
      account_id: account.id,
      sender_key: sender.key,
      to_addresses: [ctx.address],
      subject: reply_subject(inbound.subject),
      body: reply.body,
      on_behalf_of_user_id: user.id,
      responsibility: Triage.responsibility_key(),
      in_reply_to_inbound_id: inbound.id
    }

    case Drafts.create({:agent, agent.id}, inbound.org_id, attrs, Triage.quiet_opts()) do
      {:ok, draft} ->
        item
        |> fresh()
        |> Item.drafter_changeset(%{draft_id: draft.id, draft_original_body: draft.body})
        |> Repo.update(Triage.quiet_opts())
        |> case do
          {:ok, updated} -> {:ok, :reply, updated}
          {:error, _} -> {:error, :not_stored}
        end

      {:error, reason} ->
        Logger.warning(
          "[Mail.Triage.Drafter] draft_refused item=#{item.id} reason=#{refusal_code(reason)}"
        )

        {:error, {:draft_refused, refusal_code(reason)}}
    end
  end

  defp refusal_code(reason) when is_atom(reason), do: reason
  defp refusal_code({code, _detail}) when is_atom(code), do: code
  defp refusal_code(_), do: :invalid

  defp fresh(%Item{id: id}), do: Repo.get!(Item, id)

  # ── The claim (dedupe + daily cap) ──────────────────────────────────────

  # Set `drafted_at` iff it is still nil, and only while fewer than the
  # daily cap of the reader's items were taken that UTC day, under a
  # per-reader transaction lock so the count and the claim are one step.
  defp claim(%Item{id: id, user_id: user_id}, now) do
    {:ok, day_start} = DateTime.new(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")

    Repo.transaction(fn ->
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        ["mail_triage_draft:" <> user_id],
        Triage.quiet_opts()
      )

      taken =
        from(i in Item,
          where: i.user_id == ^user_id and i.drafted_at >= ^day_start,
          select: count(i.id)
        )
        |> Repo.one()

      if taken >= @daily_cap, do: Repo.rollback(:daily_cap)

      case from(i in Item,
             where: i.id == ^id and is_nil(i.drafted_at) and is_nil(i.draft_id),
             where: is_nil(i.plan_steps)
           )
           |> Repo.update_all([set: [drafted_at: now, updated_at: now]], Triage.quiet_opts()) do
        {1, _} -> :claimed
        _ -> Repo.rollback(:already_drafted)
      end
    end)
    |> case do
      {:ok, :claimed} -> :claimed
      {:error, reason} -> {:skipped, reason}
    end
  end

  # A provider failure gives the item back, so the next run retries it.
  defp release(%Item{id: id}) do
    from(i in Item,
      where: i.id == ^id and is_nil(i.draft_id) and is_nil(i.plan_steps)
    )
    |> Repo.update_all([set: [drafted_at: nil]], Triage.quiet_opts())
  end

  # ── Sender ──────────────────────────────────────────────────────────────

  # `{account, sender}` of the email's OWN account that the reader may send
  # from: the sender the email was addressed to, else the first. `:none`.
  defp pick_sender(user, %InboundMessage{} = inbound) do
    senders =
      user
      |> Drafts.sendable_senders(inbound.org_id)
      |> Enum.filter(fn {account, _sender} -> account.id == inbound.account_id end)

    addressed = MapSet.new(inbound.to_addresses || [], &(Context.address(&1) || ""))

    Enum.find(senders, fn {_account, sender} ->
      MapSet.member?(addressed, String.downcase(sender.address || ""))
    end) || List.first(senders) || :none
  end

  defp reply_subject(subject) when is_binary(subject) do
    line = subject |> ExternalContent.sanitize_line() |> String.trim()

    cond do
      line == "" -> "Re: your email"
      String.match?(line, ~r/\Are:/i) -> line
      true -> "Re: " <> line
    end
  end

  defp reply_subject(_), do: "Re: your email"

  # ── Thread history (THIS mailbox only) ──────────────────────────────────

  @norm_to "btrim(lower(coalesce(substring(r.addr FROM '<([^<>]+)>'), r.addr)))"
  @norm_from "btrim(lower(coalesce(substring(m.from_address FROM '<([^<>]+)>'), m.from_address)))"

  @history_in_sql """
  SELECT m.from_address, m.subject, m.text_body, coalesce(m.received_at, m.inserted_at)
    FROM mail_inbound_messages m
   WHERE m.account_id = $1 AND m.id <> $3 AND #{@norm_from} = $2
     AND coalesce(m.received_at, m.inserted_at) <= $4
   ORDER BY coalesce(m.received_at, m.inserted_at) DESC
   LIMIT #{@history_per_side}
  """

  @history_out_sql """
  SELECT d.from_address, d.subject, d.body, coalesce(d.accepted_at, d.inserted_at)
    FROM mail_deliveries d
   WHERE d.account_id = $1 AND d.status = 'accepted'
     AND EXISTS (SELECT 1 FROM unnest(d.recipients) AS r(addr) WHERE #{@norm_to} = $2)
     AND coalesce(d.accepted_at, d.inserted_at) <= $3
   ORDER BY coalesce(d.accepted_at, d.inserted_at) DESC
   LIMIT #{@history_per_side}
  """

  @doc """
  Up to #{@history_per_side} earlier inbound emails from `address` and
  #{@history_per_side} accepted outbound emails to it, in `inbound`'s OWN
  account only, oldest first: `[%{direction, from, subject, body, at}]`.
  Read with `quiet_opts/0` (the address is a query parameter).
  """
  @spec thread_history(InboundMessage.t(), String.t() | nil) :: [map()]
  def thread_history(_inbound, nil), do: []

  def thread_history(%InboundMessage{} = inbound, address) when is_binary(address) do
    at = inbound.received_at || inbound.inserted_at || DateTime.utc_now()
    account = Ecto.UUID.dump!(inbound.account_id)
    at = DateTime.to_naive(at)
    quiet = Triage.quiet_opts()

    %{rows: in_rows} =
      Repo.query!(
        @history_in_sql,
        [account, address, Ecto.UUID.dump!(inbound.id), at],
        quiet
      )

    %{rows: out_rows} = Repo.query!(@history_out_sql, [account, address, at], quiet)

    (Enum.map(in_rows, &history_row(:inbound, &1)) ++
       Enum.map(out_rows, &history_row(:outbound, &1)))
    |> Enum.sort_by(& &1.at, NaiveDateTime)
  end

  defp history_row(direction, [from, subject, body, at]) do
    %{direction: direction, from: from, subject: subject, body: body || "", at: at}
  end

  # ── Messages ────────────────────────────────────────────────────────────

  @doc """
  The two messages sent to the provider. Options: `:system`
  (pre-rendered), `:marker_id` (tests only).
  """
  @spec build_messages(InboundMessage.t(), Context.t(), [map()], keyword()) :: [map()]
  def build_messages(%InboundMessage{} = inbound, ctx, history, opts \\ []) do
    system = Keyword.get_lazy(opts, :system, &system_prompt/0)
    marker = Keyword.get(opts, :marker_id)

    earlier =
      case history do
        [] ->
          "(none)"

        rows ->
          Enum.map_join(rows, "\n\n", fn row ->
            label = if row.direction == :inbound, do: "From them:", else: "From this mailbox:"

            label <>
              "\n" <>
              ExternalContent.wrap(
                cap(row.body, @history_body_cap),
                wrap_opts(row.from, row.subject, marker)
              )
          end)
      end

    wrapped =
      ExternalContent.wrap(
        cap(inbound.text_body || "", Platform.Mail.Inbound.body_cap_bytes()),
        wrap_opts(inbound.from_address, inbound.subject, marker)
      )

    user =
      [
        "Context the reader can see (JSON):",
        Jason.encode!(reader_facts(ctx)),
        "",
        "Earlier emails between this mailbox and this sender, oldest first:",
        earlier,
        "",
        "The email to answer:",
        wrapped
      ]
      |> Enum.join("\n")
      |> ExternalContent.escape_mentions()

    [%{role: "system", content: system}, %{role: "user", content: user}]
  end

  defp wrap_opts(sender, subject, marker) do
    opts = [source: :email, sender: sender, subject: subject]
    if marker, do: Keyword.put(opts, :id, marker), else: opts
  end

  # What the reader can see, for THIS reader only: the context was built
  # for them, through the reader-scoped Tasks and Meetings reads.
  defp reader_facts(ctx) do
    %{
      "waiting_on_their_reply" => not is_nil(ctx.waiting_on),
      "relation" => ctx.person && ctx.person.relation,
      "your_open_tasks_involving_them" => Enum.map(ctx.task_titles, &clean_title(&1.title)),
      "your_recent_meetings_with_them" => Enum.map(ctx.meeting_titles, &clean_title(&1.title))
    }
  end

  defp clean_title(title) when is_binary(title),
    do: title |> ExternalContent.sanitize_line() |> String.slice(0, 200)

  defp clean_title(_), do: ""

  # ── Parse ───────────────────────────────────────────────────────────────

  @doc "Parse raw model output against the closed shape. Public for tests."
  @spec parse(any()) :: {:ok, map()} | {:rejected, String.t()}
  def parse(content) when is_binary(content) do
    with {:ok, decoded} <- decode(content) do
      case decoded do
        %{"kind" => "reply"} -> parse_reply(decoded)
        %{"kind" => "plan"} -> parse_plan(decoded)
        _ -> {:rejected, "kind is not reply or plan"}
      end
    end
  end

  def parse(_content), do: {:rejected, "output is not a string"}

  defp parse_reply(map) do
    with :ok <- exact_keys(map, @reply_keys),
         {:subject, subject} when is_binary(subject) <- {:subject, map["subject"]},
         {:body, body} when is_binary(body) <- {:body, map["body"]},
         body =
           body |> ExternalContent.sanitize() |> String.trim() |> String.slice(0, @reply_body_cap),
         true <- body != "" || {:rejected, "body is empty"} do
      {:ok, %{kind: "reply", body: body}}
    else
      {:subject, _} -> {:rejected, "subject is not a string"}
      {:body, _} -> {:rejected, "body is not a string"}
      {:rejected, _} = rejected -> rejected
    end
  end

  defp parse_plan(map) do
    max = Item.max_plan_steps()

    with :ok <- exact_keys(map, @plan_keys),
         {:summary, summary} when is_binary(summary) <- {:summary, map["summary"]},
         summary = Classifier.clean_line(summary),
         true <- summary != "" || {:rejected, "summary is empty"},
         {:steps, steps} when is_list(steps) and steps != [] <- {:steps, map["steps"]},
         true <- length(steps) <= max || {:rejected, "more than #{max} steps"},
         true <- Enum.all?(steps, &is_binary/1) || {:rejected, "a step is not a string"},
         steps = Enum.map(steps, &Classifier.clean_line/1),
         true <- Enum.all?(steps, &(&1 != "")) || {:rejected, "a step is empty"} do
      {:ok, %{kind: "plan", summary: summary, steps: steps}}
    else
      {:summary, _} -> {:rejected, "summary is not a string"}
      {:steps, _} -> {:rejected, "steps is not a non-empty list"}
      {:rejected, _} = rejected -> rejected
    end
  end

  defp decode(content) do
    trimmed = String.trim(content)

    inner =
      case Regex.run(~r/\A```(?:json)?\s*\n(.*)\n```\z/s, trimmed) do
        [_, inner] -> inner
        _ -> trimmed
      end

    case Jason.decode(inner) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:rejected, "output is not a JSON object"}
      {:error, _} -> {:rejected, "output is not JSON"}
    end
  end

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == keys,
      do: :ok,
      else: {:rejected, "output keys are not exactly #{Enum.join(keys, ", ")}"}
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp emit(%Item{} = item, result) do
    {kind, outcome} =
      case result do
        {:ok, kind, _} -> {Atom.to_string(kind), "drafted"}
        {:skipped, reason} -> {nil, "skipped_" <> Atom.to_string(reason)}
        {:error, {:draft_refused, _}} -> {nil, "draft_refused"}
        {:error, reason} when is_atom(reason) -> {nil, Atom.to_string(reason)}
        _ -> {nil, "error"}
      end

    if outcome == "drafted" do
      Logger.info(
        "[Mail.Triage.Drafter] drafted item=#{item.id} user=#{item.user_id} kind=#{kind}"
      )
    end

    :telemetry.execute(
      [:platform, :mail, :triage, :drafted],
      %{count: 1},
      %{
        org_id: item.org_id,
        account_id: item.account_id,
        item_id: item.id,
        user_id: item.user_id,
        kind: kind,
        outcome: outcome
      }
    )
  end

  defp cap(body, limit) when is_binary(body) do
    if byte_size(body) <= limit,
      do: body,
      else: body |> binary_part(0, limit) |> trim_partial_codepoint()
  end

  defp cap(_body, _limit), do: ""

  defp trim_partial_codepoint(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
  end

  defp system_prompt do
    case PromptTemplates.render_template(@template_slug, %{}) do
      {:ok, prompt} ->
        prompt

      {:error, _} ->
        case PromptTemplates.render_default(@template_slug, %{}) do
          {:ok, prompt} -> prompt
          {:error, _} -> ""
        end
    end
  end

  defp provider_module do
    Application.get_env(:platform, :mail_triage_provider, Platform.Agents.Providers.Ollama)
  end
end
