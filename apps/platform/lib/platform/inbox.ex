defmodule Platform.Inbox do
  @moduledoc """
  The Inbox context — durable, per-user attention rows and the single write
  seam every notification producer goes through.

  `emit/1` is THE write seam: it inserts exactly ONE `Inbox.Item` row for ONE
  user and broadcasts `{:inbox_item_added, item}` on that user's topic. There is
  no fan-out here — producers that want to notify several users call `emit/1`
  once per recipient.

  Semantics ("dismiss = gone; @mention = back", mirroring `Platform.Chat`):
  dismissal is per-ROW. Re-emitting for the same
  `(user_id, source_type, source_id)` triple ALWAYS inserts a fresh row even if
  a prior row for that triple was dismissed — there is no dedup or resurrection.

  For a viewer still allowed to read its source, **dismissal is the only
  action that takes a row off the LIST** (task `01a00108` stage 4). A later
  resource deny hides an existing row at read time. The underlying
  `unread_scope/1` still keys on `dismissed_at` alone. What changed in task
  `01a11703` is WHAT dismisses on open:

    * Opening a row from `/inbox` goes through `open_item/2`. For every kind
      outside `action_kinds/0` it is an acknowledgement: one write stamps
      `read_at` and `dismissed_at` with the same instant, so the row leaves the
      list. For a kind in `action_kinds/0` it stamps `read_at` only; the row
      stays listed until the thing it asks for is resolved (the plan settles,
      the reviews resolve) or the user dismisses it by hand.
    * The BADGE is `badge_scope/1`: undismissed rows with `read_at` nil. A row
      the user has opened is never in the badge, whatever its kind, so the
      badge counts what nobody has looked at yet and the list carries what is
      still outstanding. The two are different numbers on purpose.

  Opening a task you sponsor from the task pane also DISMISSES your
  `task_sponsor_assigned` row for it (`dismiss_sponsor_row_on_open/2`, called
  from `PlatformWeb.TasksLive.handle_params/3`, task `01a116ff`) — a dismissal,
  so dismissal is still the only clear.
  """
  import Ecto.Query

  require Logger

  alias Platform.Access
  alias Platform.Access.{Query, Scope}
  alias Platform.Chat.{Message, Space}
  alias Platform.Inbox.Item
  alias Platform.Meetings.Meeting
  alias Platform.Push.Notification
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tasks.{ReviewRequest, Task}

  # The kinds whose row asks the user to DO something that has its own
  # resolution path (approve/reject the plan, resolve the review). Opening one
  # marks it read and leaves it listed. An ALLOWLIST: every other kind,
  # including any kind added later, is acknowledged (dismissed) on open.
  # Equal to `Platform.Mobile`'s `@approval_kinds`.
  @action_kinds ~w(task_plan_review review_request_pending)

  # Core kinds that stay listed when opened but are NOT approvals, so they are
  # in `action_kinds/0` and never in `core_action_kinds/0` (which must equal
  # `Platform.Mobile`'s `@approval_kinds`: Mobile cannot act on these).
  # `briefing` (task 01a15ee1 stage 1): opening the day's briefing is reading
  # it, not handling it. The row stays listed through the day, "All done"
  # once every item is handled, and the reconciler clears it only once the
  # day is past the insight TTL (`row_stale?/1`, task 01a15ee1 stage 6).
  @listed_on_open ~w(briefing)

  # The inbox kinds an EXTERNAL viewer has a destination for on their surface.
  # A new kind is excluded by default: the rule holds without anyone
  # remembering to exclude it.
  @external_reachable_kinds ["chat_mention"]

  @doc """
  The kinds that stay listed after they are opened: core's `task_plan_review`
  and `review_request_pending`, core's non-approval `briefing` (task
  `01a15ee1` stage 1), then every registered extension kind declared
  with `stays_listed_on_open: true` (`Platform.Extension` `inbox_kinds/0`,
  read per call). `open_item/2` marks these read and dismisses every other
  kind. The list is an allowlist, so a new kind is acknowledged on open
  unless it is added here or declared by its extension.
  """
  @spec action_kinds() :: [String.t()]
  def action_kinds do
    @action_kinds ++
      @listed_on_open ++
      for %{kind: kind, stays_listed_on_open: true} <- Platform.Extensions.inbox_kinds(),
          do: kind
  end

  @doc """
  Core's own action kinds, without any extension's. Equal to
  `Platform.Mobile`'s `@approval_kinds`: an extension kind never becomes a
  mobile approval, because Mobile's `act/3` could not act on it.
  """
  @spec core_action_kinds() :: [String.t()]
  def core_action_kinds, do: @action_kinds

  @doc "PubSub topic for a user's inbox stream."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(user_id), do: "inbox:#{user_id}"

  @doc "Subscribe the calling process to a user's inbox topic."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(Platform.PubSub, topic(user_id))
  end

  @doc """
  The write seam: insert ONE inbox item for ONE user and broadcast it.

  Accepts an attrs map with `:user_id`, `:kind`, `:source_type`, `:source_id`,
  `:title`, and optional `:body` / `:url`. On success inserts a single row,
  broadcasts `{:inbox_item_added, item}` on `topic(user_id)`, and returns
  `{:ok, item}`. A denied source returns `{:error, :denied}` before insertion,
  broadcast, or push. A changeset failure returns `{:error, changeset}`. No
  fan-out — call once per recipient.
  """
  @spec emit(map()) :: {:ok, Item.t()} | {:error, Ecto.Changeset.t()} | {:error, :denied}
  def emit(attrs) do
    changeset = Item.changeset(%Item{}, attrs)

    if changeset.valid? do
      recipient = Repo.get(Platform.Accounts.User, Ecto.Changeset.get_field(changeset, :user_id))

      resource =
        resource_for(
          Ecto.Changeset.get_field(changeset, :source_type),
          Ecto.Changeset.get_field(changeset, :source_id)
        )

      with :ok <- resource_check(recipient, resource),
           {:ok, item} <- Repo.insert(changeset) do
        Phoenix.PubSub.broadcast(Platform.PubSub, topic(item.user_id), {:inbox_item_added, item})
        maybe_push(item)
        {:ok, item}
      end
    else
      {:error, changeset}
    end
  end

  @doc "The resource whose read permission guards an inbox source."
  def resource_for("chat_message", id), do: resource_id(Message, id, :space_id, :space)
  def resource_for("task", id), do: {:task, id}
  def resource_for("task_review", id), do: {:task, id}
  def resource_for("review_request", id), do: resource_id(ReviewRequest, id, :task_id, :task)
  def resource_for("meeting", id), do: resource_id(Meeting, id, :chat_space_id, :space)
  def resource_for(_, _), do: nil

  defp resource_id(schema, id, field, type) do
    case Repo.get(schema, id) do
      nil -> nil
      row -> {type, Map.fetch!(row, field)}
    end
  end

  defp resource_check(_recipient, nil), do: :ok
  defp resource_check(nil, _resource), do: :ok

  defp resource_check(recipient, {type, _} = resource) do
    permission = if type == :task, do: "tasks.read", else: "chat.read"
    Access.check(Scope.for_user(recipient), permission, resource)
  end

  # Kinds whose row is ALSO a push (task 01a10882). Approvals had no push
  # before: the row was the only signal. `chat_mention` is deliberately NOT
  # here: `Platform.Chat.AttentionRouter` already pushes every mention, so
  # pushing it again from its inbox row would double-notify.
  @push_kinds ~w(task_plan_review review_request_pending)

  @doc "The inbox kinds `emit/1` also pushes (both transports, one notification)."
  @spec push_kinds() :: [String.t()]
  def push_kinds, do: @push_kinds

  # A push failure never fails the emit: the row is the durable record and is
  # already written and broadcast.
  defp maybe_push(%Item{kind: kind, user_id: user_id} = item) when kind in @push_kinds do
    notifications_module().fan_out_to_user(user_id, Notification.from_inbox_item(item))
    :ok
  rescue
    e ->
      Logger.warning("[Inbox] push for item #{item.id} raised: #{inspect(e.__struct__)}")
      :ok
  end

  defp maybe_push(_item), do: :ok

  # Same indirection as `Platform.Tasks` and `MeetingNotifier`, so tests can
  # swap in a Recorder double (the real `fan_out_to_user/3` short-circuits in
  # :test env).
  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
  end

  @doc """
  Write or refresh the ONE Inbox row for a delivered daily briefing
  (`Platform.Memory.Briefing`). Task `01a15ee1-48c8-7000-a8f1-33a5586cb458`,
  stage 1.

  The row is keyed by `(briefing.user_id, "briefing", briefing.id)`, and the
  briefing is unique per `(user_id, digest_date)`, so there is one row per
  person per day:

    * no row yet: inserted through `emit/1`, returns `{:ok, item, :created}`;
    * a row exists: its `title` / `body` / `url` are updated and, when
      `attrs[:new_items?]` is true, `read_at` and `dismissed_at` are cleared
      so the row is unread and listed again. Returns
      `{:ok, item, :updated}`. A second row is never inserted, even when the
      first was dismissed.

  `attrs`: `:title`, `:body`, `:url` (defaults built from `:digest_date` /
  `:total` / `:calls` by `briefing_title/0`, `briefing_summary/2` and
  `briefing_url/1`) and `:new_items?` (default true).

  Serialised per briefing by a transaction-scoped advisory lock, so two
  concurrent deliveries for one day cannot both insert. Broadcasts
  `{:inbox_changed, user_id}` after the write commits.
  """
  @spec upsert_briefing_item(Platform.Memory.Briefing.t(), map()) ::
          {:ok, Item.t(), :created | :updated} | {:error, term()}
  def upsert_briefing_item(%Platform.Memory.Briefing{} = briefing, attrs \\ %{}) do
    attrs = Map.new(attrs)
    total = Map.get(attrs, :total, map_size(briefing.items || %{}))
    calls = Map.get(attrs, :calls, 0)

    fields = %{
      title: Map.get(attrs, :title, briefing_title()),
      body: Map.get(attrs, :body, briefing_summary(total, calls)),
      url: Map.get(attrs, :url, briefing_url(briefing.digest_date))
    }

    new_items? = Map.get(attrs, :new_items?, true)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "inbox:briefing:" <> briefing.id
        ])

        case briefing_row(briefing) do
          nil ->
            attrs =
              Map.merge(fields, %{
                user_id: briefing.user_id,
                kind: "briefing",
                source_type: "briefing",
                source_id: briefing.id
              })

            case emit(attrs) do
              {:ok, item} -> {item, :created}
              {:error, reason} -> Repo.rollback(reason)
            end

          %Item{} = item ->
            changes =
              if new_items?,
                do: Map.merge(fields, %{read_at: nil, dismissed_at: nil}),
                else: fields

            case item |> Ecto.Changeset.change(changes) |> Repo.update() do
              {:ok, updated} -> {updated, :updated}
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)

    case result do
      {:ok, {item, outcome}} ->
        broadcast_changed(item.user_id)
        {:ok, item, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The day's row for `briefing`, dismissed or not (newest first, in case a
  # pre-lock race ever wrote two).
  defp briefing_row(briefing) do
    Repo.one(
      from(i in Item,
        where:
          i.user_id == ^briefing.user_id and i.source_type == "briefing" and
            i.source_id == ^briefing.id,
        order_by: [desc: i.inserted_at, desc: i.id],
        limit: 1
      )
    )
  end

  @doc "The briefing row's title."
  @spec briefing_title() :: String.t()
  def briefing_title, do: "Today's briefing"

  @doc """
  The briefing row's subtitle: `"N items · K need your call"`, `"1 needs your
  call"` when K is 1, `"N items · FYI only"` when K is 0.
  """
  @spec briefing_summary(non_neg_integer(), non_neg_integer()) :: String.t()
  def briefing_summary(total, calls) do
    items = if total == 1, do: "1 item", else: "#{total} items"

    case calls do
      0 -> items <> " · FYI only"
      1 -> items <> " · 1 needs your call"
      k -> items <> " · #{k} need your call"
    end
  end

  @doc "Where the briefing row opens: `/inbox/briefing/<digest_date>`."
  @spec briefing_url(Date.t()) :: String.t()
  def briefing_url(%Date{} = date), do: "/inbox/briefing/" <> Date.to_iso8601(date)

  @doc """
  List a user's non-dismissed inbox items, newest first. Pass `opts[:kind]` to
  filter to a single kind.

  > #### Dead in production, and now a duplicate {: .warning}
  >
  > This has ZERO production call sites — the `/inbox` list is
  > `InboxLive.load_items/1`, built on `unread_scope/1`. Its only callers are
  > tests using it as a "did a row get emitted" helper.
  >
  > Since stage 4 of task `01a00108` it also returns exactly what
  > `unread_scope/1` selects (both key on `dismissed_at` alone), so it is a
  > second spelling of the canonical scope with an ordering baked in. It is
  > kept, unrenamed, only because rewriting its test call sites would inflate a
  > diff whose risk lives elsewhere. Do not reach for it in new production
  > code: compose `unread_scope/1` instead, so there stays exactly one list
  > query, and the badge (`badge_scope/1`) stays built on it.
  """
  @spec list_unread_for_user(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_unread_for_user(user_id, opts \\ []) do
    Item
    |> where([i], i.user_id == ^user_id and is_nil(i.dismissed_at))
    |> maybe_filter_kind(opts[:kind])
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [i], i.kind == ^kind)

  @doc """
  The LIST scope: the rows `/inbox` renders. A row is listed iff it is not
  dismissed (`dismissed_at`), scoped to `user_id`. It is not the badge scope;
  the badge is `badge_scope/1`, which composes on this one and adds
  `is_nil(read_at)`. Because the badge is built ON this query, the badge is
  always a subset of the list and the #589/#592 drift (a badge counting rows
  the list does not show) cannot recur.

  Built on this scope: `InboxLive.load_items/1`, `dismiss_all_unread/1` (Clear
  all clears what is listed), `reachable_unread_scope/1,2` and
  `Platform.Mobile.AppEntities.list_approvals/1`.

  ## Reading is not clearing (task `01a00108` stage 4)

  This predicate used to be `is_nil(dismissed_at) and is_nil(read_at)`, which
  made OPENING a row the way you cleared it. The inbox is a to-do list, so
  reading and doing are two different acts: opening an item is now just having
  seen it, and only an explicit dismissal takes it off the list.

  `read_at` means "has been seen", not "done", so it is not a filter HERE. Do
  not reintroduce it into this scope without reopening that decision. Since
  task `01a11703` it IS a filter in `badge_scope/1`, which is where "seen"
  belongs.

  Migration `20260817120000_backfill_read_as_dismissed_inbox_items.exs` copied
  `read_at` into `dismissed_at` for every historical row, so the rows users
  cleared under the old meaning stayed cleared through the change rather than
  resurfacing in a heap.

  The name is kept. `unread_scope/1` is referenced from `shell_live.ex`,
  `inbox_live.ex` and four functions below, and renaming it would touch far
  more than the meaning change warrants — but read it as "not cleared", not as
  "never opened".

  Returns a composable query (no `order_by`, no execution) — callers add their
  own ordering/aggregation:

    * `badge_scope/1` → `unread_scope(user_id) |> where(is_nil(read_at))`
    * `InboxLive.load_items/1` →
      `unread_scope(user_id) |> order_by(desc: :inserted_at) |> Repo.all()`
  """
  @spec unread_scope(Ecto.UUID.t()) :: Ecto.Query.t()
  def unread_scope(user_id) do
    from(i in Item,
      where: i.user_id == ^user_id and is_nil(i.dismissed_at)
    )
  end

  @doc """
  The reachability-aware form of `unread_scope/1`: the SAME canonical scope,
  narrowed to kinds whose destination the viewer can actually reach.

  The rule, from the design canvas "Design direction — the inbox badge an
  external user cannot act on" (rev 1): A COUNT NEVER INCLUDES SOMETHING THE
  VIEWER HAS NO WAY TO ACT ON. If nothing reachable remains the count is 0, and
  the rail's `badge_text/1` already returns nil at 0 — so no badge renders at
  all, not a zero and not a dot. Nothing in the badge's LOOK changes here
  (same treatment, same `99+` cap); only what the number counts changes.

  * external viewer → `#{inspect(@external_reachable_kinds)}` only. An external
    user is fenced off `/inbox` by `PlatformWeb.Plugs.ExternalUserScope`, so
    every other kind is a promise their surface cannot keep. `chat_mention`
    survives because a mention's home is the conversation, which their chat
    rail already renders (and marks unread) on the host they are on.
  * internal viewer → `unread_scope/1` VERBATIM. No filter, no behaviour change.

  This composes ON `unread_scope/1` rather than restating it, so it is the
  reachable LIST. The reachable BADGE is `reachable_badge_scope/1,2`, which
  applies the same rule to `badge_scope/1` (itself composed on
  `unread_scope/1`), so every reachable badge row is a reachable list row. The
  externality branch keys off `Platform.Tenancy.external_user?/1`, the existing
  shared predicate — there is deliberately no second externality test.

  Arity 2 takes the already-known externality so a caller that has it does not
  re-query; arity 1 answers it once via `Tenancy.external_user?/1`.

  Note this is the COUNT-side rule, not a template rule. At the time of writing
  the badge is painted only by `PlatformWeb.Components.IconRail`'s
  `badge_text/1` from `layouts/shell.html.heex`, and the external surface
  (`Layouts.external/1`) renders NO icon rail — so for an external user the
  count is COMPUTED but not currently PAINTED. Enforcing at the count makes the
  rule hold for every present and future renderer instead of one template.
  """
  @spec reachable_unread_scope(Ecto.UUID.t(), boolean()) :: Ecto.Query.t()
  def reachable_unread_scope(user_id, external?)

  def reachable_unread_scope(user_id, true) do
    where(unread_scope(user_id), [i], i.kind in @external_reachable_kinds)
  end

  def reachable_unread_scope(user_id, false), do: unread_scope(user_id)

  @spec reachable_unread_scope(Ecto.UUID.t()) :: Ecto.Query.t()
  def reachable_unread_scope(user_id) do
    reachable_unread_scope(user_id, Tenancy.external_user?(%{id: user_id}))
  end

  @doc "The reachable inbox list narrowed by the viewer's current grants."
  @spec reachable_unread_scope(Ecto.UUID.t(), boolean(), Scope.t()) :: Ecto.Query.t()
  def reachable_unread_scope(user_id, external?, %Scope{} = scope) do
    user_id
    |> reachable_unread_scope(external?)
    |> restrict_sources(scope)
  end

  @doc """
  The BADGE scope: the rows of `unread_scope/1` the user has not opened
  (`read_at` nil). Task `01a11703`.

  It composes ON `unread_scope/1` rather than restating it, so the badge is
  always a subset of the list. The difference between the two is exactly the
  read, undismissed rows: an action row (`action_kinds/0`) the user opened and
  has not yet resolved, or any row restored by an undo after it was opened.
  Those are listed and not counted.
  """
  @spec badge_scope(Ecto.UUID.t()) :: Ecto.Query.t()
  def badge_scope(user_id) do
    user_id |> unread_scope() |> where([i], is_nil(i.read_at))
  end

  @doc """
  `badge_scope/1` narrowed to what this viewer can reach, by the same rule as
  `reachable_unread_scope/1,2`: an internal viewer gets `badge_scope/1`
  VERBATIM, an external viewer gets it filtered to
  `#{inspect(@external_reachable_kinds)}`. It selects exactly the rows of
  `reachable_unread_scope/1,2` with `read_at` nil.

  It composes on `badge_scope/1`, not on `reachable_unread_scope/1,2` plus a
  second copy of the `read_at` filter, so the "not yet opened" predicate is
  written once. Every badge number (the rail, the Dock/title marker, the
  app-icon `approvals` count) is built on this scope.
  """
  @spec reachable_badge_scope(Ecto.UUID.t(), boolean()) :: Ecto.Query.t()
  def reachable_badge_scope(user_id, external?)

  def reachable_badge_scope(user_id, true) do
    where(badge_scope(user_id), [i], i.kind in @external_reachable_kinds)
  end

  def reachable_badge_scope(user_id, false), do: badge_scope(user_id)

  @spec reachable_badge_scope(Ecto.UUID.t()) :: Ecto.Query.t()
  def reachable_badge_scope(user_id) do
    reachable_badge_scope(user_id, Tenancy.external_user?(%{id: user_id}))
  end

  @doc "The reachable badge is always a subset of the grant-filtered list."
  @spec reachable_badge_scope(Ecto.UUID.t(), boolean(), Scope.t()) :: Ecto.Query.t()
  def reachable_badge_scope(user_id, external?, %Scope{} = scope) do
    user_id
    |> reachable_unread_scope(external?, scope)
    |> where([i], is_nil(i.read_at))
  end

  # Restrict source IDs through Access.Query rather than duplicating grant
  # precedence in the Inbox. The grants_apply? guard preserves historical
  # orphan rows when no grant names that permission.
  defp restrict_sources(query, %Scope{} = scope) do
    query
    |> restrict_task_sources(scope)
    |> restrict_space_sources(scope)
  end

  defp restrict_task_sources(query, scope) do
    if Access.grants_apply?(scope, "tasks.read") do
      tasks =
        Task
        |> Query.restrict(scope, "tasks.read", :task, %{id: :id})
        |> select([t], t.id)

      reviews = from(r in ReviewRequest, where: r.task_id in subquery(tasks), select: r.id)

      where(
        query,
        [i],
        i.source_type not in ["task", "task_review", "review_request"] or
          (i.source_type in ["task", "task_review"] and i.source_id in subquery(tasks)) or
          (i.source_type == "review_request" and i.source_id in subquery(reviews))
      )
    else
      query
    end
  end

  defp restrict_space_sources(query, scope) do
    if Access.grants_apply?(scope, "chat.read") do
      spaces =
        Space
        |> Query.restrict(scope, "chat.read", :space, %{id: :id})
        |> select([s], s.id)

      messages = from(m in Message, where: m.space_id in subquery(spaces), select: m.id)
      meetings = from(m in Meeting, where: m.chat_space_id in subquery(spaces), select: m.id)

      where(
        query,
        [i],
        i.source_type not in ["chat_message", "meeting"] or
          (i.source_type == "chat_message" and i.source_id in subquery(messages)) or
          (i.source_type == "meeting" and i.source_id in subquery(meetings))
      )
    else
      query
    end
  end

  @doc """
  The badge number for this viewer: one aggregate over
  `reachable_badge_scope/1`. For an internal user this is `unread_count/1`
  exactly; for an external user it counts reachable kinds only, and 0 means
  the badge node leaves the DOM.

  The name is kept because `PlatformWeb.ShellLive` calls it; read "unread" as
  "not yet opened". It is NOT the length of the `/inbox` list.
  """
  @spec reachable_unread_count(Ecto.UUID.t()) :: non_neg_integer()
  def reachable_unread_count(user_id) do
    scope = Scope.for_user(%{id: user_id})
    external? = Tenancy.external_user?(%{id: user_id})
    Repo.aggregate(reachable_badge_scope(user_id, external?, scope), :count)
  end

  @doc """
  Whether a live (non-dismissed) inbox row already exists for a source triple.

  The producer-side dedup seam: before emitting a rolled-up review row a
  producer checks this so a task with N review gates yields exactly ONE
  `(user, source_type, source_id)` inbox row instead of N. Read status is
  irrelevant — a read-but-not-dismissed rollup row still represents the live
  attention, so it blocks a duplicate insert.
  """
  @spec active_source_row?(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: boolean()
  def active_source_row?(user_id, source_type, source_id) do
    Repo.exists?(
      from(i in Item,
        where:
          i.user_id == ^user_id and i.source_type == ^source_type and
            i.source_id == ^source_id and is_nil(i.dismissed_at)
      )
    )
  end

  @doc """
  The badge number: undismissed rows the user has not opened. One aggregate
  over `badge_scope/1`.

  It is NOT the length of the `/inbox` list. A read action row (opened, not
  yet resolved) is listed and not counted; since task `01a11703` that is the
  only kind of row the two disagree on in normal use, plus a row restored by
  an undo after it was opened. Every counted row is listed, because
  `badge_scope/1` composes on `unread_scope/1`, which is what
  `InboxLive.load_items/1` selects from. That is the half of the #589/#592 fix
  that still holds: the badge never counts a row the list does not show.

  Scoping is inherent: only rows whose `user_id` matches are counted, so an
  external user's count is naturally limited to their own (allowlisted) rows
  without an extra scope filter.
  """
  @spec unread_count(Ecto.UUID.t()) :: non_neg_integer()
  def unread_count(user_id) do
    Repo.aggregate(badge_scope(user_id), :count)
  end

  @doc """
  Mark an item read for `user_id` — "the user has seen this", and nothing more.

  Reading alone does NOT take a row off the list; only `dismissed_at` does.
  It DOES take the row out of the badge: since task `01a11703`, `read_at` has
  a reader, `badge_scope/1`, which counts only rows with `read_at` nil.

  `/inbox` no longer calls this when a row is opened; it calls `open_item/2`,
  which also dismisses every kind outside `action_kinds/0`. This stays the
  plain "seen" write for any caller that wants exactly that.

  The `user_id` is a defensive cross-user guard: the update is scoped by both
  `id` and `user_id`, so a mismatched user mutates nothing and gets
  `{:error, :not_found}`.
  """
  @spec mark_read(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def mark_read(item_id, user_id) do
    case set_timestamp(item_id, user_id, :read_at) do
      {:ok, item} = ok ->
        # Load-bearing since task `01a11703`: the badge (`badge_scope/1`)
        # filters on `read_at`, so a read moves the count, and this coarse
        # `{:inbox_changed, user_id}` is what tells shells to recompute it. A
        # cross-user guard miss (`{:error, :not_found}`) broadcasts nothing.
        broadcast_changed(item.user_id)
        ok

      other ->
        other
    end
  end

  @doc """
  Acknowledge an inbox row the user opened from `/inbox`. Task `01a11703`.

    * A kind in `action_kinds/0`: sets `read_at` only, then broadcasts
      `{:inbox_changed, user_id}`. The row stays listed, out of the badge,
      until its own resolution path dismisses it (plan approve/reject,
      review resolution, or the reconciler) or the user dismisses it.
    * Every other kind: ONE update sets `read_at` and `dismissed_at` to the
      SAME instant, then broadcasts `{:inbox_item_dismissed, item}`. The equal
      timestamps are how a later reader tells "dismissed by opening" from any
      other dismissal.

  A row that is already dismissed keeps its `dismissed_at`; only `read_at` is
  written. Cross-user guarded like `mark_read/2`: the row is loaded by `id`
  AND `user_id`, so another user's id returns `{:error, :not_found}`, writes
  nothing and broadcasts nothing.
  """
  @spec open_item(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def open_item(item_id, user_id) do
    case fetch_owned(item_id, user_id) do
      nil -> {:error, :not_found}
      %Item{} = item -> acknowledge(item, DateTime.utc_now())
    end
  end

  defp acknowledge(%Item{kind: kind} = item, now) do
    if kind in action_kinds(), do: mark_read_on_open(item, now), else: dismiss_on_open(item, now)
  end

  defp mark_read_on_open(item, now) do
    {:ok, updated} = item |> Ecto.Changeset.change(%{read_at: now}) |> Repo.update()
    broadcast_changed(updated.user_id)
    {:ok, updated}
  end

  defp dismiss_on_open(%Item{dismissed_at: %DateTime{}} = item, now) do
    {:ok, updated} = item |> Ecto.Changeset.change(%{read_at: now}) |> Repo.update()
    broadcast_changed(updated.user_id)
    {:ok, updated}
  end

  defp dismiss_on_open(%Item{} = item, now) do
    {:ok, updated} =
      item
      |> Ecto.Changeset.change(%{read_at: now, dismissed_at: now})
      |> Repo.update()

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      topic(updated.user_id),
      {:inbox_item_dismissed, updated}
    )

    {:ok, updated}
  end

  @doc """
  The newest row `user_id` dismissed by OPENING it within the last
  `within_seconds` (default 300), or `nil`. Task `01a11703` stage 3.

  `/inbox` derives its single-row Undo toast from this on mount: the open
  navigates away, so a socket-assign toast cannot survive the trip.

  "Dismissed by opening" is read off the shape `open_item/2` writes for a kind
  outside `action_kinds/0`: `dismissed_at == read_at`, stamped from one `now`.
  No other writer in this module stamps both from one value — `mark_read/2`,
  `mark_dismissed/2` and `dismiss_many/2` each take their own `utc_now/0` at
  microsecond precision. Rows the backfill migration stamped equal carry old
  timestamps and fall outside the window. Action kinds are excluded outright:
  opening one never dismisses it.
  """
  @spec last_dismissed_on_open(Ecto.UUID.t(), pos_integer()) :: Item.t() | nil
  def last_dismissed_on_open(user_id, within_seconds \\ 300) do
    since = DateTime.add(DateTime.utc_now(), -within_seconds, :second)

    Item
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.kind not in ^action_kinds())
    |> where([i], not is_nil(i.dismissed_at))
    |> where([i], i.dismissed_at == i.read_at)
    |> where([i], i.dismissed_at > ^since)
    |> order_by([i], desc: i.dismissed_at, desc: i.id)
    |> limit(1)
    |> Repo.one()
  end

  defp broadcast_changed(user_id) do
    Phoenix.PubSub.broadcast(Platform.PubSub, topic(user_id), {:inbox_changed, user_id})
  end

  @doc """
  Mark an item dismissed for `user_id` (removes it from the unread list).

  Same cross-user guard as `mark_read/2`. Dismissal is per-ROW — a later
  `emit/1` for the same source triple still inserts a fresh row.

  On success broadcasts `{:inbox_item_dismissed, item}` on `topic(user_id)`
  (mirroring `emit/1`'s add broadcast) so live consumers — e.g. the icon-rail
  unread badge — can decrement without a re-query. A cross-user guard miss
  (`{:error, :not_found}`) broadcasts nothing.
  """
  @spec mark_dismissed(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def mark_dismissed(item_id, user_id) do
    case set_timestamp(item_id, user_id, :dismissed_at) do
      {:ok, item} ->
        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          topic(item.user_id),
          {:inbox_item_dismissed, item}
        )

        {:ok, item}

      other ->
        other
    end
  end

  @doc """
  Dismiss every non-dismissed inbox row for `user_id` keyed to a source triple.

  Source-keyed dismissal seam: when the attention condition a
  `(source_type, source_id)` row points at resolves for a user (e.g. they join
  the meeting a `meeting_starting` row references), the producer calls this to
  clear all live rows for that source. Uses the
  `(user_id, source_type, source_id)` index M1 ships.

  Cross-user guarded (scoped by `user_id`, like `mark_dismissed/2`) and
  idempotent — already-dismissed or absent rows are a safe no-op. Returns
  `{:ok, count}` with the number of rows dismissed.

  ## `kind:` — clear only the kind you own

  A source triple is NOT unique per kind. `task_sponsor_assigned` and
  `task_plan_review` both carry `source_type: "task"` and the same task id, so
  an unfiltered sweep from a plan-settle path dismisses the sponsor row too —
  in the same write, with the same `dismissed_at`. That contradicts
  `row_stale?/1`'s documented decision that sponsor rows are cleared by hand
  OR when the sponsor opens the task (`dismiss_sponsor_row_on_open/2`, task
  `01a116ff`, which itself calls this with `kind: "task_sponsor_assigned"`),
  and it silently undoes a choice this system made on purpose.

  So a caller that owns ONE kind passes `kind: "task_plan_review"` and touches
  nothing else. Callers whose resolution genuinely retires every row for the
  source — joining the meeting a `meeting_starting` row points at — keep the
  unfiltered form deliberately.
  """
  @spec dismiss_by_source(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, non_neg_integer()}
  def dismiss_by_source(user_id, source_type, source_id, opts \\ []) do
    now = DateTime.utc_now()

    {count, _} =
      Item
      |> where(
        [i],
        i.user_id == ^user_id and i.source_type == ^source_type and
          i.source_id == ^source_id and is_nil(i.dismissed_at)
      )
      |> filter_kind(Keyword.get(opts, :kind))
      |> Repo.update_all(set: [dismissed_at: now])

    # Source-keyed dismissal is another silent mutation the live badge used to
    # miss (it broadcast NOTHING). When it actually cleared rows, broadcast the
    # coarse `{:inbox_changed, user_id}` so shells recompute the badge and
    # InboxLive re-derives. A no-op (count 0) stays quiet.
    if count > 0, do: broadcast_changed(user_id)

    {:ok, count}
  end

  @doc """
  Dismiss `user_id`'s live `task_sponsor_assigned` row for `task_id`: the
  sponsor opened the task (task `01a116ff`).

  Called from `PlatformWeb.TasksLive.handle_params/3` for `/tasks/:task_id`,
  the one clause both open paths run: the board pane (`select_task` ->
  `push_patch`) and the inbox deep link (`InboxLive` "open" ->
  `push_navigate` -> mount). A call in `InboxLive` alone would miss the pane.

  Scoped to the CURRENT user, so a non-sponsor's visit clears nothing of the
  sponsor's (a former sponsor whose old row is still live clears their own
  row, which is intended). `kind:` is REQUIRED here: `task_plan_review` rows
  carry the same `source_type: "task"` and task id, and an unfiltered sweep
  would clear the plan-review row too. `handle_params/3` runs on both the
  dead and the connected render; the second call is a count-0 no-op that
  does not broadcast. A non-binary `user_id` (no session user) is a no-op.

  Since task `01a11703`, the inbox deep link dismisses the clicked sponsor row
  itself (`open_item/2`, with `dismissed_at == read_at`) before navigating, so
  on that path this call clears only OTHER live sponsor rows for the same task
  (usually none). The board pane remains the path this call exists for.
  """
  @spec dismiss_sponsor_row_on_open(term(), Ecto.UUID.t()) :: :ok
  def dismiss_sponsor_row_on_open(user_id, task_id) when is_binary(user_id) do
    {:ok, _} = dismiss_by_source(user_id, "task", task_id, kind: "task_sponsor_assigned")
    :ok
  end

  def dismiss_sponsor_row_on_open(_user_id, _task_id), do: :ok

  # nil kind means "every kind for this source" — the pre-existing behaviour,
  # kept as the default so no current caller changes shape.
  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind) when is_binary(kind), do: where(query, [i], i.kind == ^kind)

  @doc """
  Dismiss many rows by id for `user_id`. Returns `{:ok, changed_ids}` — EXACTLY
  the ids this call transitioned, never merely the ids it was handed.

  The inbox is a to-do list, so ticking several things off is one gesture. This
  is `dismiss_by_source/4`'s write-then-single-broadcast shape keyed on a
  caller-supplied id list instead of a source triple: ONE `update_all`, then ONE
  coarse `{:inbox_changed, user_id}` — not N per-row events for an N-row sweep.

  ## Why the returned list is the point

  The `is_nil(i.dismissed_at)` filter does double duty. It keeps the write
  idempotent, and — because `RETURNING` reports only rows the statement actually
  touched — it makes the returned list precisely "what this call changed". A row
  the user dismissed an hour ago is silently skipped and is ABSENT from the
  result even when its id is passed.

  That absence is the contract an undo depends on: an undo built from this list
  can only ever restore rows this call dismissed, so it cannot resurrect
  something the user dismissed deliberately and earlier. Dropping the filter
  would still dismiss the right rows, and would still look correct — the damage
  would surface only later, as an undo reviving rows nobody asked back.

  Ordering is Postgres's and is not guaranteed; callers that compare should sort.

  Cross-user guarded like `mark_dismissed/2`: the `user_id` scope is part of the
  WHERE, so ids belonging to another user match nothing, mutate nothing, and are
  absent from the returned list.
  """
  @spec dismiss_many(Ecto.UUID.t(), [Ecto.UUID.t()]) :: {:ok, [Ecto.UUID.t()]}
  def dismiss_many(user_id, ids) do
    now = DateTime.utc_now()

    {_count, changed_ids} =
      Item
      |> where([i], i.user_id == ^user_id and i.id in ^ids and is_nil(i.dismissed_at))
      |> select([i], i.id)
      |> Repo.update_all(set: [dismissed_at: now])

    # One coarse broadcast for the whole sweep, mirroring `dismiss_by_source/4`:
    # shells recompute the badge and InboxLive re-derives its list once. A sweep
    # that changed nothing stays quiet.
    if changed_ids != [], do: broadcast_changed(user_id)

    {:ok, changed_ids}
  end

  @doc """
  Dismiss EVERY row the user's inbox surface is showing — the "Clear all" sweep.
  Returns `{:ok, changed_ids}` under exactly `dismiss_many/2`'s contract: the ids
  this call transitioned, and only those.

  ## Why this takes no id list

  "Clear all" must not be a clear-what-is-drawn. Handing the LiveView's rendered
  ids to `dismiss_many/2` would read the set in one query and write it in
  another, so a row that arrived in between survives a gesture that said "all" —
  and the surface would then re-derive and show it, which reads as the button
  having failed. Selecting and updating in ONE statement removes the gap: the
  scope is evaluated by Postgres at write time.

  ## The scope is `unread_scope/1`, and the rule is "clear what you can see"

  The governing rule is that the count on the button and the set this writes
  must be the SAME set, or the button lies — and an undo built from the write
  would restore rows into invisibility.

  `unread_scope/1` is what satisfies that: `/inbox` renders it and this clears
  it. One scope, so no call site has to guess. (Since task `01a11703` the rail
  badge counts the narrower `badge_scope/1`; the button's own count comes from
  the rendered sections, which are this scope.)

  This paragraph used to argue something narrower — that the sweep must skip
  read-but-not-dismissed rows, because such a row was absent from the surface
  and the button's count could not name it. Stage 4 of task `01a00108` retired
  read-as-cleared, so that case no longer exists: a row you opened is on the
  list, is in the count, and is therefore swept, which is correct under the
  same rule that previously excluded it. The rule did not change; what counts
  as visible did. Keep deriving both from `unread_scope/1` and this stays true
  through whatever the predicate becomes next.

  One `update_all`, then ONE coarse `{:inbox_changed, user_id}` — shells recompute
  the badge (rail, Dock icon and title prefix all hang off that one number) and
  `InboxLive` re-derives. A sweep that changed nothing stays quiet.
  """
  @spec dismiss_all_unread(Ecto.UUID.t()) :: {:ok, [Ecto.UUID.t()]}
  def dismiss_all_unread(user_id) do
    now = DateTime.utc_now()

    {_count, changed_ids} =
      user_id
      |> unread_scope()
      |> select([i], i.id)
      |> Repo.update_all(set: [dismissed_at: now])

    if changed_ids != [], do: broadcast_changed(user_id)

    {:ok, changed_ids}
  end

  @doc """
  Bring a dismissed briefing row back to the list: clears `dismissed_at`
  (only) on `briefing`'s row. A no-op when the row is live or absent.
  Called by `Platform.Memory.Insights.Briefings` when a handle or an undo
  leaves the briefing with an open item (task 01a15ee1 stage 6). Does not
  broadcast: the caller's `{:inbox_changed, user_id}` follows.
  """
  @spec relist_briefing_item(Platform.Memory.Briefing.t()) :: :ok
  def relist_briefing_item(%Platform.Memory.Briefing{id: id, user_id: user_id})
      when is_binary(id) and is_binary(user_id) do
    Item
    |> where(
      [i],
      i.user_id == ^user_id and i.kind == "briefing" and i.source_type == "briefing" and
        i.source_id == ^id and not is_nil(i.dismissed_at)
    )
    |> Repo.update_all(set: [dismissed_at: nil])

    :ok
  end

  def relist_briefing_item(_briefing), do: :ok

  @doc """
  The inverse of `dismiss_many/2`: clear `dismissed_at` for the given ids,
  returning `{:ok, restored_ids}`. Same single-write, single-broadcast shape and
  the same non-optional `user_id` scope.

  Note the deliberate asymmetry with `dismiss_many/2`: there is NO
  `not is_nil(i.dismissed_at)` guard here, so the returned list is every row the
  scope matched rather than only rows that changed state. Restoring an
  already-live row is a no-op on that row's value, and the caller that needs
  exactness — an undo — gets it from `dismiss_many/2`'s list, which is the one
  that has to be precise.
  """
  @spec restore_many(Ecto.UUID.t(), [Ecto.UUID.t()]) :: {:ok, [Ecto.UUID.t()]}
  def restore_many(user_id, ids) do
    {_count, restored_ids} =
      Item
      |> where([i], i.user_id == ^user_id and i.id in ^ids)
      |> select([i], i.id)
      |> Repo.update_all(set: [dismissed_at: nil])

    if restored_ids != [], do: broadcast_changed(user_id)

    {:ok, restored_ids}
  end

  @doc """
  Lazy reconciler: dismiss every live inbox row for `user_id` whose underlying
  subject can be POSITIVELY confirmed resolved.

  The operator's "simple & reliable" self-healing seam (no push coupling): rather than
  chase every resolution path to dismiss the row it produced, callers run this
  at load so a stale row drops off on next view. Eager per-actor clearing
  (`Meetings.maybe_dismiss_meeting_inbox/2`, the rollup dismiss on the last
  resolved review) stays in place as an OPTIMISATION beside this reconciler —
  never as the primary mechanism. If actors were the only mechanism then every
  future resolution path would have to remember, and the one that forgets
  leaves a stale row that looks live.

  ## The governing rule

  NEVER dismiss a row that cannot be positively confirmed dead. An unresolvable
  subject, a MISSING SOURCE ROW, or an unknown kind is NOT stale and survives —
  the catch-all `row_stale?/1` head returns `false`, and each predicate is
  written so its ambiguous answer means "still live". There is no optimistic
  reconciliation here: a surviving stale row is a small annoyance, a dismissed
  live row is lost attention.

  This is why the `task_plan_review` and `meeting_starting` clauses each pair
  their staleness predicate with an existence check. Stage 1's
  `Tasks.plan_pending_review?/1` and `Meetings.meeting_live?/1` answer `false`
  for two different worlds — the subject settled, and no such row — and only
  the first is a confirmation. The reconciler, not those predicates, is where
  the missing-row rule belongs, so they are unchanged.

  Nothing is stored to record the outcome — no `resolved_at` / `cleared_at`
  column, no migration. Staleness is DERIVED on read from the subject's own
  state, so it cannot disagree with that state the way a denormalised column
  could. Clearing goes through `mark_dismissed/2`, so the existing
  `{:inbox_item_dismissed, item}` broadcast and the badge and list scopes are
  unchanged.

  ## Per-kind clauses

    * `review_request_pending` — stale iff the resolved task has no pending
      review requests. Rows key their source three ways historically:
      `task_review` (the per-task rollup, `source_id` = task id), plain `task`,
      or the legacy per-request `review_request` (`source_id` = request id).
    * `chat_mention` (`source_type: "chat_message"`) — stale iff the user has
      read the message, per `Platform.Chat.message_read_by_user?/2`.
    * `task_plan_review` (`source_type: "task"`, `source_id` = TASK id) — stale
      iff the task has no plan in `pending_review`. This covers BOTH producers
      of the kind: the plan-settled emit and
      `Platform.Tasks.ArchitectureRejection`'s escalation row, whose subject is
      also a plan left sitting in `pending_review` for a human decision.
    * `meeting_starting` (`source_type: "meeting"`) — stale iff the meeting is
      no longer live. This closes the gap where a meeting ENDS without you ever
      joining: `Meetings.maybe_dismiss_meeting_inbox/2` fires at join time only,
      so nothing else would ever clear that row.
    * `briefing` (`source_type: "briefing"`, `source_id` = the
      `memory_briefings` id; task `01a15ee1` stages 1 and 6, ADR 0049) —
      stale iff the briefing row exists and its `digest_date` is older than
      the insight TTL (`Platform.Memory.Insight.default_ttl_days/0`).
      Handling every item does NOT clear it: the row stays listed for the
      day as "All done · nothing waiting". See
      `Platform.Memory.Insights.Briefings.inbox_row_stale?/2`.
    * `task_sponsor_assigned` — deliberately NO clause; see `row_stale?/1`.

  Cost: one indexed load of the user's live rows (indexed on `user_id`), then a
  single indexed EXISTS or id comparison per row. No preloads, no aggregates,
  no N+1 joins — this runs on a shell-mount path.

  Best-effort by design (`rescue -> :ok`): reconciliation is a convenience over
  the durable rows, and a reconciler that raises must never take down the mount
  that called it.
  """
  @spec reconcile_for_user(Ecto.UUID.t()) :: :ok
  def reconcile_for_user(user_id) when is_binary(user_id) do
    Repo.all(from(i in Item, where: i.user_id == ^user_id and is_nil(i.dismissed_at)))
    |> Enum.each(fn item ->
      if row_stale?(item), do: mark_dismissed(item.id, user_id)
    end)

    :ok
  rescue
    _ -> :ok
  end

  def reconcile_for_user(_), do: :ok

  # Whether a live row's subject is positively confirmed resolved. One head per
  # reconcilable kind; everything else falls to the catch-all and SURVIVES.
  defp row_stale?(%Item{kind: "review_request_pending"} = item), do: review_row_stale?(item)

  defp row_stale?(%Item{kind: "chat_mention", source_type: "chat_message"} = item) do
    Platform.Chat.message_read_by_user?(item.source_id, item.user_id)
  end

  # The existence check is not redundant. `plan_pending_review?/1` and
  # `meeting_live?/1` each answer `false` for TWO different worlds — the subject
  # settled, and no such row — and only the first is a positive confirmation.
  # Without the `_exists?` conjunct a row whose task or meeting cannot be found
  # would be dismissed on an unresolvable subject, which is the governing rule
  # violated exactly. It costs one extra primary-key EXISTS on these two kinds.
  defp row_stale?(%Item{kind: "task_plan_review", source_type: "task", source_id: task_id}) do
    Platform.Tasks.task_exists?(task_id) and not Platform.Tasks.plan_pending_review?(task_id)
  end

  defp row_stale?(%Item{kind: "meeting_starting", source_type: "meeting", source_id: meeting_id}) do
    Platform.Meetings.meeting_exists?(meeting_id) and
      not Platform.Meetings.meeting_live?(meeting_id)
  end

  defp row_stale?(%Item{kind: "briefing", source_type: "briefing", source_id: briefing_id}) do
    Platform.Memory.Insights.Briefings.inbox_row_stale?(briefing_id)
  end

  # DELIBERATE DECISION — do not add a `task_sponsor_assigned` clause without
  # reopening it. Sponsorship has no resolution EVENT; it is an ongoing state,
  # so there is nothing for a reconciler to observe becoming true. Task
  # completion is the only candidate and it is exactly wrong: a sponsor's row
  # means "you now own this", which becomes MORE relevant while the task runs,
  # not less. Clearing on completion would dismiss a row whose subject is still
  # true — the never-dismiss-what-you-cannot-confirm-dead rule violated from the
  # other direction. Sponsor rows are cleared by hand, when the sponsor opens
  # the task (`dismiss_sponsor_row_on_open/2`, task 01a116ff), or when the sponsor
  # opens the row from /inbox (`open_item/2`, task 01a11703, which dismisses
  # every kind outside `action_kinds/0`). Both are user actions, not
  # reconciler clauses, so the decision here is unchanged.
  # `inbox_test.exs` pins this: a sponsor row survives reconciliation even after
  # its task completes. If that test detonates, the decision is being changed
  # and must be reopened rather than patched.
  #
  # `meeting_invited` and `lifecycle_step_failed` land here too, for the same
  # reason in a weaker form: neither has a subject this module can positively
  # confirm dead today.
  defp row_stale?(%Item{}), do: false

  # Stale iff the resolved task has no pending review requests. Unresolvable
  # task ids (nil) are treated as NOT stale — we never dismiss a row we cannot
  # positively confirm is dead.
  defp review_row_stale?(item) do
    case review_row_task_id(item) do
      task_id when is_binary(task_id) ->
        not Platform.Tasks.ReviewRequests.task_has_pending_reviews?(task_id)

      _ ->
        false
    end
  end

  defp review_row_task_id(%Item{source_type: st, source_id: sid})
       when st in ["task", "task_review"],
       do: sid

  defp review_row_task_id(%Item{source_type: "review_request", source_id: sid}),
    do: Platform.Tasks.ReviewRequests.task_id_for_request(sid)

  defp review_row_task_id(_), do: nil

  defp set_timestamp(item_id, user_id, field) do
    case fetch_owned(item_id, user_id) do
      nil ->
        {:error, :not_found}

      %Item{} = item ->
        item
        |> Ecto.Changeset.change(%{field => DateTime.utc_now()})
        |> Repo.update()
    end
  end

  # The one owned-row lookup behind `mark_read/2`, `mark_dismissed/2` and
  # `open_item/2`: scoped by `id` AND `user_id`. `item_id` arrives from a
  # client event (`InboxLive` "open"/"dismiss"), so a malformed id is
  # `nil` (-> `{:error, :not_found}`) rather than an `Ecto.Query.CastError`.
  defp fetch_owned(item_id, user_id) do
    if Platform.UUID.valid?(item_id) and Platform.UUID.valid?(user_id) do
      Repo.one(from(i in Item, where: i.id == ^item_id and i.user_id == ^user_id))
    end
  end
end
