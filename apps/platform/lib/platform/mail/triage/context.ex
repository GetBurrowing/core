defmodule Platform.Mail.Triage.Context do
  @moduledoc """
  What the org already knows about an email's sender, FOR ONE READER (task
  01a1f426 stage 1). Deterministic (no model) and ids-and-counts only: no
  subject, body, task title or meeting name leaves this module.

  Built for one (reader, inbound) pair whose mailbox the caller has already
  established is eligible (`Platform.Mail.Triage.eligible_account_ids/3`):

    * `waiting_on` — the latest accepted `mail_deliveries` row FROM this
      mailbox TO the sender's address (else to anyone at the sender's
      domain), sent before this email, with no other inbound from that
      address (domain) since. The same address normalisation as
      `Platform.Mail.Digest`'s activity SQL (the `<addr>` inside a display
      form, lower-cased, trimmed);
    * `thread` — counts of earlier inbound from, and accepted outbound to,
      the sender's address in THIS mailbox only;
    * `open_task_ids` — open tasks the READER can see that name the sender's
      domain or People-page organisation, through
      `Platform.Tasks.list_open_tasks_matching_for_user/4` (the task
      visibility rule lives in Tasks, not here);
    * `meeting_ids` — meetings of the last 14 days the reader can see
      (`Platform.Meetings.list_meetings_in_range_for_user/4`) and took part
      in (created, started, or holds a live invite that was not declined),
      with an invite (`Platform.Meetings.list_invites/2`) whose `email` is
      the sender's address or at the sender's domain;
    * `person` — the People card (`Platform.People.Pages.roster/1`) whose
      aliases hold the sender's address, or whose organisation is the
      sender's domain label: `%{slug, relation}`;
    * `feedback` — this reader's `mail_triage_feedback` counts for the
      sender's domain, and the most recent verdict.

  A freemail domain (gmail.com and friends) is never used as an
  organisation term: it names a provider, not a counterparty.

  ## Titles, for the drafter only (stage 4)

  `task_titles` and `meeting_titles` hold the titles / names of the SAME
  reader-visible tasks and meetings as `open_task_ids` / `meeting_ids`
  (`%{id, title}`), read through the same public Tasks and Meetings
  functions. They never reach `signals/1` or `model_facts/1`: only
  `Platform.Mail.Triage.Drafter` renders them, into a prompt for this
  reader's own draft, so reader B's draft never cites reader A's tasks.

  ## The sender's address stays out of the query log

  Every read that takes the sender's address or domain as a query
  parameter (waiting_on, thread, feedback priors, the task search) passes
  `Platform.Mail.Triage.quiet_opts/0`: no Ecto `:debug` line and no
  `[:platform, :repo, :query]` event, whose metadata carries the params.
  """

  import Ecto.Query

  alias Platform.Mail.InboundMessage
  alias Platform.Mail.Triage.Feedback
  alias Platform.Repo

  @meeting_window_days 14
  @task_limit 5

  @freemail ~w(gmail.com googlemail.com outlook.com hotmail.com live.com msn.com yahoo.com
               ymail.com icloud.com me.com mac.com aol.com proton.me protonmail.com
               gmx.com gmx.net mail.com zoho.com fastmail.com hey.com)

  @type t :: %{
          address: String.t() | nil,
          domain: String.t() | nil,
          waiting_on: binary() | nil,
          thread: %{inbound: non_neg_integer(), outbound: non_neg_integer()},
          open_task_ids: [binary()],
          meeting_ids: [binary()],
          task_titles: [%{id: binary(), title: String.t()}],
          meeting_titles: [%{id: binary(), title: String.t()}],
          person: %{slug: String.t(), relation: String.t()} | nil,
          feedback: %{
            not_important: non_neg_integer(),
            missed: non_neg_integer(),
            latest: String.t() | nil
          }
        }

  @doc """
  The context of `inbound` for `user`. Options: `:roster` (a pre-read
  People roster, so a run reads it once), `:now`.
  """
  @spec build(map(), InboundMessage.t(), keyword()) :: t()
  def build(%{id: _} = user, %InboundMessage{} = inbound, opts \\ []) do
    address = address(inbound.from_address)
    domain = domain(address)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    at = inbound.received_at || inbound.inserted_at || now

    person = person(address, domain, Keyword.get_lazy(opts, :roster, &roster/0))
    tasks = open_tasks(user, inbound.org_id, domain, person)
    meetings = meetings(user, address, domain, now)

    %{
      address: address,
      domain: domain,
      waiting_on: waiting_on(inbound, address, domain, at),
      thread: thread(inbound, address, at),
      open_task_ids: Enum.map(tasks, & &1.id),
      meeting_ids: Enum.map(meetings, & &1.id),
      task_titles: Enum.map(tasks, &%{id: &1.id, title: &1.title}),
      meeting_titles: Enum.map(meetings, &%{id: &1.id, title: &1.name}),
      person: person && Map.take(person, [:slug, :relation]),
      feedback: feedback(user, address, domain)
    }
  end

  @doc """
  The stored form of a context: a list of `%{"kind" => ...}` maps holding
  ids and counts only.
  """
  @spec signals(t()) :: [map()]
  def signals(ctx) do
    List.flatten([
      if(ctx.waiting_on,
        do: [%{"kind" => "waiting_on", "delivery_id" => ctx.waiting_on}],
        else: []
      ),
      if(ctx.thread.inbound + ctx.thread.outbound > 0,
        do: [
          %{
            "kind" => "thread_history",
            "inbound" => ctx.thread.inbound,
            "outbound" => ctx.thread.outbound
          }
        ],
        else: []
      ),
      Enum.map(ctx.open_task_ids, &%{"kind" => "open_task", "task_id" => &1}),
      Enum.map(ctx.meeting_ids, &%{"kind" => "recent_meeting", "meeting_id" => &1}),
      if(ctx.person,
        do: [%{"kind" => "person", "slug" => ctx.person.slug, "relation" => ctx.person.relation}],
        else: []
      ),
      if(ctx.feedback.missed > 0,
        do: [%{"kind" => "feedback_missed", "count" => ctx.feedback.missed}],
        else: []
      ),
      if(ctx.feedback.not_important > 0,
        do: [%{"kind" => "feedback_not_important", "count" => ctx.feedback.not_important}],
        else: []
      )
    ])
  end

  @doc """
  The facts the classifier model is shown: booleans, counts and the
  relation keyword. No ids (they mean nothing to the model) and no text.
  """
  @spec model_facts(t()) :: map()
  def model_facts(ctx) do
    %{
      "waiting_on_their_reply" => not is_nil(ctx.waiting_on),
      "earlier_emails_from_them" => ctx.thread.inbound,
      "earlier_emails_to_them" => ctx.thread.outbound,
      "reader_open_tasks_naming_them" => length(ctx.open_task_ids),
      "reader_meetings_with_them_last_14_days" => length(ctx.meeting_ids),
      "relation" => ctx.person && ctx.person.relation,
      "reader_said_earlier_email_needed_them" => missed?(ctx),
      "reader_said_sender_not_important" => demoted?(ctx)
    }
  end

  @doc "Did this reader's most recent verdict on the sender say it was missed?"
  @spec missed?(t()) :: boolean()
  def missed?(%{feedback: %{latest: "missed"}}), do: true
  def missed?(_ctx), do: false

  @doc """
  Is this reader's most recent verdict on the sender's domain (on a
  freemail domain, the sender's address) `not_important`? One tap is
  enough: a reader who said "not important" once expects the next email
  from that sender to stay out of the call-out list. A later `missed` verdict makes `latest` "missed" and lifts it.
  Per reader: the counts come from this reader's feedback rows only.
  """
  @spec demoted?(t()) :: boolean()
  def demoted?(%{feedback: %{not_important: n, latest: "not_important"}}) when n >= 1, do: true
  def demoted?(_ctx), do: false

  @doc """
  The bare, lower-cased address of a From value (`"Name <a@b>"` or
  `"a@b"`), or nil.
  """
  @spec address(String.t() | nil) :: String.t() | nil
  def address(value) when is_binary(value) do
    bare =
      case Regex.run(~r/<([^<>]+)>/, value) do
        [_, inner] -> inner
        _ -> value
      end

    bare = bare |> String.trim() |> String.downcase()
    if String.contains?(bare, "@"), do: bare, else: nil
  end

  def address(_), do: nil

  @doc "The domain of a bare address, or nil."
  @spec domain(String.t() | nil) :: String.t() | nil
  def domain(address) when is_binary(address) do
    case String.split(address, "@") do
      [_local, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  def domain(_), do: nil

  @doc "The local part of a bare address, or nil."
  @spec local_part(String.t() | nil) :: String.t() | nil
  def local_part(address) when is_binary(address) do
    case String.split(address, "@") do
      [local, _domain] when local != "" -> local
      _ -> nil
    end
  end

  def local_part(_), do: nil

  @doc "Is `domain` a consumer mail provider rather than an organisation?"
  @spec freemail?(String.t() | nil) :: boolean()
  def freemail?(domain), do: domain in @freemail

  @doc "The People roster, or `[]` when it cannot be read."
  @spec roster() :: [map()]
  def roster do
    Platform.People.Pages.roster(nil)
  rescue
    _ -> []
  end

  # ── waiting_on / thread ──────────────────────────────────────────────────

  @norm_to "btrim(lower(coalesce(substring(r.addr FROM '<([^<>]+)>'), r.addr)))"
  @norm_from "btrim(lower(coalesce(substring(m.from_address FROM '<([^<>]+)>'), m.from_address)))"

  @waiting_address_sql """
  SELECT d.id
    FROM mail_deliveries d
   WHERE d.account_id = $1 AND d.status = 'accepted'
     AND coalesce(d.accepted_at, d.inserted_at) < $3
     AND EXISTS (SELECT 1 FROM unnest(d.recipients) AS r(addr) WHERE #{@norm_to} = $2)
     AND NOT EXISTS (
       SELECT 1 FROM mail_inbound_messages m
        WHERE m.account_id = $1 AND m.id <> $4
          AND #{@norm_from} = $2
          AND m.received_at > coalesce(d.accepted_at, d.inserted_at)
          AND m.received_at <= $3)
   ORDER BY coalesce(d.accepted_at, d.inserted_at) DESC
   LIMIT 1
  """

  @waiting_domain_sql """
  SELECT d.id
    FROM mail_deliveries d
   WHERE d.account_id = $1 AND d.status = 'accepted'
     AND coalesce(d.accepted_at, d.inserted_at) < $3
     AND EXISTS (SELECT 1 FROM unnest(d.recipients) AS r(addr)
                  WHERE split_part(#{@norm_to}, '@', 2) = $2)
     AND NOT EXISTS (
       SELECT 1 FROM mail_inbound_messages m
        WHERE m.account_id = $1 AND m.id <> $4
          AND split_part(#{@norm_from}, '@', 2) = $2
          AND m.received_at > coalesce(d.accepted_at, d.inserted_at)
          AND m.received_at <= $3)
   ORDER BY coalesce(d.accepted_at, d.inserted_at) DESC
   LIMIT 1
  """

  defp waiting_on(_inbound, nil, _domain, _at), do: nil

  defp waiting_on(inbound, address, domain, at) do
    params = fn key -> [dump(inbound.account_id), key, naive(at), dump(inbound.id)] end

    first_id(Repo.query!(@waiting_address_sql, params.(address), quiet())) ||
      if(is_binary(domain) and not freemail?(domain),
        do: first_id(Repo.query!(@waiting_domain_sql, params.(domain), quiet())),
        else: nil
      )
  end

  @thread_sql """
  SELECT
    (SELECT count(*) FROM mail_inbound_messages m
      WHERE m.account_id = $1 AND m.id <> $3 AND #{@norm_from} = $2 AND m.received_at <= $4),
    (SELECT count(*) FROM mail_deliveries d
      WHERE d.account_id = $1 AND d.status = 'accepted'
        AND EXISTS (SELECT 1 FROM unnest(d.recipients) AS r(addr) WHERE #{@norm_to} = $2))
  """

  defp thread(_inbound, nil, _at), do: %{inbound: 0, outbound: 0}

  defp thread(inbound, address, at) do
    %{rows: [[inbound_count, outbound_count]]} =
      Repo.query!(
        @thread_sql,
        [dump(inbound.account_id), address, dump(inbound.id), naive(at)],
        quiet()
      )

    %{inbound: inbound_count, outbound: outbound_count}
  end

  defp first_id(%{rows: [[id] | _]}), do: Ecto.UUID.load!(id)
  defp first_id(_), do: nil

  # ── tasks / meetings / people ────────────────────────────────────────────

  defp open_tasks(user, org_id, domain, person) do
    terms =
      [
        if(is_binary(domain) and not freemail?(domain), do: domain),
        person && Map.get(person, :organisation)
      ]
      |> Enum.filter(&(is_binary(&1) and String.length(String.trim(&1)) >= 3))

    case terms do
      [] ->
        []

      terms ->
        Platform.Tasks.list_open_tasks_matching_for_user(user, terms, @task_limit,
          org_id: org_id,
          repo_opts: quiet()
        )
    end
  end

  defp meetings(_user, nil, _domain, _now), do: []

  defp meetings(user, address, domain, now) do
    from = DateTime.add(now, -@meeting_window_days * 86_400, :second)

    user
    |> Platform.Meetings.list_meetings_in_range_for_user(from, now)
    |> Enum.filter(&took_part?(&1, user))
    |> Enum.filter(fn meeting ->
      meeting.id
      |> Platform.Meetings.list_invites()
      |> Enum.any?(&invite_matches?(&1, address, domain))
    end)
  end

  defp took_part?(meeting, %{id: user_id} = user) do
    meeting.created_by_user_id == user_id or meeting.started_by_user_id == user_id or
      Platform.Meetings.invite_rsvp(meeting, user) not in [nil, "declined"]
  end

  defp invite_matches?(%{email: email}, address, domain) when is_binary(email) do
    invited = address(email)

    invited == address or
      (is_binary(domain) and not freemail?(domain) and domain(invited) == domain)
  end

  defp invite_matches?(_invite, _address, _domain), do: false

  defp person(nil, _domain, _roster), do: nil

  defp person(address, domain, roster) when is_list(roster) do
    Enum.find(roster, fn card ->
      Enum.any?(Map.get(card, :aliases) || [], &(String.downcase(&1) == address))
    end) ||
      if(is_binary(domain) and not freemail?(domain),
        do: Enum.find(roster, &organisation_matches?(&1, domain))
      )
  end

  defp person(_address, _domain, _roster), do: nil

  defp organisation_matches?(%{organisation: organisation}, domain)
       when is_binary(organisation) do
    key = organisation |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    key != "" and
      domain |> String.split(".") |> Enum.drop(-1) |> Enum.any?(&(&1 == key))
  end

  defp organisation_matches?(_card, _domain), do: false

  # ── feedback priors ──────────────────────────────────────────────────────

  # A reader's verdict applies to the sender's domain, except on a freemail
  # domain: one "Not important" tap on news@gmail.com must not demote every
  # other gmail.com sender, so there the verdict is matched by address.
  defp feedback(_user, _address, nil), do: %{not_important: 0, missed: 0, latest: nil}

  defp feedback(%{id: user_id}, address, domain) do
    rows =
      from(f in Feedback,
        where: f.user_id == ^user_id,
        order_by: [desc: f.inserted_at, desc: f.id],
        select: f.verdict
      )
      |> feedback_sender(address, domain)
      |> Repo.all(quiet())

    %{
      not_important: Enum.count(rows, &(&1 == "not_important")),
      missed: Enum.count(rows, &(&1 == "missed")),
      latest: List.first(rows)
    }
  end

  defp feedback_sender(query, address, domain) do
    if freemail?(domain),
      do: where(query, [f], f.sender_address == ^address),
      else: where(query, [f], f.sender_domain == ^domain)
  end

  defp quiet, do: Platform.Mail.Triage.quiet_opts()

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp naive(%DateTime{} = at), do: DateTime.to_naive(at)
  defp naive(%NaiveDateTime{} = at), do: at
end
