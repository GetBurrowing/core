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
      Platform.Chat.pin_message(%{space_id: space.id, message_id: msg.id, pinned_by: p.id})
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
    Participant,
    Pin,
    Reaction,
    Space,
    Thread
  }

  alias Platform.Chat.CanvasAccess
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Canvas.Versions, as: CanvasVersions
  alias Platform.Chat.MessageVersions
  alias Platform.Chat.PubSub, as: ChatPubSub
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

    * `:scope` — an optional `%Platform.Chat.ExternalScope{}`. When it is an
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

    * `:scope` — optional `%Platform.Chat.ExternalScope{}`. For an external
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
  branch returns the OLDEST row of any org, so an SXI channel would answer a
  Fabrikam member's lookup and ADR-0042's per-org slug scoping would be weakened.
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
    * `:scope`        — optional `%Platform.Chat.ExternalScope{}`. For an
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
  List the space_ids a human user is a `chat_participants` member of — the
  allowlisted set for external-user presence/typing scope (rbac-external-users
  M10).

  Mirrors `list_spaces_for_agent/2` but keyed on a `participant_type: "user"`
  participant and selecting `p.space_id` rather than the `Space` structs.
  Archived spaces are excluded (`s.archived_at IS NULL`); `chat_participants`
  has no `archived_at` column of its own (see the `Participant` schema), so
  membership is scoped purely on the space's archive state, exactly as
  `list_spaces_for_agent/2` does for agents. An optional `:kind` opt filters
  `s.kind`.
  """
  @spec list_member_space_ids(binary(), keyword()) :: [binary()]
  def list_member_space_ids(user_id, opts \\ []) when is_binary(user_id) do
    kind = Keyword.get(opts, :kind)

    base =
      from(p in Participant,
        join: s in Space,
        on: s.id == p.space_id,
        where:
          p.participant_type == "user" and
            p.participant_id == ^user_id and
            is_nil(s.archived_at),
        select: p.space_id
      )

    base = if kind, do: where(base, [_p, s], s.kind == ^kind), else: base
    Repo.all(base)
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

  Returns EVERY space kind, and it has to stay that way. `Platform.Chat.Presence`
  and `ShellLive`'s PubSub subscribe set both read this list, so narrowing it
  here would silently shrink presence and drop broadcast subscriptions. A
  caller that wants fewer kinds adds its own predicate to
  `viewer_space_ids_query/2` instead, the way `total_unread_for_viewer/1` does.

  Takes the loaded user struct (not an id) so `Tenancy.visibility/1` can take
  its zero-query preloaded-`:org_memberships` clause. Anything that is not a
  user struct with a binary id returns `[]`.
  """
  @spec list_viewer_presence_space_ids(map() | nil) :: [binary()]
  def list_viewer_presence_space_ids(%{id: user_id} = user) when is_binary(user_id) do
    user_id
    |> viewer_space_ids_query(Tenancy.visibility(user))
    |> Repo.all()
  end

  def list_viewer_presence_space_ids(_user), do: []

  # THE SEAM. The two gates documented above, as a QUERY rather than a result
  # set, so a caller can add its own predicate AND its own select before
  # running it. This is the single definition of "spaces this viewer both
  # participates in and is allowed to see"; `list_viewer_presence_space_ids/1`
  # and `countable_participant_rows/2` (the rail badge's count and the bulk
  # mark-all-read that clears it) all build on it, and anything else needing
  # that set should extend this rather than hand-roll a second copy that
  # drifts.
  #
  # Both bindings are NAMED (`as: :participant`, `as: :space`). Callers filter
  # and select through the names, so inserting another join here cannot
  # silently move what a positional `[_p, s]` pattern points at.
  defp viewer_spaces_query(user_id, vis) when is_binary(user_id) do
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
    |> Tenancy.scope(vis, binding: :space)
  end

  defp viewer_space_ids_query(user_id, vis) when is_binary(user_id) do
    user_id
    |> viewer_spaces_query(vis)
    |> select([participant: p], p.space_id)
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
  User-initiated archive. Allowed for Fabrikam admins and the space's creator
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
  `archive_space/2`: Fabrikam admin or space creator.
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
    if Platform.Tenancy.fabrikam_admin?(actor) or space_creator?(actor, space) do
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

  Fabrikam-admin only — deletion is destructive, so unlike `archive_space/2`
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
      not Platform.Tenancy.fabrikam_admin?(actor) ->
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
  Cancel a scheduled deletion (Fabrikam-admin only, task 019e95ea stage 3).

  Clears `deletion_scheduled_at` but leaves `archived_at` — the channel
  returns to the plain archived state; `unarchive_space/2` is the separate
  existing path back to active. Returns `{:error, :not_scheduled}` when no
  deletion is pending.
  """
  @spec cancel_space_deletion(map(), Space.t()) ::
          {:ok, Space.t()} | {:error, :unauthorized | :not_scheduled | Ecto.Changeset.t()}
  def cancel_space_deletion(actor, %Space{} = space) do
    cond do
      not Platform.Tenancy.fabrikam_admin?(actor) ->
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
      covers external→allowlisted-org member AND SXI↔SXI (a second
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
  Build a map of `participant.id → accent_color_string` for agent participants in a space.

  Used to supply per-agent color identity to chat rendering. Agents without a color
  fall back to the default blue accent via `ColorPalette.accent_for/1`.
  """
  @spec agent_color_map_for_participants([Participant.t()]) :: %{binary() => binary()}
  def agent_color_map_for_participants(participants) do
    alias Platform.Agents.ColorPalette

    # Build map: agent_id → participant.id (for agent participants only)
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
          {participant_id, ColorPalette.accent_for(color)}
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
  changes. This mirrors `agent_color_map_for_participants/1`, which resolves
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
          joined_at: Keyword.get(opts, :joined_at, DateTime.utc_now())
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
      Repo.get_by(Agent, slug: id)
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
        reinvite_and_pin_mentioned(msg)
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

        reinvite_and_pin_mentioned(message)
        emit_inbox_for_mentions(message)
        publish_message_posted(message, opts)
        {:ok, message, attachments}

      {:error, _operation, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch a message by primary key. Returns `nil` if not found.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}`) gates the message
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

  @doc """
  List non-deleted messages in a space, newest first.

  ## Options

    * `:limit`     — max number of messages (default: 50)
    * `:before_id` — keyset cursor — only messages with `id < before_id`
    * `:after_id`  — keyset cursor — only messages with `id > after_id`
    * `:thread_id` — filter to a specific thread
    * `:top_level_only` — when `true`, include only messages where `thread_id` is `NULL`
    * `:order` — `:desc` (default, newest first) | `:asc` (oldest first)

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
    before_id = Keyword.get(opts, :before_id)
    after_id = Keyword.get(opts, :after_id)
    thread_id = Keyword.get(opts, :thread_id)
    top_level_only = Keyword.get(opts, :top_level_only, false)
    scope = Keyword.get(opts, :scope)
    order = if Keyword.get(opts, :order) == :asc, do: :asc, else: :desc

    base =
      from(m in Message,
        where: m.space_id == ^space_id and is_nil(m.deleted_at),
        order_by: [{^order, m.inserted_at}],
        limit: ^limit
      )

    base =
      cond do
        thread_id -> where(base, [m], m.thread_id == ^thread_id)
        top_level_only -> where(base, [m], is_nil(m.thread_id))
        true -> base
      end

    base = if before_id, do: where(base, [m], m.id < ^before_id), else: base
    base = if after_id, do: where(base, [m], m.id > ^after_id), else: base

    base
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
  end

  @doc """
  Peek whether more non-deleted messages exist before the given cursor.
  Used by the infinite-scroll UI to decide whether to keep rendering the
  load-more sentinel. Single-row `LIMIT 1` query — cheap.

  ## Options

    * `:before_id`       — keyset cursor — only counts messages with `id < before_id`
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

    base = if before_id, do: where(base, [m], m.id < ^before_id), else: base

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

    * `:after_id`        — keyset cursor — only counts messages with `id > after_id`
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

    base = if after_id, do: where(base, [m], m.id > ^after_id), else: base

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
  #     Fabrikam-internal digest.
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

  A MIXED space (both a Fabrikam human and an external user as participants)
  classifies as external here: its content is already visible to an
  external party, so it belongs to the external surface and is excluded
  from the pure Fabrikam-internal Historian digest.

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
  Fabrikam-internal content.
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
    limit = Keyword.get(opts, :limit, 20)
    scope = Keyword.get(opts, :scope)
    trimmed_query = String.trim(query)

    if trimmed_query == "" do
      []
    else
      # Apply the external scope to the row filter FIRST — an out-of-scope
      # `space_id` (the M6-bypassed case) yields zero rows BEFORE `ts_headline`
      # ever runs, so no highlighted fragment of an off-limits message is
      # produced (design canvas §9).
      base =
        from(m in Message,
          where:
            m.space_id == ^space_id and
              is_nil(m.deleted_at) and
              fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^trimmed_query)
        )
        |> ExternalScope.scope_by_space_id(scope)

      from(m in base,
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
  end

  @doc "Edit a message's content. Sets `edited_at` to now."
  @spec edit_message(Message.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
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

  Required attrs: `:space_id`, `:message_id` (integer), `:pinned_by`.
  """
  @spec pin_message(map()) ::
          {:ok, Pin.t()} | {:error, :space_archived | Ecto.Changeset.t()}
  def pin_message(attrs) do
    with :ok <- ensure_space_writable(attrs[:space_id] || attrs["space_id"]) do
      do_pin_message(attrs)
    end
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

  @doc "Unpin a message from a space. Returns `{:error, :not_found}` if not pinned."
  @spec unpin_message(binary(), integer()) ::
          {:ok, Pin.t()} | {:error, :not_found | any()}
  def unpin_message(space_id, message_id) do
    with :ok <- ensure_space_writable(space_id) do
      do_unpin_message(space_id, message_id)
    end
  end

  defp do_unpin_message(space_id, message_id) when is_binary(message_id) do
    # `message_id` is a `phx-value-` param (live/chat/pin_hooks.ex:76) and both
    # pin columns are :binary_id. Malformed and absent are the same outcome.
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
      |> Multi.insert(:canvas, Canvas.changeset(%Canvas{}, attrs))
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

      {:error, :canvas, %Ecto.Changeset{} = changeset, _} ->
        {:error, changeset}

      {:error, _step, reason, _} ->
        {:error, reason}
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
      |> Multi.run(:canvas, fn repo, _changes ->
        attrs
        |> Map.put("space_id", space_id)
        |> Map.put("created_by", participant_id)
        |> Map.put("created_by_display_name", snapshot[:author_display_name])
        |> Map.put("created_by_participant_type", snapshot[:author_participant_type])
        |> then(&Canvas.changeset(%Canvas{}, &1))
        |> repo.insert()
      end)
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

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}`) gates the canvas
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

  defp do_update_canvas(%Canvas{} = canvas, attrs) do
    attrs = stringify_canvas_payload(attrs)

    result =
      canvas
      |> Canvas.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} -> publish_canvas_updated(updated)
      _ -> :ok
    end

    result
  end

  @doc """
  List canvases in a space (excluding soft-deleted), oldest first.

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}`) yields `[]` when
  the `space_id` is out of the external caller's participant set (canvas embeds
  from an off-limits space can't be resolved from an external session). Absent
  / nil / internal scopes are pass-through.
  """
  @spec list_canvases(binary(), keyword()) :: [Canvas.t()]
  def list_canvases(space_id, opts \\ []) do
    scope = Keyword.get(opts, :scope)

    from(c in Canvas,
      where: c.space_id == ^space_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at]
    )
    |> ExternalScope.scope_by_space_id(scope)
    |> Repo.all()
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

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}`) gates the
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
        if external_principal?(principal), do: nil, else: attachment

      %Attachment{space_id: space_id} = attachment ->
        if principal_is_member?(space_id, principal), do: attachment, else: nil
    end
  end

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

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}`) drops attachments
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

  The optional `:scope` (a `%Platform.Chat.ExternalScope{}`) drops attachments
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
            from(a in Platform.Agents.Agent, where: a.status != "archived")
            |> maybe_scope_to_workspace(space.workspace_id)
            |> Repo.all()
            |> Enum.each(fn agent ->
              slug = String.downcase(agent.slug || "")
              name = String.downcase(agent.name || "")

              if slug in tokens or name in tokens do
                reinstate_on_mention(space_id, agent)
              end
            end)

            # Stage 3 pin-propagation pass. Only executes when the space is
            # a task's execution space AND the message author is that task's
            # sponsor. Any lookup miss short-circuits the pass — this is a
            # side-effect layered on top of the reinvite; it must never
            # crash the message-post transaction.
            maybe_propagate_task_pins(space, msg, tokens)
            :ok
        end
    end
  end

  defp reinvite_and_pin_mentioned(_), do: :ok

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
  # `msg.author_user_id`, and the recipient set is deduped by user. Each
  # surviving user is gated through the single `inbox_emit_allowed?/2` seam so
  # the RBAC M6/M7 external-scope predicate drops in without touching the loop.
  defp emit_inbox_for_mentions(%Message{space_id: space_id, content: content} = msg)
       when is_binary(content) do
    space = Repo.get(Space, space_id)

    if space do
      space_id
      |> list_participants()
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.filter(&Platform.Chat.AttentionRouter.mentioned?(&1, msg))
      |> Enum.reject(&(&1.participant_id == msg.author_user_id))
      |> Enum.uniq_by(& &1.participant_id)
      |> Enum.each(fn p ->
        if inbox_emit_allowed?(p.participant_id, space) do
          Platform.Inbox.emit(%{
            user_id: p.participant_id,
            kind: "chat_mention",
            source_type: "chat_message",
            source_id: msg.id,
            title: mention_inbox_title(msg, space),
            body: String.slice(content, 0, 200),
            url: "/chat/#{space_path_segment(space)}?message=#{msg.id}"
          })
        end
      end)
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

  # External-scope gate seam (task 019f904c-904d — M2). The RBAC M6/M7
  # predicate (`Platform.Chat.ExternalScope`) is NOT in the repo yet; until it
  # lands the effective gate is space participation — a user only appears in
  # `list_participants/1` for spaces they belong to, which already enforces
  # "external users only get inbox rows for allowlisted spaces". Kept as ONE
  # predicate so the M6/M7 call drops in here without touching the emit loop.
  defp inbox_emit_allowed?(_user_id, _space), do: true

  # Inbox title for a chat mention. For DM spaces the space has no meaningful
  # `name`, so the label is the DM PEER's display name — in a 2-party DM the
  # peer relative to any recipient is the author (recipients exclude the
  # author), so `author_display_name` is exactly the peer name.
  defp mention_inbox_title(%Message{} = msg, %Space{} = space),
    do: "@Mention from #{msg.author_display_name} in ##{space_label(space, msg)}"

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
    cond do
      user = Repo.get_by(Platform.Accounts.User, email: token) ->
        %{kind: "user", id: user.email}

      agent = Repo.get_by(Platform.Agents.Agent, slug: token) ->
        %{kind: "agent", id: agent.slug}

      true ->
        nil
    end
  end

  defp resolve_pin_target(_), do: nil

  # Mention-reinvite. Post-ADR-0038 there's no soft-dismissed state —
  # either the row exists (already in the space) or it doesn't (dismissed
  # and hard-deleted). So "reinvite" is just an add-if-missing.
  defp reinstate_on_mention(space_id, %Platform.Agents.Agent{} = agent) do
    case add_agent_participant(space_id, agent, attention_mode: "mention") do
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

  @doc "Remove an agent from a space entirely (hard delete, ADR 0038)."
  @spec remove_space_agent(binary(), binary()) :: :ok | {:error, :not_found}
  def remove_space_agent(space_id, agent_id) do
    case get_agent_participant(space_id, agent_id) do
      nil ->
        {:error, :not_found}

      %Participant{} = participant ->
        {:ok, _} = Repo.delete(participant)
        broadcast_roster_changed(space_id, agent_id, :removed)
        :ok
    end
  end

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

    # Additive global fan-out. The shell's agents meter is viewer-scoped
    # across every visible space, so it cannot subscribe to N per-space
    # topics without unbounded fan-out; it subscribes to this one topic
    # instead and recomputes its union on receipt. The per-space topic
    # above and all of its subscribers are untouched.
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      global_roster_topic(),
      {:roster_changed_any, space_id}
    )
  end

  @doc """
  Single global topic carrying `{:roster_changed_any, space_id}` for every
  roster mutation in the install. Subscribers must re-scope for themselves —
  the message is a "something changed" ping, not an authorization.
  """
  @spec global_roster_topic() :: String.t()
  def global_roster_topic, do: "space_agents:*"

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

  Takes the LOADED user struct, not an id, because it composes two functions
  with different arities. `unread_counts_for_user/1` keys off the user id;
  the member query needs the struct so `Tenancy.visibility/1` can take its
  zero-query preloaded-`:org_memberships` clause.

  Counting exactly the set Chat RENDERS is what makes the badge honest, and
  three predicates do that work:

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
    * **org visibility**: the shell receives no broadcasts for a space outside
      the viewer's fence, so a count that included one could never move either.

  Deliberately composes rather than adding a counting query.
  `unread_counts_for_user/1` is the single definition of "unread" in this
  codebase and a second one is the defect this repo keeps producing. Anything
  that is not a user struct with a binary id returns 0.
  """
  @spec total_unread_for_viewer(map() | nil) :: non_neg_integer()
  def total_unread_for_viewer(%{id: user_id} = user) when is_binary(user_id) do
    counts = unread_counts_for_user(user_id)

    ids =
      user_id
      |> countable_participant_rows(Tenancy.visibility(user))
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
  `countable_participant_rows/2`. If the two ever name different sets the
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
  def mark_all_chat_spaces_read(%{id: user_id} = user) when is_binary(user_id) do
    rows = countable_participant_rows(user_id, Tenancy.visibility(user))
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
  # badge counts: the viewer's own membership, not archived, inside the tenancy
  # fence, of a kind the Chat surface renders. All four predicates are applied
  # in SQL by the seam plus the kind allow-list.
  #
  # Returns the three columns a caller needs to either count the row
  # (`space_id`) or move its read cursor (`participant_id` — the
  # `chat_participants` PK `mark_space_read/2` takes, not the user id — and
  # `last_read_message_id`).
  defp countable_participant_rows(user_id, vis) do
    user_id
    |> viewer_spaces_query(vis)
    |> where([space: s], s.kind in @chat_surface_kinds)
    |> select([participant: p], %{
      participant_id: p.id,
      space_id: p.space_id,
      last_read_message_id: p.last_read_message_id
    })
    |> Repo.all()
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
    from(m in Message,
      where: m.space_id in ^space_ids and is_nil(m.thread_id) and is_nil(m.deleted_at),
      distinct: [asc: m.space_id],
      order_by: [asc: m.space_id, desc: m.id],
      select: {m.space_id, m.id}
    )
    |> Repo.all()
    |> Map.new()
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

  # ── AI Activity (Activity panel — list + undo agent-driven actions) ────────

  @doc """
  Count of agent-driven actions visible to `list_recent_agent_actions/1` under
  the same filter options. Used by the Activity panel for numbered-page
  pagination (total page count = ceil(count / page_size)).

  Accepts the same `:since` and `:include_deleted` options as the list
  function. `:limit` is ignored (this is a count, not a slice).
  """
  @spec count_recent_agent_actions(keyword()) :: non_neg_integer()
  def count_recent_agent_actions(opts \\ []) do
    since = Keyword.get(opts, :since)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    space_ids = list_accessible_space_ids()

    if space_ids == [] do
      0
    else
      msg_count = count_recent_agent_messages(space_ids, since, include_deleted)
      canvas_count = count_recent_agent_canvases(space_ids, since, include_deleted)
      msg_count + canvas_count
    end
  end

  defp count_recent_agent_messages(space_ids, since, include_deleted) do
    base =
      Message
      |> where([m], m.space_id in ^space_ids)
      |> where([m], m.author_participant_type == "agent")

    base = if include_deleted, do: base, else: where(base, [m], is_nil(m.deleted_at))
    base = if since, do: where(base, [m], m.inserted_at >= ^since), else: base

    Repo.aggregate(base, :count, :id)
  end

  defp count_recent_agent_canvases(space_ids, since, include_deleted) do
    base =
      Canvas
      |> where([c], c.space_id in ^space_ids)
      |> where([c], c.created_by_participant_type == "agent")

    base = if include_deleted, do: base, else: where(base, [c], is_nil(c.deleted_at))
    base = if since, do: where(base, [c], c.inserted_at >= ^since), else: base

    Repo.aggregate(base, :count, :id)
  end

  @doc """
  List recent AI-agent-driven actions (messages, canvases) in spaces the given
  user participates in. Used by the Activity LiveView. Returns currently-active
  items (not soft-deleted), sorted chronologically newest first.

  Each result is a map: `%{kind: :message | :canvas, item: t, agent_name: name,
  agent_avatar_url: url | nil, space_id: id, inserted_at: dt}`.

  `agent_avatar_url` is resolved from the `agents` table at read time, not from
  the author snapshot: the snapshot columns freeze the acting agent's NAME so a
  historical row keeps saying who acted, but an avatar is a mutable fact about
  the agent and the feed should show the face the agent has now.

  Options:
    * `:since` (`DateTime`) — only items with `inserted_at >= since`. If omitted,
      all-time history is returned.
    * `:limit` (`integer`) — cap on combined results. Default `200`.
  """
  @spec list_recent_agent_actions(keyword()) :: [map()]
  def list_recent_agent_actions(opts \\ []) do
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 200)
    include_deleted = Keyword.get(opts, :include_deleted, false)

    # Scope to every non-archived, non-execution space. Single-tenant
    # assumption — when workspace partitioning ships, this should re-scope
    # to spaces in the user's workspace(s).
    space_ids = list_accessible_space_ids()

    if space_ids == [] do
      []
    else
      messages = list_recent_agent_messages(space_ids, since, limit, include_deleted)
      canvases = list_recent_agent_canvases(space_ids, since, limit, include_deleted)

      (messages ++ canvases)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.take(limit)
    end
  end

  defp list_accessible_space_ids do
    from(s in Space,
      where: is_nil(s.archived_at) and s.kind != "execution",
      select: s.id
    )
    |> Repo.all()
  end

  @doc """
  Returns `true` if the given `space_id` exists, is not archived, and is not an
  execution space. Used as the access gate for cross-space surfaces like the
  Activity panel's undo. Single-tenant — extend with workspace scoping when
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
  # of (an allowlisted SXI location). Threaded into `post_message_with_attachments/3`
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

  defp list_recent_agent_messages(space_ids, since, limit, include_deleted) do
    base =
      Message
      |> where([m], m.space_id in ^space_ids)
      |> where([m], m.author_participant_type == "agent")
      |> order_by([m], desc: m.inserted_at)
      |> limit(^limit)

    base =
      if include_deleted, do: base, else: where(base, [m], is_nil(m.deleted_at))

    base = if since, do: where(base, [m], m.inserted_at >= ^since), else: base

    rows = Repo.all(base)

    avatars =
      rows
      |> Enum.map(& &1.author_agent_id)
      |> agent_avatar_map_for_agent_ids()

    Enum.map(rows, fn m ->
      %{
        kind: :message,
        item: m,
        agent_name: m.author_display_name || "Agent",
        agent_avatar_url: Map.get(avatars, m.author_agent_id),
        space_id: m.space_id,
        inserted_at: m.inserted_at,
        state: if(is_nil(m.deleted_at), do: :active, else: :undone)
      }
    end)
  end

  defp list_recent_agent_canvases(space_ids, since, limit, include_deleted) do
    base =
      Canvas
      |> where([c], c.space_id in ^space_ids)
      |> where([c], c.created_by_participant_type == "agent")
      |> order_by([c], desc: c.inserted_at)
      |> limit(^limit)

    base =
      if include_deleted, do: base, else: where(base, [c], is_nil(c.deleted_at))

    base = if since, do: where(base, [c], c.inserted_at >= ^since), else: base

    # A canvas snapshots its creator's NAME but carries no agent id (see the
    # Canvas schema) — only `created_by`, the participant row id. Messages have
    # `author_agent_id` directly. So the agent behind a canvas is reached one
    # hop further out, through the participant row, and a hard-deleted
    # participant (ADR 0038) simply yields no avatar rather than breaking the row.
    rows =
      base
      |> join(:left, [c], p in Participant, on: p.id == c.created_by)
      |> select([c, p], {c, p.participant_id})
      |> Repo.all()

    avatars =
      rows
      |> Enum.map(fn {_c, agent_id} -> agent_id end)
      |> agent_avatar_map_for_agent_ids()

    Enum.map(rows, fn {c, agent_id} ->
      %{
        kind: :canvas,
        item: c,
        agent_name: c.created_by_display_name || "Agent",
        agent_avatar_url: Map.get(avatars, agent_id),
        space_id: c.space_id,
        inserted_at: c.inserted_at,
        state: if(is_nil(c.deleted_at), do: :active, else: :undone)
      }
    end)
  end

  # `agent.id → avatar_url` for a list of (possibly nil, possibly repeated)
  # agent ids. Mirrors `agent_avatar_map_for_participants/1`: agents with no
  # avatar — or a blank one — are ABSENT from the map rather than present with
  # an empty value, so a plain `Map.get/2` yields nil and the render layer is
  # never handed "". The `?v=` cache token on the stored URL is passed through
  # verbatim.
  defp agent_avatar_map_for_agent_ids(agent_ids) do
    agent_ids =
      agent_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if agent_ids == [] do
      %{}
    else
      from(a in Agent,
        where: a.id in ^agent_ids and not is_nil(a.avatar_url),
        select: {a.id, a.avatar_url}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {agent_id, avatar_url}, acc ->
        case String.trim(avatar_url) do
          "" -> acc
          url -> Map.put(acc, agent_id, url)
        end
      end)
    end
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
