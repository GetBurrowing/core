defmodule Platform.Chat do
  @moduledoc """
  Core context for all Chat domain operations.

  Covers spaces, participants, messages, threads, reactions, pins,
  canvases, and attachments. Telemetry events are emitted for key writes
  and bridged to the audit log via `Platform.Chat.TelemetryHandler`.

  ## Quick reference

      # Spaces
      Platform.Chat.create_space(%{name: "General", slug: "general", kind: "channel"})
      Platform.Chat.list_spaces(workspace_id: id, kind: "channel", archived: false)

      # Participants
      Platform.Chat.add_participant(space.id, %{participant_type: "user", participant_id: uid, display_name: "Ada", joined_at: DateTime.utc_now()})
      Platform.Chat.add_participant(space.id, %{participant_type: "agent", participant_id: agent.id, display_name: agent.name, joined_at: DateTime.utc_now()})
      Platform.Chat.list_participants(space.id)

      # `display_name` is resolved from the `agents` / `users` row when omitted,
      # but pass it explicitly when you have it. A blank agent name used to be
      # written as NULL, which silently dropped every `@[Name]` mention of that
      # agent — see `resolve_display_name/1` and ADR 0037.

      # Messages
      Platform.Chat.post_message(%{space_id: id, participant_id: pid, content_type: "text", content: "hello"})
      Platform.Chat.list_messages(space.id, limit: 50, before_id: cursor_id)
      Platform.Chat.search_messages(space.id, "elixir phoenix", limit: 20)

      # Threads
      Platform.Chat.create_thread(space.id, %{parent_message_id: msg.id, title: "Discussion"})
      Platform.Chat.get_thread_for_message(msg.id)

      # Reactions / Pins / Canvases / Attachments
      Platform.Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "👍"})
      Platform.Chat.pin_message({:user, user.id}, %{space_id: space.id, message_id: msg.id})
      Platform.Chat.create_canvas_with_message(space.id, p.id, %{title: "Sprint board"})
      Platform.Chat.list_reactions_for_messages([msg1.id, msg2.id])
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Platform.Agents.{Agent, AgentRuntime}

  alias Platform.Chat.{
    Attachment,
    Canvas,
    Message,
    MessageAttention,
    Participant,
    Pin,
    Reaction,
    Space,
    Thread
  }

  alias Platform.Chat.CanvasAccess
  alias Platform.Chat.CanvasSearchIndex
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Canvas.Versions, as: CanvasVersions
  alias Platform.Chat.MentionIdentity
  alias Platform.Chat.MessageVersions
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.SpaceAccess
  alias Platform.Repo
  alias Platform.Tenancy

  # ── Spaces ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new chat space (channel, dm, or group).

  Required attrs: `:name`, `:slug`, `:kind`.
  Optional: `:workspace_id`, `:description`, `:topic`, `:metadata`.
  """
  @spec create_space(map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def create_space(attrs) do
    result =
      %Space{}
      |> Space.changeset(attrs)
      |> Platform.Tenancy.Lifecycle.guard_org_active()
      |> Repo.insert()

    case result do
      {:ok, space} ->
        :telemetry.execute(
          [:platform, :chat, :space_created],
          %{system_time: System.system_time()},
          %{space_id: space.id, slug: space.slug, kind: space.kind}
        )

        # Attach the role-pinned historian agent BEFORE broadcasting the
        # space so subscribers that render the roster on :space_created
        # see the historian already present — no "channel appeared →
        # historian joined a beat later" UI flicker.
        maybe_add_historian(space)

        # Seat a channel's recorded creator as its admin (task
        # 01a0fd62-a7ef-7001-8477-bd17e47bbaca), BEFORE the broadcast for the
        # same reason as the historian above: a subscriber rendering the roster
        # on :space_created sees the admin already present. Without this no
        # code path granted a user `role: "admin"` in a channel, so
        # `mention_summon_authorized?/2` was false for every human author.
        maybe_seat_creator_admin(space)

        # Broadcast on the global space-lifecycle topic so connected chat
        # sessions can surface the new channel without requiring a refresh.
        ChatPubSub.broadcast_space_event({:space_created, space})

      _ ->
        :ok
    end

    result
  end

  # DMs are private-to-participants by contract — no observer agents.
  defp maybe_add_historian(%Space{kind: "dm"}), do: :ok
  # `system-*` slugs are Historian's own dispatch spaces; self-join is a no-op.
  defp maybe_add_historian(%Space{slug: "system-" <> _}), do: :ok
  # Any space without a slug (e.g. execution spaces) is out of scope; the
  # historian roster surface keys off slug-visible spaces today.
  defp maybe_add_historian(%Space{slug: nil}), do: :ok

  defp maybe_add_historian(%Space{slug: slug} = space) when is_binary(slug) do
    case Platform.Roles.agent_id_for_role("historian") do
      nil ->
        :ok

      historian_id ->
        # Defense-in-depth: `add_agent_participant/3` is already idempotent
        # (returns `{:ok, existing}` on duplicate) but skipping explicitly
        # keeps the log clean and makes intent obvious to future readers.
        case get_agent_participant(space.id, historian_id) do
          %Participant{} -> :ok
          nil -> attach_historian(space, historian_id, slug)
        end
    end
  rescue
    err ->
      Logger.warning(
        "[Chat.create_space] historian attach raised for slug=#{inspect(space.slug)}: " <>
          Exception.message(err)
      )

      :ok
  end

  # Channels only. DM and group creation stamp `created_by` AND seat their own
  # participants, so seating here would collide with their rows; the kind guard
  # is what keeps those paths untouched. A channel created without a user
  # creator (MCP `space_create`, where an agent is the creator) seats no one.
  defp maybe_seat_creator_admin(%Space{kind: "channel", created_by: user_id} = space)
       when is_binary(user_id) do
    seat_creator_admin(space, user_id)
  rescue
    err ->
      Logger.warning(
        "[Chat.create_space] creator admin seat raised for space_id=#{space.id}: " <>
          Exception.message(err)
      )

      :ok
  end

  defp maybe_seat_creator_admin(_space), do: :ok

  # Mirrors `Platform.Federation.Peers.SharedSpaces.seat_admin/2`. If a row for
  # the creator already exists (a race with `ChatLive.ensure_participant/2`),
  # ONLY that row's role is promoted; nothing else on it is rewritten.
  defp seat_creator_admin(space, user_id) do
    attrs = %{
      participant_type: "user",
      participant_id: user_id,
      role: "admin",
      display_name: user_display_name(user_id),
      joined_at: DateTime.utc_now()
    }

    case add_participant(space.id, attrs) do
      {:ok, _participant} ->
        :ok

      {:error, reason} ->
        case Repo.get_by(Participant,
               space_id: space.id,
               participant_type: "user",
               participant_id: user_id
             ) do
          %Participant{role: "admin"} ->
            :ok

          %Participant{} = existing ->
            {:ok, _} = update_participant(existing, %{role: "admin"})
            :ok

          nil ->
            Logger.warning(
              "[Chat.create_space] creator admin seat failed for space_id=#{space.id}: " <>
                inspect(reason)
            )

            :ok
        end
    end
  end

  defp attach_historian(space, historian_id, slug) do
    case add_agent_participant(space.id, historian_id, attention_mode: "heartbeat") do
      {:ok, _participant} ->
        Logger.info(
          "[Chat.create_space] auto-joined historian to space slug=#{slug} " <>
            "historian_id=#{historian_id}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[Chat.create_space] historian attach failed for slug=#{slug}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # System-minted slug prefixes. Spaces behind these are created by
  # orchestration code paths (meetings, task execution, DM/group creation) and
  # MAY carry `org_id = NULL` — meeting and DM spaces are cross-org BY DESIGN,
  # and exec spaces predate the org_id backfill. Any org-scoped slug lookup
  # therefore CANNOT match them: `where s.org_id == ^org_id` never matches
  # NULL.
  #
  # This list is the guard on every unscoped slug fallback, and it is the
  # reason those fallbacks do not weaken ADR-0042 per-org channel scoping
  # ("#general" in one tenant vs another): a USER-CREATED channel slug can
  # never carry one of these prefixes, so it never reaches an unscoped lookup.
  #
  # Lives here, not in a caller, because two independent call sites need the
  # SAME list — `ChatLive.system_prefix_fallback/1` (which renders the space)
  # and `ExternalUserScope.resolve_space/2` (which admits the request to it).
  # They drifted once already: the LiveView gained the fallback and the plug
  # did not, so the plug denied an invited member their own meeting's chat
  # before the authorizer ever ran. Do not re-inline a private copy.
  @reserved_slug_prefixes ~w(meeting- task-exec- dm- group-)

  @doc """
  True when `slug` names a system-minted space (meeting, task-exec, DM, group).

  Callers use this to decide whether an org-scoped slug miss may retry
  unscoped. It answers a question about the SLUG only — it is not an
  authorization check and grants nothing on its own.
  """
  @spec reserved_slug_prefix?(term()) :: boolean()
  def reserved_slug_prefix?(slug) when is_binary(slug) do
    Enum.any?(@reserved_slug_prefixes, &String.starts_with?(slug, &1))
  end

  def reserved_slug_prefix?(_slug), do: false

  @doc """
  Fetch a space by primary key. Returns `nil` if not found.

  ## Options

    * `:scope` — an optional `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`. When it is an
      external scope, a space the user does not participate in resolves to
      `nil` (a 404-shaped miss, not a leak). Absent / nil / internal scopes are
      pass-through, so `get_space/1` and every existing caller are unchanged.
  """
  @spec get_space(binary(), keyword()) :: Space.t() | nil
  def get_space(id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    # This is the PR #613 site. `space_id` arrives verbatim from MCP tool
    # arguments and from the `/chat/:slug` URL segment, so it is routinely a
    # channel slug rather than a UUID. Guard with Platform.UUID.valid?/1 —
    # a bare Ecto.UUID.cast/1 accepts any 16-byte binary, so a 16-character
    # slug clears it and still raises inside Repo. Do not "simplify".
    if Platform.UUID.valid?(id) do
      case Repo.get(Space, id) do
        nil -> nil
        space -> if ExternalScope.visible_space_id?(id, scope), do: space, else: nil
      end
    else
      nil
    end
  end

  @doc """
  The canonical `/chat/:space_slug` path segment for a space.

  THE single definition of "how a space is addressed in a URL". Every producer
  of a chat link — the sidebar rail, the mobile pinned strip, a settings
  redirect, the @mention inbox row — must route through this function.
  `PlatformWeb.ChatLive.space_nav_target/1` delegates here and exists only as
  the web-layer alias the templates already import.

  The rule:

    * **org-scoped space** (non-nil `org_id`, post-ADR-0042) → the space UUID.
      A uuid segment hits `handle_params/3`'s `Chat.get_space/1` fallback
      exactly, bypassing the slug-then-org-resolve cascade that routes an
      ambiguous slug (e.g. "general", which now exists once per tenant) to the
      reader's PRIMARY membership org rather than the org of the space the link
      actually points at.
    * **org-less space** → `slug || id`. Legacy pre-ADR-0042 channels keep
      their shareable slug URL; DM and group spaces have NO slug at all
      (`create_dm_space/3` inserts only `kind`/`is_direct`/`created_by`, and
      `Space.validate_channel_fields/1` requires a slug only for
      `kind: "channel"`), so they address by id.

  Task 019fabe8: the @mention inbox producer used to interpolate `space.slug`
  raw. For a DM or group that rendered `"/chat/?message=<uuid>"`, which does
  not match `/chat/:space_slug` at all — the reader fell through to the
  catch-all clause and was pushed to their FIRST CHANNEL. A mention in a DM
  did not land at the wrong position; it landed in the wrong conversation.

  Map-pattern signature so it works on a loaded `%Space{}` and on any plain map
  carrying `:org_id` / `:slug` / `:id` (e.g. test fixtures).

  An EMPTY slug is treated as no slug. `space_nav_target/1` used a bare
  `slug || id`, which is fine for a `NULL` column but returns `""` for an empty
  string — and an empty segment is the precise failure this function exists to
  prevent. The guarantee is: the result is always a non-empty binary.
  """
  @spec space_path_segment(map()) :: String.t()
  def space_path_segment(%{org_id: org_id, id: id}) when not is_nil(org_id), do: id
  def space_path_segment(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  def space_path_segment(%{id: id}), do: id

  @doc """
  Resolve a `/chat/:space_slug` path segment back to its space — the inverse of
  `space_path_segment/1`.

  Read-only and deliberately UNSCOPED: the only consumer today is the inbox
  mention row, which needs a human label for a space the viewer already holds
  an inbox row for. It renders a NAME, never message content, so there is no
  scope to leak through it. Anything that renders space CONTENT must keep using
  the org-scoped `get_space_by_slug/2` + `get_space/1` cascade in
  `ChatLive.handle_params/3`.

  Returns `nil` for an unknown segment; it NEVER creates a space.
  """
  @spec space_for_path_segment(String.t() | nil) :: Space.t() | nil
  def space_for_path_segment(segment) when is_binary(segment) and segment != "" do
    if Platform.UUID.valid?(segment) do
      Repo.get(Space, segment)
    else
      get_space_by_slug(segment, [])
    end
  end

  def space_for_path_segment(_), do: nil

  @doc """
  Fetch a space by slug.

  ## Options

    * `:org_id` — when present, scope the lookup to a single org. The partial
      unique index `chat_spaces_unique_org_slug` guarantees at most one match
      per `(org_id, slug)` pair, so the result is deterministic without an
      `order_by + limit`. Use this for any URL flow where the active org can
      be derived from the user's session (e.g. `/chat/general` resolving to
      *this user's* tenant General, not the oldest cross-tenant match).

    * `:scope` — optional `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`. For an external
      scope a slug outside the caller's participant set resolves to `nil`
      (a 404, not a leak). Absent / nil / internal scopes are pass-through.

  When `:org_id` is absent (or nil), the legacy behavior is preserved: the
  oldest matching row by `inserted_at` is returned. This back-compat path is
  what every pre-existing caller relies on — system-channel lookups,
  bootstrap_space retries, dev-login add-to-general — none of which carry an
  org context.

  Returns `nil` if no row matches.
  """
  @spec get_space_by_slug(String.t(), keyword()) :: Space.t() | nil
  def get_space_by_slug(slug, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    query = where(Space, [s], s.slug == ^slug)
    query = ExternalScope.scope_spaces(query, scope)

    query =
      case Keyword.get(opts, :org_id) do
        nil ->
          # Back-compat path: oldest match wins, matching the pre-opts
          # behavior so callers that never learned about org scoping keep
          # working unchanged.
          query |> order_by([s], asc: s.inserted_at) |> limit(1)

        org_id when is_binary(org_id) ->
          # Org-scoped path: the partial unique index makes this a single
          # deterministic row, no `limit/1` needed.
          where(query, [s], s.org_id == ^org_id)
      end

    Repo.one(query)
  end

  @doc """
  Fetch the ORG-LESS space with this slug, if there is one.

  Deliberately narrower than `get_space_by_slug(slug, [])`: that back-compat
  branch returns the OLDEST row of any org, so a Globex channel would answer a
  root-org member's lookup and ADR-0042's per-org slug scoping would be weakened.
  This one matches `org_id IS NULL` explicitly and can therefore never hand
  back another tenant's channel.

  Exists for `ChatLive.bootstrap_space/2` (task 01a00910 stage 5): a channel
  created without an org (the pre-fix "+ New channel" dialog, and every
  historical org-less row) is invisible to the org-scoped mount lookup, which
  used to conclude "no such channel" and INSERT A SECOND ROW for the same slug
  244ms later. See `chat_live_bootstrap_duplicate_test.exs`.
  """
  @spec get_orgless_space_by_slug(String.t()) :: Space.t() | nil
  def get_orgless_space_by_slug(slug) when is_binary(slug) do
    Space
    |> where([s], s.slug == ^slug and is_nil(s.org_id))
    |> order_by([s], asc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_orgless_space_by_slug(_), do: nil

  @doc """
  List spaces with optional filters.

  ## Options

    * `:workspace_id` — filter by workspace
    * `:kind`         — filter by kind ("channel", "dm", "group")
    * `:archived`     — `true` for archived only, `false` (default) for active only
    * `:scope`        — optional `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`. For an
      external scope the result is narrowed to the caller's participant spaces
      (so `list_spaces(kind: "channel", scope: ext)` returns ONLY their
      channels, never the full channel set). Absent / nil / internal scopes are
      pass-through.

  Spaces flagged for deletion (`deletion_scheduled_at` set, task 019e95ea
  stage 3) are excluded from BOTH branches: the default branch already
  excludes them because scheduling sets `archived_at`, and the archived
  branch filters them explicitly so the sidebar's Archived section never
  shows a channel pending deletion.
  """
  @spec list_spaces(keyword()) :: [Space.t()]
  def list_spaces(opts \\ []) do
    {archived, opts} = Keyword.pop(opts, :archived, false)
    {include_execution, opts} = Keyword.pop(opts, :include_execution, false)
    {scope, opts} = Keyword.pop(opts, :scope)

    base =
      if archived do
        from(s in Space,
          where: not is_nil(s.archived_at) and is_nil(s.deletion_scheduled_at),
          order_by: [asc: s.inserted_at]
        )
      else
        from(s in Space, where: is_nil(s.archived_at), order_by: [asc: s.inserted_at])
      end

    # Exclude execution spaces by default
    base =
      if include_execution do
        base
      else
        where(base, [s], s.kind != "execution")
      end

    opts
    |> Enum.reduce(base, fn
      # `workspace_id: nil` means "match spaces with NULL workspace_id" (the
      # single-tenant / default-org case), not "skip the filter". Ecto refuses
      # to compare against nil so we must branch to `is_nil/1`.
      {:workspace_id, nil}, q -> where(q, [s], is_nil(s.workspace_id))
      {:workspace_id, wid}, q -> where(q, [s], s.workspace_id == ^wid)
      {:kind, kind}, q -> where(q, [s], s.kind == ^kind)
      _other, q -> q
    end)
    |> ExternalScope.scope_spaces(scope)
    |> Repo.all()
  end

  @doc """
  List EVERY recoverable channel for the recovery surface — `kind: "channel"`
  spaces with `archived_at` set, **both** the independently-archived ones and
  the cascade-hidden children of an archived/deletion-scheduled org (i.e. no
  `archived_cascade_org_id` filter, unlike the sidebar's `list_spaces/1`).

  Both the plain-archived and the deletion-scheduled states are returned
  (scheduling also stamps `archived_at`), ordered deletion-scheduled first
  (soonest deadline first — the rows the admin most needs to act on) then by
  name. The same ordering as `Tasks.list_recoverable_projects/0` and
  `Tenancy.list_archived_tenants/0`, so the recovery surface buckets the two
  states consistently across all three entity types.

  Scoped to `kind: "channel"` on purpose: execution spaces are task audit
  logs (recovering one would be meaningless — the deletion path already
  refuses them), and dm/group/meeting spaces are not recovery targets. The
  unified recovery row this feeds (`Platform.Tenancy.Lifecycle.list_recoverable/0`)
  types every space row as `:channel`, matching `cascade_hidden/1` /
  `cascade_preview/1`.

  `archived_cascade_org_id` is left on each struct so the caller can tell an
  independently-archived channel from a cascade child and resolve the org the
  child hangs off. Read-only companion to `list_spaces/1`; lifecycle mutators
  live in `archive_space/2`, `schedule_space_deletion/2`, `unarchive_space/2`.
  """
  @spec list_archived_spaces() :: [Space.t()]
  def list_archived_spaces do
    Space
    |> where([s], s.kind == "channel" and not is_nil(s.archived_at))
    |> Repo.all()
    |> Enum.sort_by(fn s ->
      {s.deletion_scheduled_at || ~U[9999-01-01 00:00:00.000000Z], s.name}
    end)
  end

  @doc "List spaces an agent is a member of via the `chat_participants` roster."
  @spec list_spaces_for_agent(binary(), keyword()) :: [Space.t()]
  def list_spaces_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    kind = Keyword.get(opts, :kind)

    base =
      from(s in Space,
        join: p in Participant,
        on: p.space_id == s.id,
        where:
          p.participant_type == "agent" and
            p.participant_id == ^agent_id and
            is_nil(s.archived_at),
        order_by: [asc: s.inserted_at]
      )

    base = if kind, do: where(base, [s], s.kind == ^kind), else: base
    Repo.all(base)
  end

  @doc """
  List the space_ids a human user is a `chat_participants` member of.

  Participation-only, with NO org fence. Two live consumers, deliberately
  different in kind:

    * the allowlisted set for external-user presence/typing scope
      (rbac-external-users M10), read by
      `Platform.Chat.Presence.external_scope_space_ids/1`;
    * `PlatformWeb.ShellLive`'s chat subscribe set: the `chat:space:<id>`
      topics the shell holds so the rail badge can move on a live post from
      `/tasks` and every other surface.

  Mirrors `list_spaces_for_agent/2` but keyed on a `participant_type: "user"`
  participant and selecting `p.space_id` rather than the `Space` structs.
  Archived spaces are excluded (`s.archived_at IS NULL`); `chat_participants`
  has no `archived_at` column of its own (see the `Participant` schema), so
  membership is scoped purely on the space's archive state, exactly as
  `list_spaces_for_agent/2` does for agents. An optional `:kind` opt filters
  `s.kind`.

  Delegates to `participant_spaces_query/1`; see the comment there for why this
  direction carries no org fence and where the fence still applies.
  """
  @spec list_member_space_ids(binary(), keyword()) :: [binary()]
  def list_member_space_ids(user_id, opts \\ []) when is_binary(user_id) do
    kind = Keyword.get(opts, :kind)

    base = participant_spaces_query(user_id)
    base = if kind, do: where(base, [space: s], s.kind == ^kind), else: base

    base
    |> select([participant: p], p.space_id)
    |> Repo.all()
  end

  @doc """
  List the space ids whose presence a given viewer is allowed to observe.

  Two independent gates, deliberately, because either one alone has already
  failed elsewhere in this codebase:

    * **membership is the grant** — the viewer must hold a
      `participant_type: "user"` row on a non-archived space, exactly the
      query shape `list_member_space_ids/2` uses.
    * **org visibility is the fence** — the resolved `t:Platform.Tenancy.visibility/0`
      is applied via `Tenancy.scope/3` against the `:space` binding, so the
      org narrowing lands on `chat_spaces.org_id` rather than on the
      participant row. A viewer resolving to `:none` therefore gets `[]`,
      never everything.

  Returns EVERY space kind, and it has to stay that way, because
  `Platform.Chat.Presence` reads this list and narrowing it here would silently
  shrink presence. A caller that wants fewer kinds adds its own predicate to
  the query it builds on, the way `countable_participant_rows/1` does.

  This is the ORG-FENCED direction and its only live consumer is
  `Platform.Chat.Presence.list_online_for_viewer/1`, which is the
  identity-exposure boundary: it carries other people's names. The shell's
  chat subscribe set and the rail badge's count read
  `participant_spaces_query/1` instead.

  Takes the loaded user struct (not an id) so `Tenancy.visibility/1` can take
  its zero-query preloaded-`:org_memberships` clause. Anything that is not a
  user struct with a binary id returns `[]`.
  """
  @spec list_viewer_presence_space_ids(map() | nil) :: [binary()]
  def list_viewer_presence_space_ids(%{id: user_id} = user) when is_binary(user_id) do
    user_id
    |> viewer_spaces_query(Tenancy.visibility(user))
    |> select([participant: p], p.space_id)
    |> Repo.all()
  end

  def list_viewer_presence_space_ids(_user), do: []

  # THE PARTICIPATION SEAM. "Spaces this viewer holds a non-archived
  # `participant_type: "user"` row on", as a QUERY rather than a result set, so
  # a caller can add its own predicate AND its own select before running it.
  # Both bindings are NAMED (`as: :participant`, `as: :space`), so callers
  # filter and select through the names and inserting another join here cannot
  # silently move what a positional `[_p, s]` pattern points at.
  #
  #   * NAMING, stated once, here: `viewer_*` means org-fenced; `member_*` and
  #     `participant_*` mean participation-only.
  #   * THE FENCE WAS REMOVED FROM THIS DIRECTION ON PURPOSE (task
  #     `01a01f4c`). `unread_counts_for_user/1`, which feeds the per-channel
  #     pills the reader already sees, has never been org-fenced, so the fence
  #     on the badge was redundant with participation and contradicted a
  #     surface that had already shipped: the badge disagreed with the pills.
  #   * CONTAINMENT, NOT EQUALITY, and it is not symmetric. The count is a
  #     SUBSET of the subscribe set: a counted space whose events never reach
  #     the shell freezes the badge at a wrong number, while a subscribed but
  #     uncounted space costs one redundant recompute returning the same
  #     integer. Enforced by shared construction rather than by a claim in a
  #     comment: `countable_participant_rows/1` is this query plus one kind
  #     predicate. Equality is unreachable, because the subscribe set must stay
  #     all-kinds or `presence_diff` stops reaching the shell for meeting and
  #     execution spaces.
  #   * STILL FENCED: `list_viewer_presence_space_ids/1` above, via
  #     `viewer_spaces_query/2`. See its `@doc` for why.
  #   * CONSIDERED AND REJECTED: a `PlatformWeb.SpaceTopics` owner of its own
  #     for the rail badge. `:chat_rail` is not free (it is `ChatLive`'s rail
  #     owner, and sharing it invites the cross-surface unsubscribe collision
  #     `space_topics.ex` exists to prevent), and a genuinely new atom in
  #     `@owners` would produce an IDENTICAL registry state. `Tenancy.scope/3`
  #     can only remove rows, so the fenced set is a subset of the member set,
  #     and `hold/3` registers only on an empty holder set. It buys nothing and
  #     costs a second release path in the shell's revocation branch.
  defp participant_spaces_query(user_id) when is_binary(user_id) do
    from(p in Participant,
      as: :participant,
      join: s in Space,
      as: :space,
      on: s.id == p.space_id,
      where:
        p.participant_type == "user" and
          p.participant_id == ^user_id and
          is_nil(s.archived_at)
    )
  end

  # The org-fenced projection of the seam: "participates in AND is allowed to
  # see". Everything else about it is documented on
  # `participant_spaces_query/1` and on `list_viewer_presence_space_ids/1`.
  defp viewer_spaces_query(user_id, vis) when is_binary(user_id) do
    user_id
    |> participant_spaces_query()
    |> Tenancy.scope(vis, binding: :space)
  end

  @doc "Update a space's attributes."
  @spec update_space(Space.t(), map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def update_space(%Space{} = space, attrs) do
    space
    |> Space.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Assign a channel space to an org by setting `chat_spaces.org_id`.

  This is the Stage-1 seam (chat sidebar v2) that replaces name-pattern
  bucketing: a channel's sub-org membership becomes a real FK to `orgs.id`.
  Pass `org_id = nil` to clear the assignment.
  """
  @spec assign_space_org(Space.t(), binary() | nil) ::
          {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def assign_space_org(%Space{} = space, org_id) when is_binary(org_id) or is_nil(org_id) do
    update_space(space, %{org_id: org_id})
  end

  @doc """
  Soft-archive a space by setting `archived_at` to now.

  System-level variant — performs NO authorization. Reserved for internal
  lifecycle callers (e.g. `Platform.Orchestration.ExecutionSpace` archiving
  an execution space at task completion). User-initiated archives must go
  through `archive_space/2`, which authorizes the actor.
  """
  @spec archive_space(Space.t()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def archive_space(%Space{} = space) do
    space
    |> Space.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
    |> tap_space_lifecycle_telemetry(:space_archived, nil)
  end

  @doc """
  User-initiated archive. Allowed for root-org admins and the space's creator
  (`created_by`); returns `{:error, :unauthorized}` for anyone else. The
  check lives here in the context layer — LiveView assigns are UI affordance
  only, never the gate.
  """
  @spec archive_space(map(), Space.t()) ::
          {:ok, Space.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def archive_space(actor, %Space{} = space) do
    with_space_lifecycle_authz(actor, space, fn ->
      space
      |> Space.changeset(%{archived_at: DateTime.utc_now()})
      |> Repo.update()
      |> tap_space_lifecycle_telemetry(:space_archived, actor)
    end)
  end

  @doc """
  Reverse an archive by clearing `archived_at`, `deletion_scheduled_at` and
  `archived_cascade_org_id`.

  System-level variant — performs NO authorization, mirroring `archive_space/1`.
  Reserved for internal lifecycle callers (e.g.
  `Platform.Orchestration.ExecutionSpace.find_or_create/1` reviving an
  execution space a write path is about to attach live state to). There is no
  actor on that path, so there is nobody to authorize. User-initiated
  unarchives must go through `unarchive_space/2`, which authorizes the actor.
  """
  @spec unarchive_space(Space.t()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def unarchive_space(%Space{} = space) do
    space
    |> Space.changeset(%{
      archived_at: nil,
      deletion_scheduled_at: nil,
      archived_cascade_org_id: nil
    })
    |> Repo.update()
    |> tap_space_lifecycle_telemetry(:space_unarchived, nil)
  end

  @doc """
  Reverse an archive by clearing `archived_at`. Same authorization as
  `archive_space/2`: root-org admin or space creator.
  """
  @spec unarchive_space(map(), Space.t()) ::
          {:ok, Space.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def unarchive_space(actor, %Space{} = space) do
    with_space_lifecycle_authz(actor, space, fn ->
      space
      |> Space.changeset(%{
        archived_at: nil,
        deletion_scheduled_at: nil,
        archived_cascade_org_id: nil
      })
      |> Repo.update()
      |> tap_space_lifecycle_telemetry(:space_unarchived, actor)
    end)
  end

  defp with_space_lifecycle_authz(actor, %Space{} = space, fun) do
    if Platform.Tenancy.root_admin?(actor) or space_creator?(actor, space) do
      fun.()
    else
      {:error, :unauthorized}
    end
  end

  defp space_creator?(%{id: user_id}, %Space{created_by: created_by})
       when is_binary(user_id) and is_binary(created_by),
       do: user_id == created_by

  defp space_creator?(_actor, _space), do: false

  @doc """
  Flag a channel for permanent deletion (task 019e95ea stage 3).

  Root-admin only — deletion is destructive, so unlike `archive_space/2`
  the space's creator does NOT qualify. Only `kind: "channel"` spaces are
  deletable: execution spaces are task audit logs (deleting them corrupts
  task history), and dm/group conversations are out of scope — all return
  `{:error, :not_deletable}`.

  Sets `archived_at` (when not already archived) and `deletion_scheduled_at`
  in one update, so the stage-1 write freeze applies immediately. The
  channel disappears from every listing/search surface at once, and
  `Platform.Chat.SpacePurger` hard-deletes it after `space_retention_days/0`
  days unless `cancel_space_deletion/2` intervenes first.
  """
  @spec schedule_space_deletion(map(), Space.t()) ::
          {:ok, Space.t()} | {:error, :unauthorized | :not_deletable | Ecto.Changeset.t()}
  def schedule_space_deletion(actor, %Space{} = space) do
    cond do
      not Platform.Tenancy.root_admin?(actor) ->
        {:error, :unauthorized}

      space.kind != "channel" ->
        {:error, :not_deletable}

      true ->
        now = DateTime.utc_now()
        deadline = DateTime.add(now, space_retention_days(), :day)

        attrs =
          if space.archived_at,
            do: %{deletion_scheduled_at: now},
            else: %{deletion_scheduled_at: now, archived_at: now}

        space
        |> Space.changeset(attrs)
        |> Repo.update()
        |> tap_space_lifecycle_telemetry(:space_deletion_scheduled, actor, %{
          retention_deadline: DateTime.to_iso8601(deadline)
        })
    end
  end

  @doc """
  Cancel a scheduled deletion (root-admin only, task 019e95ea stage 3).

  Clears `deletion_scheduled_at` but leaves `archived_at` — the channel
  returns to the plain archived state; `unarchive_space/2` is the separate
  existing path back to active. Returns `{:error, :not_scheduled}` when no
  deletion is pending.
  """
  @spec cancel_space_deletion(map(), Space.t()) ::
          {:ok, Space.t()} | {:error, :unauthorized | :not_scheduled | Ecto.Changeset.t()}
  def cancel_space_deletion(actor, %Space{} = space) do
    cond do
      not Platform.Tenancy.root_admin?(actor) ->
        {:error, :unauthorized}

      is_nil(space.deletion_scheduled_at) ->
        {:error, :not_scheduled}

      true ->
        space
        |> Space.changeset(%{deletion_scheduled_at: nil, archived_cascade_org_id: nil})
        |> Repo.update()
        |> tap_space_lifecycle_telemetry(:space_deletion_cancelled, actor)
    end
  end

  @doc """
  Days a deletion-flagged channel is retained (still cancellable) before
  `Platform.Chat.SpacePurger` hard-deletes it. Configurable via
  `config :platform, :space_retention_days`; defaults to 30.
  """
  @spec space_retention_days() :: pos_integer()
  def space_retention_days do
    Application.get_env(:platform, :space_retention_days, 30)
  end

  # Bridged into the append-only audit log by `Platform.Audit.TelemetryHandler`.
  # `extra` is merged into the metadata map for event-specific keys (e.g.
  # `retention_deadline` on :space_deletion_scheduled) — values must be
  # JSON-safe scalars (stringify DateTimes) so the audit bridge persists them.
  defp tap_space_lifecycle_telemetry(result, event, actor, extra \\ %{}) do
    with {:ok, %Space{} = space} <- result do
      :telemetry.execute(
        [:platform, :chat, event],
        %{system_time: System.system_time()},
        Map.merge(
          %{
            actor_id: actor && Map.get(actor, :id),
            actor_type: if(actor, do: "user", else: "system"),
            resource_type: "chat_space",
            resource_id: space.id,
            action: Atom.to_string(event),
            space_kind: space.kind,
            space_name: space.name
          },
          extra
        )
      )
    end

    result
  end

  # ── Conversations (DM / Group / Channel creation) ─────────────────────────

  @doc """
  Is `initiator_user_id` allowed to open/hold a DM with the given target?

  The single, reusable server-side predicate composing M1's
  `Platform.Tenancy.may_dm_org?/2`. Both the DM/conversation CREATE seam
  (`find_or_create_dm/4`, `create_group_conversation/3`) and the message
  SEND seam (`ensure_dm_send_allowed/2`) call this so enforcement never
  diverges between the two.

  Rules:

    * Internal initiator (`not Tenancy.external_user?/1`) → `true`.
      Internal users keep today's unrestricted DM behavior; this predicate
      only constrains external initiators.
    * External initiator, `target_type == "agent"` → `false`. Deliberate
      deny: the external chat surface is scoped to allowlisted humans;
      agent DMs are out of scope for external users.
    * External initiator, `target_type == "user"` → `true` iff ANY of the
      target's orgs is in the initiator's DM allowlist. This uniformly
      covers external→allowlisted-org member AND Globex↔Globex (a second
      external user whose org is the same allowlisted org).
  """
  @spec external_dm_permitted?(binary(), String.t(), binary()) :: boolean()
  def external_dm_permitted?(initiator_user_id, target_type, target_id) do
    cond do
      not Tenancy.external_user?(%{id: initiator_user_id}) ->
        true

      target_type == "agent" ->
        false

      target_type == "user" ->
        %{id: target_id}
        |> Tenancy.list_user_memberships()
        |> Enum.map(& &1.org_id)
        |> Enum.any?(&Tenancy.may_dm_org?(initiator_user_id, &1))

      true ->
        false
    end
  end

  @doc """
  Find an existing DM between initiator and target, or create one.

  `target_type` is "user" or "agent", `target_id` is the UUID.
  Returns `{:ok, space}`.
  """
  @spec find_or_create_dm(binary(), String.t(), binary(), keyword()) ::
          {:ok, Space.t()} | {:error, :dm_not_allowed | term()}
  def find_or_create_dm(user_id, target_type, target_id, _opts \\ []) do
    if external_dm_permitted?(user_id, target_type, target_id) do
      do_find_or_create_dm(user_id, target_type, target_id)
    else
      {:error, :dm_not_allowed}
    end
  end

  defp do_find_or_create_dm(user_id, target_type, target_id) do
    # Look for an existing DM space where both participants are active
    existing =
      from(s in Space,
        join: p1 in Participant,
        on: p1.space_id == s.id,
        join: p2 in Participant,
        on: p2.space_id == s.id,
        where:
          s.kind == "dm" and s.is_direct == true and is_nil(s.archived_at) and
            p1.participant_type == "user" and p1.participant_id == ^user_id and
            p2.participant_type == ^target_type and p2.participant_id == ^target_id,
        limit: 1,
        select: s
      )
      |> Repo.one()

    case existing do
      %Space{} = space ->
        {:ok, space}

      nil ->
        create_dm_space(user_id, target_type, target_id)
    end
  end

  defp create_dm_space(user_id, target_type, target_id) do
    Multi.new()
    |> Multi.insert(
      :space,
      Space.changeset(%Space{}, %{
        kind: "dm",
        is_direct: true,
        created_by: user_id
      })
    )
    |> Multi.run(:initiator, fn _repo, %{space: space} ->
      add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: user_display_name(user_id),
        joined_at: DateTime.utc_now()
      })
    end)
    |> Multi.run(:target, fn _repo, %{space: space} ->
      if target_type == "agent" do
        case resolve_agent(target_id) do
          %Agent{} = agent ->
            add_agent_participant(space.id, agent)

          nil ->
            {:error, :agent_not_found}
        end
      else
        add_participant(space.id, %{
          participant_type: "user",
          participant_id: target_id,
          display_name: user_display_name(target_id),
          joined_at: DateTime.utc_now()
        })
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{space: space}} -> {:ok, space}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Find, or create, the 1:1 DM between an AGENT and a human USER, with the
  agent as the initiating party (task 01a04ad4).

  `find_or_create_dm/4` above is the human-initiated seam: its first argument
  is a `users.id`, it stamps that id into `chat_spaces.created_by`, and it
  inserts the initiator as a `participant_type: "user"` row. None of that can
  express an agent as the initiator, so this is a second seam rather than an
  extra clause on the first.

  ## The invariant this seam carries, and the one it does not touch

  The agent names a **person**, never a space. There is no `space_id`
  parameter here and deliberately so: a function that took one would be a
  function that could be pointed at somebody else's conversation, and the
  whole safety argument for this feature is that it cannot be.

  What comes out is therefore always a space in which the calling agent is
  already a party — either one it opened itself, or the one the human opened
  with it. `existing_agent_dm/2` pins BOTH halves of the roster (`agent_id`
  AND `user_id`) precisely so that "the product lead's DM with the operator" cannot satisfy the
  lookup on the strength of the product lead alone.

  This does NOT touch, and must not be read as touching:

    * `chat.ex`'s "DMs are private-to-participants by contract — no observer
      agents" — no observer is added anywhere below, and the Historian
      exclusion in `maybe_add_historian/1` is unchanged.
    * "DMs are exempt: mentioning an agent in a DM must NOT auto-add them" —
      `reinvite_and_pin_mentioned/1` is unchanged; an agent still cannot be
      pulled into a DM it is not on by anyone typing its name.
    * `PlatformWeb.ChatLive`'s `@implicitly_joinable_kinds` (task 01a01d0e /
      PR #835) — unchanged. `dm` still requires a pre-existing participant
      row to open by URL.

  An agent opening a DM WITH a human creates a NEW space whose only two
  members are the agent and that human. It exposes nobody's existing
  conversation, which is why it is safe and why the three rules above stay
  exactly as they were.

  ## Idempotency is the anti-spam property

  The lookup runs first and matches a DM created from EITHER direction — the
  participant rows a human-initiated agent DM writes are indistinguishable
  from the ones written here. So an agent that calls this in a loop gets the
  SAME thread back every time; it cannot mint the recipient a new
  conversation per message. That is a property of the query, not a throttle.

  ## Who may be DM'd

  One rule is enforced here, at the seam, because it must hold for every
  future caller: **the target must not be an external user.**
  `external_dm_permitted?/3` already refuses external→agent DMs outright
  ("the external chat surface is scoped to allowlisted humans; agent DMs are
  out of scope for external users"). Allowing agent→external would reinstate
  exactly that conversation from the other end, so the same
  `Tenancy.external_user?/1` predicate refuses it here.

  ORG scoping — may a tenant-pinned agent reach a person in another tenant —
  is answered one layer up in `Platform.Federation.ToolSurface`, by the same
  private `agent_home_org/1` that `space_create` already uses for exactly
  this question. See `dm_create` there.

  `chat_spaces.created_by` is left NULL on purpose: the column is
  `references(:users, ...)` (`20260319120000_add_dm_group_fields.exs`), so an
  agent id in it is a foreign-key violation, not a record. The agent is
  recorded in `metadata["created_by_agent_id"]` instead, which is a plain map
  field and can hold what is true.
  """
  @spec find_or_create_agent_dm(binary(), binary()) ::
          {:ok, Space.t()}
          | {:error, :agent_not_found | :user_not_found | :dm_not_allowed | term()}
  def find_or_create_agent_dm(agent_id, user_id)
      when is_binary(agent_id) and is_binary(user_id) do
    agent = resolve_agent(agent_id)
    user = Platform.Accounts.get_user(user_id)

    cond do
      is_nil(agent) ->
        {:error, :agent_not_found}

      is_nil(user) ->
        {:error, :user_not_found}

      Tenancy.external_user?(user) ->
        {:error, :dm_not_allowed}

      true ->
        case existing_agent_dm(agent.id, user.id) do
          %Space{} = space -> {:ok, space}
          nil -> create_agent_dm_space(agent, user)
        end
    end
  end

  def find_or_create_agent_dm(_agent_id, _user_id), do: {:error, :user_not_found}

  # BOTH roster halves are pinned. Dropping the agent clause would make this
  # "any DM the target user is in", which is the human-to-human conversation
  # this feature exists not to reach.
  defp existing_agent_dm(agent_id, user_id) do
    from(s in Space,
      join: pa in Participant,
      on: pa.space_id == s.id,
      join: pu in Participant,
      on: pu.space_id == s.id,
      where:
        s.kind == "dm" and s.is_direct == true and is_nil(s.archived_at) and
          pa.participant_type == "agent" and pa.participant_id == ^agent_id and
          pu.participant_type == "user" and pu.participant_id == ^user_id,
      limit: 1,
      select: s
    )
    |> Repo.one()
  end

  # Mirrors `create_dm_space/3` with the two roles swapped: the AGENT is the
  # initiator and the USER is the target. `created_by` is absent — see the
  # `find_or_create_agent_dm/2` doc for why an agent id cannot go in it.
  defp create_agent_dm_space(%Agent{} = agent, user) do
    Multi.new()
    |> Multi.insert(
      :space,
      Space.changeset(%Space{}, %{
        kind: "dm",
        is_direct: true,
        metadata: %{"created_by_agent_id" => agent.id}
      })
    )
    |> Multi.run(:initiator, fn _repo, %{space: space} ->
      add_agent_participant(space.id, agent)
    end)
    |> Multi.run(:target, fn _repo, %{space: space} ->
      add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user_display_name(user.id),
        joined_at: DateTime.utc_now()
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{space: space}} -> {:ok, space}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Create a group conversation with multiple participants.

  `participant_specs` is a list of `%{type: "user"|"agent", id: uuid}`.
  If only 1 other participant, redirects to find_or_create_dm.
  """
  @spec create_group_conversation(binary(), [map()], keyword()) ::
          {:ok, Space.t()} | {:error, :dm_not_allowed | term()}
  def create_group_conversation(user_id, participant_specs, _opts \\ []) do
    # If only one other participant, create a DM instead. That branch
    # delegates to `find_or_create_dm/4`, which inherits the allowlist
    # guard; the multi-participant branch needs its own check below.
    cond do
      length(participant_specs) == 1 ->
        [spec] = participant_specs
        type = Map.get(spec, :type) || Map.get(spec, "type")
        id = Map.get(spec, :id) || Map.get(spec, "id")
        find_or_create_dm(user_id, type, id)

      not all_participants_dm_permitted?(user_id, participant_specs) ->
        {:error, :dm_not_allowed}

      true ->
        do_create_group_conversation(user_id, participant_specs)
    end
  end

  # True unless the initiator is external and some participant spec is not
  # a permitted DM target. Internal initiators always pass (the predicate
  # short-circuits to `true` for them).
  defp all_participants_dm_permitted?(user_id, participant_specs) do
    Enum.all?(participant_specs, fn spec ->
      type = Map.get(spec, :type) || Map.get(spec, "type")
      id = Map.get(spec, :id) || Map.get(spec, "id")
      external_dm_permitted?(user_id, type, id)
    end)
  end

  defp do_create_group_conversation(user_id, participant_specs) do
    multi =
      Multi.new()
      |> Multi.insert(
        :space,
        Space.changeset(%Space{}, %{
          kind: "group",
          is_direct: false,
          created_by: user_id
        })
      )
      |> Multi.run(:creator, fn _repo, %{space: space} ->
        add_participant(space.id, %{
          participant_type: "user",
          participant_id: user_id,
          display_name: user_display_name(user_id),
          joined_at: DateTime.utc_now()
        })
      end)

    multi =
      participant_specs
      |> Enum.with_index()
      |> Enum.reduce(multi, fn {spec, idx}, multi ->
        type = Map.get(spec, :type) || Map.get(spec, "type")
        id = Map.get(spec, :id) || Map.get(spec, "id")

        Multi.run(multi, {:participant, idx}, fn _repo, %{space: space} ->
          if type == "agent" do
            case resolve_agent(id) do
              %Agent{} = agent -> add_agent_participant(space.id, agent)
              nil -> {:error, :agent_not_found}
            end
          else
            add_participant(space.id, %{
              participant_type: "user",
              participant_id: id,
              display_name: user_display_name(id),
              joined_at: DateTime.utc_now()
            })
          end
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, %{space: space}} -> {:ok, space}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Create a channel space. Requires name and slug."
  @spec create_channel(map()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def create_channel(attrs) do
    attrs = Map.put(attrs, :kind, "channel")
    create_space(attrs)
  end

  @doc """
  Promote a group conversation to a channel.

  Only works on kind=group spaces. Sets name and slug from attrs.
  """
  @spec promote_to_channel(Space.t(), map()) ::
          {:ok, Space.t()} | {:error, :not_promotable | Ecto.Changeset.t()}
  def promote_to_channel(%Space{kind: "group", is_direct: false} = space, attrs) do
    space
    |> Space.changeset(Map.merge(attrs, %{kind: "channel"}))
    |> Repo.update()
  end

  def promote_to_channel(%Space{kind: "dm"}, _attrs), do: {:error, :not_promotable}
  def promote_to_channel(%Space{is_direct: true}, _attrs), do: {:error, :not_promotable}
  def promote_to_channel(%Space{kind: "channel"}, _attrs), do: {:error, :not_promotable}
  def promote_to_channel(_, _), do: {:error, :not_promotable}

  @doc """
  List all non-archived spaces where the user is an active participant,
  ordered by most recent message (or inserted_at).

  This path JOINs `chat_participants` on the caller's own `user_id`, so it is
  INHERENTLY scoped to the caller's spaces — for an external caller it is the
  naturally-scoped read. The optional `:scope` opt applies
  `ExternalScope.scope_spaces/2` anyway as belt-and-suspenders defense in
  depth. Absent / nil / internal scopes are pass-through.

  Each returned `%Space{}` carries the virtual `last_activity_at`, which is the
  same value the ordering uses. `Platform.Chat.ClosedDms.filter/2` compares it
  against the user's stored close timestamp to decide whether a closed DM has
  earned its way back onto the rail. This is the only read path that populates
  it; everywhere else it stays nil, which ClosedDms treats as visible.
  """
  @spec list_user_conversations(binary(), keyword()) :: [Space.t()]
  def list_user_conversations(user_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    # One expression with two consumers: the rail orders by it, and the
    # closed-DM rule compares against it. Writing it out twice would let the
    # ordering and the return rule drift apart on a later edit.
    last_activity =
      dynamic(
        [s, _p, m],
        type(fragment("COALESCE(MAX(?), ?)", m.inserted_at, s.inserted_at), :utc_datetime_usec)
      )

    from(s in Space,
      join: p in Participant,
      on: p.space_id == s.id,
      left_join: m in Message,
      on: m.space_id == s.id and is_nil(m.deleted_at),
      where:
        p.participant_type == "user" and p.participant_id == ^user_id and
          is_nil(s.archived_at),
      group_by: s.id,
      order_by: ^[desc: last_activity],
      select: s,
      select_merge: ^%{last_activity_at: last_activity}
    )
    |> ExternalScope.scope_spaces(scope)
    |> Repo.all()
  end

  @doc """
  Compute a display name for a space relative to the current user.

  - Channel: space.name
  - Meeting: space.name (falls back to "Meeting")
  - Guest meeting: space.name (falls back to "Meeting")
  - DM: the other participant's display_name
  - Group: comma-separated names (excluding current user), truncated
  """
  @spec display_name_for_space(Space.t(), [Participant.t()], binary()) :: String.t()
  def display_name_for_space(%Space{kind: "channel"} = space, _participants, _current_user_id) do
    space.name || "Unnamed Channel"
  end

  # Meeting spaces surface in the ChatLive sidebar/header like any other
  # space (`space_page_title/3`, `space_header_name/3`, `sidebar_display_name/2`
  # route non-"channel" kinds through here). Without this clause a
  # `kind: "meeting"` space raised `FunctionClauseError` and crashed the
  # LiveView — the gap two reviewers worked around today by re-seeding
  # meeting spaces as channels. Mirrors the "channel" clause: just the name.
  def display_name_for_space(%Space{kind: "meeting"} = space, _participants, _current_user_id) do
    space.name || "Meeting"
  end

  # Execution spaces became human-navigable via the Pin-to-Chat rail
  # (task 019f62a1). Before the pin feature they were TaskRouter-only,
  # so `space_page_title`/`space_header_name` never hit them and the
  # missing clause was invisible. Post-stage-2 sponsors AND cross-org
  # bystanders (stage 3 safety-net) both reach handle_params/3 for an
  # exec-space slug, and the LiveView crashed on FunctionClauseError.
  # Delegate to `Platform.Tasks.ChatPins.display_name_for_space/1`
  # which joins `space.metadata["task_id"]` → tasks and returns the
  # real task title — same helper the rail rows already use. Defensive
  # fallback to `space.name` if the metadata is malformed (matches the
  # rail's own fallback shape).
  def display_name_for_space(
        %Space{kind: "execution"} = space,
        _participants,
        _current_user_id
      ) do
    Platform.Tasks.ChatPins.display_name_for_space(space)
  end

  # Guest-meeting spaces (`Meetings.create_guest_chat_space/2`) became
  # human-navigable when task 019fb955's stage 4 made them the delivery
  # surface for EXTERNAL meeting invites: `delivery_space_for_invite/2`
  # reuses this kind, and the invite message body the invitee receives is
  # literally `/chat/<space.id>`. That url lands in `ChatLive`, whose
  # `handle_params/3` routes every non-"channel" kind through here — so
  # the single link the invite hands its addressee raised
  # `FunctionClauseError` and answered HTTP 500. Both the
  # `live_session :external_chat` and `:authenticated` scopes map
  # `/chat/:space_slug` to the same LiveView, so the internal surface
  # crashed on these spaces too.
  #
  # Mirrors the "meeting" clause exactly — the name, falling back to
  # "Meeting". `create_guest_chat_space/2` always stamps a name
  # ("Guest — <meeting.name>"), so the fallback is defensive only, and it
  # reads as a meeting to the person looking at it.
  def display_name_for_space(
        %Space{kind: "guest_meeting"} = space,
        _participants,
        _current_user_id
      ) do
    space.name || "Meeting"
  end

  def display_name_for_space(%Space{kind: "dm"}, participants, current_user_id) do
    other = Enum.find(participants, fn p -> p.participant_id != current_user_id end)

    case other do
      %Participant{display_name: name} when is_binary(name) and name != "" -> name
      _ -> "DM"
    end
  end

  def display_name_for_space(%Space{kind: "group"}, participants, current_user_id) do
    names =
      participants
      |> Enum.filter(fn p -> p.participant_id != current_user_id end)
      |> Enum.map(fn p -> p.display_name || "User" end)

    case names do
      [] ->
        "Group"

      list ->
        joined = Enum.join(list, ", ")
        if String.length(joined) > 40, do: String.slice(joined, 0, 37) <> "...", else: joined
    end
  end

  @doc "List active agents for the conversation picker."
  @spec list_agents_for_picker() :: [Agent.t()]
  def list_agents_for_picker do
    from(a in Agent,
      where: a.status == "active",
      order_by: [asc: a.name]
    )
    |> Repo.all()
  end

  @doc """
  The people `user` may open a DM with, matching `query` (name or email,
  as `Platform.Accounts.list_users/1` searches; `""` lists everyone).

  ONE candidate predicate (task 01a111bb). The New Conversation picker and
  the native app's people directory (`Platform.Mobile.AppPeople`) both call
  this, and so do the app's recent-collaborator list and call invitees
  (`Platform.Meetings.CallInvites`), through `opts[:ids]`. Moved here from
  the picker's private `picker_users/3` so the four cannot drift.

  For an external user every candidate goes through
  `external_dm_permitted?/3`, the same gate `find_or_create_dm/4` enforces,
  so nothing is offered that the create would refuse. Internal users get the
  unfiltered list.

  ## Options

    * `:external?` - overrides the external test. The picker passes the
      surface it renders on (the chrome-less external chat surface), which
      is how it behaved before the extraction. Defaults to
      `Platform.Tenancy.external_user?/1` on `user`.
    * `:ids` - only these user ids (already-valid UUIDs).

  The caller is NOT removed; callers that list people drop themselves.
  """
  @spec dm_candidates(%{id: binary()}, String.t() | nil, keyword()) :: [
          Platform.Accounts.User.t()
        ]
  def dm_candidates(%{id: user_id} = user, query, opts \\ []) do
    external? = Keyword.get_lazy(opts, :external?, fn -> Tenancy.external_user?(user) end)
    users = Platform.Accounts.list_users(query: query || "", ids: Keyword.get(opts, :ids))

    if external? do
      Enum.filter(users, &external_dm_permitted?(user_id, "user", &1.id))
    else
      users
    end
  end

  @doc """
  The agents `user` may open a DM with, matching `query` by name (a
  case-insensitive substring). The agent half of `dm_candidates/3`, with
  the same options.

  External users get none: `external_dm_permitted?/3` denies every agent
  target for them, and the external surface shows no agents.
  """
  @spec dm_agent_candidates(%{id: binary()}, String.t() | nil, keyword()) :: [Agent.t()]
  def dm_agent_candidates(user, query, opts \\ []) do
    external? = Keyword.get_lazy(opts, :external?, fn -> Tenancy.external_user?(user) end)

    if external? do
      []
    else
      pattern = String.downcase(query || "")

      list_agents_for_picker()
      |> filter_agent_ids(Keyword.get(opts, :ids))
      |> Enum.filter(fn a ->
        pattern == "" or String.contains?(String.downcase(a.name || ""), pattern)
      end)
    end
  end

  defp filter_agent_ids(agents, ids) when is_list(ids) do
    wanted = MapSet.new(ids)
    Enum.filter(agents, &MapSet.member?(wanted, &1.id))
  end

  defp filter_agent_ids(agents, _ids), do: agents

  defp user_display_name(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "User"
    end
  end

  # ── Participants ────────────────────────────────────────────────────────────

  @doc """
  Add a participant to a space.

  `space_id` is injected automatically; attrs must include:
  `:participant_type`, `:participant_id`, `:joined_at`.
  Optional: `:role`, `:display_name`, `:avatar_url`, `:attention_mode`.
  """
  @spec add_participant(binary(), map()) ::
          {:ok, Participant.t()} | {:error, :space_archived | Ecto.Changeset.t()}
  def add_participant(space_id, attrs) do
    with :ok <- ensure_space_writable(space_id) do
      do_add_participant(space_id, attrs)
    end
  end

  defp do_add_participant(space_id, attrs) do
    attrs =
      attrs
      |> Map.put(:space_id, space_id)
      |> resolve_display_name()

    result =
      %Participant{}
      |> Participant.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, p} ->
        :telemetry.execute(
          [:platform, :chat, :participant_added],
          %{system_time: System.system_time()},
          %{
            space_id: space_id,
            participant_id: p.id,
            participant_type: p.participant_type
          }
        )

        ChatPubSub.broadcast(space_id, {:participant_joined, p})

        # Task 01a017a3. Seating a user in a space changes that user's rail, and
        # a session that mounted before this write holds no subscription for the
        # new space. The per-user sidebar invalidation is what makes that session
        # reconcile its subscribe set, so the unread badge on the just-granted
        # space is live instead of dead until the next reload.
        #
        # `_from self()` matters HERE and at neither of the two `ExternalGrants`
        # emit sites. `ChatLive.ensure_participant/2` inserts a row on a user's
        # first navigation into a space, and on that path the acting process IS
        # that user's own LiveView, already subscribed to its own sidebar topic.
        # A self-echo would make it reconcile against itself mid-navigation. At
        # the `ExternalGrants` sites the acting process is an operator's session
        # on a different user's topic, so nothing needs excluding there.
        if p.participant_type == "user" do
          ChatPubSub.broadcast_sidebar_changed_from(p.participant_id, self())
        end

      _ ->
        :ok
    end

    result
  end

  # Fill in `display_name` from the principal whenever the caller did not
  # supply a usable one.
  #
  # `display_name` is a denormalised cache of the agent's / user's name. It is
  # nullable and absent from `Participant.changeset/2`'s `validate_required`,
  # so any caller reaching `add_participant/2` directly — RPC channel creation
  # being the common one — could omit it and silently write NULL. A NULL agent
  # name then breaks three unrelated things at once: the roster renders the
  # literal "Agent", the @-mention picker offers only "Agent", and
  # `AttentionRouter.mentioned?/2` stops matching the agent's real name so
  # every mention of it is dropped with no error and no dead-letter row.
  #
  # Resolving here rather than validating-required closes the hole for EVERY
  # caller, present and future, without breaking the ones that legitimately
  # pass only the principal id. Validation would merely move the silent failure
  # to a loud one at each call site; resolution removes the failure.
  #
  # Both the missing key AND an explicit `nil`/blank value are handled — that
  # asymmetry is the exact trap `Keyword.get(opts, :display_name, agent.name)`
  # in `do_add_agent_participant/3` used to fall into, since a default does not
  # apply when the key is present holding nil.
  defp resolve_display_name(attrs) do
    supplied =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name")

    case supplied do
      name when is_binary(name) ->
        if String.trim(name) == "" do
          put_resolved_display_name(attrs)
        else
          attrs
        end

      _ ->
        put_resolved_display_name(attrs)
    end
  end

  defp put_resolved_display_name(attrs) do
    type = Map.get(attrs, :participant_type) || Map.get(attrs, "participant_type")
    principal_id = Map.get(attrs, :participant_id) || Map.get(attrs, "participant_id")

    case principal_display_name(type, principal_id) do
      nil -> attrs
      name -> attrs |> Map.delete("display_name") |> Map.put(:display_name, name)
    end
  end

  defp principal_display_name("agent", agent_id) when is_binary(agent_id) do
    case resolve_agent(agent_id) do
      %Agent{name: name} when is_binary(name) and name != "" -> name
      %Agent{slug: slug} when is_binary(slug) and slug != "" -> slug
      _ -> nil
    end
  end

  defp principal_display_name("user", user_id) when is_binary(user_id) do
    # `user_display_name/1` already falls back email → "User", so it never
    # returns nil for a resolvable user; guard the unresolvable case anyway.
    case user_display_name(user_id) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp principal_display_name(_type, _principal_id), do: nil

  @doc "Fetch a participant by primary key. Returns `nil` if not found."
  @spec get_participant(binary()) :: Participant.t() | nil
  def get_participant(id), do: Repo.get(Participant, id)

  @doc """
  Fast existence check: is `user_id` a `"user"` participant of `space_id`?

  The auth-hot-path counterpart to `find_user_participant/2`, which loads
  every row via `list_participants/1`. This issues a single `Repo.exists?`
  query (idiomatic here — chat.ex:1182/1219/1645/2594) and is what
  `PlatformWeb.Plugs.ExternalUserScope` uses to gate an external user on
  `/chat/:slug` without an N-row load. Only `participant_type == "user"`
  rows count — an agent-type row sharing the same id is not a match.
  """
  @spec participant?(binary(), binary()) :: boolean()
  def participant?(space_id, user_id) when is_binary(space_id) and is_binary(user_id) do
    Repo.exists?(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id == ^user_id
      )
    )
  end

  def participant?(_, _), do: false

  @doc """
  List participants in a space (ADR 0038: all rows are active).

  ## Options

    * `:participant_type` — filter by `"user"` or `"agent"`
  """
  @spec list_participants(binary(), keyword()) :: [Participant.t()]
  def list_participants(space_id, opts \\ []) do
    participant_type = Keyword.get(opts, :participant_type)

    base = from(p in Participant, where: p.space_id == ^space_id, order_by: [asc: p.joined_at])

    base =
      if participant_type do
        where(base, [p], p.participant_type == ^participant_type)
      else
        base
      end

    Repo.all(base)
  end

  @doc """
  Return the ids of `chat_participants` rows in `space_id` whose participant is
  a NOT-known-to-be-archived user (`participant_type == "user"` and the joined
  `users` row either does not exist or has `is_nil(archived_at)`).

  Agent participants are OUT of scope for this helper — pair it with the caller's
  agent-side split (see `Platform.Chat.AttentionRouter.route/1`). The LEFT JOIN
  semantics — "unknown user row treated as active" — are deliberate: `chat_participants`
  has no FK back to `users` (see `20260314080000_create_chat_tables.exs`), so bogus
  participant_ids can exist (test fixtures use random UUIDs). Silencing those would
  be a semantic change unrelated to archival; we only suppress the ONE case the
  archival contract cares about: participant.user is present and archived.

  Used by `AttentionRouter.route/1` (task 019f671f Stage 3) to silence attention
  routing for archived users while keeping their historical author snapshots
  attributable via `presence_hooks`' `include_archived: true` participant map
  build.
  """
  @spec list_active_user_participant_ids(binary()) :: [binary()]
  def list_active_user_participant_ids(space_id) when is_binary(space_id) do
    from(p in Participant,
      left_join: u in Platform.Accounts.User,
      on: u.id == p.participant_id,
      where: p.space_id == ^space_id and p.participant_type == "user",
      where: is_nil(u.id) or is_nil(u.archived_at),
      select: p.id
    )
    |> Repo.all()
  end

  @doc "Update a participant's attributes (role, display_name, attention settings, etc.)."
  @spec update_participant(Participant.t(), map()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def update_participant(%Participant{} = participant, attrs) do
    participant
    |> Participant.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Build a map of `participant.id → agent slot id` for agent participants in a
  space, the slot whose `--ag-<id>*` theme tokens paint the agent's identity.

  Agents with a nil, blank or unknown colour resolve to the blue slot via
  `ColorPalette.slot_for/1`. Used to give every agent surface its
  `data-agent-slot` (task 01a1557a rung 3; it replaced the OKLCH accent map
  in stage 2).
  """
  @spec agent_slot_map_for_participants([Participant.t()]) :: %{binary() => binary()}
  def agent_slot_map_for_participants(participants) do
    alias Platform.Agents.ColorPalette

    agent_participant_ids =
      participants
      |> Enum.filter(&(&1.participant_type == "agent"))
      |> Map.new(fn p -> {p.participant_id, p.id} end)

    cond do
      map_size(agent_participant_ids) == 0 ->
        %{}

      :color not in Agent.__schema__(:fields) ->
        %{}

      true ->
        agent_ids = Map.keys(agent_participant_ids)

        from(a in Agent, where: a.id in ^agent_ids, select: {a.id, a.color})
        |> Repo.all()
        |> Map.new(fn {agent_id, color} ->
          participant_id = Map.fetch!(agent_participant_ids, agent_id)
          {participant_id, ColorPalette.slot_for(color)}
        end)
    end
  end

  @doc """
  Build a map of `participant.id → avatar_url` for agent participants in a space.

  Resolves from the `agents` table, NOT from `chat_participants.avatar_url`.
  That column is never written for agent rows (`do_add_agent_participant/3`
  inserts no avatar), and it deliberately stays that way: an avatar is one
  mutable fact about the agent, so copying it onto every participant row in
  every space would mean rewriting all of them whenever the agent's avatar
  changes. This mirrors `agent_slot_map_for_participants/1`, which resolves
  `agent.color` the same way and for the same reason.

  Agents with no avatar (or a blank one) are ABSENT from the map rather than
  present with a nil/empty value, so a plain `Map.get/2` yields `nil` and the
  seam never hands the render layer an empty string.

  The stored URL carries a `?v=` cache token hashed from the storage key
  (the serving route does not change when the bytes do). It is passed
  through verbatim — never parsed or stripped.
  """
  @spec agent_avatar_map_for_participants([Participant.t()]) :: %{binary() => binary()}
  def agent_avatar_map_for_participants(participants) do
    # Build map: agent_id → participant.id (for agent participants only)
    agent_participant_ids =
      participants
      |> Enum.filter(&(&1.participant_type == "agent"))
      |> Map.new(fn p -> {p.participant_id, p.id} end)

    if map_size(agent_participant_ids) == 0 do
      %{}
    else
      agent_ids = Map.keys(agent_participant_ids)

      from(a in Agent,
        where: a.id in ^agent_ids and not is_nil(a.avatar_url),
        select: {a.id, a.avatar_url}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {agent_id, avatar_url}, acc ->
        case String.trim(avatar_url) do
          "" -> acc
          url -> Map.put(acc, Map.fetch!(agent_participant_ids, agent_id), url)
        end
      end)
    end
  end

  @doc """
  `%{space_id => [Participant.t()]}` for many spaces in ONE query, each
  space's rows ordered by `joined_at` (the order `list_participants/2` uses).
  A space with no participants is absent from the map.

  Decides nothing about access: the caller passes only spaces already on the
  user's own list (the phone Chat list passes its DMs and group
  conversations). A caller passing an arbitrary id gets that space's
  participant rows.
  """
  @spec participants_by_space([binary()]) :: %{binary() => [Participant.t()]}
  def participants_by_space([]), do: %{}

  def participants_by_space(space_ids) when is_list(space_ids) do
    from(p in Participant, where: p.space_id in ^space_ids, order_by: [asc: p.joined_at])
    |> Repo.all()
    |> Enum.group_by(& &1.space_id)
  end

  @doc """
  Resolve an agent principal's human-readable name (`agents.name`, falling back
  to `agents.slug`). Returns `nil` when the agent no longer exists.

  Exists so read surfaces can repair a blank
  `chat_participants.display_name` instead of rendering the literal "Agent".
  """
  @spec agent_principal_name(binary() | nil) :: String.t() | nil
  def agent_principal_name(agent_id) when is_binary(agent_id) do
    principal_display_name("agent", agent_id)
  end

  def agent_principal_name(_), do: nil

  @doc """
  Hard-delete a participant row (ADR 0038). Messages/pins/canvases
  authored by this participant survive via the author_* snapshot columns.

  Returns `{:ok, participant}` with the deleted struct for backward
  compatibility with callers that want telemetry on who was removed.
  """
  @spec remove_participant(Participant.t()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def remove_participant(%Participant{} = participant) do
    case Repo.delete(participant) do
      {:ok, deleted} ->
        :telemetry.execute(
          [:platform, :chat, :participant_removed],
          %{system_time: System.system_time()},
          %{space_id: deleted.space_id, participant_id: deleted.id}
        )

        ChatPubSub.broadcast(deleted.space_id, {:participant_left, deleted})
        {:ok, deleted}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Insert an agent participant row for the space. Returns the existing row
  if one already exists; otherwise inserts a fresh one. Never resurrects —
  dismissal is durable, and `reinvite_and_pin_mentioned/1` is the only path
  that brings a dismissed agent back (ADR 0038; see also task 019f62a1
  stage 3 for the sponsor pin-propagation pass layered on the same seam).
  """
  @spec add_agent_participant(binary(), Agent.t() | binary(), keyword()) ::
          {:ok, Participant.t()} | {:error, term()}
  def add_agent_participant(space_id, agent_or_id, opts \\ [])

  def add_agent_participant(space_id, %Agent{} = agent, opts) do
    # `space_id` arrives from the MCP `add_participant` tool. `participants`
    # keys `space_id` / `participant_id` as :binary_id, which raises on a
    # malformed value exactly like a UUIDv7 primary key does.
    if not Platform.UUID.valid?(space_id) do
      {:error, :not_found}
    else
      do_add_agent_participant(space_id, agent, opts)
    end
  end

  def add_agent_participant(space_id, agent_id, opts) when is_binary(agent_id) do
    case resolve_agent(agent_id) do
      %Agent{} = agent -> add_agent_participant(space_id, agent, opts)
      nil -> {:error, :not_found}
    end
  end

  defp do_add_agent_participant(space_id, %Agent{} = agent, opts) do
    case Repo.get_by(Participant,
           space_id: space_id,
           participant_type: "agent",
           participant_id: agent.id
         ) do
      %Participant{} = existing ->
        {:ok, existing}

      nil ->
        add_participant(space_id, %{
          participant_type: "agent",
          participant_id: agent.id,
          # `||`, not `Keyword.get(opts, :display_name, agent.name)`: the
          # default does not apply when the key is PRESENT holding nil, which
          # is exactly how callers that thread an unresolved name through
          # (see `DispatchMembership.maybe_put_display_name/2`) used to write
          # NULL. `do_add_participant/2` resolves it again as a backstop.
          display_name: Keyword.get(opts, :display_name) || agent.name,
          attention_mode: Keyword.get(opts, :attention_mode, "mention"),
          joined_at: Keyword.get(opts, :joined_at, DateTime.utc_now()),
          # NULL unless the caller is an authorized mention grant. The
          # dispatch-side path (`DispatchMembership.ensure_writable/3`) does
          # not pass it, so its rows stay unbounded by construction.
          history_visible_from: Keyword.get(opts, :history_visible_from)
        })
    end
  end

  # Resolve an agent by UUID *or* slug, returning nil for anything that is
  # neither. Every caller below receives `agent_id` from an MCP tool argument
  # (`dm_create`, `add_participant`) or a LiveView param, where an agent slug
  # is at least as common as a UUID — so a bare `Repo.get(Agent, id)` both
  # raises on slugs and misses ones the caller meant.
  #
  # Platform.UUID.valid?/1, NOT `Ecto.UUID.cast/1`: a bare cast hex-encodes any
  # 16-byte binary and returns {:ok, _}, so a 16-character slug such as
  # "higginshigginsxx" clears it, skips the slug fallback, and then raises
  # Ecto.Query.CastError inside Repo against Agent's strict UUIDv7 primary key.
  # Branch structure mirrors Platform.Agents.Orchestration.fetch_agent/1; the
  # predicate deliberately does not.
  @spec resolve_agent(Agent.t() | binary() | term()) :: Agent.t() | nil
  defp resolve_agent(%Agent{} = agent), do: agent

  defp resolve_agent(id) when is_binary(id) do
    if Platform.UUID.valid?(id) do
      Repo.get(Agent, id)
    else
      # Fail closed on a slug shared across workspaces (task 01a0e77c): an
      # ambiguous slug resolves to nothing rather than raising
      # Ecto.MultipleResultsError; SlugLookup logs the ambiguity.
      case Platform.Agents.SlugLookup.resolve(id) do
        {:ok, agent} -> agent
        {:error, _} -> nil
      end
    end
  end

  defp resolve_agent(_other), do: nil

  @doc """
  Strict participant lookup — returns the row if present or `nil`. Use
  this in read paths (tool surface, runtime channel, responder context
  load) where an agent calling without being in the space is an error to
  surface, not a reason to auto-join.
  """
  @spec get_agent_participant(binary(), Agent.t() | binary()) :: Participant.t() | nil
  def get_agent_participant(space_id, %Agent{id: agent_id}),
    do: get_agent_participant(space_id, agent_id)

  def get_agent_participant(space_id, agent_id) when is_binary(agent_id) do
    # Both columns are :binary_id, so either being malformed raises. Keep the
    # existing `nil` not-found contract — a malformed id and an absent one are
    # the same outcome to every caller.
    if Platform.UUID.valid?(space_id) and Platform.UUID.valid?(agent_id) do
      Repo.get_by(Participant,
        space_id: space_id,
        participant_type: "agent",
        participant_id: agent_id
      )
    else
      nil
    end
  end

  @doc """
  Strict lookup of a participant row by its own id, scoped to `space_id`.
  Returns the row only when participant `participant_id` belongs to space
  `space_id`, otherwise `nil`.

  Use this to VERIFY a caller-supplied participant id against the space it is
  about to write into (task 01a0cbe0): a participant id from another space is
  a refusal, not a re-attribution. A malformed id and an absent one are the
  same outcome, `nil`, exactly as in `get_agent_participant/2`.
  """
  @spec get_space_participant(binary(), binary()) :: Participant.t() | nil
  def get_space_participant(space_id, participant_id) do
    # Both columns are :binary_id, so either being malformed raises.
    if Platform.UUID.valid?(space_id) and Platform.UUID.valid?(participant_id) do
      Repo.get_by(Participant, id: participant_id, space_id: space_id)
    else
      nil
    end
  end

  # ── Messages ────────────────────────────────────────────────────────────────

  @doc """
  Post a new message to a space.

  Required attrs: `:space_id`, `:participant_id`, `:content_type`.
  Optional: `:thread_id`, `:content`, `:structured_content`, `:metadata`.
  """
  @spec post_message(map(), keyword()) ::
          {:ok, Message.t()}
          | {:error, :space_archived | :dm_not_allowed | Ecto.Changeset.t()}
  def post_message(attrs, opts \\ []) do
    space_id = attrs[:space_id] || attrs["space_id"]
    participant_id = attrs[:participant_id] || attrs["participant_id"]

    with :ok <- ensure_space_writable(space_id),
         :ok <- ensure_dm_send_allowed(space_id, participant_id) do
      do_post_message(attrs, opts)
    end
  end

  defp do_post_message(attrs, opts) do
    attrs = put_author_snapshot(attrs, :participant_id, :author)

    # Wrap the insert + v1 history record in a single transaction. The
    # v1 row is the source-of-truth baseline for the `(edited)` affix
    # on chat_message.ex (gates on versions_count > 1). Without it,
    # the first edit lands the version at 1 (not 2), and the indicator
    # stays hidden after a user's first edit (task 019e2ce2).
    result =
      Repo.transaction(fn ->
        case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
          {:ok, msg} ->
            _v1 = MessageVersions.record_v1!(msg)
            msg

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, msg} ->
        msg |> reinvite_and_pin_mentioned() |> notify_refused_summons(msg, opts)
        emit_inbox_for_mentions(msg)
        publish_message_posted(msg, opts)
        {:ok, msg}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Post a new message and create any attachments in the same transaction.

  `attachment_attrs_list` should contain maps with `:filename`, `:content_type`,
  `:byte_size`, and `:storage_key`.
  """
  @spec post_message_with_attachments(map(), [map()], keyword()) ::
          {:ok, Message.t(), [Attachment.t()]}
          | {:error, :space_archived | :dm_not_allowed | :out_of_external_scope | term()}
  def post_message_with_attachments(attrs, attachment_attrs_list, opts \\ [])
      when is_list(attachment_attrs_list) do
    space_id = attrs[:space_id] || attrs["space_id"]
    participant_id = attrs[:participant_id] || attrs["participant_id"]
    poster_user_id = Keyword.get(opts, :poster_user_id)

    with :ok <- ensure_space_writable(space_id),
         :ok <- ensure_dm_send_allowed(space_id, participant_id),
         :ok <- ensure_external_upload_allowed(space_id, poster_user_id) do
      do_post_message_with_attachments(attrs, attachment_attrs_list, opts)
    end
  end

  defp do_post_message_with_attachments(attrs, attachment_attrs_list, opts) do
    attrs = put_author_snapshot(attrs, :participant_id, :author)

    multi =
      Multi.new()
      |> Multi.insert(:message, Message.changeset(%Message{}, attrs))
      # v1 history baseline — see post_message/2 comment for rationale.
      # MessageVersions.record_v1!/1 raises on failure, which Multi.run
      # converts to {:error, …} and rolls back the whole multi (incl.
      # the message + attachments inserts above).
      |> Multi.run(:v1_version, fn _repo, %{message: message} ->
        {:ok, MessageVersions.record_v1!(message)}
      end)

    multi =
      Enum.with_index(attachment_attrs_list)
      |> Enum.reduce(multi, fn {attachment_attrs, index}, multi ->
        Multi.run(multi, {:attachment, index}, fn repo, %{message: message} ->
          attachment_attrs
          |> Map.put(:message_id, message.id)
          |> Map.put(:space_id, message.space_id)
          |> then(&Attachment.changeset(%Attachment{}, &1))
          |> repo.insert()
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, changes} ->
        message = changes.message

        attachments =
          changes
          |> Enum.filter(fn {key, _value} -> match?({:attachment, _}, key) end)
          |> Enum.sort_by(fn {{:attachment, index}, _value} -> index end)
          |> Enum.map(fn {_key, attachment} -> attachment end)

        message |> reinvite_and_pin_mentioned() |> notify_refused_summons(message, opts)
        emit_inbox_for_mentions(message)
        publish_message_posted(message, opts)
        {:ok, message, attachments}

      {:error, _operation, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  # ── Large-file user uploads (task 01a120be stage 2) ─────────────────────

  @doc """
  Reserve a chunked large-file upload for a user's message. The ONE entry
  point the app API (`POST /api/app/spaces/:space_id/uploads`) and the web
  composer share, so web and native cannot drift.

  `poster` is an already-authorized sender: `%{space_id, participant_id,
  user_id, thread_id, content}` (the caller checked membership, as
  `post_message_with_attachments/3`'s callers do). `file` is `%{filename,
  content_type, byte_size}`.

  Refuses `byte_size` over `Platform.Chat.UploadLimits.max_bytes/0` with
  `{:error, :too_large}` and runs the same space-writable, DM and external
  scope guards a post would, all before any byte moves. On success inserts a
  pending `chat_attachments` row owned by `uploaded_by_user_id` that carries
  the message to post in `metadata["pending_message"]`, presigns it, and
  returns `%{id, upload_url, chunk_bytes, offset: 0, expires_at,
  max_upload_bytes}`. The upload's last PATCH posts the message server-side
  (`Platform.Chat.Attachments.ToolHandlers.finalize_pending/2`), so a client
  whose process is gone by then (iOS background URLSession, Android
  WorkManager) loses nothing.
  """
  @spec reserve_user_upload(map(), map()) ::
          {:ok, map()}
          | {:error,
             :too_large
             | :invalid_file
             | :space_archived
             | :dm_not_allowed
             | :out_of_external_scope
             | term()}
  def reserve_user_upload(poster, file) do
    %{space_id: space_id, participant_id: participant_id, user_id: user_id} = poster
    byte_size = file[:byte_size]
    filename = file[:filename]

    with :ok <- valid_reservation_file(filename, byte_size),
         :ok <- Platform.Chat.UploadLimits.check_size(byte_size),
         :ok <- ensure_space_writable(space_id),
         :ok <- ensure_dm_send_allowed(space_id, participant_id),
         :ok <- ensure_external_upload_allowed(space_id, user_id) do
      do_reserve_user_upload(poster, filename, file[:content_type], byte_size)
    end
  end

  @doc """
  `reserve_user_upload/2` for a caller that holds only a space id, which may
  have come from the client (the web composer's re-reservation after an
  expiry carries the space the upload began in, not the session's).

  Composes `SpaceAccess.authorize_writer/2` first and derives the poster from
  the participant row it returns, so a forged space id is `{:error,
  :forbidden}` and no row is written. `attrs` is `%{space_id, content,
  thread_id, participant_id}`; when `participant_id` is given it must be the
  actor's own row in that space, otherwise `{:error, :forbidden}`. `file` is
  as for `reserve_user_upload/2`.
  """
  @spec reserve_space_upload(SpaceAccess.actor(), map(), map()) ::
          {:ok, map()} | {:error, :forbidden | term()}
  def reserve_space_upload(actor, attrs, file) do
    with {:ok, participant} <- SpaceAccess.authorize_writer(attrs[:space_id], actor),
         :ok <- same_participant(participant, attrs[:participant_id]) do
      reserve_user_upload(
        %{
          space_id: participant.space_id,
          participant_id: participant.id,
          user_id: participant.participant_id,
          thread_id: attrs[:thread_id],
          content: attrs[:content] || ""
        },
        file
      )
    end
  end

  defp same_participant(_participant, nil), do: :ok
  defp same_participant(%Participant{id: id}, id), do: :ok
  defp same_participant(_participant, _other), do: {:error, :forbidden}

  defp valid_reservation_file(filename, byte_size)
       when is_binary(filename) and filename != "" and is_integer(byte_size) and byte_size > 0,
       do: :ok

  defp valid_reservation_file(_filename, _byte_size), do: {:error, :invalid_file}

  defp do_reserve_user_upload(poster, filename, client_type, byte_size) do
    %{storage_key: key, content_type: content_type} =
      Platform.Chat.AttachmentStorage.reservation(filename, client_type)

    ttl_s = Application.get_env(:platform, :pending_ttl_seconds, 15 * 60)

    adapter =
      Application.get_env(
        :platform,
        :attachment_storage_adapter,
        Platform.Chat.AttachmentStorage.Adapter.LocalDisk
      )

    pending_message = %{
      "space_id" => poster.space_id,
      "participant_id" => poster.participant_id,
      "user_id" => poster.user_id,
      "thread_id" => Map.get(poster, :thread_id),
      "content" => Map.get(poster, :content) || ""
    }

    with {:ok, attachment} <-
           create_attachment(%{
             space_id: poster.space_id,
             uploaded_by_user_id: poster.user_id,
             filename: filename,
             content_type: content_type,
             byte_size: byte_size,
             storage_key: key,
             state: "pending",
             upload_expires_at: DateTime.utc_now() |> DateTime.add(ttl_s, :second),
             metadata: %{"pending_message" => pending_message}
           }) do
      case adapter.presign_upload(key, Platform.Chat.UploadLimits.max_bytes(), ttl_s) do
        {:ok, %{url: url, expires_at: expires_at}} ->
          {:ok,
           %{
             id: attachment.id,
             upload_url: url,
             chunk_bytes: Platform.Chat.UploadLimits.chunk_bytes(),
             offset: 0,
             expires_at: expires_at,
             max_upload_bytes: Platform.Chat.UploadLimits.max_bytes()
           }}

        {:error, reason} ->
          Repo.delete(attachment)
          {:error, {:presign_failed, reason}}
      end
    end
  end

  @doc """
  Sibling of `post_message_with_attachments/3` for a `chat_attachments` row
  that already exists and is `ready` (the finished chunked upload): posts the
  message and LINKS the row to it instead of inserting one. Same guards, same
  broadcast and notification path. The link is conditional on the row having
  no message yet, so a row can never end up attached to two messages.
  """
  @spec post_message_with_existing_attachment(map(), Attachment.t(), keyword()) ::
          {:ok, Message.t(), [Attachment.t()]}
          | {:error, :space_archived | :dm_not_allowed | :out_of_external_scope | term()}
  def post_message_with_existing_attachment(attrs, %Attachment{} = attachment, opts \\ []) do
    space_id = attrs[:space_id]
    participant_id = attrs[:participant_id]
    poster_user_id = Keyword.get(opts, :poster_user_id)

    with :ok <- ensure_space_writable(space_id),
         :ok <- ensure_dm_send_allowed(space_id, participant_id),
         :ok <- ensure_external_upload_allowed(space_id, poster_user_id) do
      attrs = put_author_snapshot(attrs, :participant_id, :author)

      Multi.new()
      |> Multi.insert(:message, Message.changeset(%Message{}, attrs))
      |> Multi.run(:v1_version, fn _repo, %{message: message} ->
        {:ok, MessageVersions.record_v1!(message)}
      end)
      |> Multi.run(:attachment, fn repo, %{message: message} ->
        from(a in Attachment,
          where: a.id == ^attachment.id and is_nil(a.message_id) and a.state == "ready",
          select: a
        )
        |> repo.update_all(set: [message_id: message.id])
        |> case do
          {1, [linked]} -> {:ok, linked}
          _ -> {:error, :attachment_not_linkable}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{message: message, attachment: linked}} ->
          message |> reinvite_and_pin_mentioned() |> notify_refused_summons(message, opts)
          emit_inbox_for_mentions(message)
          publish_message_posted(message, opts)
          {:ok, message, [linked]}

        {:error, _operation, reason, _changes_so_far} ->
          {:error, reason}
      end
    end
  end

  @max_existing_attachment_ids 10

  @doc """
  Post a message carrying attachments that ALREADY exist, by id (task
  01a1655c stage 1). The plural, id-based sibling of
  `post_message_with_existing_attachment/3`: same guards
  (`ensure_space_writable`, `ensure_dm_send_allowed`,
  `ensure_external_upload_allowed`), same post-commit path, one transaction.
  One bad id posts nothing.

  Each id must be a valid UUID, exist, live in the message's own space, pass
  `attachment_access_check/2` for the poster's access scope (`opts[:access_scope]`,
  else the scope of `opts[:poster_user_id]`, else none), and be `ready`. A
  missing row, a row in another space and a denied row all answer
  `{:error, {:attachment_not_found, id}}`, the same shape, so the answer
  confirms nothing about ids the poster cannot see. Only a `pending` row in
  the same space (and readable) answers `{:error, {:attachment_not_ready, id}}`.

  The uploader is deliberately NOT required to be the poster. Upload dedup
  (`ToolHandlers.finalize_or_dedup`) can hand back a canonical id that
  someone else uploaded in the same space, and every member of that space
  can already read the row, so tying it to the uploader would refuse the id
  the upload itself just returned while protecting nothing.

  Linking: a row with no message and no canvas is linked in place, by the
  same conditional `update_all` the single-row function uses. A row that is
  already on another message, or bound to a canvas, is left alone and a NEW
  reference row (same storage key, content hash, filename, type, size,
  metadata and uploader) is inserted for this message, so no row is ever on
  two messages and a canvas keeps its own row. Duplicate ids collapse to
  one; more than #{@max_existing_attachment_ids} distinct ids is
  `{:error, :too_many_attachments}`. The message is stamped
  `metadata["attachments_linked_by_id"] => true`.
  """
  @spec post_message_with_existing_attachments(map(), [binary()], keyword()) ::
          {:ok, Message.t(), [Attachment.t()]}
          | {:error,
             :space_archived
             | :dm_not_allowed
             | :out_of_external_scope
             | :no_attachments
             | :too_many_attachments
             | {:attachment_not_found, term()}
             | {:attachment_not_ready, binary()}
             | term()}
  def post_message_with_existing_attachments(attrs, attachment_ids, opts \\ [])

  def post_message_with_existing_attachments(attrs, attachment_ids, opts)
      when is_list(attachment_ids) do
    ids = Enum.uniq(attachment_ids)
    space_id = attrs[:space_id]
    participant_id = attrs[:participant_id]
    poster_user_id = Keyword.get(opts, :poster_user_id)

    with :ok <- check_existing_attachment_count(ids),
         :ok <- ensure_space_writable(space_id),
         :ok <- ensure_dm_send_allowed(space_id, participant_id),
         :ok <- ensure_external_upload_allowed(space_id, poster_user_id) do
      scope = existing_attachment_scope(opts, poster_user_id)

      attrs =
        attrs
        |> put_author_snapshot(:participant_id, :author)
        |> Map.update(
          :metadata,
          %{"attachments_linked_by_id" => true},
          &Map.put(&1 || %{}, "attachments_linked_by_id", true)
        )

      Multi.new()
      |> Multi.run(:rows, fn repo, _ ->
        resolve_existing_attachments(repo, ids, space_id, scope)
      end)
      |> Multi.insert(:message, Message.changeset(%Message{}, attrs))
      |> Multi.run(:v1_version, fn _repo, %{message: message} ->
        {:ok, MessageVersions.record_v1!(message)}
      end)
      |> Multi.run(:attachments, fn repo, %{message: message, rows: rows} ->
        link_existing_attachments(repo, rows, message)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{message: message, attachments: linked}} ->
          message |> reinvite_and_pin_mentioned() |> notify_refused_summons(message, opts)
          emit_inbox_for_mentions(message)
          publish_message_posted(message, opts)
          {:ok, message, linked}

        {:error, _operation, reason, _changes_so_far} ->
          {:error, reason}
      end
    end
  end

  def post_message_with_existing_attachments(_attrs, _attachment_ids, _opts),
    do: {:error, :no_attachments}

  defp check_existing_attachment_count([]), do: {:error, :no_attachments}

  defp check_existing_attachment_count(ids) when length(ids) > @max_existing_attachment_ids,
    do: {:error, :too_many_attachments}

  defp check_existing_attachment_count(_ids), do: :ok

  defp existing_attachment_scope(opts, poster_user_id) do
    case Keyword.get(opts, :access_scope) do
      %Platform.Access.Scope{} = scope -> scope
      _ when is_binary(poster_user_id) -> Platform.Access.Scope.for_user(%{id: poster_user_id})
      _ -> nil
    end
  end

  # Locks each row for the transaction so a concurrent link cannot slip in
  # between the check and the link.
  defp resolve_existing_attachments(repo, ids, space_id, scope) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case resolve_existing_attachment(repo, id, space_id, scope) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp resolve_existing_attachment(repo, id, space_id, scope) do
    row =
      if is_binary(id) and Platform.UUID.valid?(id),
        do: repo.one(from(a in Attachment, where: a.id == ^id, lock: "FOR UPDATE"))

    cond do
      is_nil(row) -> {:error, {:attachment_not_found, id}}
      is_nil(space_id) or row.space_id != space_id -> {:error, {:attachment_not_found, id}}
      attachment_access_check(row, scope) != :ok -> {:error, {:attachment_not_found, id}}
      row.state != "ready" -> {:error, {:attachment_not_ready, id}}
      true -> {:ok, row}
    end
  end

  defp link_existing_attachments(repo, rows, message) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case link_existing_attachment(repo, row, message) do
        {:ok, linked} -> {:cont, {:ok, [linked | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, linked} -> {:ok, Enum.reverse(linked)}
      error -> error
    end
  end

  defp link_existing_attachment(repo, %Attachment{message_id: nil, canvas_id: nil} = row, message) do
    from(a in Attachment,
      where:
        a.id == ^row.id and is_nil(a.message_id) and is_nil(a.canvas_id) and a.state == "ready",
      select: a
    )
    |> repo.update_all(set: [message_id: message.id])
    |> case do
      {1, [linked]} -> {:ok, linked}
      _ -> {:error, :attachment_not_linkable}
    end
  end

  defp link_existing_attachment(repo, %Attachment{} = row, message) do
    %Attachment{}
    |> Attachment.changeset(%{
      space_id: row.space_id,
      message_id: message.id,
      filename: row.filename,
      content_type: row.content_type,
      byte_size: row.byte_size,
      storage_key: row.storage_key,
      content_hash: row.content_hash,
      metadata: row.metadata,
      uploaded_by_user_id: row.uploaded_by_user_id,
      uploaded_by_agent_id: row.uploaded_by_agent_id,
      state: "ready"
    })
    |> repo.insert()
  end

  @doc """
  Fetch a message by primary key. Returns `nil` if not found.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`) gates the message
  on its space: for an external caller a message in a non-participant space
  resolves to `nil`. Absent / nil / internal scopes are pass-through.
  """
  @spec get_message(binary(), keyword()) :: Message.t() | nil
  def get_message(id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    # `message_id` is a raw MCP tool argument (tool_surface.ex:2430) and a
    # `phx-value-` param. Platform.UUID.valid?/1, not a bare cast — see
    # get_space/2 above.
    if Platform.UUID.valid?(id) do
      case Repo.get(Message, id) do
        nil -> nil
        msg -> if ExternalScope.visible_space_id?(msg.space_id, scope), do: msg, else: nil
      end
    else
      nil
    end
  end

  # ── The scrollback ordering key ────────────────────────────────────────
  #
  # An agent's spoken line in a meeting is posted as a chat message when
  # the runtime ACKS the utterance, which can be seconds — or, through
  # `Platform.Meetings.SayRegistry`'s five-minute back-fill window,
  # minutes — after the line was actually said. `inserted_at` on that row
  # is therefore ACK time, and ordering a room by it files a slowly-acked
  # agent line after everything that was said while it was still in
  # flight (task 01a07401).
  #
  # Stage 1 of that task stamps the dispatch instant onto the row as
  # `metadata["spoken_at"]` (ISO 8601 UTC), with `metadata["spoken_at_source"]`
  # recording that it is dispatch time and not a worker-reported playback
  # start. That is the key a scrollback sorts by; `m.id` stays as the
  # tiebreaker for the same reason it always was (see `list_messages/2`).
  #
  # COMPATIBILITY — the rows that have no stamp. Every message posted
  # before stage 1 shipped, and every message that is not agent speech
  # (which is nearly all of them, in every space in the product), has no
  # `spoken_at`. `coalesce` falls those rows back to their own
  # `inserted_at`, so an unstamped row sorts exactly where it sorts
  # today — at its own place in the room, NOT hoisted to the top of it or
  # dumped at the bottom. That is why no backfill is needed, and it is
  # just as well: the dispatch instant of a historical utterance was
  # never recorded anywhere, so a backfill is not possible even in
  # principle. A room of purely historical messages is bit-for-bit the
  # same order it was before this shipped.
  #
  # On the SQL: `->>` already yields NULL for a missing key, and
  # `nullif(…, '')` extends that to a present-but-empty value so the cast
  # cannot see one. The cast itself is unguarded because
  # `Platform.Meetings.post_spoken_utterance/2` is the only writer of this
  # key anywhere in the tree and it always writes `DateTime.to_iso8601/1`
  # output. `inserted_at` is `:utc_datetime_usec`, which Postgres stores
  # as `timestamp` (no zone), so the cast target is `timestamp` too — an
  # ISO 8601 UTC string's trailing `Z` is dropped against a column that is
  # already UTC, which is what makes the two arms of the `coalesce`
  # comparable at all.
  defmacrop ordering_key(m) do
    quote do
      fragment(
        "coalesce(nullif(?->>'spoken_at', '')::timestamp, ?)",
        unquote(m).metadata,
        unquote(m).inserted_at
      )
    end
  end

  @doc """
  The instant a message sorts at in a room's scrollback: the `spoken_at`
  its metadata carries when it has one, else its `inserted_at`.

  The Elixir mirror of the SQL ordering key `list_messages/2` sorts by, for
  the callers that have a `%Message{}` in hand and need to agree with the
  order it came back in — the day separators and the per-row clock in the
  chat stream. A malformed or missing stamp falls back to `inserted_at`,
  matching the `coalesce` in the query.
  """
  @spec message_ordered_at(map()) :: DateTime.t() | nil
  def message_ordered_at(%{metadata: metadata, inserted_at: inserted_at})
      when is_map(metadata) do
    with raw when is_binary(raw) <- Map.get(metadata, "spoken_at"),
         {:ok, %DateTime{} = spoken_at, _offset} <- DateTime.from_iso8601(raw) do
      spoken_at
    else
      _ -> inserted_at
    end
  end

  def message_ordered_at(%{inserted_at: inserted_at}), do: inserted_at

  # Keyset cursors compare on the ORDERING key, not on `id` alone.
  #
  # `id` is UUIDv7 and so agrees with insertion order — which is exactly
  # what the ordering key no longer does for an agent's spoken line. With
  # an `id`-only cursor, a page whose oldest row (by spoken time) carries a
  # LATE id would hand the next page a cursor above rows it had already
  # rendered, and the reader would see them twice; derive the cursor the
  # other way and rows go missing instead. So the cursor row's own
  # ordering key is resolved (a primary-key lookup) and the comparison is
  # the (key, id) pair the query is ordered by.
  #
  # A cursor naming a row that no longer exists falls back to the plain
  # `id` comparison, which is what this did before and still the only
  # sensible reading of "everything before a row that is gone".
  # `Platform.UUID.valid?/1` before the lookup, not after: `before_id` /
  # `after_id` arrive from the MCP `space_get_messages` tool and from
  # `phx-value-` params, and `where: m.id == ^value` raises the same
  # `Ecto.Query.CastError` a bare `Repo.get/2` would. Returning nil for a
  # malformed cursor drops through to the plain `id` comparison below,
  # which is what this path did before and still raises exactly where it
  # always did — this lookup does not add a new failure mode of its own.
  defp cursor_ordered_at(id) do
    if Platform.UUID.valid?(id) do
      Repo.one(from(m in Message, where: m.id == ^id, select: ordering_key(m)))
    end
  end

  defp keyset_before(query, nil), do: query

  defp keyset_before(query, before_id) do
    case cursor_ordered_at(before_id) do
      nil ->
        where(query, [m], m.id < ^before_id)

      key ->
        where(
          query,
          [m],
          ordering_key(m) < type(^key, :naive_datetime_usec) or
            (ordering_key(m) == type(^key, :naive_datetime_usec) and m.id < ^before_id)
        )
    end
  end

  defp keyset_after(query, nil), do: query

  defp keyset_after(query, after_id) do
    case cursor_ordered_at(after_id) do
      nil ->
        where(query, [m], m.id > ^after_id)

      key ->
        where(
          query,
          [m],
          ordering_key(m) > type(^key, :naive_datetime_usec) or
            (ordering_key(m) == type(^key, :naive_datetime_usec) and m.id > ^after_id)
        )
    end
  end

  @doc """
  List non-deleted messages in a space, newest first.

  ## Options

    * `:limit`     — max number of messages (default: 50)
    * `:before_id` — keyset cursor — only messages ordered before that row
    * `:after_id`  — keyset cursor — only messages ordered after that row
    * `:thread_id` — filter to a specific thread
    * `:top_level_only` — when `true`, include only messages where `thread_id` is `NULL`
    * `:order` — `:desc` (default, newest first) | `:asc` (oldest first)
    * `:as_participant` — a `%Participant{}` or participant id. When that row
      carries a non-NULL `history_visible_from` (stage 1 of task 01a0ac64), the
      read is bounded to `m.inserted_at >= history_visible_from`.

  ## `:as_participant` and the history grant

  `history_visible_from` is written ONLY by the mention grant in
  `reinvite_and_pin_mentioned/1`. It is NULL for every pre-existing row and for
  every row `Platform.Chat.DispatchMembership.ensure_writable/3` adds at
  dispatch time, and a NULL (or an absent `:as_participant`) leaves this read
  byte-identical to what it was before the opt existed — a genuinely assigned
  executor still reads the ticket history posted before its participant row
  existed. The bound therefore applies exactly to the path that grants space
  access without the author being authorized to grant it.

  Threaded through the AGENT-facing reads only (`Federation.ToolSurface`'s
  `space_get_messages` and `Chat.AgentResponder`'s context load). Human
  LiveView reads (`PlatformWeb.Chat.MessagesHooks`) deliberately do NOT pass
  it: bounding those would silently truncate human scrollback, which is a
  separate decision nobody has taken.

  ## `:order` and the `:after_id` cursor

  `:limit` is applied AFTER the ordering, so the two interact. With the
  default `:desc`, `after_id: cursor` returns the `limit` NEWEST messages
  in the space that are newer than the cursor — which for a deep cursor
  skips over everything in between. That is the right shape for "catch me
  up to the live tail" (`MessagesHooks.load_newer_messages/2`) and the
  wrong shape for "give me the messages immediately following this one."

  Pass `order: :asc` for the latter: it returns the `limit` messages
  directly after the cursor, contiguous with it. The anchored history
  window (`MessagesHooks.enter_space_anchored/4`) depends on that
  contiguity — a window with a hole in it renders as a silent lie about
  what was said around the anchor.

  `before_id` needs no such flag: under `:desc` the limit already lands on
  the messages immediately preceding the cursor.
  """
  @spec list_messages(binary(), keyword()) :: [Message.t()]
  def list_messages(space_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    order = if Keyword.get(opts, :order) == :asc, do: :asc, else: :desc

    space_id
    |> messages_query(opts)
    # `m.id` is a REQUIRED tiebreaker, not decoration. `inserted_at` is
    # `:utc_datetime_usec` and messages posted in the same microsecond DO
    # collide — production currently holds 7,909 timestamps shared by more
    # than one message. With ties, Postgres may return them in any order,
    # so an anchored window can place the anchor row at a different index
    # on each read and the reader sees the target surrounded by messages
    # that are not its neighbours.
    #
    # `id` is `Platform.Types.UUIDv7`, which is time-ordered, so it agrees
    # with insertion order rather than fighting it. Same defect and same
    # remedy as the task-paging fix in #864.
    #
    # The leading key is `ordering_key/1`, NOT `inserted_at` — see the
    # comment on that macro. It is `inserted_at` for every row that has
    # no `spoken_at`, which is every row this product had before task
    # 01a07401 and nearly every row it has now, so the tiebreaker
    # reasoning above is untouched.
    |> order_by([m], [{^order, ordering_key(m)}, {^order, m.id}])
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Count the messages `list_messages/2` could return for the same options,
  ignoring `:limit` and `:order` (task 01a04a7a stage 3).

  Every filter is shared through one private builder (`messages_query/2`):
  `deleted_at` nil, `:thread_id` / `:top_level_only`, the `:before_id` /
  `:after_id` keyset cursors, the `:as_participant` history grant and the
  external `:scope`. The count therefore cannot see a row the page could not
  — in particular it never counts history from before a participant's
  `history_visible_from`, which would leak its size.
  """
  @spec count_messages(binary(), keyword()) :: non_neg_integer()
  def count_messages(space_id, opts \\ []) do
    space_id
    |> messages_query(opts)
    |> Repo.aggregate(:count)
  end

  defp messages_query(space_id, opts) do
    thread_id = Keyword.get(opts, :thread_id)
    top_level_only = Keyword.get(opts, :top_level_only, false)

    base = from(m in Message, where: m.space_id == ^space_id and is_nil(m.deleted_at))

    base =
      cond do
        thread_id -> where(base, [m], m.thread_id == ^thread_id)
        top_level_only -> where(base, [m], is_nil(m.thread_id))
        true -> base
      end

    base
    |> keyset_before(Keyword.get(opts, :before_id))
    |> keyset_after(Keyword.get(opts, :after_id))
    |> bound_by_history_grant(Keyword.get(opts, :as_participant))
    |> ExternalScope.scope_by_space_id(Keyword.get(opts, :scope))
  end

  # NULL `history_visible_from`, an unknown id, or no `:as_participant` at all
  # all mean "unbounded" — the pre-01a0ac64 behaviour. Only a real timestamp
  # narrows the read.
  defp bound_by_history_grant(query, nil), do: query

  defp bound_by_history_grant(query, %Participant{history_visible_from: nil}), do: query

  defp bound_by_history_grant(query, %Participant{history_visible_from: %DateTime{} = from}) do
    where(query, [m], m.inserted_at >= ^from)
  end

  defp bound_by_history_grant(query, participant_id) when is_binary(participant_id) do
    if Platform.UUID.valid?(participant_id) do
      bound_by_history_grant(query, get_participant(participant_id))
    else
      query
    end
  end

  @doc """
  Peek whether more non-deleted messages exist before the given cursor.
  Used by the infinite-scroll UI to decide whether to keep rendering the
  load-more sentinel. Single-row `LIMIT 1` query — cheap.

  ## Options

    * `:before_id`       — keyset cursor — only counts messages ordered before that row
    * `:thread_id`       — filter to a specific thread
    * `:top_level_only`  — when `true`, include only messages where `thread_id` is `NULL`
  """
  @spec has_more_messages_before?(binary(), keyword()) :: boolean()
  def has_more_messages_before?(space_id, opts \\ []) do
    before_id = Keyword.get(opts, :before_id)
    thread_id = Keyword.get(opts, :thread_id)
    top_level_only = Keyword.get(opts, :top_level_only, false)
    scope = Keyword.get(opts, :scope)

    base =
      from(m in Message,
        where: m.space_id == ^space_id and is_nil(m.deleted_at),
        limit: 1,
        select: 1
      )

    base =
      cond do
        thread_id -> where(base, [m], m.thread_id == ^thread_id)
        top_level_only -> where(base, [m], is_nil(m.thread_id))
        true -> base
      end

    base = keyset_before(base, before_id)

    base
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.exists?()
  end

  @doc """
  Peek whether more non-deleted messages exist after the given cursor.
  Used by the chat infinite-scroll UI to decide whether to keep
  rendering the bottom (load-newer) sentinel after the live tail has
  been evicted from the bounded stream. Single-row `LIMIT 1` query.

  ## Options

    * `:after_id`        — keyset cursor — only counts messages ordered after that row
    * `:thread_id`       — filter to a specific thread
    * `:top_level_only`  — when `true`, include only messages where `thread_id` is `NULL`
  """
  @spec has_more_messages_after?(binary(), keyword()) :: boolean()
  def has_more_messages_after?(space_id, opts \\ []) do
    after_id = Keyword.get(opts, :after_id)
    thread_id = Keyword.get(opts, :thread_id)
    top_level_only = Keyword.get(opts, :top_level_only, false)
    scope = Keyword.get(opts, :scope)

    base =
      from(m in Message,
        where: m.space_id == ^space_id and is_nil(m.deleted_at),
        limit: 1,
        select: 1
      )

    base =
      cond do
        thread_id -> where(base, [m], m.thread_id == ^thread_id)
        top_level_only -> where(base, [m], is_nil(m.thread_id))
        true -> base
      end

    base = keyset_after(base, after_id)

    base
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.exists?()
  end

  @doc """
  Fetch multiple non-deleted messages by primary key in a single query.

  Returns matching `%Message{}` records; missing or deleted ids are
  silently dropped. Order is not preserved — callers must sort if needed.

  Used by `PlatformWeb.Live.Chat.MessagesHooks.reinsert_stream_messages/3`
  to refresh many currently-rendered stream rows after a parent assign
  changes, avoiding the N+1 that would result from per-message
  `get_message/1` calls.
  """
  @spec get_messages_by_ids([binary()], keyword()) :: [Message.t()]
  def get_messages_by_ids(ids, opts \\ [])

  def get_messages_by_ids([], _opts), do: []

  def get_messages_by_ids(ids, opts) when is_list(ids) do
    scope = Keyword.get(opts, :scope)

    from(m in Message,
      where: m.id in ^ids and is_nil(m.deleted_at)
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
  end

  @doc """
  Returns messages across all spaces within a time window.

  Used by the Historian's activity digest. Filters out DMs and non-chat
  space kinds (system, execution), deleted messages, log-only messages,
  and non-conversational content types by default.

  ## Options

    * `:window_end`       — upper bound (exclusive); default `DateTime.utc_now/0`
    * `:include_kinds`    — list of space kinds to include; default `~w(channel group)`
    * `:content_types`    — list of content_types to include; default `~w(text agent_action)`
    * `:include_archived` — when `true`, messages in archived spaces are
      included (task 019e95ea: archived channels are read-only snapshots
      whose history stays searchable); default `false`. Spaces flagged for
      deletion (`deletion_scheduled_at` set, stage 3) are always excluded,
      even with `include_archived: true`.

  Messages are ordered by `inserted_at` ASC to make grouping-by-space
  and chronological formatting straightforward downstream.
  """
  @spec list_messages_since(DateTime.t(), keyword()) :: [Message.t()]
  def list_messages_since(%DateTime{} = window_start, opts \\ []) do
    window_end = Keyword.get(opts, :window_end, DateTime.utc_now())

    opts
    |> digest_eligible_messages_query()
    |> where([m], m.inserted_at >= ^window_start and m.inserted_at < ^window_end)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  The newest non-deleted, non-log-only message in `space_id` authored by
  one of `agent_ids` and inserted STRICTLY after `since`, or `nil`.

  Built for `Platform.Responsibilities.Handlers.AgentsGoalHeartbeat`
  (task `01a0ca24` stage 3), which reads the leader's last reply back as
  the next beat's prior claim. It lives here rather than as a `Repo`
  query inside the handler so the Responsibilities context does not
  reach into the messages table.

  `author_agent_id` is the author snapshot `put_author_snapshot/3`
  writes at insert: the participant's `participant_id` when the
  participant is an agent, which is the agent's id. The bound is
  exclusive on purpose: a message stamped at exactly `since` belongs to
  the beat that wrote `since`, not to the one after it. `m.id`
  (UUIDv7, time-ordered) breaks `inserted_at` ties.
  """
  @spec latest_agent_message_since(binary(), [binary()], DateTime.t()) :: Message.t() | nil
  def latest_agent_message_since(space_id, agent_ids, %DateTime{} = since)
      when is_binary(space_id) and is_list(agent_ids) do
    from(m in Message,
      where:
        m.space_id == ^space_id and
          m.author_agent_id in ^agent_ids and
          is_nil(m.deleted_at) and
          m.log_only == false and
          m.inserted_at > ^since,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  The unbounded digest-eligibility predicate for the `messages` corpus —
  every filter that decides whether a `chat_messages` row can ever reach a
  Historian digest, and nothing else. No time bound, no ordering, no select.

  This is the **single seam** between the Historian's pending-bytes signal
  and what the digest actually renders. `list_messages_since/2` is this
  query plus `[window_start, window_end)` and an order; the byte-sizing
  queries in `Platform.Agents.Historian` (`sum_corpus_bytes("messages", …)`
  and `per_day_bytes_query("messages", …)`) are this query plus a range and
  a `sum(octet_length(content))`.

  **The invariant:** any filter added here is inherited by the byte signal
  automatically. Adding an eligibility filter to only one side is a bug of
  a specific, measured class — task `019fa1cc` found 86 oversize digest
  windows on prod, 56 of them spurious, because these two callers each
  carried their own copy of the predicate and the copies drifted. Do not
  hand-write this filter list anywhere else; compose this query.

  Accepts the same `:include_kinds` / `:content_types` / `:include_archived`
  / `:scope` options as `list_messages_since/2`, with the same defaults.
  """
  @spec digest_eligible_messages_query(keyword()) :: Ecto.Query.t()
  def digest_eligible_messages_query(opts \\ []) do
    include_kinds = Keyword.get(opts, :include_kinds, ~w(channel group))
    content_types = Keyword.get(opts, :content_types, ~w(text agent_action))
    include_archived = Keyword.get(opts, :include_archived, false)
    scope = Keyword.get(opts, :scope, :internal)

    query =
      from(m in Message,
        join: s in Space,
        on: s.id == m.space_id,
        where:
          is_nil(m.deleted_at) and
            m.log_only == false and
            m.content_type in ^content_types and
            s.kind in ^include_kinds
      )

    query = apply_digest_scope(query, scope)

    if include_archived do
      # Deletion-flagged spaces must vanish from search immediately even
      # though their history would otherwise qualify as "archived".
      where(query, [m, s], is_nil(s.deletion_scheduled_at))
    else
      where(query, [m, s], is_nil(s.archived_at))
    end
  end

  # ── External-space digest partition (stack member 12, rbac-external-users) ──
  #
  # The Historian's activity digest partitions message/transcript selection
  # by the M1 `external` marker in BOTH directions:
  #   * `:internal` (default) — exclude external-user spaces/DMs from the
  #     internal digest.
  #   * `{:external_spaces, ids}` — restrict to the external user's
  #     allowlisted spaces for an external-user-facing summary.
  # `external_space_ids/0` and `participant_space_ids_for_user/1` supply the
  # two id-sets; `list_messages_since/2` and `Meetings.list_transcripts_since/2`
  # thread the `:scope` opt.

  defp apply_digest_scope(query, :internal) do
    exclude = external_space_ids()
    where(query, [m, s], s.id not in ^exclude)
  end

  defp apply_digest_scope(query, {:external_spaces, space_ids}) do
    where(query, [m, s], s.id in ^space_ids)
  end

  @doc """
  Distinct chat space ids that carry any external-visible content — i.e.
  spaces where at least one external user (a user holding an
  `org_memberships.external == true` membership, per M1) participates.

  A MIXED space (both an internal human and an external user as participants)
  classifies as external here: its content is already visible to an
  external party, so it belongs to the external surface and is excluded
  from the pure internal Historian digest.

  Returns `[]` when there are no external memberships (fast path — the
  internal digest's `NOT IN ^[]` filter is then a no-op, leaving all-internal
  orgs byte-for-byte unchanged).
  """
  @spec external_space_ids() :: [binary()]
  def external_space_ids do
    external_user_ids =
      Tenancy.list_orgs()
      |> Enum.flat_map(&Tenancy.list_external_memberships(&1.id))
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()

    case external_user_ids do
      [] ->
        []

      ids ->
        from(p in Participant,
          where: p.participant_type == "user" and p.participant_id in ^ids,
          distinct: true,
          select: p.space_id
        )
        |> Repo.all()
    end
  end

  @doc """
  Distinct chat space ids the given external `user_id` participates in.

  This is the allowlisted-space set that scopes an external-user-facing
  summary: an external user is only ever a participant of their allowlisted
  spaces, so scoping a digest to this set intrinsically excludes
  internal content.
  """
  @spec participant_space_ids_for_user(binary()) :: [binary()]
  def participant_space_ids_for_user(user_id) when is_binary(user_id) do
    from(p in Participant,
      where: p.participant_type == "user" and p.participant_id == ^user_id,
      distinct: true,
      select: p.space_id
    )
    |> Repo.all()
  end

  @doc """
  Distinct chat_participants ROW ids (the `id` PK, which
  `push_subscriptions.participant_id` references) for the given human
  `user_id` across every space they participate in.

  A user has one participant row per space, so this returns the full set of
  push targets for that user. Returns `[]` when the user has no participant
  rows (then a caller's push fan-out is simply a no-op). Distinct from
  `participant_space_ids_for_user/1` (which selects `space_id`); this selects
  the participant PK used by `Platform.Push.send_notification/2`.
  """
  @spec participant_ids_for_user(binary()) :: [binary()]
  def participant_ids_for_user(user_id) when is_binary(user_id) do
    from(p in Participant,
      where: p.participant_type == "user" and p.participant_id == ^user_id,
      distinct: true,
      select: p.id
    )
    |> Repo.all()
  end

  @doc """
  Returns the deduplicated list of participant ids (the chat_participants
  `id` column, the same value used as the `chat:participant:<id>` PubSub
  topic suffix) entitled to receive `{:message_edited, payload}` for this
  message per Policy 1 of the editable-messages contract.

  Eligible set is the union of:
    1. Participants of the message's chat space whose body matches the
       canonical mention predicate
       (`Platform.Chat.AttentionRouter.mentioned?/2`, which covers ADR
       0037 `@[Display Name]` bracketed form, legacy `@name` substring
       form, the participant's id, and user-configured
       `attention_config["keywords"]`).
    2. Agent participants of the message's space whose `participant_id`
       matches the `assignee_id` of the task linked to the space via
       `chat_spaces.metadata["task_id"]` (the same execution-space-binding
       pattern AttentionRouter and Policy 2 freeze use).

  The two clauses are unioned and deduplicated so an agent that is both
  `@`-mentioned and task-assigned receives the broadcast exactly once.

  Pure read, idempotent. Returns `[]` when no participants match, when
  the space has no `metadata["task_id"]`, when the linked task is missing,
  or when the assignee is a user (not an agent). The caller is
  `Platform.Chat.Messages.Edit` (Stage 2 of task 019e1e83), which
  broadcasts to each entitled participant's runtime topic in addition to
  the existing space-wide broadcast that user LiveView clients subscribe to.
  """
  @spec eligible_edit_recipients_for_message(Message.t()) :: [binary()]
  def eligible_edit_recipients_for_message(%Message{space_id: space_id} = message)
      when is_binary(space_id) do
    participants = list_participants(space_id)

    mentioned_ids =
      participants
      |> Enum.filter(&Platform.Chat.AttentionRouter.mentioned?(&1, message))
      |> Enum.map(& &1.id)

    assignee_ids = task_assignee_participant_ids_for_space(space_id, participants)

    Enum.uniq(mentioned_ids ++ assignee_ids)
  end

  def eligible_edit_recipients_for_message(_), do: []

  defp task_assignee_participant_ids_for_space(space_id, participants) do
    with %Space{metadata: %{"task_id" => task_id}} <- Repo.get(Space, space_id),
         true <- is_binary(task_id),
         %Platform.Tasks.Task{assignee_type: "agent", assignee_id: assignee_id} <-
           Repo.get(Platform.Tasks.Task, task_id),
         true <- is_binary(assignee_id) do
      participants
      |> Enum.filter(fn p ->
        p.participant_type == "agent" and p.participant_id == assignee_id
      end)
      |> Enum.map(& &1.id)
    else
      _ -> []
    end
  end

  @doc """
  For a list of message IDs, returns thread preview data for any that have threads with replies.

  Returns `%{message_id => %{thread_id: id, reply_count: count, last_reply_at: datetime}}`.
  """
  @spec thread_previews_for_messages([binary()]) :: map()
  def thread_previews_for_messages([]), do: %{}

  def thread_previews_for_messages(message_ids) do
    from(t in Thread,
      where: t.parent_message_id in ^message_ids,
      left_join: m in Message,
      on: m.thread_id == t.id and is_nil(m.deleted_at),
      group_by: [t.id, t.parent_message_id],
      having: count(m.id) > 0,
      select:
        {t.parent_message_id,
         %{thread_id: t.id, reply_count: count(m.id), last_reply_at: max(m.inserted_at)}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns true when `query` parses to at least one lexeme under the SAME
  `websearch_to_tsquery('english', ...)` parse that `search_messages/3` uses.

  Exists so callers can tell "no message matched" apart from "the query had
  nothing to match with". Punctuation-only input (`"--- ??? !!!"`) parses to an
  EMPTY tsquery, which matches every row zero times — indistinguishable from a
  genuine miss if you only look at the row count. Task 01a006c2 stage 4.

  Note that UUIDs and dates are NOT in this category: Postgres' `english`
  parser splits `01a006c2-6c88-...` and `2026-08-15` into real lexemes, so they
  search fine.
  """
  @spec searchable_query?(term()) :: boolean()
  def searchable_query?(query) when not is_binary(query), do: false

  def searchable_query?(query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      false
    else
      %{rows: [[rendered]]} =
        Repo.query!("SELECT websearch_to_tsquery('english', $1)::text", [trimmed])

      rendered not in [nil, ""]
    end
  end

  @doc """
  Full-text search messages in a space using PostgreSQL text search.

  Returns up to `limit` results ordered by search rank (highest first) with a
  lightweight highlighted excerpt in the virtual `search_headline` field.
  Blank queries return an empty list.
  """
  @spec search_messages(binary(), String.t(), keyword()) :: [Message.t()]
  def search_messages(space_id, query, opts \\ [])
  def search_messages(_space_id, query, _opts) when not is_binary(query) or query == "", do: []

  def search_messages(space_id, query, opts) do
    trimmed_query = String.trim(query)

    if trimmed_query == "" do
      []
    else
      from(m in Message, where: m.space_id == ^space_id)
      |> ranked_message_search(trimmed_query, opts)
    end
  end

  @doc """
  Full-text search messages across several spaces at once. The cross-space
  sibling of `search_messages/3`, with the same parse, rank, headline and
  external-scope ordering.

  Returns up to `:limit` (default 20) `%Message{}` hits ordered by search rank
  (highest first), then newest first, each carrying the virtual
  `search_rank` and `search_headline` fields. Top-level messages AND thread
  replies match; every hit carries its own `space_id` (and `thread_id`), so a
  caller can link `?message=<id>` into the right space.

  Returns `[]` for an empty `space_ids` list, a blank query, or a query that
  parses to no lexemes (see `searchable_query?/1`).

  **This function does not decide which spaces a user may read.** The caller
  passes only the spaces already on that user's list (the Chat list passes
  channels ++ DMs minus restricted channels). A caller that passes an
  arbitrary space id gets that space's rows, exactly as `search_messages/3`
  does today. `:scope` (an `ExternalScope` or `Access.Scope`) narrows the
  rows further and is applied BEFORE `ts_headline` runs.

  Naming the author: a hit is a full `%Message{}`, so the existing
  `PlatformWeb.ChatLive.PresenceHooks.sender_name/2` message clause resolves
  it (the live participant name when the caller has it in its participants
  map, else the `author_display_name` snapshot). Naming the space is the
  caller's job, from the same list it took `space_ids` from.
  """
  @spec search_messages_in_spaces([binary()], String.t(), keyword()) :: [Message.t()]
  def search_messages_in_spaces(space_ids, query, opts \\ [])
  def search_messages_in_spaces([], _query, _opts), do: []

  def search_messages_in_spaces(_space_ids, query, _opts)
      when not is_binary(query) or query == "",
      do: []

  def search_messages_in_spaces(space_ids, query, opts) when is_list(space_ids) do
    trimmed_query = String.trim(query)

    if searchable_query?(trimmed_query) do
      from(m in Message, where: m.space_id in ^space_ids)
      |> ranked_message_search(trimmed_query, opts)
    else
      []
    end
  end

  # The shared body of `search_messages/3` and `search_messages_in_spaces/3`.
  # `base` carries the caller's space filter; everything else (deleted rows
  # out, the tsquery match, the external scope, rank, headline, order, limit)
  # is defined once here so the two searches cannot drift.
  defp ranked_message_search(base, trimmed_query, opts) do
    limit = Keyword.get(opts, :limit, 20)
    scope = Keyword.get(opts, :scope)

    # Apply the external scope to the row filter FIRST — an out-of-scope
    # `space_id` (the M6-bypassed case) yields zero rows BEFORE `ts_headline`
    # ever runs, so no highlighted fragment of an off-limits message is
    # produced (design canvas §9).
    filtered =
      from(m in base,
        where:
          is_nil(m.deleted_at) and
            fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^trimmed_query)
      )
      |> ExternalScope.scope_by_space_id(scope)

    from(m in filtered,
      select_merge: %{
        search_rank:
          fragment(
            "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))",
            ^trimmed_query
          ),
        search_headline:
          fragment(
            "ts_headline('english', coalesce(?, ''), websearch_to_tsquery('english', ?), 'StartSel=<mark>, StopSel=</mark>, MaxWords=18, MinWords=5')",
            m.content,
            ^trimmed_query
          )
      },
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))",
            ^trimmed_query
          ),
        desc: m.inserted_at
      ],
      limit: ^limit
    )
    |> Repo.all()
  end

  @typedoc """
  One `search_canvases/3` hit.

  `snippet` is `nil` unless the BODY matched and the TITLE did not — see
  `search_canvases/3`. It carries `<mark>` markup and is **not** HTML-safe;
  render it through the same sanitising path the message search headline
  already uses, never `raw/1`.
  """
  @type canvas_search_hit :: %{
          canvas: Canvas.t(),
          title_matched?: boolean(),
          body_matched?: boolean(),
          snippet: String.t() | nil,
          rank: float()
        }

  @doc """
  Full-text search canvases across `space_ids`, over TITLE **and** BODY.

  Returns up to `:limit` (default 25) `t:canvas_search_hit/0` maps, best-first.
  A blank or non-binary query returns `[]` without touching the database.

  ## The left join is load-bearing

  `chat_canvases.title_search_vector` has shipped since task `019fb954-c848`;
  `chat_canvas_search` is new in task `01a07402` and is populated by a backfill
  that may not have reached every row yet. An INNER join here would drop every
  canvas without an index row — **including from title search, which works
  today** — turning a partial backfill into a regression of shipped behaviour.
  Hence `left_join` plus `coalesce(?, ''::tsvector)` on the body side, and
  `canvas_search_test.exs`'s "unindexed title match" test.

  ## Ranking comes from the stored weights, not from bespoke scoring

  The title vector is weight `B` and the body vector is weight `D`, so
  `ts_rank_cd` over `title || body` scores a title hit 0.4 against a body hit's
  0.1 with no scoring factor of our own. That is a per-occurrence comparison,
  not a guarantee: `ts_rank_cd` with the default `normalization = 0` SUMS cover
  densities, so a body repeating the term many times does outrank a
  single-occurrence title (measured: ~6 occurrences draws level, 20 wins
  outright). That is ordinary term-frequency behaviour and is deliberately left
  alone — bending it back would mean inventing exactly the bespoke scoring the
  weights exist to avoid.

  `c.updated_at` desc is the tiebreak, so equal-rank rows have a stable order.

  ## `snippet` is suppressed on a title match

  Per the design canvas: a caller must not be able to render a body fragment
  next to a title hit, so the rule is *nil unless `body_matched? and not
  title_matched?`*, applied in Elixir after the query. The both-matched case
  collapses into "title matched -> no snippet" by the canvas author's explicit
  sanction, rather than growing a third rendering mode.
  """
  @spec search_canvases([binary()], String.t(), keyword()) :: [canvas_search_hit()]
  def search_canvases(space_ids, query, opts \\ [])

  def search_canvases(_space_ids, query, _opts) when not is_binary(query), do: []

  def search_canvases(space_ids, query, opts) when is_list(space_ids) do
    # An embedded hyphen is part of a canvas title, not websearch's negation
    # operator. Keep a leading `-term` intact for callers using that syntax.
    trimmed_query =
      query
      |> String.trim()
      |> String.replace(~r/(?<=[[:alnum:]])-(?=[[:alnum:]])/u, " ")

    if space_ids == [] or trimmed_query == "" do
      []
    else
      limit = Keyword.get(opts, :limit, 25)

      from(c in Canvas,
        left_join: s in CanvasSearchIndex,
        on: s.canvas_id == c.id,
        where: c.space_id in ^space_ids and is_nil(c.deleted_at),
        where:
          fragment(
            "(? @@ websearch_to_tsquery('english', ?)) OR (coalesce(?, ''::tsvector) @@ websearch_to_tsquery('english', ?))",
            c.title_search_vector,
            ^trimmed_query,
            s.body_search_vector,
            ^trimmed_query
          ),
        order_by: [
          desc:
            fragment(
              "ts_rank_cd(? || coalesce(?, ''::tsvector), websearch_to_tsquery('english', ?))",
              c.title_search_vector,
              s.body_search_vector,
              ^trimmed_query
            ),
          desc: c.updated_at
        ],
        limit: ^limit,
        select: %{
          canvas: c,
          title_matched?:
            fragment(
              "(? @@ websearch_to_tsquery('english', ?))",
              c.title_search_vector,
              ^trimmed_query
            ),
          body_matched?:
            fragment(
              "(coalesce(?, ''::tsvector) @@ websearch_to_tsquery('english', ?))",
              s.body_search_vector,
              ^trimmed_query
            ),
          rank:
            fragment(
              "ts_rank_cd(? || coalesce(?, ''::tsvector), websearch_to_tsquery('english', ?))",
              c.title_search_vector,
              s.body_search_vector,
              ^trimmed_query
            ),
          # `body_text` rides along so the ellipsis rule below can ask where in
          # the document the headline came from. Bounded by `:limit` rows.
          body_text: s.body_text,
          headline:
            fragment(
              "ts_headline('english', coalesce(?, ''), websearch_to_tsquery('english', ?), 'StartSel=<mark>, StopSel=</mark>, MaxWords=18, MinWords=8, MaxFragments=1')",
              s.body_text,
              ^trimmed_query
            )
        }
      )
      |> maybe_scope_canvases(canvas_access_scope(opts))
      |> Repo.all()
      |> Enum.map(&canvas_search_hit/1)
    end
  end

  defp canvas_search_hit(row) do
    %{
      canvas: row.canvas,
      title_matched?: row.title_matched?,
      body_matched?: row.body_matched?,
      rank: row.rank,
      snippet: canvas_search_snippet(row)
    }
  end

  # The design rule, enforced HERE rather than in the query: a title match
  # never carries a body fragment.
  defp canvas_search_snippet(%{body_matched?: true, title_matched?: false} = row) do
    ellipsised_headline(row.headline, row.body_text)
  end

  defp canvas_search_snippet(_row), do: nil

  # Mark a fragment as a fragment.
  #
  # `ts_headline/4` returns a verbatim slice of its input with `<mark>` tags
  # inserted, so the source text is recoverable by stripping the markup — and
  # that stripped slice is then a literal prefix / suffix of `body_text` exactly
  # when the fragment reaches that end of the document. Both sides are trimmed
  # first because `ts_headline` drops leading non-token characters (the `# ` of
  # a markdown heading, a leading blank line) that would otherwise read as
  # "started late".
  #
  # Anything the comparison cannot recognise falls through to BOTH ellipses,
  # which is the conservative direction: an over-marked fragment understates
  # what the reader is being shown, whereas a missing leading ellipsis would
  # claim a mid-document match is the document's opening line.
  defp ellipsised_headline(nil, _body_text), do: nil

  defp ellipsised_headline(headline, body_text) do
    fragment_text = String.trim(headline)

    stripped =
      fragment_text
      |> String.replace("<mark>", "")
      |> String.replace("</mark>", "")

    body = String.trim(body_text || "")

    prefix = if String.starts_with?(body, stripped), do: "", else: "… "
    suffix = if String.ends_with?(body, stripped), do: "", else: " …"

    prefix <> fragment_text <> suffix
  end

  @doc """
  The one author rule for editing or unsending a message (task 01a111bb):
  only the participant who wrote it may. A nil participant (not in the
  space) is forbidden.

  Shared by ChatLive's inline editor, the HTTP `PATCH /api/messages/:id`
  and the native app's `PlatformWeb.AppMessagesController`.
  """
  @spec authorize_author(Message.t(), Participant.t() | map() | nil) ::
          :ok | {:error, :forbidden}
  def authorize_author(_message, nil), do: {:error, :forbidden}
  def authorize_author(%Message{participant_id: pid}, %{id: pid}) when is_binary(pid), do: :ok
  def authorize_author(_message, _participant), do: {:error, :forbidden}

  @doc """
  Edit a message's content. Sets `edited_at` to now.

  Refuses a frozen message (an agent began work on it) with
  `{:error, :frozen, freezing_action}`, the same answer
  `Platform.Chat.Messages.Edit.apply_edit/3` gives, so no caller can edit
  past the freeze (task 01a111bb).
  """
  @spec edit_message(Message.t(), String.t()) ::
          {:ok, Message.t()}
          | {:error, Ecto.Changeset.t() | :space_archived}
          | {:error, :frozen, map()}
  def edit_message(%Message{frozen_at: %DateTime{}} = message, _content),
    do: {:error, :frozen, Platform.Chat.Messages.Edit.freezing_action(message)}

  def edit_message(%Message{} = message, content) do
    with :ok <- ensure_message_space_writable(message) do
      do_edit_message(message, content)
    end
  end

  defp do_edit_message(%Message{} = message, content) do
    result =
      message
      |> Message.changeset(%{content: content, edited_at: DateTime.utc_now()})
      |> Repo.update()

    case result do
      {:ok, msg} ->
        :telemetry.execute(
          [:platform, :chat, :message_edited],
          %{system_time: System.system_time()},
          %{message_id: msg.id, space_id: msg.space_id}
        )

        ChatPubSub.broadcast(msg.space_id, {:message_updated, msg})

      _ ->
        :ok
    end

    result
  end

  @doc "Soft-delete a message by setting `deleted_at` to now."
  @spec delete_message(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def delete_message(%Message{} = message) do
    with :ok <- ensure_message_space_writable(message) do
      do_delete_message(message)
    end
  end

  defp do_delete_message(%Message{} = message) do
    result =
      message
      |> Message.changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update()

    case result do
      {:ok, msg} ->
        :telemetry.execute(
          [:platform, :chat, :message_deleted],
          %{system_time: System.system_time()},
          %{message_id: msg.id, space_id: msg.space_id}
        )

        ChatPubSub.broadcast(msg.space_id, {:message_deleted, msg})

      _ ->
        :ok
    end

    result
  end

  @doc """
  Restore a soft-deleted message by clearing `deleted_at`. Counterpart to
  `delete_message/1`. Emits `:message_restored` telemetry and broadcasts
  `{:message_restored, msg}` to the space topic so chat clients can re-stream
  the row. Used by the Activity panel's Restore action (BACKLOG #15).
  """
  @spec restore_message(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def restore_message(%Message{} = message) do
    with :ok <- ensure_message_space_writable(message) do
      do_restore_message(message)
    end
  end

  defp do_restore_message(%Message{} = message) do
    result =
      message
      |> Message.changeset(%{deleted_at: nil})
      |> Repo.update()

    case result do
      {:ok, msg} ->
        :telemetry.execute(
          [:platform, :chat, :message_restored],
          %{system_time: System.system_time()},
          %{message_id: msg.id, space_id: msg.space_id}
        )

        ChatPubSub.broadcast(msg.space_id, {:message_restored, msg})

      _ ->
        :ok
    end

    result
  end

  @doc """
  Returns the set of message ids in `space_id` that are "in context" for
  `agent_participant_id` per the editable-messages Policy 2 contract.

  In-context = union of:

    1. **Mention arm** — messages whose content contains `@[DisplayName]` or
       legacy `@displayname` resolving to the agent participant's
       `display_name`. Mirrors `AttentionRouter` mention semantics.

    2. **Task arm** — when `space_id` is an execution space whose
       `metadata->>'task_id'` resolves to a task assigned to this agent
       (`tasks.assignee_id` == the participant's underlying agent id) AND
       whose status is `"planning"` or `"in_progress"`, every non-deleted
       message in the space is task-linked. Closed/done tasks are excluded
       so historical linkage doesn't eternally freeze old messages.

  Both arms are scoped to the single `space_id` argument — cross-space
  leakage is impossible by construction.

  Returns a `MapSet` of message ids. Returns an empty set if the
  participant doesn't exist in the space, the space doesn't exist, or no
  messages match either arm.

  Used by Policy 2's task-scoped and ad-hoc freeze triggers (task
  `019e1e80-4230-7a79-ac73-c157975b3999`).
  """
  @spec in_context_message_ids_for_agent(binary(), binary()) :: MapSet.t()
  def in_context_message_ids_for_agent(agent_participant_id, space_id)
      when is_binary(agent_participant_id) and is_binary(space_id) do
    case Repo.get(Participant, agent_participant_id) do
      nil ->
        MapSet.new()

      %Participant{space_id: ^space_id} = participant ->
        mention_ids = mention_arm_message_ids(participant, space_id)
        task_ids = task_arm_message_ids(participant, space_id)
        MapSet.union(mention_ids, task_ids)

      %Participant{} ->
        # Participant exists but is in a different space — empty (no cross-space leakage).
        MapSet.new()
    end
  end

  defp mention_arm_message_ids(%Participant{display_name: nil}, _space_id), do: MapSet.new()

  defp mention_arm_message_ids(%Participant{display_name: ""}, _space_id), do: MapSet.new()

  defp mention_arm_message_ids(%Participant{display_name: display_name}, space_id) do
    # Match ADR 0037 bracketed (@[Name]) or legacy (@name) mention forms.
    # Display name is escaped for ILIKE so `%` or `_` in a name doesn't
    # accidentally widen the match.
    escaped = escape_ilike(display_name)
    bracketed = "%@[" <> escaped <> "]%"
    legacy = "%@" <> escaped <> "%"

    ids =
      from(m in Message,
        where:
          m.space_id == ^space_id and
            is_nil(m.deleted_at) and
            (ilike(m.content, ^bracketed) or ilike(m.content, ^legacy)),
        select: m.id
      )
      |> Repo.all()

    MapSet.new(ids)
  end

  defp task_arm_message_ids(%Participant{participant_id: nil}, _space_id), do: MapSet.new()

  defp task_arm_message_ids(
         %Participant{participant_type: "agent", participant_id: agent_id},
         space_id
       )
       when is_binary(agent_id) do
    # The given space is task-linked for this agent IFF:
    #   space.kind == "execution"
    #   AND space.metadata->>'task_id' resolves to a task whose
    #       assignee_id == agent_id AND status IN (planning, in_progress).
    # If yes, every non-deleted message in the space is task-linked.
    case Repo.get(Space, space_id) do
      %Space{kind: "execution", metadata: %{} = metadata} ->
        task_id = Map.get(metadata, "task_id") || Map.get(metadata, :task_id)

        if is_binary(task_id) and task_linked?(task_id, agent_id) do
          ids =
            from(m in Message,
              where: m.space_id == ^space_id and is_nil(m.deleted_at),
              select: m.id
            )
            |> Repo.all()

          MapSet.new(ids)
        else
          MapSet.new()
        end

      _ ->
        MapSet.new()
    end
  end

  defp task_arm_message_ids(_participant, _space_id), do: MapSet.new()

  defp task_linked?(task_id, agent_id) do
    from(t in Platform.Tasks.Task,
      where:
        t.id == ^task_id and
          t.assignee_id == ^agent_id and
          t.status in ["planning", "in_progress"] and
          is_nil(t.deleted_at),
      select: t.id
    )
    |> Repo.exists?()
  end

  defp escape_ilike(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── Threads ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new thread anchored to a space.

  `space_id` is injected automatically. Optional attrs:
  `:parent_message_id`, `:title`, `:metadata`.
  """
  @spec create_thread(binary(), map()) ::
          {:ok, Thread.t()} | {:error, Ecto.Changeset.t()}
  def create_thread(space_id, attrs \\ %{}) do
    attrs = Map.put(attrs, :space_id, space_id)

    %Thread{}
    |> Thread.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a thread by primary key. Returns `nil` if not found."
  @spec get_thread(binary()) :: Thread.t() | nil
  # Guarded: `thread_id` reaches reply_to_thread/3 from the thread UI.
  def get_thread(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Thread, id), else: nil
  end

  @doc """
  Find the thread anchored to a specific parent message.

  Returns `nil` if no thread has been started for this message yet.
  """
  @spec get_thread_for_message(binary()) :: Thread.t() | nil
  def get_thread_for_message(parent_message_id) do
    Repo.get_by(Thread, parent_message_id: parent_message_id)
  end

  @doc "List threads in a space, oldest first."
  @spec list_threads(binary()) :: [Thread.t()]
  def list_threads(space_id) do
    from(t in Thread, where: t.space_id == ^space_id, order_by: [asc: t.inserted_at])
    |> Repo.all()
  end

  @doc """
  The space's threads that have at least one non-deleted reply, for the phone
  space sheet's Threads page (task 01a1557a-8a6d stage 2). Most recent reply
  first, at most 50, each as
  `%{thread_id, parent_message_id, excerpt, author, reply_count, last_reply_at}`.

  The reply aggregate is `thread_previews_for_messages/1`'s: non-deleted
  replies only, counted and their latest `inserted_at` taken. `excerpt` and
  `author` come from the parent message, and are nil when that message is
  deleted, so a deleted parent's text is never shown.

  The optional `:scope` drops threads in spaces outside an external caller's
  participant set (`ExternalScope.scope_by_space_id/2`).
  """
  @spec list_thread_summaries(binary(), keyword()) :: [map()]
  def list_thread_summaries(space_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    replies =
      from(r in Message,
        where: r.space_id == ^space_id and not is_nil(r.thread_id) and is_nil(r.deleted_at),
        group_by: r.thread_id,
        select: %{
          thread_id: r.thread_id,
          reply_count: count(r.id),
          last_reply_at: max(r.inserted_at)
        }
      )

    from(t in Thread,
      join: r in subquery(replies),
      on: r.thread_id == t.id,
      left_join: pm in Message,
      on: pm.id == t.parent_message_id and is_nil(pm.deleted_at),
      left_join: a in Participant,
      on: a.id == pm.participant_id,
      where: t.space_id == ^space_id,
      order_by: [desc: r.last_reply_at, desc: t.id],
      limit: 50,
      select: %{
        thread_id: t.id,
        parent_message_id: t.parent_message_id,
        excerpt: pm.content,
        author: a.display_name,
        reply_count: r.reply_count,
        last_reply_at: r.last_reply_at
      }
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
  end

  @doc """
  Idempotent thread creation for a parent message.

  If a thread already exists anchored to `parent_message_id`, returns it.
  Otherwise creates a new thread in the space. Optional attrs: `:title`, `:metadata`.
  """
  @spec create_thread_for_message(binary(), binary(), map()) ::
          {:ok, Thread.t()} | {:error, Ecto.Changeset.t()}
  def create_thread_for_message(space_id, parent_message_id, attrs \\ %{}) do
    case Repo.get_by(Thread, parent_message_id: parent_message_id) do
      %Thread{} = existing ->
        {:ok, existing}

      nil ->
        attrs =
          attrs
          |> Map.put(:space_id, space_id)
          |> Map.put(:parent_message_id, parent_message_id)

        result =
          %Thread{}
          |> Thread.changeset(attrs)
          |> Repo.insert()

        case result do
          {:ok, thread} ->
            :telemetry.execute(
              [:platform, :chat, :thread_created],
              %{system_time: System.system_time()},
              %{space_id: space_id, thread_id: thread.id, parent_message_id: parent_message_id}
            )

          _ ->
            :ok
        end

        result
    end
  end

  @doc """
  Post a reply to an existing thread.

  Creates a message in `space_id` with `thread_id` set. Returns `{:error, :thread_not_found}`
  if the thread ID does not exist.
  """
  @spec reply_to_thread(binary(), binary(), map()) ::
          {:ok, Message.t()} | {:error, :thread_not_found | Ecto.Changeset.t()}
  def reply_to_thread(thread_id, participant_id, attrs) do
    case Repo.get(Thread, thread_id) do
      nil ->
        {:error, :thread_not_found}

      thread ->
        attrs =
          attrs
          |> Map.put(:space_id, thread.space_id)
          |> Map.put(:thread_id, thread_id)
          |> Map.put(:participant_id, participant_id)
          |> Map.put_new(:content_type, "text")

        post_message(attrs)
    end
  end

  @doc "Returns the number of replies in a thread."
  @spec count_thread_replies(binary()) :: non_neg_integer()
  def count_thread_replies(thread_id) do
    from(m in Message, where: m.thread_id == ^thread_id and is_nil(m.deleted_at), select: count())
    |> Repo.one()
  end

  @doc "Batch version: returns `%{thread_id => reply_count}` for the given thread IDs."
  @spec list_thread_reply_counts([binary()]) :: %{binary() => non_neg_integer()}
  def list_thread_reply_counts([]), do: %{}

  def list_thread_reply_counts(thread_ids) do
    from(m in Message,
      where: m.thread_id in ^thread_ids and is_nil(m.deleted_at),
      group_by: m.thread_id,
      select: {m.thread_id, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  # NOTE (task 01a01041 stage 2): a SECOND, byte-identical definition of
  # `thread_previews_for_messages/1` used to sit here, ~460 lines after the
  # canonical one at the top of this module. Both clauses were unreachable
  # (`cannot match because a previous clause at line 2052 always matches`), so
  # every caller has always been served by the earlier copy. `diff` of the two
  # blocks — docstring, `@spec`, and both bodies — was empty, so there is no
  # behaviour question about which one callers get: the two were the same
  # function. The dead pair is deleted; the live one is unchanged.

  # ── Reactions ───────────────────────────────────────────────────────────────

  @doc """
  Add a reaction to a message.

  Required attrs: `:message_id`, `:participant_id`, `:emoji`.

  Captures a reactor identity snapshot (display name, avatar, participant
  type) from the current `chat_participants` row — mirrors ADR 0038's
  author snapshots on `chat_messages`. If the participant is hard-deleted
  from the space later, the reactor's name still renders in reactor
  popovers and MCP tool output.

  Callers MAY override the snapshot fields via `attrs` (e.g. tests
  asserting specific snapshot state); when absent, we look them up.
  """
  @spec add_reaction(map()) ::
          {:ok, Reaction.t()} | {:error, :space_archived | Ecto.Changeset.t()}
  def add_reaction(attrs) do
    with :ok <- ensure_message_space_writable(attrs[:message_id] || attrs["message_id"]) do
      do_add_reaction(attrs)
    end
  end

  defp do_add_reaction(attrs) do
    attrs_with_snapshot = maybe_put_reactor_snapshot(attrs)

    msg_id = Map.get(attrs_with_snapshot, :message_id)
    pid = Map.get(attrs_with_snapshot, :participant_id)
    emoji = Map.get(attrs_with_snapshot, :emoji)

    # If a *soft-deleted* row already exists for this (message, participant,
    # emoji), resurrect it (clear `deleted_at`) instead of inserting a
    # duplicate. Keeps the table clean and lets the partial unique index do
    # its job. Active-row duplicates fall through to a regular insert and
    # produce a natural `{:error, changeset}` with the unique_constraint
    # violation — preserving the pre-soft-delete public API contract that
    # callers (e.g. `Federation.ToolSurface`'s `react` handler) rely on to
    # detect "already_reacted."
    result =
      case find_soft_deleted_reaction(msg_id, pid, emoji) do
        %Reaction{} = soft_deleted ->
          soft_deleted
          |> Reaction.delete_changeset(%{deleted_at: nil})
          |> Repo.update()

        nil ->
          %Reaction{}
          |> Reaction.changeset(attrs_with_snapshot)
          |> Repo.insert()
      end

    case result do
      {:ok, r} ->
        :telemetry.execute(
          [:platform, :chat, :reaction_added],
          %{system_time: System.system_time()},
          %{message_id: r.message_id, participant_id: r.participant_id, emoji: r.emoji}
        )

        case Repo.get(Message, r.message_id) do
          %Message{space_id: space_id} -> ChatPubSub.broadcast(space_id, {:reaction_added, r})
          nil -> :ok
        end

      _ ->
        :ok
    end

    result
  end

  defp find_soft_deleted_reaction(nil, _pid, _emoji), do: nil
  defp find_soft_deleted_reaction(_msg_id, nil, _emoji), do: nil
  defp find_soft_deleted_reaction(_msg_id, _pid, nil), do: nil

  defp find_soft_deleted_reaction(msg_id, pid, emoji) do
    from(r in Reaction,
      where:
        r.message_id == ^msg_id and r.participant_id == ^pid and r.emoji == ^emoji and
          not is_nil(r.deleted_at),
      limit: 1
    )
    |> Repo.one()
  end

  # Stamp reactor-identity snapshot from the current participant row if
  # the caller didn't pass one. A missing participant still inserts the
  # reaction cleanly — the snapshot fields stay nil and the read-path
  # falls through to `get_participant/1` and eventually "Someone."
  defp maybe_put_reactor_snapshot(attrs) do
    attrs = normalize_attr_keys(attrs)
    participant_id = Map.get(attrs, :participant_id)

    snapshot_present? =
      Map.has_key?(attrs, :reactor_display_name) or
        Map.has_key?(attrs, :reactor_participant_type)

    cond do
      snapshot_present? ->
        attrs

      is_binary(participant_id) ->
        case Repo.get(Participant, participant_id) do
          %Participant{} = p ->
            attrs
            |> Map.put_new(:reactor_display_name, p.display_name)
            |> Map.put_new(:reactor_avatar_url, p.avatar_url)
            |> Map.put_new(:reactor_participant_type, p.participant_type)

          _ ->
            attrs
        end

      true ->
        attrs
    end
  end

  defp normalize_attr_keys(%{} = attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end

  @doc """
  Soft-delete a reaction (sets `deleted_at`). Returns `{:error, :not_found}`
  if no active reaction exists for the (message, participant, emoji) triple.
  Already soft-deleted rows are treated as not-found, since the user-visible
  state is identical.
  """
  @spec remove_reaction(binary(), binary(), String.t()) ::
          {:ok, Reaction.t()} | {:error, :not_found | any()}
  def remove_reaction(message_id, participant_id, emoji) do
    with :ok <- ensure_message_space_writable(message_id) do
      do_remove_reaction(message_id, participant_id, emoji)
    end
  end

  defp do_remove_reaction(message_id, participant_id, emoji) do
    query =
      from(r in Reaction,
        where:
          r.message_id == ^message_id and
            r.participant_id == ^participant_id and
            r.emoji == ^emoji and
            is_nil(r.deleted_at)
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      reaction ->
        with {:ok, deleted} <-
               reaction
               |> Reaction.delete_changeset(%{deleted_at: DateTime.utc_now()})
               |> Repo.update() do
          :telemetry.execute(
            [:platform, :chat, :reaction_removed],
            %{system_time: System.system_time()},
            %{message_id: message_id, participant_id: participant_id, emoji: emoji}
          )

          case Repo.get(Message, message_id) do
            %Message{space_id: space_id} ->
              ChatPubSub.broadcast(
                space_id,
                {:reaction_removed,
                 %{message_id: message_id, participant_id: participant_id, emoji: emoji}}
              )

            nil ->
              :ok
          end

          {:ok, deleted}
        end
    end
  end

  @doc "List active reactions for a message (soft-deleted rows excluded), ordered by insertion time."
  @spec list_reactions(binary()) :: [Reaction.t()]
  def list_reactions(message_id) do
    from(r in Reaction,
      where: r.message_id == ^message_id and is_nil(r.deleted_at),
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  List reactions for a message grouped by emoji.

  Returns a list of maps with `:emoji`, `:count`, and `:participants`
  (list of participant_ids who reacted with that emoji), ordered by first
  appearance.

  Example:
      [%{emoji: "👍", count: 2, participants: ["uid-1", "uid-2"]}, ...]
  """
  @spec list_reactions_grouped(binary()) :: [
          %{emoji: String.t(), count: non_neg_integer(), participants: [binary()]}
        ]
  def list_reactions_grouped(message_id) do
    message_id
    |> list_reactions()
    |> Enum.group_by(& &1.emoji)
    |> Enum.map(fn {emoji, reactions} ->
      %{
        emoji: emoji,
        count: length(reactions),
        participants: Enum.map(reactions, & &1.participant_id)
      }
    end)
    |> Enum.sort_by(fn %{participants: ps} ->
      # stable ordering by first reactor's insertion (already sorted in list_reactions)
      List.first(ps)
    end)
  end

  @doc """
  Toggle a reaction on a message.

  If the participant has already reacted with this emoji, removes the reaction.
  Otherwise adds it. Returns `{:ok, :added, Reaction.t()}` or `{:ok, :removed, Reaction.t()}`.
  """
  @spec toggle_reaction(binary(), binary(), String.t()) ::
          {:ok, :added, Reaction.t()}
          | {:ok, :removed, Reaction.t()}
          | {:error, any()}
  def toggle_reaction(message_id, participant_id, emoji) do
    # Treat a soft-deleted row as "not present" — toggling on it should re-add
    # (handled by add_reaction/1's resurrection path), not remove.
    query =
      from(r in Reaction,
        where:
          r.message_id == ^message_id and
            r.participant_id == ^participant_id and
            r.emoji == ^emoji and
            is_nil(r.deleted_at)
      )

    case Repo.one(query) do
      nil ->
        case add_reaction(%{message_id: message_id, participant_id: participant_id, emoji: emoji}) do
          {:ok, reaction} -> {:ok, :added, reaction}
          {:error, reason} -> {:error, reason}
        end

      _existing ->
        case remove_reaction(message_id, participant_id, emoji) do
          {:ok, reaction} -> {:ok, :removed, reaction}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Batch-load reactions for a list of message IDs in a single query.

  Returns `%{message_id => [Reaction.t()]}`. Message IDs with no reactions
  are omitted from the result map.
  """
  @spec list_reactions_for_messages([binary()]) :: %{binary() => [Reaction.t()]}
  def list_reactions_for_messages([]), do: %{}

  def list_reactions_for_messages(message_ids) do
    from(r in Reaction,
      where: r.message_id in ^message_ids and is_nil(r.deleted_at),
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end

  # ── Pins ────────────────────────────────────────────────────────────────────

  @doc """
  Pin a message in a space.

  Actor-first (task 01a01ce0, stage 1), matching `update_canvas/3` and
  `patch_canvas/3`. `actor` is a `t:Platform.Chat.SpaceAccess.actor/0` —
  `{:user, id}`, `{:agent, id}` or a `%Platform.Accounts.User{}` — and must
  hold a `chat_participants` row in the target space. There is deliberately no
  defaulting arity: a default moves the breakage to runtime and invites
  someone to default it to a bypass.

  Required attrs: `:space_id` and `:message_id`. Both are `:binary_id` columns
  — the pre-actor `@doc` here called `:message_id` an integer, which it has
  not been since the messages table moved to a uuid key.

  `:pinned_by` is DERIVED from the participant `authorize_writer/2` resolved
  IN THE TARGET SPACE, and any caller-supplied `:pinned_by` (or pre-computed
  `pinned_by_*` snapshot) is discarded. `chat_pins.pinned_by` FKs
  `chat_participants(id)` with no same-space constraint, and
  `put_author_snapshot/3` denormalizes a display name onto the row, so without
  this a pin in space B can name a participant of space A and render that
  person to space B's members.
  """
  @spec pin_message(SpaceAccess.actor(), map()) ::
          {:ok, Pin.t()} | {:error, :forbidden | :space_archived | Ecto.Changeset.t()}
  def pin_message(actor, attrs) do
    space_id = attrs[:space_id] || attrs["space_id"]

    # ORDER, and the reconciliation with the canvas writes below — do not
    # re-invert this. `update_canvas/3` and `patch_canvas/3` run
    # `ensure_space_writable/1` FIRST, with a comment saying a member writing
    # to an archived space should hear about the archive rather than about
    # permissions. Authorize-first preserves that outcome exactly, because a
    # member is never `:forbidden` and so still gets `:space_archived`. It
    # additionally denies a NON-member the ability to distinguish an archived
    # space from one that does not exist, which writable-first would leak:
    # `space_writable?/1` returns `true` for unknown ids BY DESIGN, so the two
    # cases answer differently to someone with no claim on either.
    with {:ok, participant} <- SpaceAccess.authorize_writer(space_id, actor),
         :ok <- ensure_space_writable(space_id) do
      attrs
      |> put_pinned_by(participant.id)
      |> do_pin_message()
    end
  end

  # `Ecto.Changeset.cast/3` raises on a map carrying MIXED atom and string
  # keys, so the derived attribution is written back in whatever key style the
  # caller used. The snapshot keys go too: leaving a caller-supplied
  # `pinned_by_display_name` in place would let `already_snapshotted?/2`
  # short-circuit `put_author_snapshot/3` and render a name of the caller's
  # choosing next to the pin.
  @pin_attribution_keys [:pinned_by, :pinned_by_display_name, :pinned_by_participant_type]

  defp put_pinned_by(attrs, participant_id) when is_map(attrs) do
    string_keyed? = Enum.any?(Map.keys(attrs), &is_binary/1)

    attrs =
      Enum.reduce(@pin_attribution_keys, attrs, fn key, acc ->
        acc |> Map.delete(key) |> Map.delete(Atom.to_string(key))
      end)

    if string_keyed?,
      do: Map.put(attrs, "pinned_by", participant_id),
      else: Map.put(attrs, :pinned_by, participant_id)
  end

  defp do_pin_message(attrs) do
    attrs = put_author_snapshot(attrs, :pinned_by, :pinned_by)

    result =
      %Pin{}
      |> Pin.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, pin} ->
        :telemetry.execute(
          [:platform, :chat, :pin_added],
          %{system_time: System.system_time()},
          %{space_id: pin.space_id, message_id: pin.message_id, pinned_by: pin.pinned_by}
        )

        ChatPubSub.broadcast(pin.space_id, {:pin_added, pin})

      _ ->
        :ok
    end

    result
  end

  @doc """
  Unpin a message from a space. Returns `{:error, :not_found}` if not pinned.

  Actor-first (task 01a01ce0, stage 1). See `pin_message/2` for the actor
  contract and for why `authorize_writer/2` runs before the archived check.

  `message_id` is a `:binary_id`, not the integer the pre-actor `@spec`
  claimed.
  """
  @spec unpin_message(SpaceAccess.actor(), binary(), binary()) ::
          {:ok, Pin.t()} | {:error, :forbidden | :space_archived | :not_found | any()}
  def unpin_message(actor, space_id, message_id) do
    with {:ok, _participant} <- SpaceAccess.authorize_writer(space_id, actor),
         :ok <- ensure_space_writable(space_id) do
      do_unpin_message(space_id, message_id)
    end
  end

  defp do_unpin_message(space_id, message_id) when is_binary(message_id) do
    # `message_id` is a `phx-value-` param off
    # `PlatformWeb.ChatLive.PinHooks`'s `"pin_toggle"` clause, and both pin
    # columns are :binary_id. Malformed and absent are the same outcome.
    if Platform.UUID.valid?(message_id) do
      do_unpin_message!(space_id, message_id)
    else
      {:error, :not_found}
    end
  end

  defp do_unpin_message(_space_id, _message_id), do: {:error, :not_found}

  defp do_unpin_message!(space_id, message_id) do
    case Repo.get_by(Pin, space_id: space_id, message_id: message_id) do
      nil ->
        {:error, :not_found}

      pin ->
        with {:ok, deleted} <- Repo.delete(pin) do
          :telemetry.execute(
            [:platform, :chat, :pin_removed],
            %{system_time: System.system_time()},
            %{space_id: space_id, message_id: message_id}
          )

          ChatPubSub.broadcast(
            space_id,
            {:pin_removed, %{space_id: space_id, message_id: message_id}}
          )

          {:ok, deleted}
        end
    end
  end

  @doc "List pinned messages in a space, oldest first."
  @spec list_pins(binary()) :: [Pin.t()]
  def list_pins(space_id) do
    from(p in Pin,
      where: p.space_id == ^space_id,
      order_by: [asc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  The space's pins joined to their messages, for the phone space sheet's
  Pinned page (task 01a1557a-8a6d stage 2): newest pin first, each as
  `%{pin_id, message_id, space_id, content, author, inserted_at, pinned_at}`.
  `inserted_at` is the message's. A pin whose message is deleted is left
  out: its content is gone, and a row with nothing to show is a dead row.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}` or
  `%Platform.Access.Scope{}`) drops pins in spaces outside an external
  caller's participant set, as `list_attachments_for_messages/2` does.
  """
  @spec list_pins_with_messages(binary(), keyword()) :: [map()]
  def list_pins_with_messages(space_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    from(p in Pin,
      join: m in Message,
      on: m.id == p.message_id and m.space_id == p.space_id and is_nil(m.deleted_at),
      left_join: a in Participant,
      on: a.id == m.participant_id,
      where: p.space_id == ^space_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      select: %{
        pin_id: p.id,
        message_id: m.id,
        space_id: p.space_id,
        content: m.content,
        author: a.display_name,
        inserted_at: m.inserted_at,
        pinned_at: p.inserted_at
      }
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
  end

  # ── Canvases ─────────────────────────────────────────────────────────────────
  #
  # First-class space-scoped canvases (ADR 0036). A canvas owns a canonical
  # document. Messages may reference a canvas via `chat_messages.canvas_id`.

  @doc """
  Create a canvas with a validated canonical document.

  Accepts either a raw map of attrs or the tuple form `{space_id, created_by, document}`.
  Required fields: `:space_id`, `:created_by`. Optional: `:title`, `:document`,
  `:metadata`, `:cloned_from`. If `:document` is omitted, a blank canonical
  document is seeded via `CanvasDocument.new/0`.
  """
  @spec create_canvas(map()) ::
          {:ok, Canvas.t()} | {:error, :space_archived | Ecto.Changeset.t()}
  def create_canvas(attrs) do
    with :ok <- ensure_space_writable(attrs[:space_id] || attrs["space_id"]) do
      do_create_canvas(attrs)
    end
  end

  defp do_create_canvas(attrs) do
    attrs =
      attrs
      |> stringify_canvas_payload()
      |> put_canvas_creator_snapshot()

    multi =
      Multi.new()
      |> Multi.insert(:inserted_canvas, Canvas.changeset(%Canvas{}, attrs))
      |> Multi.run(:canvas, fn repo, %{inserted_canvas: canvas} ->
        stamp_scripted_embeds(repo, canvas, CanvasVersions.attribution_from_canvas(canvas))
      end)
      |> CanvasSearchIndex.upsert_multi(:canvas_search, & &1.canvas)
      |> Multi.merge(fn %{canvas: canvas} ->
        version_revision = canvas_version_revision(canvas)

        CanvasVersions.multi_insert(
          Multi.new(),
          :canvas_version,
          canvas.id,
          version_revision,
          canvas.document,
          CanvasVersions.attribution_from_canvas(canvas),
          nil
        )
      end)

    case Repo.transaction(multi) do
      {:ok, %{canvas: canvas}} ->
        publish_canvas_created(canvas)
        {:ok, canvas}

      {:error, step, %Ecto.Changeset{} = changeset, _} when step in [:inserted_canvas, :canvas] ->
        {:error, changeset}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  # Task 01a1316b-677a: stamp every embed's `prototype_ref`
  # (`Platform.Chat.Canvas.ScriptedEmbeds`) AFTER the insert, because a
  # canvas-owned prototype references the canvas row, and inside the same
  # transaction, so a refused stamp (`prototypes_disabled`, ...) creates no
  # canvas. A document with no scripted embed and no stray ref is untouched
  # and costs no query.
  defp stamp_scripted_embeds(repo, %Canvas{} = canvas, attribution) do
    ctx = %{canvas_id: canvas.id, space_id: canvas.space_id, actor: attribution}

    case Platform.Chat.Canvas.ScriptedEmbeds.stamp(canvas.document, ctx) do
      {:ok, document, _verified} when document == canvas.document ->
        {:ok, canvas}

      {:ok, document, _verified} ->
        canvas |> Canvas.changeset(%{"document" => document}) |> repo.update()

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Create a canvas and its companion chat message atomically.

  The message's `canvas_id` FK is set directly — no back-patch step. Messages
  reference canvases; canvases do not reference messages.
  """
  @spec create_canvas_with_message(binary(), binary(), map()) ::
          {:ok, Canvas.t(), Message.t()} | {:error, term()}
  def create_canvas_with_message(space_id, participant_id, attrs \\ %{}) do
    with :ok <- ensure_space_writable(space_id) do
      do_create_canvas_with_message(space_id, participant_id, attrs)
    end
  end

  defp do_create_canvas_with_message(space_id, participant_id, attrs) do
    attrs = stringify_canvas_payload(attrs)
    snapshot = author_snapshot_for(participant_id)

    multi =
      Multi.new()
      |> Multi.run(:inserted_canvas, fn repo, _changes ->
        attrs
        |> Map.put("space_id", space_id)
        |> Map.put("created_by", participant_id)
        |> Map.put("created_by_display_name", snapshot[:author_display_name])
        |> Map.put("created_by_participant_type", snapshot[:author_participant_type])
        |> then(&Canvas.changeset(%Canvas{}, &1))
        |> repo.insert()
      end)
      |> Multi.run(:canvas, fn repo, %{inserted_canvas: canvas} ->
        stamp_scripted_embeds(
          repo,
          canvas,
          CanvasVersions.attribution_from_fields(%{
            type: snapshot[:author_participant_type] || "unknown",
            id: participant_id,
            display_name: snapshot[:author_display_name]
          })
        )
      end)
      |> CanvasSearchIndex.upsert_multi(:canvas_search, & &1.canvas)
      |> Multi.run(:message, fn repo, %{canvas: canvas} ->
        message_attrs =
          %{
            space_id: space_id,
            participant_id: participant_id,
            canvas_id: canvas.id,
            content_type: "canvas",
            content: Map.get(attrs, "message_content") || default_canvas_message(attrs),
            structured_content: %{
              "canvas_id" => canvas.id,
              "title" => Map.get(attrs, "title")
            }
          }
          |> Map.merge(snapshot)

        %Message{}
        |> Message.changeset(message_attrs)
        |> repo.insert()
      end)
      |> Multi.merge(fn %{canvas: canvas} ->
        version_revision = canvas_version_revision(canvas)

        attribution =
          CanvasVersions.attribution_from_fields(%{
            type: snapshot[:author_participant_type] || "unknown",
            id: participant_id,
            display_name: snapshot[:author_display_name],
            slug:
              if(snapshot[:author_participant_type] == "agent",
                do: snapshot[:author_agent_id]
              )
          })

        CanvasVersions.multi_insert(
          Multi.new(),
          :canvas_version,
          canvas.id,
          version_revision,
          canvas.document,
          attribution,
          nil
        )
      end)

    case Repo.transaction(multi) do
      {:ok, %{canvas: canvas, message: message}} ->
        publish_canvas_created(canvas)
        publish_message_posted(message)
        {:ok, canvas, message}

      {:error, _operation, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch a canvas. Returns `nil` if not found or soft-deleted.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`) gates the canvas
  on its `space_id`: for an external caller a canvas in a non-participant space
  resolves to `nil`. Absent / nil / internal scopes are pass-through.
  """
  @spec get_canvas(binary(), keyword()) :: Canvas.t() | nil
  def get_canvas(id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    # `canvas_id` backs the canvas_get / canvas_describe MCP tools, so it is
    # whatever the agent typed. Platform.UUID.valid?/1, not a bare cast.
    if Platform.UUID.valid?(id) do
      case Repo.get(Canvas, id) do
        %Canvas{deleted_at: nil} = canvas ->
          if ExternalScope.visible_space_id?(canvas.space_id, scope), do: canvas, else: nil

        _ ->
          nil
      end
    else
      nil
    end
  end

  @doc """
  Fetch a canvas including soft-deleted rows. Used by the Activity panel's
  Restore flow, which specifically needs to load a soft-deleted canvas to
  un-delete it. Returns `nil` only if no row with the given id exists.
  """
  @spec get_canvas_with_deleted(binary(), keyword()) :: Canvas.t() | nil
  def get_canvas_with_deleted(id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    if Platform.UUID.valid?(id) do
      case Repo.get(Canvas, id) do
        nil ->
          nil

        canvas ->
          if ExternalScope.visible_space_id?(canvas.space_id, scope), do: canvas, else: nil
      end
    else
      nil
    end
  end

  @doc """
  Update canvas metadata/title. Document changes go through `patch_canvas/3`.

  Actor-first (task 019e2c4b, stage 2). `actor` is a
  `t:Platform.Chat.CanvasAccess.actor/0` — `{:user, id}`, `{:agent, id}` or
  `:system`. Writes require `:member` (space participation); the
  `:task_reader` / `:org_reader` READ grants do not confer write.

  There is deliberately no defaulting arity. A default `:system` would be a
  silent authorization bypass for every caller that forgot the argument.
  """
  @spec update_canvas(CanvasAccess.actor(), Canvas.t(), map()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def update_canvas(actor, %Canvas{} = canvas, attrs) do
    # `ensure_space_writable/1` runs FIRST so an archived space still rejects
    # with `:space_archived` rather than `:forbidden` — a member writing to an
    # archived space should hear about the archive, not about permissions.
    with :ok <- ensure_space_writable(canvas.space_id),
         {:ok, canvas} <- CanvasAccess.fetch_for_writer(canvas.id, actor) do
      do_update_canvas(canvas, attrs)
    end
  end

  # `:document` is in `Canvas.changeset/2`'s cast list, so this is a body-write
  # path even though every in-tree caller today goes through the canvas server.
  # The bare `Repo.update/1` this used to be became a `Multi` so the search
  # index write shares its transaction: a failed index write has to fail the
  # save rather than leave a canvas whose body search text is stale.
  defp do_update_canvas(%Canvas{} = canvas, attrs) do
    attrs = stringify_canvas_payload(attrs)

    multi =
      Multi.new()
      |> Multi.update(:updated_canvas, Canvas.changeset(canvas, attrs))
      |> Multi.run(:canvas, fn repo, %{updated_canvas: updated} ->
        # Only a write that changes the document can change an embed.
        if Map.has_key?(attrs, "document") and updated.document != canvas.document,
          do:
            stamp_scripted_embeds(repo, updated, CanvasVersions.attribution_from_canvas(updated)),
          else: {:ok, updated}
      end)
      |> CanvasSearchIndex.upsert_multi(:canvas_search, & &1.canvas)

    case Repo.transaction(multi) do
      {:ok, %{canvas: updated}} ->
        publish_canvas_updated(updated)
        {:ok, updated}

      {:error, step, %Ecto.Changeset{} = changeset, _} when step in [:updated_canvas, :canvas] ->
        {:error, changeset}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  List canvases in a space (excluding soft-deleted).

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`) yields `[]` when
  the `space_id` is out of the external caller's participant set (canvas embeds
  from an off-limits space can't be resolved from an external session). Absent
  / nil / internal scopes are pass-through.

  `:order` selects the sequence, defaulting to `:inserted_asc` — the order this
  function has always returned. **The default is deliberately unchanged.** Two
  other callers read this list (`Platform.Deploy.ProjectFiles` and the
  `canvas_list` / `task_list_canvases` MCP tools), and agents may depend on the
  order they already see; the human-facing panel asks for what it wants instead
  of everyone silently inheriting a new sequence.

  `:updated_desc` is most-recently-edited first. That is a real signal rather
  than a proxy: `Canvas.Server.do_persist/5` writes every patch through
  `Multi.update(:canvas, Canvas.changeset(canvas, %{"document" => document}))`
  (`chat/canvas/server.ex:429`), so a document edit bumps the row's
  `updated_at`. Confirmed against production, where 228 of 818 canvases carry
  `updated_at > inserted_at`.

  `:access_scope` (a `%Platform.Access.Scope{}`, also read from `:scope` when
  `:scope` is one) drops every canvas a `canvas.read` deny covers
  (`scope_by/3`, task 01a1386d-e528 stage 3). Absent, nothing changes.
  """
  @spec list_canvases(binary(), keyword()) :: [Canvas.t()]
  def list_canvases(space_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    from(c in Canvas,
      where: c.space_id == ^space_id and is_nil(c.deleted_at)
    )
    |> canvas_order(Keyword.get(opts, :order, :inserted_asc))
    |> ExternalScope.scope_by_space_id(scope)
    |> maybe_scope_canvases(canvas_access_scope(opts))
    |> Repo.all()
  end

  @doc """
  The most recently edited live canvases across `space_ids`, newest first,
  capped by `:limit` (default 25), loaded WITHOUT `document` (`id`, `title`,
  `space_id`, `updated_at`, `inserted_at` only). The empty-query state of the task canvas
  picker (`PlatformWeb.Tasks.CanvasPickerComponent`, task 01a1559a stage 3).

  Like `search_canvases/3` it is NOT cast-safe on `space_ids`: every id must be
  DB-derived. `:access_scope` drops every canvas a `canvas.read` deny covers
  (`scope_by/3`), exactly as in `list_canvases/2`.
  """
  @spec list_recent_canvases([binary()], keyword()) :: [Canvas.t()]
  def list_recent_canvases(space_ids, opts \\ [])

  def list_recent_canvases([], _opts), do: []

  def list_recent_canvases(space_ids, opts) when is_list(space_ids) do
    from(c in Canvas,
      where: c.space_id in ^space_ids and is_nil(c.deleted_at),
      limit: ^Keyword.get(opts, :limit, 25),
      # The picker renders a title and a meta line; the document stays behind.
      select: struct(c, [:id, :title, :space_id, :updated_at, :inserted_at])
    )
    |> canvas_order(:updated_desc)
    |> maybe_scope_canvases(canvas_access_scope(opts))
    |> Repo.all()
  end

  @doc """
  The canvas listing behind the Files & Canvases browser
  (`Platform.Files.Browser`, task 01a1557a-b5f9 stage 1): live canvases
  across `space_ids`, most recently edited first, as plain maps WITHOUT
  `document`: `id`, `title`, `space_id`, `created_by_display_name`,
  `cloned_from`, `updated_at`, `inserted_at`, `game?`, `game_task_id` and
  `game_review_sha`.

  `game?` is computed in SQL: true when the document holds a node of type
  `game_stream` anywhere in its tree (`jsonb_path_exists`), so a caller
  learns an item's type without loading a document. `game_stream` is an
  extension kind; core names only the string, never the extension's modules.

  `game_task_id` and `game_review_sha` are the `task_id` and `review_sha`
  props of the FIRST `game_stream` node (`jsonb_path_query_first` on the
  same path, so "first" in the `.**` walk's order: document order among
  siblings, but a shallower node can precede a deeper earlier one), also
  computed in SQL; both are nil for a non-game, and either
  is nil when that node lacks the prop (task 01a1557a-efdd stage 1).

  Like `list_recent_canvases/2` it is NOT cast-safe on `space_ids`: every
  id must be DB-derived. `:access_scope` drops every canvas a `canvas.read`
  deny covers (`scope_by/3`), exactly as in `list_canvases/2`.

  ## Options

    * `:since` — only canvases with `updated_at` at or after this instant.
    * `:limit` — cap (default 50; `nil` disables it).
    * `:type` — `:canvas` (not a game) or `:game`; absent means both.
    * `:ids` — narrow to these canvas ids (DB-derived, e.g. search hits
      being classified); absent means no narrowing.
  """
  @spec list_browser_canvases([binary()], keyword()) :: [map()]
  def list_browser_canvases(space_ids, opts \\ [])

  def list_browser_canvases([], _opts), do: []

  def list_browser_canvases(space_ids, opts) when is_list(space_ids) do
    # Bound as TEXT and cast in SQL: a bare `?::jsonpath` makes Postgres type
    # the parameter as jsonpath, which Postgrex cannot encode.
    game_path = ~s|$.** ? (@.type == "game_stream")|

    query =
      from(c in Canvas,
        where: c.space_id in ^space_ids and is_nil(c.deleted_at),
        select: %{
          id: c.id,
          title: c.title,
          space_id: c.space_id,
          created_by_display_name: c.created_by_display_name,
          cloned_from: c.cloned_from,
          updated_at: c.updated_at,
          inserted_at: c.inserted_at,
          game?: fragment("jsonb_path_exists(?, ?::text::jsonpath)", c.document, ^game_path),
          # The FIRST game_stream node's props, read in SQL so the document
          # never leaves the database. NULL (nil) for a canvas with no game.
          game_task_id:
            fragment(
              "jsonb_path_query_first(?, ?::text::jsonpath) -> 'props' ->> 'task_id'",
              c.document,
              ^game_path
            ),
          game_review_sha:
            fragment(
              "jsonb_path_query_first(?, ?::text::jsonpath) -> 'props' ->> 'review_sha'",
              c.document,
              ^game_path
            )
        }
      )

    query =
      case Keyword.get(opts, :since) do
        nil -> query
        since -> where(query, [c], c.updated_at >= ^since)
      end

    query =
      case Keyword.get(opts, :ids) do
        nil -> query
        ids when is_list(ids) -> where(query, [c], c.id in ^ids)
      end

    query =
      case Keyword.get(opts, :type) do
        :canvas ->
          where(
            query,
            [c],
            not fragment("jsonb_path_exists(?, ?::text::jsonpath)", c.document, ^game_path)
          )

        :game ->
          where(
            query,
            [c],
            fragment("jsonb_path_exists(?, ?::text::jsonpath)", c.document, ^game_path)
          )

        nil ->
          query
      end

    query =
      case Keyword.get(opts, :limit, 50) do
        nil -> query
        n when is_integer(n) and n > 0 -> limit(query, ^n)
      end

    query
    |> canvas_order(:updated_desc)
    |> maybe_scope_canvases(canvas_access_scope(opts))
    |> Repo.all()
  end

  @doc """
  Restrict a `Space` or `Canvas` query (its root binding) by explicit grants
  (task 01a1386d-e528 stage 3,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`).

    * `:space` — `chat.read`. This is `ExternalScope.scope_spaces/2`'s
      `%Platform.Access.Scope{}` clause: a guest's live participant subquery,
      or everything for an internal scope, UNION the spaces a `chat.read`
      allow covers (a project allow covers its tasks' execution spaces),
      MINUS the spaces a `chat.read` deny covers.
    * `:canvas` — `canvas.read`, through `Platform.Access.Query.restrict/5`
      with no base: the query's own filters are the existing check, and a
      deny on the canvas, its space or a project above it drops the row.

  With no grant naming the permission the query reads exactly what it read
  before. The deny-wins condition lives in `Platform.Access.Query`.

  `list_canvases/2` and `list_canvas_groups/2` apply `:canvas` when given
  `:access_scope` (or a `%Platform.Access.Scope{}` as `:scope`).
  """
  @spec scope_by(Ecto.Queryable.t(), Platform.Access.Scope.t(), :space | :canvas) ::
          Ecto.Queryable.t()
  def scope_by(query, %Platform.Access.Scope{} = scope, :space),
    do: ExternalScope.scope_spaces(query, scope)

  def scope_by(query, %Platform.Access.Scope{} = scope, :canvas),
    do: Platform.Access.Query.restrict(query, scope, "canvas.read", :canvas, %{id: :id})

  defp maybe_scope_canvases(query, %Platform.Access.Scope{} = scope),
    do: scope_by(query, scope, :canvas)

  defp maybe_scope_canvases(query, _scope), do: query

  # `:access_scope`, else a `%Platform.Access.Scope{}` passed as `:scope`
  # (ChatLive's `@external_scope` is one since task 01a1386d-e528 stage 3).
  defp canvas_access_scope(opts) do
    case {Keyword.get(opts, :access_scope), Keyword.get(opts, :scope)} do
      {%Platform.Access.Scope{} = scope, _} -> scope
      {_, %Platform.Access.Scope{} = scope} -> scope
      _ -> nil
    end
  end

  # Title sort is case-insensitive: an `asc: c.title` would file "Zebra" before
  # "apple" on Postgres's default collation, which reads as broken rather than
  # as sorted. Ties break on `inserted_at` so the sequence is stable — without a
  # tiebreaker two canvases sharing a title (or a timestamp) can swap between
  # reads, which is the same defect #864 fixed in task paging.
  defp canvas_order(query, :updated_desc),
    do: order_by(query, [c], desc: c.updated_at, desc: c.inserted_at)

  defp canvas_order(query, :inserted_desc),
    do: order_by(query, [c], desc: c.inserted_at, desc: c.id)

  defp canvas_order(query, :title_asc),
    do: order_by(query, [c], asc: fragment("lower(?)", c.title), asc: c.inserted_at)

  defp canvas_order(query, _inserted_asc),
    do: order_by(query, [c], asc: c.inserted_at, asc: c.id)

  @default_canvas_group_limit 20

  @typedoc """
  One space's slice of the canvas explorer. `total_count` is the space's true
  live-canvas count; `rows` is at most `:limit` of them.
  """
  @type canvas_group :: %{
          space_id: binary(),
          space_name: String.t() | nil,
          total_count: non_neg_integer(),
          rows: [canvas_group_row()]
        }

  @typedoc """
  A canvas as the explorer needs it. Deliberately NOT a `%Canvas{}`: no
  `:document` key at all. See `list_canvas_groups/2`.
  """
  @type canvas_group_row :: %{
          id: binary(),
          title: String.t() | nil,
          space_id: binary(),
          updated_at: DateTime.t(),
          inserted_at: DateTime.t(),
          created_by_display_name: String.t() | nil,
          cloned_from: binary() | nil
        }

  @doc """
  Bounded canvas listing across MANY spaces, grouped one entry per space.

  This exists because `list_canvases/2` cannot serve an explorer. That function
  takes one space id, has no `:limit`, and selects the full `%Canvas{}`
  **including `document`** — a node tree. At the scale this was built for (409
  canvases over 14 spaces) reusing it means loading 409 node trees in order to
  render 409 titles, and it cannot page at all.

  Returns one `t:canvas_group/0` per space id given, ordered alphabetically
  (case-insensitively) by space name. Space ids that name no row are dropped;
  a space with no live canvases is KEPT, as `total_count: 0, rows: []`, because
  the explorer has to be able to say "this space is empty" rather than silently
  omitting it.

  ## `total_count` is a COUNT, not `length(rows)`

  `total_count` is the number of live canvases in the space, computed by the
  database over the whole partition and therefore unaffected by `:limit`. That
  is the entire point: a group header must be able to read "41" while the group
  shows 20 rows. Deriving it from `length(rows)` would make the header agree
  with the cap forever and the paging control would never appear.

  ## Rows are lightweight maps

  Each row carries exactly `:id`, `:title`, `:space_id`, `:updated_at`,
  `:inserted_at`, `:created_by_display_name` and `:cloned_from`. **`:document`
  is not selected and the key is not present.** A `%Canvas{}` struct would
  carry `document` whether or not the caller touched it, so the rows are plain
  maps: the absence of the key is assertable, and it is asserted in
  `canvas_explorer_listing_test.exs`.

  ## Ordering and paging

  Rows are ordered `asc: lower(title), asc: inserted_at`, so the same canvas
  sits in the same place on every visit — a title sort without the
  `inserted_at` tiebreaker lets two canvases sharing a title swap between
  reads, which is the paging defect #864 fixed for tasks.

  Both bounds are applied per space by a single windowed query rather than one
  query per space, so a 14-space explorer is two round trips (spaces+counts,
  then rows) regardless of how many spaces are open.

  ## Options

    * `:limit` — max rows per space. Defaults to
      `#{@default_canvas_group_limit}`.
    * `:offset` — rows to skip per space. Defaults to `0`.
    * `:order` — `:title_asc` (default), `:updated_desc`, `:inserted_desc` or
      `:inserted_asc`. These are exactly the four the canvases drawer's sort
      control offers (`PlatformWeb.ChatLive.CanvasHooks.sort_options/0`), and
      they exist here rather than in the caller for one reason: the caller only
      ever holds ONE PAGE of a group, so sorting in memory would order 20 rows
      out of 41 and present the result as the group's order. That is not a
      slower version of this — it is a different, wrong answer. An unrecognised
      value falls back to `:title_asc` rather than raising, matching how the
      drawer's own allow-list parses an unknown sort.

      Every ordering ends in a tiebreaker (`inserted_at`, then `id`), so a page
      boundary cannot let two rows sharing a sort key swap between reads — the
      paging defect #864 fixed for tasks. The window and the outer query are
      driven from the SAME list, so a page's contents and its sequence cannot
      disagree about what page 2 is.
    * `:access_scope` — an optional `%Platform.Access.Scope{}`; a canvas a
      `canvas.read` deny covers leaves both `rows` and `total_count`
      (`scope_by/3`). Absent, nothing changes.
  """
  @spec list_canvas_groups([binary()], keyword()) :: [canvas_group()]
  def list_canvas_groups(space_ids, opts \\ [])

  def list_canvas_groups([], _opts), do: []

  def list_canvas_groups(space_ids, opts) when is_list(space_ids) do
    limit = Keyword.get(opts, :limit, @default_canvas_group_limit)
    offset = Keyword.get(opts, :offset, 0)
    order = Keyword.get(opts, :order, :title_asc)

    spaces =
      from(s in Space,
        where: s.id in ^space_ids,
        order_by: [asc: fragment("lower(?)", s.name), asc: s.id],
        select: %{id: s.id, name: s.name}
      )
      |> Repo.all()

    # A denied canvas leaves the rows AND the count, or `total_count` would
    # tell the reader how many hidden canvases a space holds.
    access_scope = canvas_access_scope(opts)
    counts = canvas_group_counts(space_ids, access_scope)
    rows_by_space = canvas_group_rows(space_ids, limit, offset, order, access_scope)

    Enum.map(spaces, fn space ->
      %{
        space_id: space.id,
        space_name: space.name,
        total_count: Map.get(counts, space.id, 0),
        rows: Map.get(rows_by_space, space.id, [])
      }
    end)
  end

  # The true per-space total, independent of `:limit`. A GROUP BY over the
  # same `is_nil(deleted_at)` filter the rows use, so the header count and the
  # rows can never disagree about what "live" means.
  defp canvas_group_counts(space_ids, access_scope) do
    from(c in Canvas,
      where: c.space_id in ^space_ids and is_nil(c.deleted_at),
      group_by: c.space_id,
      select: {c.space_id, count(c.id)}
    )
    |> maybe_scope_canvases(access_scope)
    |> Repo.all()
    |> Map.new()
  end

  # One query for every space's page. `row_number()` partitioned by space is
  # what makes a per-space LIMIT expressible in a single statement — a bare
  # `limit:` would cap the whole result set, handing all 20 rows to whichever
  # space sorted first and none to the rest.
  #
  # The outer select re-lists the columns rather than passing the subquery row
  # through, so `row_number` is dropped and the returned maps carry exactly the
  # seven documented keys. `document` is absent from both selects.
  defp canvas_group_rows(space_ids, limit, offset, order, access_scope) do
    row_order = canvas_group_order(order)

    numbered =
      from(c in Canvas,
        where: c.space_id in ^space_ids and is_nil(c.deleted_at),
        windows: [
          space: [
            partition_by: c.space_id,
            order_by: ^row_order
          ]
        ],
        select: %{
          id: c.id,
          title: c.title,
          space_id: c.space_id,
          updated_at: c.updated_at,
          inserted_at: c.inserted_at,
          created_by_display_name: c.created_by_display_name,
          cloned_from: c.cloned_from,
          rank: over(row_number(), :space)
        }
      )
      # Scoped INSIDE the window, so a denied canvas takes no rank.
      |> maybe_scope_canvases(access_scope)

    from(r in subquery(numbered),
      where: r.rank > ^offset and r.rank <= ^(offset + limit),
      order_by: [asc: r.space_id, asc: r.rank],
      select: %{
        id: r.id,
        title: r.title,
        space_id: r.space_id,
        updated_at: r.updated_at,
        inserted_at: r.inserted_at,
        created_by_display_name: r.created_by_display_name,
        cloned_from: r.cloned_from
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.space_id)
  end

  # The four orderings the canvases drawer's sort control offers, as ONE list
  # each, handed to the window that numbers the rows. The outer query then only
  # has to order by `rank`, so the sequence a page is CUT at and the sequence it
  # is RENDERED in are the same expression rather than two that have to be kept
  # in step.
  #
  # Every one ends in a tiebreaker, `inserted_at` then `id`. Without it two
  # canvases sharing a title (or a same-second `updated_at`, which the
  # near-duplicate clusters this explorer exists for produce readily) can swap
  # places between two reads, and a row that swaps across a page boundary is a
  # row the reader sees twice or never — the paging defect #864 fixed for tasks.
  # `id` is UUIDv7, so the final tiebreaker is itself stable and total.
  #
  # An unrecognised atom falls back to `:title_asc` rather than raising, for the
  # same reason `CanvasHooks`' `@sorts` map falls back instead of calling
  # `String.to_existing_atom/1`: the value's provenance is a client `<select>`,
  # and a drawer that crashes on a stale option is worse than one that sorts
  # alphabetically.
  defp canvas_group_order(:updated_desc) do
    [desc: dynamic([c], c.updated_at), asc: dynamic([c], c.inserted_at), asc: dynamic([c], c.id)]
  end

  defp canvas_group_order(:inserted_desc) do
    [desc: dynamic([c], c.inserted_at), asc: dynamic([c], c.id)]
  end

  defp canvas_group_order(:inserted_asc) do
    [asc: dynamic([c], c.inserted_at), asc: dynamic([c], c.id)]
  end

  defp canvas_group_order(_title_asc) do
    [
      asc: dynamic([c], fragment("lower(?)", c.title)),
      asc: dynamic([c], c.inserted_at),
      asc: dynamic([c], c.id)
    ]
  end

  @doc """
  Resolve a batch of `cloned_from` ids to their parent canvases' titles.

  ONE query for the whole batch. The explorer renders a "cloned from …" line
  per row, and resolving that per row is an N+1 that scales with the page.

  ## The three outcomes are three distinct values

    * parent is live — maps to its `title` (a binary, possibly `nil` if the
      parent was saved without one);
    * parent is soft-deleted, or names no row at all — maps to `:deleted`;
    * id was never asked about — **absent** from the map.

  `:deleted` is an atom rather than `nil` on purpose. The UI must render
  "cloned from a deleted canvas", which is a real piece of provenance, so the
  deleted case has to be distinguishable from "this canvas is not a clone".
  With `nil` for both, `Map.get/2` returns the same thing for a clone of a
  deleted parent and for a canvas that was never cloned, and the deleted case
  silently loses its line. Callers should match on `:deleted`, never on
  presence — `nil` is present too.

  A malformed id is treated as `:deleted` for the same reason a missing one is:
  it can never name a live canvas, and dropping it would erase the fact that
  the row IS a clone.
  """
  @spec canvas_parent_titles([binary() | nil]) :: %{
          optional(binary()) => String.t() | nil | :deleted
        }
  def canvas_parent_titles(cloned_from_ids)

  def canvas_parent_titles(cloned_from_ids) when is_list(cloned_from_ids) do
    ids =
      cloned_from_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Enum.filter(ids, &Platform.UUID.valid?/1) do
      [] ->
        Map.new(ids, &{&1, :deleted})

      valid_ids ->
        live =
          from(c in Canvas,
            where: c.id in ^valid_ids and is_nil(c.deleted_at),
            select: {c.id, c.title}
          )
          |> Repo.all()
          |> Map.new()

        # Default is `:deleted`, so soft-deleted parents, ids naming no row and
        # malformed ids all land on the marker without a second query.
        Map.new(ids, fn id -> {id, Map.get(live, id, :deleted)} end)
    end
  end

  @doc """
  List the ids of non-deleted messages that reference a given canvas.
  Used by the chat LiveView to know which stream items to re-insert when
  `{:canvas_updated, canvas}` fires — stream items otherwise keep their
  render snapshot from insert time and miss the updated document.
  """
  @spec list_message_ids_for_canvas(binary()) :: [binary()]
  def list_message_ids_for_canvas(canvas_id) when is_binary(canvas_id) do
    from(m in Message,
      where: m.canvas_id == ^canvas_id and is_nil(m.deleted_at),
      select: m.id
    )
    |> Repo.all()
  end

  @doc """
  Apply `CanvasPatch` operations to a canvas document.

  Routes through `Platform.Chat.Canvas.Server` for rebase-or-reject concurrency
  (ADR 0036, Phase 3). Callers that have a specific `base_revision` should use
  `Canvas.Server.apply_patches/3` directly; this helper assumes head writes
  and refetches the canvas for the return value.

  Actor-first (task 019e2c4b, stage 2). `actor` is a
  `t:Platform.Chat.CanvasAccess.actor/0` — `{:user, id}`, `{:agent, id}` or
  `:system`. Writes require `:member` (space participation); the
  `:task_reader` / `:org_reader` READ grants do not confer write, which is the
  whole reason this gate lands before the standalone read route.

  Callers reaching `Canvas.Server.apply_patches/3,4` directly must authorize
  for themselves — the server is the unauthorized primitive, by design.
  """
  @spec patch_canvas(CanvasAccess.actor(), Canvas.t(), [
          Platform.Chat.CanvasPatch.operation()
        ]) ::
          {:ok, Canvas.t()} | {:conflict, map()} | {:error, term()}
  def patch_canvas(actor, %Canvas{} = canvas, operations) when is_list(operations) do
    # Archive check first — see `update_canvas/3`.
    with :ok <- ensure_space_writable(canvas.space_id),
         {:ok, canvas} <- CanvasAccess.fetch_for_writer(canvas.id, actor) do
      do_patch_canvas(canvas, operations, actor)
    end
  end

  defp do_patch_canvas(%Canvas{} = canvas, operations, actor) do
    alias Platform.Chat.Canvas.Server, as: CanvasServer
    alias Platform.Chat.Canvas.Versions

    # The authorized writer is already known here; passing it on is what keeps
    # the version row from recording `unknown` for a write we can name (task
    # 019fed8d). `actor` is CanvasAccess's shape, not a tool-call context, so
    # it is normalized before resolution.
    attribution = Versions.attribution_from_context(actor_context(actor), canvas.space_id)

    case CanvasServer.describe(canvas.id) do
      {:ok, %{revision: current_revision}} ->
        case CanvasServer.apply_patches(canvas.id, operations, current_revision, attribution) do
          {:ok, _new_revision} ->
            # Refetch to return the fresh struct; the server has already
            # triggered an async persist.
            {:ok, get_canvas(canvas.id) || canvas}

          {:conflict, payload} ->
            {:conflict, payload}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # CanvasAccess actors are tuples/atoms; `Versions.attribution_from_context/2`
  # reads the tool-call context map. `:system` and `nil` map to an empty
  # context, which resolves to an explicit `system` attribution rather than
  # `unknown` — a write we chose not to attribute should not look like one we
  # failed to attribute.
  defp actor_context({:user, id}) when is_binary(id), do: %{user_id: id}
  defp actor_context({:agent, id}) when is_binary(id), do: %{agent_id: id}
  defp actor_context(actor) when is_map(actor), do: actor
  defp actor_context(_), do: %{}

  @doc """
  Clone a canvas into another space (ADR 0036, Phase 6).

  Produces a new canvas with:

    * a new canvas id
    * freshly-generated node ids (canvas-local uniqueness)
    * document structure copied verbatim
    * revision reset to 1
    * `created_by` = `actor_id`
    * `cloned_from` = the source canvas id

  Space-scoped `$bind` references whose target resource does not exist in the
  target space are cleared; universal bindings are preserved. Messages in the
  source space remain valid — the source is untouched.

  Permissions note: this function does NOT check participant membership.
  Callers (tool handlers, HTTP controllers, LiveView) must assert that the
  actor has read on the source space and write on the target space before
  invoking.
  """
  @spec clone_canvas(binary(), binary(), binary()) ::
          {:ok, Canvas.t()} | {:error, term()}
  def clone_canvas(source_canvas_id, target_space_id, actor_id)
      when is_binary(source_canvas_id) and is_binary(target_space_id) and is_binary(actor_id) do
    case get_canvas(source_canvas_id) do
      nil ->
        {:error, :source_not_found}

      %Canvas{document: document, title: title} = source ->
        {cloned_document, _mapping} = regenerate_node_ids(document)

        attrs = %{
          "space_id" => target_space_id,
          "created_by" => actor_id,
          "cloned_from" => source.id,
          "title" => title,
          "document" => Map.put(cloned_document, "revision", 1)
        }

        case create_canvas(attrs) do
          {:ok, cloned} ->
            :telemetry.execute(
              [:platform, :chat, :canvas_cloned],
              %{system_time: System.system_time()},
              %{
                source_id: source.id,
                clone_id: cloned.id,
                source_space_id: source.space_id,
                target_space_id: target_space_id
              }
            )

            {:ok, cloned}

          {:error, _} = err ->
            err
        end
    end
  end

  defp regenerate_node_ids(document) when is_map(document) do
    case Map.get(document, "root") do
      root when is_map(root) ->
        {new_root, mapping} = regenerate_subtree(root, %{})
        {Map.put(document, "root", new_root), mapping}

      _ ->
        {document, %{}}
    end
  end

  defp regenerate_subtree(%{"id" => old_id} = node, mapping) do
    new_id =
      if old_id == "root", do: "root", else: Ecto.UUID.generate()

    mapping = Map.put(mapping, old_id, new_id)

    children =
      case Map.get(node, "children") do
        list when is_list(list) ->
          Enum.map_reduce(list, mapping, fn child, m ->
            regenerate_subtree(child, m)
          end)

        _ ->
          {[], mapping}
      end

    {children_list, child_mapping} = children

    new_node =
      node
      |> Map.put("id", new_id)
      |> then(fn n ->
        if Map.has_key?(n, "children"), do: Map.put(n, "children", children_list), else: n
      end)

    {new_node, child_mapping}
  end

  defp regenerate_subtree(other, mapping), do: {other, mapping}

  # ── Attachments ──────────────────────────────────────────────────────────────

  @doc """
  Record a new attachment. Required: `:filename`, `:content_type`, `:byte_size`,
  `:storage_key`. Provide `:space_id` and/or `:message_id` to anchor ownership
  (ADR 0039 allows space- or canvas-scoped attachments without a parent message).
  """
  @spec create_attachment(map()) ::
          {:ok, Attachment.t()} | {:error, :space_archived | Ecto.Changeset.t()}
  def create_attachment(attrs) do
    # Attachments may be space-anchored, message-anchored, or both (ADR 0039);
    # guard on whichever anchor is present.
    space_check = ensure_space_writable(attrs[:space_id] || attrs["space_id"])

    message_check =
      ensure_message_space_writable(attrs[:message_id] || attrs["message_id"])

    with :ok <- space_check,
         :ok <- message_check do
      %Attachment{}
      |> Attachment.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Fetch an attachment by primary key. Returns `nil` if not found.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`) gates the
  attachment on its `space_id`: for an external caller an attachment in a
  non-participant space resolves to `nil`. Legacy `space_id: nil` rows have no
  space to scope and pass through. Absent / nil / internal scopes are
  pass-through.
  """
  @spec get_attachment(binary(), keyword()) :: Attachment.t() | nil
  def get_attachment(id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    # `attachment_id` arrives from the MCP attachment tools. Guarded.
    if Platform.UUID.valid?(id) do
      case Repo.get(Attachment, id) do
        nil -> nil
        att -> if ExternalScope.visible_space_id?(att.space_id, scope), do: att, else: nil
      end
    else
      nil
    end
  end

  @doc """
  Fetch an attachment for the viewer.

  Message-owned attachments remain gated on the parent message being
  non-deleted. Space-owned or canvas-owned attachments (nil `message_id`,
  introduced in ADR 0039) have no parent message to check, so they pass
  through as long as the row exists.
  """
  @spec get_visible_attachment(binary(), keyword()) :: Attachment.t() | nil
  def get_visible_attachment(id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    from(a in Attachment,
      left_join: m in Message,
      on: m.id == a.message_id,
      where: a.id == ^id and (is_nil(a.message_id) or is_nil(m.deleted_at)),
      select: a
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.one()
  end

  @doc """
  Fetch an attachment for a principal (ADR 0039 phase 3).

  Extends `get_visible_attachment/1` with a space-membership check so the
  same route can serve session users and runtime bearers:

    - `{:user, user_id}` — must be a `participant_type: "user"` participant in
      `attachment.space_id`.
    - `{:runtime, %AgentRuntime{}}` — the runtime's `agent_id` must be a
      `participant_type: "agent"` participant in `attachment.space_id`.

  Attachments without a `space_id` (legacy rows pre-1a backfill) fall back to
  the message-deleted check alone, so existing behavior is preserved.
  """
  @spec get_visible_attachment_for_principal(
          binary(),
          {:user, binary()} | {:runtime, AgentRuntime.t()}
        ) :: Attachment.t() | nil
  def get_visible_attachment_for_principal(id, principal) do
    case get_visible_attachment(id) do
      nil ->
        nil

      %Attachment{space_id: nil} = attachment ->
        # M9 (rbac-external-users): the nil-space (legacy / canvas-orphan) branch
        # used to pass through UNCONDITIONALLY — the one download leak for an
        # external user, who has no space to scope on. Fail closed for external
        # principals; internal users and agent runtimes keep the pass-through
        # (a nil-space row is a pre-backfill artifact an internal caller may
        # still need). The space-bound branch below is unchanged — its
        # `principal_is_member?/2` already equals M7's read-scope membership.
        if external_principal?(principal), do: nil, else: attachment_access(attachment, principal)

      %Attachment{space_id: space_id} = attachment ->
        if principal_is_member?(space_id, principal),
          do: attachment_access(attachment, principal),
          else: nil
    end
  end

  @doc """
  The RBAC v2 read check on one attachment for an access `scope` (task
  01a1386e-45a5 stage 1): `Platform.Access.check/3` with `chat.read` on the
  attachment's space and, when it is canvas-bound, `canvas.read` on its
  canvas. Conjunctive: callers run it only after their own membership check
  has admitted. With no grants on the scope it is `:ok`.
  """
  @spec attachment_access_check(Attachment.t(), Platform.Access.Scope.t() | nil) ::
          :ok | {:error, :denied}
  def attachment_access_check(%Attachment{} = attachment, scope) do
    with :ok <- maybe_access_check(scope, "chat.read", :space, attachment.space_id) do
      maybe_access_check(scope, "canvas.read", :canvas, attachment.canvas_id)
    end
  end

  defp maybe_access_check(_scope, _permission, _type, nil), do: :ok

  defp maybe_access_check(scope, permission, type, id),
    do: Platform.Access.check(scope, permission, {type, id})

  # A denied attachment is `nil`, so the download route answers the same 404
  # a missing id gets, before its range branch (206/416) is reached.
  defp attachment_access(attachment, principal) do
    case attachment_access_check(attachment, principal_access_scope(principal)) do
      :ok -> attachment
      {:error, :denied} -> nil
    end
  end

  defp principal_access_scope({:user, user_id}) when is_binary(user_id),
    do: Platform.Access.Scope.for_user(%{id: user_id})

  defp principal_access_scope({:runtime, %AgentRuntime{} = runtime}),
    do: Platform.Access.Scope.for_runtime(runtime)

  defp principal_access_scope(_principal), do: nil

  @doc """
  Is the download `principal` an external user? (M9, rbac-external-users.)

  Consumes M7's `Platform.Tenancy.external_user?/1` — the single by-user
  predicate; this must NOT re-implement it. `external_user?/1` matches on a
  struct/map carrying an `:id`, so a `{:user, uid}` principal is wrapped as
  `%{id: uid}`. Runtime (agent) principals are never external.
  """
  @spec external_principal?({:user, binary()} | {:runtime, AgentRuntime.t()} | term()) ::
          boolean()
  def external_principal?({:user, user_id}) when is_binary(user_id),
    do: Tenancy.external_user?(%{id: user_id})

  def external_principal?(_), do: false

  defp principal_is_member?(space_id, {:user, user_id}) when is_binary(user_id) do
    Repo.exists?(
      from(p in Participant,
        where:
          p.space_id == ^space_id and
            p.participant_type == "user" and
            p.participant_id == ^user_id
      )
    )
  end

  defp principal_is_member?(space_id, {:runtime, %AgentRuntime{agent_id: agent_id}})
       when is_binary(agent_id) do
    not is_nil(get_agent_participant(space_id, agent_id))
  end

  defp principal_is_member?(_space_id, _principal), do: false

  @doc """
  List attachments for a message, oldest first.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`) drops attachments
  whose `space_id` is out of the external caller's participant set. Absent /
  nil / internal scopes are pass-through.
  """
  @spec list_attachments(binary(), keyword()) :: [Attachment.t()]
  def list_attachments(message_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    from(a in Attachment,
      where: a.message_id == ^message_id,
      order_by: [asc: a.inserted_at]
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
  end

  @doc """
  Batch-load attachments for a list of message IDs in a single query.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}` or `%Platform.Access.Scope{}`) drops attachments
  whose `space_id` is out of the external caller's participant set. Absent /
  nil / internal scopes are pass-through.
  """
  @spec list_attachments_for_messages([binary()], keyword()) :: %{binary() => [Attachment.t()]}
  def list_attachments_for_messages(message_ids, opts \\ [])

  def list_attachments_for_messages([], _opts), do: %{}

  def list_attachments_for_messages(message_ids, opts) do
    scope = Keyword.get(opts, :scope)

    from(a in Attachment,
      where: a.message_id in ^message_ids,
      order_by: [asc: a.inserted_at]
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end

  @doc """
  The space's shared files, for the phone space sheet's Files and Videos
  segments (task 01a1557a-8a6d stage 4). `state == "ready"` attachments whose
  message is not deleted, newest first, at most 50, each as
  `%{id, filename, content_type, byte_size, message_id, author, inserted_at}`.
  A pending upload, a canvas-only attachment (no message) and an attachment
  on a deleted message are all left out.

  The optional `:scope` drops attachments in spaces outside an external
  caller's participant set (`ExternalScope.scope_by_space_id/2`).
  """
  @spec list_space_attachments(binary(), keyword()) :: [map()]
  def list_space_attachments(space_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    from(a in Attachment,
      join: m in Message,
      on: m.id == a.message_id and m.space_id == a.space_id and is_nil(m.deleted_at),
      left_join: p in Participant,
      on: p.id == m.participant_id,
      where: a.space_id == ^space_id and a.state == "ready",
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: 50,
      select: %{
        id: a.id,
        filename: a.filename,
        content_type: a.content_type,
        byte_size: a.byte_size,
        message_id: m.id,
        author: p.display_name,
        inserted_at: a.inserted_at
      }
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
  end

  # How many recent messages `list_space_links/2` reads, and how many links
  # it returns. A bounded scan: no link table, no migration.
  @space_links_window 300
  @space_links_limit 50

  @doc """
  The http(s) links shared in a space, for the phone space sheet's Sites and
  Videos segments (task 01a1557a-8a6d stage 4).

  A link is exactly what the timeline turns into a clickable link: each of
  the space's #{@space_links_window} most recent non-deleted messages is
  rendered through `ContentRenderer.render_message/1`, the renderer the
  message list uses, and the http(s) `href`s of its `<a>` tags are taken. So
  a bare URL Earmark autolinks, a markdown `[text](url)` link and nothing
  else count, and the Links list cannot disagree with the timeline. There is
  no URL regex here to drift from the renderer's.

  Deduplicated by URL keeping the newest, newest first, at most
  #{@space_links_limit}, each as
  `%{url, host, kind, message_id, author, inserted_at}` where `kind` is
  `:video` for a youtube.com / youtu.be / vimeo.com / loom.com host (and
  their subdomains) and `:site` otherwise. `:scope` as
  `list_space_attachments/2`.
  """
  @spec list_space_links(binary(), keyword()) :: [map()]
  def list_space_links(space_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    from(m in Message,
      left_join: p in Participant,
      on: p.id == m.participant_id,
      where: m.space_id == ^space_id and is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: @space_links_window,
      select: %{
        message_id: m.id,
        content: m.content,
        author: p.display_name,
        inserted_at: m.inserted_at,
        space_id: m.space_id
      }
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
    |> Enum.flat_map(fn msg ->
      msg.content
      |> rendered_link_urls()
      |> Enum.map(fn url ->
        host = URI.parse(url).host |> to_string() |> String.downcase()

        %{
          url: url,
          host: host,
          kind: link_kind(host),
          message_id: msg.message_id,
          author: msg.author,
          inserted_at: msg.inserted_at
        }
      end)
    end)
    |> Enum.uniq_by(& &1.url)
    |> Enum.take(@space_links_limit)
  end

  @doc """
  The http(s) URLs the message renderer turns into links in `content`, in
  order. Public so the test that holds `list_space_links/2` to the timeline
  can ask the same question of the same renderer.
  """
  @spec rendered_link_urls(String.t() | nil) :: [String.t()]
  def rendered_link_urls(content) when is_binary(content) and content != "" do
    content
    |> Platform.Chat.ContentRenderer.render_message()
    |> Phoenix.HTML.safe_to_string()
    |> Floki.parse_fragment!()
    |> Floki.attribute("a", "href")
    |> Enum.filter(&String.match?(&1, ~r{\Ahttps?://}i))
    |> Enum.uniq()
  end

  def rendered_link_urls(_content), do: []

  @video_hosts ~w(youtube.com youtu.be vimeo.com loom.com)

  defp link_kind(host) do
    if Enum.any?(@video_hosts, &(host == &1 or String.ends_with?(host, "." <> &1))),
      do: :video,
      else: :site
  end

  defp publish_canvas_created(canvas) do
    :telemetry.execute(
      [:platform, :chat, :canvas_created],
      %{system_time: System.system_time()},
      %{
        canvas_id: canvas.id,
        space_id: canvas.space_id,
        document_kind: Platform.Chat.CanvasDocument.root_kind(canvas.document),
        title: canvas.title
      }
    )

    ChatPubSub.broadcast(canvas.space_id, {:canvas_created, canvas})
    ChatPubSub.broadcast_canvas(canvas.id, {:canvas_updated, canvas})
  end

  @doc """
  Public so out-of-module write paths (e.g. `Canvas.Server.do_persist/5`)
  can fire the same broadcast/telemetry as `update_canvas/2`. UI relies on
  the space-topic broadcast to refresh stream-rendered canvas messages.
  """
  def publish_canvas_updated(canvas) do
    :telemetry.execute(
      [:platform, :chat, :canvas_updated],
      %{system_time: System.system_time()},
      %{
        canvas_id: canvas.id,
        space_id: canvas.space_id,
        document_kind: Platform.Chat.CanvasDocument.root_kind(canvas.document),
        title: canvas.title
      }
    )

    ChatPubSub.broadcast(canvas.space_id, {:canvas_updated, canvas})
    ChatPubSub.broadcast_canvas(canvas.id, {:canvas_updated, canvas})
  end

  defp default_canvas_message(attrs) do
    title = Map.get(attrs, "title") || "Untitled Canvas"
    "opened a live canvas: #{title}"
  end

  defp stringify_canvas_payload(value) when is_map(value) do
    Map.new(value, fn
      {key, nested} when is_atom(key) -> {Atom.to_string(key), stringify_canvas_payload(nested)}
      {key, nested} -> {key, stringify_canvas_payload(nested)}
    end)
  end

  defp stringify_canvas_payload(value) when is_list(value) do
    Enum.map(value, &stringify_canvas_payload/1)
  end

  defp stringify_canvas_payload(value), do: value

  # ── Mention-based reinvite + pin-propagation (ADR 0038 + task 019f62a1) ────
  #
  # An @-mention of an agent who isn't currently an active participant brings
  # them back. This is the ONLY path that should resurrect a dismissed agent
  # — the contract the product owner wants is "dismiss = gone; @mention = back".
  #
  # DMs are exempt: mentioning an agent in a DM must NOT auto-add them. DMs
  # are private by contract; only agents already on the DM's roster receive
  # attention routing. Channels continue to support the mention-reinvite
  # contract.
  #
  # Stage 3 of task 019f62a1 (Pin-to-Chat) adds a second pass: when the
  # message lands in an EXECUTION space carrying a task_id AND the message
  # author is that task's sponsor, resolve each `@[…]` token to a user
  # (by email) or agent (by slug) and pin them via
  # `Platform.Tasks.ChatPins.pin/3`. Only sponsors may propagate a pin —
  # non-sponsor @-mentions in exec spaces reinvite agents (existing
  # behaviour) but do NOT add a pin row. Idempotency of `pin/3` (short-
  # circuit on repeat) covers the "same token twice in one message" case
  # without a broadcast storm. Channels + DMs are untouched by the
  # pin-propagation pass — the exec-space guard is the only gate that
  # matters here.

  defp reinvite_and_pin_mentioned(%Message{space_id: space_id, content: content} = msg)
       when is_binary(content) and content != "" do
    {bracketed, _legacy_zone} =
      Platform.Chat.AttentionRouter.extract_bracketed_tokens(String.downcase(content))

    case bracketed do
      [] ->
        :ok

      tokens ->
        space = Repo.get(Space, space_id)

        cond do
          is_nil(space) ->
            :ok

          space.kind == "dm" ->
            # DM privacy guard: do not auto-add agents to DMs on @-mention.
            :ok

          true ->
            # Any active agent in the space's workspace is eligible. Match by
            # slug OR display name (case-insensitive). Currently-present
            # participants are handled by the attention router; this path only
            # fires an insert-if-missing, so already-present agents are no-ops.
            # Task 01a0ac64 stage 1: the add is AUTHORIZED, not automatic.
            # Only an admin user participant of the space, or the sponsor of
            # the task owning an execution space, may summon an agent into it.
            # An unauthorized author's mention is a silent no-op: no row, no
            # error, the message posts normally.
            #
            # Task 01a0fd62 stage 2: an unauthorized mention is no longer
            # silent TO ITS AUTHOR. The agents it would have added (matched
            # by token AND not already present) come back as
            # `{:refused, agents}` so the post path can tell the author's own
            # process. Already-present agents are not refused: the mention is
            # honoured by the attention router as before.
            #
            # Task 01a1386e-45a5 stage 2 (RBAC stack member 7): an agent whose
            # owner, or whose own grants, may not read the space is never
            # summoned, by ANY author. It joins the refused list whether or
            # not it is already present, because the attention router will
            # not wake it here either, and the author should be told so.
            matched = mentioned_summonable_agents(space, tokens)
            unreadable = unreadable_agents(matched, space_id)
            readable = Enum.reject(matched, &MapSet.member?(unreadable, &1.id))
            refused_unreadable = Enum.filter(matched, &MapSet.member?(unreadable, &1.id))

            result =
              if mention_summon_authorized?(space, msg.author_user_id) do
                Enum.each(readable, &reinstate_on_mention(space_id, &1))
                refused_result(refused_unreadable)
              else
                refused_result(reject_present_agents(space_id, readable) ++ refused_unreadable)
              end

            # Stage 3 pin-propagation pass. Only executes when the space is
            # a task's execution space AND the message author is that task's
            # sponsor. Any lookup miss short-circuits the pass — this is a
            # side-effect layered on top of the reinvite; it must never
            # crash the message-post transaction.
            maybe_propagate_task_pins(space, msg, tokens)
            result
        end
    end
  end

  defp reinvite_and_pin_mentioned(_), do: :ok

  # The registry's read permission for a chat space (`Platform.Access.Registry`).
  @chat_read "chat.read"

  defp refused_result([]), do: :ok
  defp refused_result(agents), do: {:refused, agents}

  defp unreadable_agents(agents, space_id) do
    agents
    |> Enum.map(& &1.id)
    |> Platform.Access.AgentWake.denied(@chat_read, {:space, space_id})
  end

  @doc """
  May `agent` be woken in the space `space_id` (task 01a1386e-45a5 stage 2,
  RBAC stack member 7)? `true` unless `Platform.Access.check/3` refuses
  `chat.read` on `{:space, space_id}` to the owner of the agent's runtime
  (`Access.Scope.for_user/1`) or to the agent's own grants
  (`Access.Scope.for_runtime/1`), through
  `Platform.Access.AgentWake.check_agent/4`.

  Conjunctive with every existing gate: the mention summon and the attention
  router still apply their own participation, roster and authorship rules
  first. With no grants reachable from the agent or its owner this is
  `true` after one `EXISTS` query.
  """
  @spec agent_may_read_space?(Platform.Agents.Agent.t(), binary()) :: boolean()
  def agent_may_read_space?(%Platform.Agents.Agent{} = agent, space_id)
      when is_binary(space_id) do
    runtime = Platform.Federation.get_runtime_for_agent(agent)

    Platform.Access.AgentWake.check_agent(agent, runtime, @chat_read, {:space, space_id}) == :ok
  end

  # Agents a `@[…]` token in `tokens` names (slug OR display name,
  # case-insensitive) among the space's summonable set.
  defp mentioned_summonable_agents(%Space{} = space, tokens) do
    space
    |> summonable_agents_query()
    |> Repo.all()
    |> Enum.filter(&MentionIdentity.agent_named?(&1, tokens))
  end

  defp reject_present_agents(_space_id, []), do: []

  defp reject_present_agents(space_id, agents) do
    ids = Enum.map(agents, & &1.id)

    present =
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id in ^ids,
        select: p.participant_id
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(agents, &MapSet.member?(present, &1.id))
  end

  @doc """
  The agents eligible to be brought into `space` by name: every non-archived
  agent, scoped to the space's workspace when it has one (agents with no
  workspace stay eligible everywhere).

  This is the set the mention-summon path matches `@[…]` tokens against, and
  the one any member picker must offer, so the two cannot disagree about who
  can be summoned (task 01a0fd62).
  """
  @spec summonable_agents_query(Space.t()) :: Ecto.Query.t()
  def summonable_agents_query(%Space{} = space) do
    from(a in Platform.Agents.Agent, where: a.status != "archived")
    |> maybe_scope_to_workspace(space.workspace_id)
  end

  @doc """
  The summonable agents (`summonable_agents_query/1`) that are NOT already
  participants of `space`, ordered by name. This is the members panel's
  "Add agent" picker (task 01a0fd62 stage 3).
  """
  @spec list_addable_agents(Space.t()) :: [Agent.t()]
  def list_addable_agents(%Space{id: space_id} = space) do
    present =
      from(p in Participant,
        where: p.space_id == ^space_id and p.participant_type == "agent",
        select: p.participant_id
      )

    space
    |> summonable_agents_query()
    |> where([a], a.id not in subquery(present))
    |> order_by([a], asc: a.name)
    |> Repo.all()
  end

  # Tell the author's own process that its mention was refused (task 01a0fd62
  # stage 2). `reinvite_and_pin_mentioned/1` runs synchronously inside the
  # caller, and both UI send paths pass `from_pid: self()`, so `from_pid` IS
  # the author's LiveView: a direct `send/2` reaches exactly that process and
  # no other member's. Agent and MCP authors (no `author_user_id`, or no
  # `from_pid`) get nothing. A post-commit side effect: it must never crash
  # the post, so a failure here is logged and swallowed.
  defp notify_refused_summons(result, %Message{} = msg, opts) do
    with {:refused, [_ | _] = agents} <- result,
         pid when is_pid(pid) <- Keyword.get(opts, :from_pid),
         author when is_binary(author) <- msg.author_user_id do
      send(pid, {:mention_summon_refused, msg.id, Enum.map(agents, &(&1.name || &1.slug))})
    end

    :ok
  rescue
    error ->
      Logger.error(
        "[Chat] notify_refused_summons failed for message #{inspect(msg.id)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # ── Inbox producer (task 019f904c-904d — M2) ───────────────────────────────
  #
  # Emit one durable inbox row per @mentioned USER for a freshly-posted message.
  # Fires AFTER a successful insert/commit, exactly like
  # `reinvite_and_pin_mentioned/1` — a post-commit side-effect that must NEVER
  # crash the post. It hooks ONLY the create seam, so no-backfill-on-edit and
  # no-retro-delete-on-delete are guaranteed STRUCTURALLY: the edit/delete paths
  # are untouched.
  #
  # Recipient resolution: the mentioned USER participants of the space. For a
  # user participant the `participant_id` field IS the user_id, so it maps
  # straight to `Platform.Inbox.emit/1`'s `:user_id`. The author is excluded at
  # the USER level (across every space they participate in) via
  # `msg.author_user_id`, and the recipient set is deduped by user.
  #
  # The only gate is space participation: a user appears in
  # `list_participants/1` only for spaces they belong to, which already
  # enforces "external users only get inbox rows for allowlisted spaces".
  # This loop used to call an `inbox_emit_allowed?/2` seam (task 019f904c-904d
  # M2) that returned `true` unconditionally; the Elixir 1.20 type checker
  # flags a conditional on a constant, so the seam was removed. An
  # external-scope predicate (`Platform.Chat.ExternalScope`) belongs as an
  # `Enum.filter/2` step above `Enum.each/2`.
  defp emit_inbox_for_mentions(%Message{space_id: space_id, content: content} = msg)
       when is_binary(content) do
    space = Repo.get(Space, space_id)

    if space do
      space_id
      |> list_participants()
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.filter(&Platform.Chat.AttentionRouter.mentioned?(&1, msg))
      |> Enum.reject(&(&1.participant_id == msg.author_user_id))
      |> emit_chat_mention_inbox(
        msg,
        space,
        mention_inbox_title(msg.author_display_name, msg, space)
      )
    end

    :ok
  rescue
    error ->
      # A post-commit side-effect must never surface to the caller. Log and
      # move on — the message is already durably persisted.
      Logger.error(
        "[Inbox] emit_inbox_for_mentions failed for message #{inspect(msg.id)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp emit_inbox_for_mentions(_), do: :ok

  # One `chat_mention` Inbox row per USER participant in `participants` who
  # may read the space. Shared by the post path's mentions and added
  # attention (task 01a1557a-a30a stage 1), so the `chat.read` check, the body
  # and the deep link cannot drift between the two.
  defp emit_chat_mention_inbox(participants, %Message{} = msg, %Space{} = space, title) do
    participants
    |> Enum.uniq_by(& &1.participant_id)
    |> Enum.filter(fn p ->
      user = Repo.get(Platform.Accounts.User, p.participant_id)

      is_nil(user) or
        Platform.Access.check(
          Platform.Access.Scope.for_user(user),
          "chat.read",
          {:space, space.id}
        ) == :ok
    end)
    |> Enum.each(fn p ->
      Platform.Inbox.emit(%{
        user_id: p.participant_id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: msg.id,
        title: title,
        body: String.slice(msg.content || "", 0, 200),
        url: "/chat/#{space_path_segment(space)}?message=#{msg.id}"
      })
    end)
  end

  # Inbox title for a chat mention. For DM spaces the space has no meaningful
  # `name`, so the label is the DM PEER's display name — in a 2-party DM the
  # peer relative to any recipient is the author (recipients exclude the
  # author), so `author_display_name` is exactly the peer name.
  # `sender` is the author for a posted mention and the adder for added
  # attention; the space label rule is the same for both.
  defp mention_inbox_title(sender, %Message{} = msg, %Space{} = space),
    do: "@Mention from #{sender} in ##{space_label(space, msg)}"

  defp space_label(%Space{kind: "dm"}, %Message{author_display_name: peer}), do: peer

  # A GROUP space also carries no name (`Space.validate_channel_fields/1`
  # requires one only for `kind: "channel"`), so this clause used to render the
  # title as a bare "in #" — the same slug-less-space assumption that produced
  # "/chat/?message=..." in the url. Fall back to the author, exactly as the DM
  # clause does. Found while capturing stage 4's inbox evidence.
  defp space_label(%Space{name: name}, %Message{author_display_name: author})
       when not is_binary(name) or name == "",
       do: author

  defp space_label(%Space{name: name}, _msg), do: name

  # Single-tenant/default-org setups leave `workspace_id: nil` on both
  # agents and spaces; in that case skip the scope filter and trust the
  # name-match. Otherwise, scope to the space's workspace.
  defp maybe_scope_to_workspace(query, nil), do: query

  defp maybe_scope_to_workspace(query, workspace_id) do
    from(a in query, where: a.workspace_id == ^workspace_id or is_nil(a.workspace_id))
  end

  # ── Pin-propagation pass (task 019f62a1 stage 3) ───────────────────────────
  #
  # Fires only when the mention lands in an execution space AND the
  # author is the task's sponsor. Delegates each resolved participant
  # to `Platform.Tasks.ChatPins.pin/3` which is idempotent — repeat
  # mentions of the same target within one message don't re-broadcast.
  # Non-sponsor mentions are silently skipped; channels/DMs never reach
  # this callsite.
  defp maybe_propagate_task_pins(%Space{kind: "execution"} = space, %Message{} = msg, tokens) do
    with %{"task_id" => task_id} when is_binary(task_id) <- space.metadata || %{},
         %Platform.Tasks.Task{} = task <- Repo.get(Platform.Tasks.Task, task_id),
         true <- sponsor_authored?(task, msg),
         pinned_by when is_binary(pinned_by) <- sponsor_email_for(task, msg) do
      tokens
      |> Enum.uniq()
      |> Enum.each(fn token ->
        case resolve_pin_target(token) do
          nil -> :ok
          participant -> Platform.Tasks.ChatPins.pin(task_id, participant, pinned_by)
        end
      end)

      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_propagate_task_pins(_space, _msg, _tokens), do: :ok

  # Sponsor check: message's snapshotted author_user_id matches task's
  # sponsor_user_id. `sponsor_user_id` is nullable (ADR 0042) — a task
  # without a sponsor cannot propagate pins even to a matching author.
  defp sponsor_authored?(%Platform.Tasks.Task{sponsor_user_id: sponsor_id}, %Message{
         author_user_id: author_id
       })
       when is_binary(sponsor_id) and is_binary(author_id),
       do: sponsor_id == author_id

  defp sponsor_authored?(_task, _msg), do: false

  # Resolve the sponsor's email for the `pinned_by` audit column on
  # `ChatPin`. Falls back to the message's snapshotted display name if
  # the user row was hard-deleted between authorship and mention
  # dispatch — the column just needs a non-empty string.
  defp sponsor_email_for(%Platform.Tasks.Task{sponsor_user_id: sponsor_id}, %Message{} = msg)
       when is_binary(sponsor_id) do
    case Repo.get(Platform.Accounts.User, sponsor_id) do
      %Platform.Accounts.User{email: email} when is_binary(email) and email != "" -> email
      _ -> msg.author_display_name || sponsor_id
    end
  end

  defp sponsor_email_for(_task, _msg), do: nil

  # Token → `{kind, id}` map suitable for `ChatPins.pin/3`. Users
  # resolve by email; agents resolve by slug. Emails are already
  # downcased by `extract_bracketed_tokens/1` so a case-insensitive
  # match against `users.email` — canonically stored lowercase in this
  # codebase — is a direct equality check. Returns `nil` when nothing
  # matches; caller skips the pin without noise.
  defp resolve_pin_target(token) when is_binary(token) do
    case Repo.get_by(Platform.Accounts.User, email: token) do
      %Platform.Accounts.User{} = user ->
        %{kind: "user", id: user.email}

      nil ->
        # An ambiguous slug (shared across workspaces) pins nothing, same as
        # a miss (task 01a0e77c); SlugLookup logs the ambiguity.
        case Platform.Agents.SlugLookup.resolve(token) do
          {:ok, agent} -> %{kind: "agent", id: agent.slug}
          {:error, _} -> nil
        end
    end
  end

  defp resolve_pin_target(_), do: nil

  # Mention-reinvite. Post-ADR-0038 there's no soft-dismissed state —
  # either the row exists (already in the space) or it doesn't (dismissed
  # and hard-deleted). So "reinvite" is just an add-if-missing.
  # Authorization for the mention-summon path (task 01a0ac64 stage 1).
  #
  # Two grounds, either sufficient:
  #   * the author is a `user` participant of THIS space with role "admin";
  #   * the space is an execution space whose task the author sponsors —
  #     the same `sponsor_user_id == author` comparison `sponsor_authored?/2`
  #     makes for `maybe_propagate_task_pins/3`, keyed on a user id since
  #     task 01a0fd62 so `can_summon_agents?/2` can ask it without a message.
  #
  # Anything else (agent authors, ordinary members, observers, a message with
  # no snapshotted author user) is unauthorized.
  #
  # Keyed on the ACTOR's user id (task 01a1557a-a30a stage 1): for a mention
  # the actor is the message author; for added attention it is whoever adds.
  defp mention_summon_authorized?(%Space{} = space, actor_user_id),
    do: can_summon_agents?(space, actor_user_id)

  @doc """
  Whether `user_id` may bring agents into `space` (task 01a0ac64's rule,
  extracted unchanged by task 01a0fd62 stage 2).

  Two grounds, either sufficient: the user is a `user` participant of the
  space with role `"admin"`, or the space is an execution space whose task the
  user sponsors. Anything else, including a non-binary `user_id`, is false.
  """
  @spec can_summon_agents?(Space.t(), term()) :: boolean()
  def can_summon_agents?(%Space{} = space, user_id) when is_binary(user_id) do
    admin_user_participant?(space.id, user_id) or sponsor_of_space_task?(space, user_id)
  end

  def can_summon_agents?(_space, _user_id), do: false

  @doc """
  Add an agent to `space` on behalf of `actor_user_id` from the channel members
  panel (task 01a0fd62 stage 3).

  The server is the gate; the panel only offers the control. The actor must
  satisfy `can_summon_agents?/2`, the same rule the `@[agent]` mention path
  uses, and the agent must be in `summonable_agents_query/1`, the same set the
  mention path matches against. The row is written with the opts
  `reinstate_on_mention/2` uses, so a panel add and a mention add are
  identical rows, including the bounded `history_visible_from` grant.

  Returns `{:ok, participant}`, or `{:error, :dm | :unauthorized | :not_found}`.
  """
  @spec admin_add_agent(Space.t(), term(), term()) ::
          {:ok, Participant.t()} | {:error, :dm | :unauthorized | :not_found | term()}
  def admin_add_agent(%Space{kind: "dm"}, _actor_user_id, _agent_id), do: {:error, :dm}

  def admin_add_agent(%Space{} = space, actor_user_id, agent_id) do
    if can_summon_agents?(space, actor_user_id) do
      # `resolve_agent/1` guards a malformed id itself (nil, never a cast
      # error), and the eligibility read pins the LOADED row's id.
      with %Agent{} = agent <- resolve_agent(agent_id),
           true <- summonable_agent?(space, agent) do
        add_agent_participant(space.id, agent,
          attention_mode: "mention",
          history_visible_from: DateTime.utc_now()
        )
      else
        _ -> {:error, :not_found}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp summonable_agent?(%Space{} = space, %Agent{id: agent_id}) do
    space |> summonable_agents_query() |> where([a], a.id == ^agent_id) |> Repo.exists?()
  end

  @doc """
  Remove an agent participant from `space` on behalf of `actor_user_id` from
  the channel members panel (task 01a0fd62 stage 3).

  Same authorization as `admin_add_agent/3`. Only an AGENT row of this space
  can be removed here (`{:error, :not_an_agent}` for a user row). On success
  the active-agent mutex is released if it pointed at the removed row, the
  same cleanup MCP `space_leave` does.

  Returns `{:ok, participant}`, or
  `{:error, :dm | :unauthorized | :not_found | :not_an_agent}`.
  """
  @spec admin_remove_agent(Space.t(), term(), term()) ::
          {:ok, Participant.t()}
          | {:error, :dm | :unauthorized | :not_found | :not_an_agent | term()}
  def admin_remove_agent(%Space{kind: "dm"}, _actor_user_id, _participant_id),
    do: {:error, :dm}

  def admin_remove_agent(%Space{} = space, actor_user_id, participant_id) do
    with true <- can_summon_agents?(space, actor_user_id) || {:error, :unauthorized},
         # `get_space_participant/2` guards both ids and scopes the row to
         # THIS space, so a participant id from another space is not found.
         %Participant{} = participant <-
           get_space_participant(space.id, participant_id) || {:error, :not_found},
         true <- participant.participant_type == "agent" || {:error, :not_an_agent},
         {:ok, removed} <- remove_participant(participant) do
      Platform.Chat.ActiveAgentStore.clear_if_match(space.id, removed.id)
      # The roster signal the deleted utility-bar Remove sent
      # (`remove_space_agent/3`, task 01a1557a-8f80 stage 3): the quickmeet's
      # People tab follows `{:roster_changed, _}`, not `{:participant_left, _}`.
      broadcast_roster_changed(space.id, removed.participant_id, :removed)
      {:ok, removed}
    end
  end

  defp admin_user_participant?(space_id, user_id) do
    Repo.exists?(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id == ^user_id and p.role == "admin"
      )
    )
  end

  defp sponsor_of_space_task?(%Space{kind: "execution"} = space, user_id) do
    with %{"task_id" => task_id} when is_binary(task_id) <- space.metadata || %{},
         %Platform.Tasks.Task{sponsor_user_id: sponsor_id} when is_binary(sponsor_id) <-
           Repo.get(Platform.Tasks.Task, task_id) do
      # The same comparison `sponsor_authored?/2` makes, keyed on a user id
      # rather than a message so callers without a message can ask it.
      sponsor_id == user_id
    else
      _ -> false
    end
  end

  defp sponsor_of_space_task?(_space, _user_id), do: false

  defp reinstate_on_mention(space_id, %Platform.Agents.Agent{} = agent) do
    case add_agent_participant(space_id, agent,
           attention_mode: "mention",
           history_visible_from: DateTime.utc_now()
         ) do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  # ── Author snapshots (ADR 0038) ────────────────────────────────────────────
  #
  # Snapshot the authoring participant's identity onto the owning row so
  # rendering never depends on the participant still existing. If the
  # caller already supplied snapshot fields, they're preserved.

  defp put_author_snapshot(attrs, source_key, role) do
    pid = fetch_map(attrs, source_key)

    cond do
      already_snapshotted?(attrs, role) ->
        attrs

      is_binary(pid) ->
        Map.merge(snapshot_map(author_snapshot_for(pid), role), attrs)

      true ->
        attrs
    end
  end

  # Pull the integer revision number out of a freshly-inserted canvas's
  # document. New canvases are seeded with revision 1; if a caller passes an
  # already-rich document (e.g. clones, restores) the document carries the
  # revision verbatim. Default to 1 — the same fallback the kind-renderer
  # uses for missing revisions.
  defp canvas_version_revision(%Canvas{document: %{"revision" => r}})
       when is_integer(r) and r > 0,
       do: r

  defp canvas_version_revision(_), do: 1

  defp put_canvas_creator_snapshot(attrs) do
    cond do
      Map.get(attrs, "created_by_display_name") not in [nil, ""] ->
        attrs

      is_binary(Map.get(attrs, "created_by")) ->
        snap = author_snapshot_for(Map.get(attrs, "created_by"))

        attrs
        |> Map.put("created_by_display_name", snap[:author_display_name])
        |> Map.put("created_by_participant_type", snap[:author_participant_type])

      true ->
        attrs
    end
  end

  defp author_snapshot_for(participant_id) when is_binary(participant_id) do
    case Repo.get(Participant, participant_id) do
      %Participant{} = p ->
        %{
          author_display_name: p.display_name,
          author_avatar_url: p.avatar_url,
          author_participant_type: p.participant_type,
          author_agent_id: if(p.participant_type == "agent", do: p.participant_id),
          author_user_id: if(p.participant_type == "user", do: p.participant_id)
        }

      nil ->
        %{}
    end
  end

  defp author_snapshot_for(_), do: %{}

  # Translate the canonical `:author_*` shape into role-specific keys. The
  # message path uses `author_*` directly; pins use `pinned_by_*`.
  defp snapshot_map(snap, :author), do: snap

  defp snapshot_map(snap, :pinned_by) do
    %{
      pinned_by_display_name: snap[:author_display_name],
      pinned_by_participant_type: snap[:author_participant_type]
    }
  end

  defp already_snapshotted?(attrs, :author) do
    fetch_map(attrs, :author_display_name) not in [nil, ""]
  end

  defp already_snapshotted?(attrs, :pinned_by) do
    fetch_map(attrs, :pinned_by_display_name) not in [nil, ""]
  end

  defp fetch_map(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_map(_, _), do: nil

  # ── Space Agent Roster ──────────────────────────────────────────────────────
  #
  # ADR 0038 Phase 5 unified the roster into `chat_participants`. There is
  # no separate `chat_space_agents` table anymore; `participant.role`
  # carries `principal | member | admin | observer` for agent rows, and
  # membership is just the presence of the row.
  #
  # The helpers below return maps shaped `%{space_id, agent_id, role, agent}` for
  # backward compatibility with UI and roster-status callers.

  @type roster_entry :: %{
          required(:space_id) => binary(),
          required(:agent_id) => binary(),
          required(:role) => String.t(),
          required(:agent) => Agent.t() | nil,
          required(:inserted_at) => DateTime.t() | nil
        }

  @doc """
  Set the principal agent for a space. Demotes any existing principal to
  `member` and promotes the target (inserting a participant row if needed).
  """
  @spec set_principal_agent(binary(), binary()) ::
          {:ok, roster_entry()} | {:error, term()}
  def set_principal_agent(space_id, agent_id) do
    Multi.new()
    |> Multi.run(:demote_existing, fn repo, _changes ->
      case repo.get_by(Participant,
             space_id: space_id,
             participant_type: "agent",
             role: "principal"
           ) do
        nil ->
          {:ok, nil}

        %Participant{participant_id: ^agent_id} = existing ->
          {:ok, existing}

        %Participant{} = existing ->
          existing
          |> Participant.changeset(%{role: "member"})
          |> repo.update()
      end
    end)
    |> Multi.run(:promote, fn repo, %{demote_existing: demoted} ->
      case demoted do
        %Participant{participant_id: ^agent_id} ->
          {:ok, demoted}

        _ ->
          case repo.get_by(Participant,
                 space_id: space_id,
                 participant_type: "agent",
                 participant_id: agent_id
               ) do
            %Participant{} = existing ->
              existing
              |> Participant.changeset(%{role: "principal"})
              |> repo.update()

            nil ->
              case resolve_agent(agent_id) do
                %Agent{} = agent ->
                  add_participant(space_id, %{
                    participant_type: "agent",
                    participant_id: agent.id,
                    display_name: agent.name,
                    role: "principal",
                    attention_mode: "all",
                    joined_at: DateTime.utc_now()
                  })

                nil ->
                  {:error, :agent_not_found}
              end
          end
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{promote: %Participant{} = participant}} ->
        broadcast_roster_changed(space_id, agent_id, :set_principal)
        {:ok, participant_to_roster_entry(participant)}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Add an agent to a space's roster. Idempotent insert; if the agent is
  already a participant the existing row is returned unchanged.

  ## Options

    * `:role` — `"member"` (default) or `"principal"`
  """
  @spec add_space_agent(binary(), binary(), keyword()) ::
          {:ok, roster_entry()} | {:error, term()}
  def add_space_agent(space_id, agent_id, opts \\ []) do
    role = Keyword.get(opts, :role, "member")

    cond do
      role == "principal" ->
        set_principal_agent(space_id, agent_id)

      true ->
        case resolve_agent(agent_id) do
          nil ->
            {:error, :agent_not_found}

          %Agent{} = agent ->
            case add_agent_participant(space_id, agent,
                   display_name: agent.name,
                   joined_at: DateTime.utc_now()
                 ) do
              {:ok, participant} ->
                broadcast_roster_changed(space_id, agent_id, :added)
                {:ok, participant_to_roster_entry(participant)}

              error ->
                error
            end
        end
    end
  end

  # ── Agent attention controls (task 01a1557a-8f80 stage 1) ─────────────────
  #
  # Three choices any USER participant of a space may make about its agents:
  # silence one agent, switch every agent off with the master switch, and
  # pick the attention policy. `Platform.Chat.AttentionRouter` obeys all
  # three. Each writer composes `SpaceAccess.authorize_writer/2` in its own
  # body, takes the space id from the caller (a LiveView passes
  # `socket.assigns.active_space`, never a param), refuses an agent actor so
  # an agent cannot unsilence itself, and broadcasts
  # `{:agent_attention_changed, space_id}` on the space topic.
  #
  # Not `can_summon_agents?/2`: that rule governs adding and removing agents.
  # The header eye these controls replace had no rule beyond membership.

  @doc """
  Silence (`true`) or wake (`false`) one agent participant of a space.

  A silenced agent is mention-only: it never receives an un-mentioned message
  (as mutex holder, by policy fan-out, or as the execution assignee fallback),
  but an @mention still routes to it. Silencing the agent that currently holds
  the space's active-agent mutex clears the mutex.

  `participant_id` is the `chat_participants.id` of an AGENT participant of
  `space_id`; anything else (a user row, another space's agent, a malformed
  id) is `{:error, :not_found}`.
  """
  @spec set_agent_silenced(SpaceAccess.actor(), binary(), binary(), boolean()) ::
          {:ok, Participant.t()}
          | {:error, :forbidden | :space_archived | :not_found | Ecto.Changeset.t()}
  def set_agent_silenced(actor, space_id, participant_id, silenced)
      when is_boolean(silenced) do
    with {:ok, writer} <- SpaceAccess.authorize_writer(space_id, actor),
         :ok <- ensure_user_writer(writer),
         :ok <- ensure_space_writable(space_id),
         %Participant{} = agent <- space_agent_participant(space_id, participant_id) do
      with {:ok, updated} <-
             agent |> Participant.changeset(%{silenced: silenced}) |> Repo.update() do
        if silenced, do: Platform.Chat.ActiveAgentStore.clear_if_match(space_id, updated.id)
        broadcast_agent_attention_changed(space_id)
        {:ok, updated}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Set the space's master switch, `chat_spaces.agents_awake`.

  Off: no un-mentioned message reaches any agent in the space and the
  active-agent mutex is cleared; @mentions still route. Per-agent `silenced`
  values are never touched. Arming an agent when the switch goes back on is
  the caller's (the Agents sheet's hook arms
  `PlatformWeb.ChatLive.AgentsSheetHooks.resolve_armable/2`'s target); this
  writer only persists.
  """
  @spec set_agents_awake(SpaceAccess.actor(), binary(), boolean()) ::
          {:ok, Space.t()}
          | {:error, :forbidden | :space_archived | :not_found | Ecto.Changeset.t()}
  def set_agents_awake(actor, space_id, awake) when is_boolean(awake) do
    with {:ok, writer} <- SpaceAccess.authorize_writer(space_id, actor),
         :ok <- ensure_user_writer(writer),
         :ok <- ensure_space_writable(space_id),
         %Space{} = space <- Repo.get(Space, space_id),
         {:ok, updated} <-
           space |> Space.agent_attention_changeset(%{agents_awake: awake}) |> Repo.update() do
      unless awake, do: Platform.Chat.ActiveAgentStore.clear_active(space_id)
      broadcast_agent_attention_changed(space_id)
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Set the space's agent attention policy, `chat_spaces.agent_attention_policy`
  (`"on_mention" | "directed" | "collaborative"`).

  Applies to channel and group spaces only: any other kind (a DM is always
  directed, an execution space keeps its assignee fallback) is
  `{:error, :not_applicable}`. An unknown value is a changeset error.
  """
  @spec set_agent_attention_policy(SpaceAccess.actor(), binary(), String.t()) ::
          {:ok, Space.t()}
          | {:error, :forbidden | :space_archived | :not_found | :not_applicable}
          | {:error, Ecto.Changeset.t()}
  def set_agent_attention_policy(actor, space_id, policy) do
    with {:ok, writer} <- SpaceAccess.authorize_writer(space_id, actor),
         :ok <- ensure_user_writer(writer),
         :ok <- ensure_space_writable(space_id),
         %Space{} = space <- Repo.get(Space, space_id),
         :ok <- ensure_policy_applicable(space),
         {:ok, updated} <-
           space
           |> Space.agent_attention_changeset(%{agent_attention_policy: policy})
           |> Repo.update() do
      broadcast_agent_attention_changed(space_id)
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # ── Get someone's attention (task 01a1557a-a30a stage 1) ───────────────────
  #
  # A member asks one or more participants to look at an ALREADY-SENT message.
  # The ask is a row in `chat_message_attentions`; the message row is never
  # updated and no `chat_message_versions` row is written, so it can never
  # render "(edited)" (that affix gates on `versions_count > 1`).

  @doc """
  Ask `principal_ids` to look at the message `message_id` in `space_id`.

  `principal_ids` are principal ids, as the mention picker's suggestions carry
  them (`principal_id`: a user id or an agent id). Any USER writer of the space
  may add attention to ANY message, not only their own (the redesign masters
  show the row on every message). Refused, changing nothing:

    * a non-member or nil actor, and an agent actor: `{:error, :forbidden}`
    * an archived space: `{:error, :space_archived}`
    * a message that is missing, deleted, or not in `space_id` (a forged
      event; a LiveView passes `socket.assigns.active_space.id`, never a
      param): `{:error, :not_found}`
    * nothing left to add: `{:error, :invalid}`

  The message author, the actor, the `@[here]` sentinel and anyone who is
  neither a participant nor a summonable agent are dropped. An agent that is
  not in the space is summoned only when the actor may summon
  (`can_summon_agents?/2`, the rule an `@[…]` mention's author meets), never
  into a DM, and never when the agent may not read the space; otherwise it
  comes back under `refused` and gets no row. A present agent that may not
  read the space is refused too, as for a mention.

  Idempotent: a principal already added is returned under `unchanged` and is
  not routed or notified again (`on_conflict: :nothing` on the unique
  `(message_id, participant_id)` index). After the insert the newly added are
  routed (`AttentionRouter.route_attention/3`), each added human gets one
  `chat_mention` Inbox row, and `{:message_attention_changed, message}` is
  broadcast on the space topic.
  """
  @spec add_message_attention(SpaceAccess.actor(), binary(), binary(), [binary()]) ::
          {:ok,
           %{
             added: [MessageAttention.t()],
             unchanged: [MessageAttention.t()],
             refused: [Agent.t()]
           }}
          | {:error, :forbidden | :space_archived | :not_found | :invalid}
  def add_message_attention(actor, space_id, message_id, principal_ids)
      when is_list(principal_ids) do
    with {:ok, writer} <- SpaceAccess.authorize_writer(space_id, actor),
         :ok <- ensure_user_writer(writer),
         :ok <- ensure_space_writable(space_id),
         %Message{} = message <- attention_target_message(space_id, message_id),
         %Space{} = space <- Repo.get(Space, space_id),
         {:ok, targets, refused} <-
           resolve_attention_targets(space, message, writer, principal_ids) do
      {added, unchanged} = insert_attention_rows(message, writer, targets)

      if added != [] do
        after_attention_added(space, message, writer, added, targets)
      end

      {:ok, %{added: added, unchanged: unchanged, refused: refused}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def add_message_attention(_actor, _space_id, _message_id, _principal_ids),
    do: {:error, :invalid}

  @doc "The attention rows on one message, oldest first, as `MessageAttention.to_view/1`."
  @spec list_message_attention(binary()) :: [map()]
  def list_message_attention(message_id) when is_binary(message_id) do
    message_id |> List.wrap() |> attention_by_message_ids() |> Map.get(message_id, [])
  end

  @doc """
  Attention rows for many messages in ONE query, keyed by message id, for
  render (`Message.attention`). Messages with none are omitted.
  """
  @spec attention_by_message_ids([binary()]) :: %{binary() => [map()]}
  def attention_by_message_ids(message_ids) when is_list(message_ids) do
    case Enum.filter(message_ids, &Platform.UUID.valid?/1) do
      [] ->
        %{}

      ids ->
        from(a in MessageAttention,
          where: a.message_id in ^ids,
          order_by: [asc: a.inserted_at, asc: a.id]
        )
        |> Repo.all()
        |> Enum.group_by(& &1.message_id, &MessageAttention.to_view/1)
    end
  end

  defp attention_target_message(space_id, message_id) do
    case get_message(message_id) do
      %Message{space_id: ^space_id, deleted_at: nil} = message -> message
      _ -> nil
    end
  end

  # Principal ids -> the participants to add, plus the agents refused.
  defp resolve_attention_targets(%Space{} = space, %Message{} = message, writer, principal_ids) do
    ids =
      principal_ids
      |> Enum.filter(&(is_binary(&1) and Platform.UUID.valid?(&1)))
      |> Enum.uniq()

    by_principal = space.id |> list_participants() |> Map.new(&{&1.participant_id, &1})
    dropped = MapSet.new([message.participant_id, writer.id])

    {present, absent} = Enum.split_with(ids, &Map.has_key?(by_principal, &1))

    present =
      present
      |> Enum.map(&Map.fetch!(by_principal, &1))
      |> Enum.reject(&MapSet.member?(dropped, &1.id))

    unreadable_present =
      present |> Enum.filter(&(&1.participant_type == "agent")) |> unreadable_participants(space)

    {summoned, refused_summons} = summon_for_attention(space, writer, absent)

    refused_present =
      Enum.filter(present, &MapSet.member?(unreadable_present, &1.participant_id))

    targets = Enum.reject(present, &MapSet.member?(unreadable_present, &1.participant_id))
    targets = targets ++ summoned
    refused = refused_present_agents(refused_present) ++ refused_summons

    if targets == [] and refused == [] do
      {:error, :invalid}
    else
      {:ok, targets, refused}
    end
  end

  # Agents not yet in the space (D5). The same rule a mention's author meets,
  # asked of the ACTOR: `mention_summon_authorized?/2`, plus the unreadable-
  # agent refusal. Never into a DM. A principal id that is not a summonable
  # agent is dropped.
  defp summon_for_attention(_space, _writer, []), do: {[], []}
  defp summon_for_attention(%Space{kind: "dm"}, _writer, _ids), do: {[], []}

  defp summon_for_attention(%Space{} = space, writer, agent_ids) do
    candidates =
      space
      |> summonable_agents_query()
      |> where([a], a.id in ^agent_ids)
      |> Repo.all()

    unreadable = unreadable_agents(candidates, space.id)

    {refused_unreadable, readable} =
      Enum.split_with(candidates, &MapSet.member?(unreadable, &1.id))

    if mention_summon_authorized?(space, writer.participant_id) do
      summoned =
        Enum.flat_map(readable, fn agent ->
          :ok = reinstate_on_mention(space.id, agent)

          case get_agent_participant(space.id, agent) do
            %Participant{} = p -> [p]
            _ -> []
          end
        end)

      {summoned, refused_unreadable}
    else
      {[], readable ++ refused_unreadable}
    end
  end

  defp unreadable_participants([], _space), do: MapSet.new()

  defp unreadable_participants(agent_participants, %Space{id: space_id}) do
    agent_participants
    |> Enum.map(& &1.participant_id)
    |> Platform.Access.AgentWake.denied(@chat_read, {:space, space_id})
  end

  defp refused_present_agents([]), do: []

  defp refused_present_agents(participants) do
    ids = Enum.map(participants, & &1.participant_id)
    Repo.all(from(a in Agent, where: a.id in ^ids))
  end

  # One statement, so idempotency holds under concurrency without a lock:
  # rows that already exist are skipped by the unique index and are NOT
  # returned, which is how `added` and `unchanged` are told apart.
  defp insert_attention_rows(%Message{} = message, %Participant{} = writer, targets) do
    now = DateTime.utc_now()

    rows =
      Enum.map(targets, fn %Participant{} = p ->
        %{
          id: Platform.Types.UUIDv7.generate(),
          message_id: message.id,
          participant_id: p.id,
          participant_type: p.participant_type,
          display_name: p.display_name,
          added_by_participant_id: writer.id,
          added_by_display_name: writer.display_name,
          inserted_at: now
        }
      end)

    {_count, inserted} =
      Repo.insert_all(MessageAttention, rows,
        on_conflict: :nothing,
        conflict_target: [:message_id, :participant_id],
        returning: true
      )

    added_ids = MapSet.new(inserted, & &1.participant_id)
    unchanged_ids = targets |> Enum.map(& &1.id) |> Enum.reject(&MapSet.member?(added_ids, &1))

    unchanged =
      if unchanged_ids == [] do
        []
      else
        Repo.all(
          from(a in MessageAttention,
            where: a.message_id == ^message.id and a.participant_id in ^unchanged_ids
          )
        )
      end

    {inserted, unchanged}
  end

  # Post-insert side effects for the NEWLY added only. Like the post path's
  # mention side effects, none of them may fail the call: the rows are
  # already durable.
  defp after_attention_added(%Space{} = space, %Message{} = message, writer, added, targets) do
    added_ids = Enum.map(added, & &1.participant_id)

    {:ok, _decisions} =
      Platform.Chat.AttentionRouter.route_attention(message, added_ids, writer)

    added_set = MapSet.new(added_ids)

    targets
    |> Enum.filter(&(&1.participant_type == "user" and MapSet.member?(added_set, &1.id)))
    |> emit_chat_mention_inbox(
      message,
      space,
      mention_inbox_title(writer.display_name, message, space)
    )

    message = %{message | attention: list_message_attention(message.id)}
    ChatPubSub.broadcast(space.id, {:message_attention_changed, message})
    :ok
  rescue
    error ->
      Logger.error(
        "[Chat] add_message_attention side effects failed for message #{inspect(message.id)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  @doc """
  The agent attention state of a space, for the Agents sheet:

      %{
        agents_awake: boolean,
        policy: stored value or nil,
        effective_policy: what the router applies (nil -> the kind default),
        agents: [%{participant_id, agent_id, name, slot, silenced}]
      }

  `agents` holds every agent participant, sorted by name; `slot` is the
  rung-3 accent slot from `agent_slot_map_for_participants/1`. A space that
  does not exist is `nil`.
  """
  @spec agent_attention_state(binary()) ::
          %{
            agents_awake: boolean(),
            policy: String.t() | nil,
            effective_policy: String.t(),
            agents: [map()]
          }
          | nil
  def agent_attention_state(space_id) when is_binary(space_id) do
    with true <- Platform.UUID.valid?(space_id),
         %Space{} = space <- Repo.get(Space, space_id) do
      agents =
        from(p in Participant,
          where: p.space_id == ^space_id and p.participant_type == "agent"
        )
        |> Repo.all()

      slots = agent_slot_map_for_participants(agents)
      names = agent_names_by_id(agents)

      %{
        agents_awake: space.agents_awake,
        policy: space.agent_attention_policy,
        effective_policy: Platform.Chat.AttentionRouter.resolve_attention_mode(space, nil),
        agents:
          agents
          |> Enum.map(fn p ->
            %{
              participant_id: p.id,
              agent_id: p.participant_id,
              name: attention_agent_name(p, names),
              slot: Map.get(slots, p.id),
              silenced: p.silenced
            }
          end)
          |> Enum.sort_by(&{String.downcase(&1.name), &1.participant_id})
      }
    else
      _ -> nil
    end
  end

  defp agent_names_by_id([]), do: %{}

  defp agent_names_by_id(agents) do
    agent_ids = Enum.map(agents, & &1.participant_id)

    from(a in Agent, where: a.id in ^agent_ids, select: {a.id, a.name})
    |> Repo.all()
    |> Map.new()
  end

  defp attention_agent_name(%Participant{display_name: name}, _names)
       when is_binary(name) and name != "",
       do: name

  defp attention_agent_name(%Participant{participant_id: agent_id}, names),
    do: Map.get(names, agent_id) || "Agent"

  @doc """
  The Members sheet's People section (task 01a1557a-8f80 stage 3): the space's
  user participants split into `online` and `away`.

  ONLINE means the user appears in `Platform.Chat.Presence.list_online_for_viewer/1`
  (online anywhere in Burrow the viewer can see, because ChatLive tracks a
  user only in the space on screen) or IS the viewer. AWAY is every other
  user participant of the space. The viewer leads `online` with `you?: true`;
  otherwise each list is sorted by name. Agents are never listed here.

  A failed presence read is `{:error, reason}`. It is never turned into a
  list with everybody away: "we could not ask" and "nobody is here" are
  different facts, the distinction `list_online_for_viewer/1` exists to keep.
  """
  @spec space_member_presence(binary(), map()) ::
          {:ok, %{online: [map()], away: [map()]}} | {:error, term()}
  def space_member_presence(space_id, %{id: viewer_id} = viewer) when is_binary(space_id) do
    case Platform.Chat.Presence.list_online_for_viewer(viewer) do
      {:ok, online} ->
        online_ids = MapSet.new(online, & &1.user_id)

        {here, away} =
          space_id
          |> list_participants(participant_type: "user")
          |> Enum.map(&member_row(&1, viewer_id))
          |> Enum.split_with(&(&1.you? or MapSet.member?(online_ids, &1.user_id)))

        {:ok, %{online: sort_members(here), away: sort_members(away)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "A user participant as a Members sheet row: `%{participant_id, user_id, name, you?}`."
  @spec member_row(%Participant{}, binary() | nil) :: map()
  def member_row(%Participant{} = participant, viewer_id) do
    %{
      participant_id: participant.id,
      user_id: participant.participant_id,
      name: participant.display_name || "Unknown",
      you?: participant.participant_id == viewer_id
    }
  end

  @doc "Members sheet order: the viewer first, then by name."
  @spec sort_members([map()]) :: [map()]
  def sort_members(rows),
    do: Enum.sort_by(rows, &{!&1.you?, String.downcase(&1.name), &1.participant_id})

  # An agent holds a participant row too, so `authorize_writer/2` alone would
  # let an agent unsilence itself or wake a space a member switched off.
  defp ensure_user_writer(%Participant{participant_type: "user"}), do: :ok
  defp ensure_user_writer(_participant), do: {:error, :forbidden}

  defp ensure_policy_applicable(%Space{kind: kind}) when kind in ["channel", "group"], do: :ok
  defp ensure_policy_applicable(_space), do: {:error, :not_applicable}

  defp space_agent_participant(space_id, participant_id) when is_binary(participant_id) do
    if Platform.UUID.valid?(participant_id) do
      Repo.get_by(Participant, id: participant_id, space_id: space_id, participant_type: "agent")
    end
  end

  defp space_agent_participant(_space_id, _participant_id), do: nil

  defp broadcast_agent_attention_changed(space_id),
    do: ChatPubSub.broadcast(space_id, {:agent_attention_changed, space_id})

  @doc """
  Ensure an agent is on a space's roster. Idempotent.
  `:role` controls whether the ensure also promotes to principal.
  """
  @spec ensure_space_agent(binary(), binary(), keyword()) ::
          {:ok, roster_entry()} | {:error, term()}
  def ensure_space_agent(space_id, agent_id, opts \\ []) do
    role = Keyword.get(opts, :role, "member")

    case {role, get_agent_participant(space_id, agent_id)} do
      {"principal", _} ->
        set_principal_agent(space_id, agent_id)

      {_, %Participant{} = existing} ->
        {:ok, participant_to_roster_entry(existing)}

      {_, nil} ->
        add_space_agent(space_id, agent_id, role: "member")
    end
  end

  @doc "List all agents in a space's roster with agent preloaded."
  @spec list_space_agents(binary()) :: [roster_entry()]
  def list_space_agents(space_id) do
    participants =
      from(p in Participant,
        where: p.space_id == ^space_id and p.participant_type == "agent",
        order_by: [asc: p.joined_at]
      )
      |> Repo.all()

    preload_roster_entries(participants)
  end

  @doc "Get the principal agent for a space. Returns `nil` if none set."
  @spec get_principal_agent(binary()) :: roster_entry() | nil
  def get_principal_agent(space_id) do
    case Repo.one(
           from(p in Participant,
             where:
               p.space_id == ^space_id and
                 p.participant_type == "agent" and
                 p.role == "principal",
             limit: 1
           )
         ) do
      nil -> nil
      %Participant{} = p -> preload_roster_entries([p]) |> List.first()
    end
  end

  @doc "Get a specific space-agent roster entry, or `nil` if not present."
  @spec get_space_agent(binary(), binary()) :: roster_entry() | nil
  def get_space_agent(space_id, agent_id) do
    case get_agent_participant(space_id, agent_id) do
      nil -> nil
      %Participant{} = p -> preload_roster_entries([p]) |> List.first()
    end
  end

  @doc """
  Roster entries that name a *live agent* — the denominator for space health.

  The predicate is POSITIVE: an entry counts when its `:agent` resolved to an
  `%Agent{}`. Rejected alternative: excluding the known non-agent kinds
  (`participant_type != "system"`), which silently readmits the next kind
  somebody adds. Unresolved entries (deleted agents, the synthetic TaskRouter)
  have no runtime to be healthy or unhealthy about, so they belong in neither
  half of the ratio. `list_space_agents/1` still returns them — the roster UI
  renders a deleted agent deliberately.
  """
  @spec list_active_space_agents(binary()) :: [roster_entry()]
  def list_active_space_agents(space_id) do
    space_id
    |> list_space_agents()
    |> Enum.filter(&match?(%Agent{}, &1.agent))
  end

  defp preload_roster_entries([]), do: []

  defp preload_roster_entries(participants) do
    agent_ids = Enum.map(participants, & &1.participant_id) |> Enum.uniq()

    agents_by_id =
      Repo.all(from(a in Agent, where: a.id in ^agent_ids))
      |> Map.new(&{&1.id, &1})

    Enum.map(participants, fn p ->
      %{
        space_id: p.space_id,
        agent_id: p.participant_id,
        role: p.role,
        agent: Map.get(agents_by_id, p.participant_id),
        inserted_at: p.joined_at
      }
    end)
  end

  defp participant_to_roster_entry(%Participant{} = p) do
    %{
      space_id: p.space_id,
      agent_id: p.participant_id,
      role: p.role,
      agent: Repo.get(Agent, p.participant_id),
      inserted_at: p.joined_at
    }
  end

  defp broadcast_roster_changed(space_id, agent_id, action) do
    :telemetry.execute(
      [:platform, :chat, :agent_roster_changed],
      %{system_time: System.system_time()},
      %{space_id: space_id, agent_id: agent_id, action: action}
    )

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      "space_agents:#{space_id}",
      {:roster_changed, space_id}
    )
  end

  # ── Unread counts ──────────────────────────────────────────────────────────

  @doc "Persist the last-read cursor for a participant."
  @spec mark_space_read(binary(), binary()) :: :ok
  def mark_space_read(participant_id, message_id) do
    from(p in Participant, where: p.id == ^participant_id)
    |> Repo.update_all(set: [last_read_message_id: message_id])

    :ok
  end

  @doc """
  Whether `user_id` has already read `message_id`.

  Derived, never stored: we load the message's space, load that user's
  participant row for the space, and compare UUIDv7 ids against the
  `last_read_message_id` watermark — the same ordering `count_unread/3` uses,
  and the same instinct as ADR 0023. A stored `read_at` would be a second
  source of truth that could disagree with the watermark.

  Returns `false` — not read, therefore the caller's row is NOT stale and
  survives — whenever the answer cannot be positively established: the message
  is gone, the user does not participate in its space, or the watermark is nil.
  """
  @spec message_read_by_user?(binary(), binary()) :: boolean()
  def message_read_by_user?(message_id, user_id)
      when is_binary(message_id) and is_binary(user_id) do
    with {:ok, message_uuid} <- Platform.UUID.cast(message_id),
         {:ok, user_uuid} <- Platform.UUID.cast(user_id),
         space_id when is_binary(space_id) <-
           Repo.one(from(m in Message, where: m.id == ^message_uuid, select: m.space_id)),
         last_read when is_binary(last_read) <-
           Repo.one(
             from(p in Participant,
               where:
                 p.space_id == ^space_id and p.participant_id == ^user_uuid and
                   p.participant_type == "user",
               select: p.last_read_message_id
             )
           ) do
      message_uuid <= last_read
    else
      _ -> false
    end
  end

  def message_read_by_user?(_message_id, _user_id), do: false

  @doc """
  Return `%{space_id => unread_count}` for every space the user participates in.

  Uses UUIDv7 ordering (`id > last_read_message_id`) to count newer messages.
  """
  @spec unread_counts_for_user(binary()) :: %{binary() => non_neg_integer()}
  def unread_counts_for_user(user_id) do
    from(p in Participant,
      where: p.participant_id == ^user_id and p.participant_type == "user",
      select: {p.space_id, p.last_read_message_id, p.id}
    )
    |> Repo.all()
    |> Enum.map(fn {space_id, last_read_id, participant_pk} ->
      {space_id, count_unread(space_id, last_read_id, participant_pk)}
    end)
    |> Enum.filter(fn {_, count} -> count > 0 end)
    |> Map.new()
  end

  # The space kinds the Chat surface actually renders as conversations, and so
  # the only kinds the rail badge counts. Channels reach the sidebar through
  # `list_spaces(kind: "channel")`, dms and groups through an inline
  # `kind in ["dm", "group"]` filter in `ChatLive`.
  #
  # ALLOW-LIST, not a deny-list, deliberately: a space kind added later then
  # stays uncounted (a pill with no badge, which is annoying and
  # self-explaining) instead of reappearing in a badge the reader cannot drive
  # to zero, which is the defect this list exists to close.
  #
  # KNOWN, DELIBERATE UNDER-COUNT, decided in task
  # `01a02491-a407-794f-a13e-d18398e4b092` stage 1 and pinned by a test in
  # `test/platform/chat/member_space_ids_test.exs`: the Chat sidebar renders a
  # fourth stream this list cannot express. Pinned task conversations are
  # `kind: "execution"` spaces selected by
  # `Platform.Tasks.ChatPins.list_pinned_task_spaces_for/1` and they do render
  # unread pills, so such a row can show a pill that contributes nothing here.
  # Membership in that set is a row in `task_chat_pins` rather than a kind, so
  # no kind predicate can cover it, and pulling it in would couple the badge to
  # the Tasks context.
  @chat_surface_kinds ~w(channel dm group)

  @doc """
  One number for the whole viewer: unread messages summed across the Chat
  conversations this viewer both participates in and can observe.

  Takes the LOADED user struct, not an id, and keeps that head for its callers
  even though the count itself now needs only the id: `ShellLive` holds the
  struct, `unread_counts_for_user/1` keys off the id, and changing the accepted
  input here would ripple into every caller for no gain.

  Counting exactly the set Chat RENDERS is what makes the badge honest, and two
  predicates do that work:

    * **kind**: only `#{Enum.join(@chat_surface_kinds, "`, `")}`. Every other
      kind seats real `participant_type: "user"` rows (`meeting` and
      `guest_meeting` via `Meetings.ensure_delivery_invitee/2`, `execution` via
      `ChatLive.ensure_participant/2` on every space the viewer opens) while
      rendering nowhere in Chat, so counting them produced a badge that could
      not be cleared by reading. See `@chat_surface_kinds` for the allow-list
      rationale and the one deliberate gap in it.
    * **archived**: `unread_counts_for_user/1` does NOT filter archived spaces
      and the member query does, so the `Map.take/2` intersection below is
      load-bearing rather than tidiness: an archived space holding unread would
      otherwise pin the badge at a number that can never move.
  There is deliberately NO org-visibility predicate. It was removed in task
  `01a01f4c`: `unread_counts_for_user/1` has never been org-fenced, so a fenced
  count disagreed permanently with the per-channel pills for any viewer whose
  `Tenancy.visibility/1` narrows. `ShellLive` subscribes the same
  participation-only set, so every counted space is one the shell hears from.
  See `participant_spaces_query/1`.

  Deliberately composes rather than adding a counting query.
  `unread_counts_for_user/1` is the single definition of "unread" in this
  codebase and a second one is the defect this repo keeps producing. Anything
  that is not a user struct with a binary id returns 0.
  """
  @spec total_unread_for_viewer(map() | nil) :: non_neg_integer()
  def total_unread_for_viewer(%{id: user_id}) when is_binary(user_id) do
    counts = unread_counts_for_user(user_id)

    ids =
      user_id
      |> countable_participant_rows()
      |> Enum.map(& &1.space_id)

    counts
    |> Map.take(ids)
    |> Map.values()
    |> Enum.sum()
  end

  def total_unread_for_viewer(_user), do: 0

  @doc """
  Mark every Chat conversation the rail badge counts as read for `user`.

  Returns `{:ok, spaces_advanced}`, the number of read cursors this call
  actually moved. A viewer with nothing unread gets `{:ok, 0}` and no writes.

  Clears EXACTLY the set `total_unread_for_viewer/1` counts, because both read
  `countable_participant_rows/1`. If the two ever name different sets the
  reader presses dismiss and the badge survives, which is the defect this
  function exists to close, so do not give either one its own membership query.

  Each space is stamped with ITS OWN newest top-level, non-deleted message id.
  Never one shared "latest" id: message ids are UUIDv7, `count_unread/3`
  compares `m.id > last_read`, and an id borrowed from a busier space carries a
  later timestamp, which would suppress genuinely new messages in a quiet space
  until wall clock caught up.

  The cursor only ever moves FORWARD. `mark_space_read/2` is a blind
  `update_all` with no monotonic guard, and a cursor that moves backward
  resurrects unread on a conversation the reader just finished
  (`PlatformWeb.ChatLive.MessagesHooks` documents the single-space version of
  the same hazard), so the guard lives in the `where` clause here.

  A cosmetic mismatch, written down so it is not filed as a bug: the no-cursor
  clause of `count_unread/3` is capped at `min(10)`, so a conversation the
  viewer has never opened contributes at most 10 to the badge however many
  messages it holds. This function clears all of them, so it can clear more
  messages than the badge displayed. Harmless, and confusing if undocumented.
  """
  @spec mark_all_chat_spaces_read(map() | nil) :: {:ok, non_neg_integer()}
  def mark_all_chat_spaces_read(%{id: user_id}) when is_binary(user_id) do
    rows = countable_participant_rows(user_id)
    tips = newest_top_level_message_ids(Enum.map(rows, & &1.space_id))

    advanced =
      Enum.count(rows, fn row ->
        case Map.get(tips, row.space_id) do
          nil -> false
          tip_id -> advance_read_cursor(row, tip_id)
        end
      end)

    {:ok, advanced}
  end

  def mark_all_chat_spaces_read(_user), do: {:ok, 0}

  # THE COUNTABLE SET, defined once. Every participant row whose space the rail
  # badge counts: the viewer's own membership, not archived, of a kind the Chat
  # surface renders. All three predicates are applied in SQL by
  # `participant_spaces_query/1` plus the kind allow-list below.
  #
  # NO org fence, on purpose, and the subset relation to the shell's subscribe
  # set is enforced by that shared construction. See
  # `participant_spaces_query/1`.
  #
  # Returns the three columns a caller needs to either count the row
  # (`space_id`) or move its read cursor (`participant_id` — the
  # `chat_participants` PK `mark_space_read/2` takes, not the user id — and
  # `last_read_message_id`).
  defp countable_participant_rows(user_id) do
    user_id
    |> participant_spaces_query()
    |> where([space: s], s.kind in @chat_surface_kinds)
    |> select([participant: p], %{
      participant_id: p.id,
      space_id: p.space_id,
      last_read_message_id: p.last_read_message_id
    })
    |> Repo.all()
  end

  @excerpt_max_graphemes 140

  @doc """
  The newest top-level message of each space, as a one-line excerpt for the
  Chat conversation list.

  Returns `%{space_id => %{content: String.t(), author_name: String.t() | nil,
  inserted_at: DateTime.t()}}`. "Newest" is the newest non-deleted TOP-LEVEL
  message: thread replies are excluded, so a reply buried in a thread does not
  become a channel's headline. A space with no such message is absent from
  the map. `content` has its whitespace (newlines included) collapsed to
  single spaces and is truncated to #{@excerpt_max_graphemes} graphemes.
  `author_name` is the message's `author_display_name` snapshot, the same
  fallback `PresenceHooks.sender_name/2` uses, and may be `nil`.

  One query for all spaces, and the SAME query `mark_all_chat_spaces_read/1`
  takes its per-space tip from (ordered by the UUIDv7 id), so the excerpt and
  the unread watermark can never disagree about which message is newest.

  **This function does not decide which spaces a user may read.** The caller
  passes only the spaces already on that user's list. A caller that passes an
  arbitrary space id gets that space's newest message. `:scope` (an
  `ExternalScope` or `Access.Scope`) narrows the rows further.
  """
  @spec last_message_excerpts([binary()], keyword()) :: %{
          optional(binary()) => %{
            content: String.t(),
            author_name: String.t() | nil,
            inserted_at: DateTime.t()
          }
        }
  def last_message_excerpts(space_ids, opts \\ [])
  def last_message_excerpts([], _opts), do: %{}

  def last_message_excerpts(space_ids, opts) when is_list(space_ids) do
    space_ids
    |> newest_top_level_messages_query()
    |> ExternalScope.scope_by_space_id(Keyword.get(opts, :scope))
    |> select([m], {m.space_id, m.content, m.author_display_name, m.inserted_at})
    |> Repo.all()
    |> Map.new(fn {space_id, content, author_name, inserted_at} ->
      {space_id,
       %{content: message_excerpt(content), author_name: author_name, inserted_at: inserted_at}}
    end)
  end

  @doc """
  One message body as a list excerpt: whitespace (newlines included) collapsed
  to single spaces, truncated to #{@excerpt_max_graphemes} graphemes. `nil`
  gives `""`. The SAME shaping `last_message_excerpts/2` applies, exposed so
  a LiveView that patches one entry from an arriving message cannot shape it
  differently from the query that loaded the rest.
  """
  @spec message_excerpt(String.t() | nil) :: String.t()
  def message_excerpt(nil), do: ""

  def message_excerpt(content) when is_binary(content) do
    content
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, @excerpt_max_graphemes)
  end

  # `%{space_id => newest top-level, non-deleted message id}`, one row per
  # space via `DISTINCT ON`, so each space gets its own tip out of a single
  # query rather than N.
  #
  # Thread replies and soft-deleted rows are excluded on purpose: they are the
  # same rows `count_unread/3` refuses to count, so stamping the cursor past
  # one would move the watermark over a message that was never unread and
  # change what the next genuine post reports.
  defp newest_top_level_message_ids([]), do: %{}

  defp newest_top_level_message_ids(space_ids) do
    space_ids
    |> newest_top_level_messages_query()
    |> select([m], {m.space_id, m.id})
    |> Repo.all()
    |> Map.new()
  end

  # THE NEWEST-MESSAGE QUERY, defined once. One row per space (`DISTINCT ON
  # space_id`): its newest top-level, non-deleted message, newest by the
  # UUIDv7 id. Both the read-cursor tip (`newest_top_level_message_ids/1`) and
  # the list excerpt (`last_message_excerpts/2`) read it, so the unread
  # watermark and the excerpt cannot name different messages. Do not give
  # either one its own predicate or its own ordering.
  defp newest_top_level_messages_query(space_ids) do
    from(m in Message,
      where: m.space_id in ^space_ids and is_nil(m.thread_id) and is_nil(m.deleted_at),
      distinct: [asc: m.space_id],
      order_by: [asc: m.space_id, desc: m.id]
    )
  end

  # Forward-only cursor write. The clause below skips the space entirely when
  # the cursor already sits at or past the tip (the common case for a viewer
  # who reads as they go, and it keeps a no-op call to zero writes); the `where`
  # in the update is the real guard, and it also holds if a message lands
  # between the read above and this write.
  defp advance_read_cursor(%{last_read_message_id: current}, tip_id)
       when is_binary(current) and current >= tip_id,
       do: false

  defp advance_read_cursor(row, tip_id) do
    {updated, _} =
      from(p in Participant,
        where: p.id == ^row.participant_id,
        where: is_nil(p.last_read_message_id) or p.last_read_message_id < ^tip_id
      )
      |> Repo.update_all(set: [last_read_message_id: tip_id])

    updated > 0
  end

  # participant_pk is the internal chat_participants.id (PK), which is what
  # chat_messages.participant_id references via foreign key.
  defp count_unread(space_id, nil, participant_pk) do
    from(m in Message,
      where:
        m.space_id == ^space_id and is_nil(m.thread_id) and is_nil(m.deleted_at) and
          m.participant_id != ^participant_pk,
      select: count(m.id)
    )
    |> Repo.one()
    |> min(10)
  end

  defp count_unread(space_id, last_read_id, participant_pk) do
    from(m in Message,
      where:
        m.space_id == ^space_id and m.id > ^last_read_id and is_nil(m.thread_id) and
          is_nil(m.deleted_at) and m.participant_id != ^participant_pk,
      select: count(m.id)
    )
    |> Repo.one()
  end

  defp publish_message_posted(msg, opts \\ []) do
    :telemetry.execute(
      [:platform, :chat, :message_posted],
      %{system_time: System.system_time()},
      %{
        space_id: msg.space_id,
        message_id: msg.id,
        participant_id: msg.participant_id
      }
    )

    case Keyword.get(opts, :from_pid) do
      pid when is_pid(pid) -> ChatPubSub.broadcast_from(msg.space_id, pid, {:new_message, msg})
      _ -> ChatPubSub.broadcast(msg.space_id, {:new_message, msg})
    end
  end

  @doc """
  Returns `true` if the given `space_id` exists, is not archived, and is not an
  execution space. Used as the access gate for cross-space surfaces (the canvas
  `:org_reader` grant). Single-tenant — extend with workspace scoping when
  multi-tenancy ships.
  """
  @spec space_accessible?(binary()) :: boolean()
  def space_accessible?(space_id) when is_binary(space_id) do
    query =
      from(s in Space,
        where: s.id == ^space_id and is_nil(s.archived_at) and s.kind != "execution",
        limit: 1,
        select: 1
      )

    Repo.one(query) != nil
  end

  @doc """
  Returns `true` if the space accepts new writes (messages, edits, reactions,
  pins, canvases, attachments, participants).

  Archived spaces are frozen for ALL interaction — human and agent alike
  (task 019e95ea: an archived channel is a read-only snapshot). Execution
  spaces are exempt: orchestration archives them at task completion and
  system surfaces may still append to their log afterwards; their lifecycle
  is owned by `Platform.Orchestration.ExecutionSpace`, not user actions.

  Unknown space ids return `true` so the write path surfaces its natural
  not-found / FK error instead of a misleading archived error.
  """
  @spec space_writable?(binary()) :: boolean()
  def space_writable?(space_id) when is_binary(space_id) do
    from(s in Space, where: s.id == ^space_id, select: {s.archived_at, s.kind})
    |> Repo.one()
    |> case do
      nil -> true
      {nil, _kind} -> true
      {_archived_at, "execution"} -> true
      _archived -> false
    end
  end

  # Guard used by every public write path. Non-binary / missing space ids
  # fall through as :ok so changeset validation reports the real problem.
  defp ensure_space_writable(space_id) when is_binary(space_id) do
    if space_writable?(space_id), do: :ok, else: {:error, :space_archived}
  end

  defp ensure_space_writable(_), do: :ok

  # Defense-in-depth guard at the message-SEND seam. Catches the residual
  # cases the create-seam guard misses: a DM created before the sender was
  # marked external, a DM whose allowlist was revoked after creation, a
  # group the external user was added to, or a caller posting to a
  # `space_id` directly. Mirrors `external_dm_permitted?/3` so create-time
  # and send-time enforcement never diverge.
  defp ensure_dm_send_allowed(space_id, author_participant_pk)
       when is_binary(space_id) and is_binary(author_participant_pk) do
    # get_space/1 rather than Repo.get/2: this guard runs BEFORE the insert
    # whose changeset would otherwise report a malformed space_id, and the
    # `else` arm below cannot catch an Ecto.Query.CastError.
    with %Space{kind: kind} when kind in ["dm", "group"] <- get_space(space_id),
         %Participant{participant_type: "user", participant_id: author_user_id} <-
           get_participant(author_participant_pk),
         true <- Tenancy.external_user?(%{id: author_user_id}) do
      other_user_ids =
        from(p in Participant,
          where:
            p.space_id == ^space_id and p.participant_type == "user" and
              p.participant_id != ^author_user_id,
          select: p.participant_id
        )
        |> Repo.all()

      if Enum.all?(other_user_ids, &external_dm_permitted?(author_user_id, "user", &1)) do
        :ok
      else
        {:error, :dm_not_allowed}
      end
    else
      # Not a DM/group, agent author, internal author, or missing rows —
      # not gated here (channels governed by membership + M6/M7; internal
      # traffic short-circuits before any per-participant work).
      _ -> :ok
    end
  end

  defp ensure_dm_send_allowed(_space_id, _author_participant_pk), do: :ok

  # M9 (rbac-external-users): bind attachment writes to the external scope so a
  # file only ever lands in a space the uploader is a `chat_participants` member
  # of (an allowlisted Globex location). Threaded into `post_message_with_attachments/3`
  # as a second guard alongside `ensure_space_writable/1`, mirroring how M8 added
  # `ensure_dm_send_allowed/2` on the send seam.
  #
  # `poster_user_id` is nil for `post_message/2` and every pre-existing caller,
  # and non-external for internal + agent + system callers — all pass through
  # unchanged because `ExternalScope.for_user/1` yields a non-external scope and
  # `visible_space_id?/2` is then unconditionally true. Only an EXTERNAL poster
  # is narrowed, and to the SAME participant set M7 uses for reads, so
  # upload-scope and read-scope cannot drift.
  defp ensure_external_upload_allowed(space_id, poster_user_id) do
    scope = ExternalScope.for_user(poster_user_id)

    if ExternalScope.visible_space_id?(space_id, scope) do
      :ok
    else
      {:error, :out_of_external_scope}
    end
  end

  # Variant for write paths addressed by message rather than space.
  defp ensure_message_space_writable(%Message{space_id: space_id}),
    do: ensure_space_writable(space_id)

  defp ensure_message_space_writable(message_id) when is_binary(message_id) do
    case Repo.one(from(m in Message, where: m.id == ^message_id, select: m.space_id)) do
      nil -> :ok
      space_id -> ensure_space_writable(space_id)
    end
  end

  defp ensure_message_space_writable(_), do: :ok

  @doc """
  Returns `true` if the given `user_id` is a participant in the given (non-archived)
  `space_id`. Stricter than `space_accessible?/1`; retained for callers that need
  participant-level scoping rather than the broader "accessible" check.
  """
  @spec user_in_space?(binary(), binary()) :: boolean()
  def user_in_space?(user_id, space_id) when is_binary(user_id) and is_binary(space_id) do
    query =
      from(p in Participant,
        join: s in Space,
        on: s.id == p.space_id,
        where:
          p.participant_id == ^user_id and
            p.participant_type == "user" and
            p.space_id == ^space_id,
        where: is_nil(s.archived_at),
        limit: 1,
        select: 1
      )

    Repo.one(query) != nil
  end

  @doc """
  Restore a soft-deleted canvas by clearing `deleted_at`. Counterpart to
  `delete_canvas/1`. Emits `:canvas_restored` telemetry and broadcasts
  `{:canvas_restored, canvas}` to the space topic so chat clients can re-add
  the row to their canvas list. Used by the Activity panel's Restore action.
  """
  @spec restore_canvas(Canvas.t()) :: {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def restore_canvas(%Canvas{} = canvas) do
    result =
      canvas
      |> Canvas.delete_changeset(%{deleted_at: nil})
      |> Repo.update()

    case result do
      {:ok, c} ->
        :telemetry.execute(
          [:platform, :chat, :canvas_restored],
          %{system_time: System.system_time()},
          %{canvas_id: c.id, space_id: c.space_id}
        )

        ChatPubSub.broadcast(c.space_id, {:canvas_restored, c})

      _ ->
        :ok
    end

    result
  end

  @doc """
  Soft-delete a canvas. Sets `deleted_at` to the current timestamp,
  emits telemetry, and broadcasts `{:canvas_deleted, canvas}` to the space.
  """
  @spec delete_canvas(Canvas.t()) :: {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def delete_canvas(%Canvas{} = canvas) do
    # Use the dedicated soft-delete changeset so `validate_document/1` doesn't
    # rewrite the stored document during a delete-only update.
    result =
      canvas
      |> Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update()

    case result do
      {:ok, c} ->
        :telemetry.execute(
          [:platform, :chat, :canvas_deleted],
          %{system_time: System.system_time()},
          %{canvas_id: c.id, space_id: c.space_id}
        )

        ChatPubSub.broadcast(c.space_id, {:canvas_deleted, c})

      _ ->
        :ok
    end

    result
  end
end
