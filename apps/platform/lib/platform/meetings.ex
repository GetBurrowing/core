defmodule Platform.Meetings do
  @moduledoc """
  Context for the Meetings domain.

  Manages meeting rooms, participant presence, recordings, and transcription
  backed by LiveKit. Broadcasts presence and recording changes via
  `Platform.Meetings.PubSub`.

  All room/participant/recording functions guard on `enabled?/0` — when
  LiveKit env vars are not set, those functions return
  `{:error, :meetings_disabled}`.

  Transcription functions (transcripts, segments, summaries) do NOT
  require LiveKit to be enabled — they work standalone.
  """

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.Voice
  alias Platform.Federation
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.SpaceAccess
  alias Platform.Meetings.{Meeting, Participant, Recording, Room, Transcript, Whiteboard}
  alias Platform.Meetings.CalendarLink
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.IntentRuntimeAdapter
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteDelivery
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.PendingExternalGrant

  require Logger

  # ── Meeting records (ADR 0042) ────────────────────────────────────────────
  #
  # SLUG READS: there is deliberately NO unscoped slug lookup on this
  # module. `meetings` carries `unique_index(:meetings, [:project_id,
  # :slug])` — a slug is unique per project, NOT globally — so any
  # `Repo.get_by(Meeting, slug: slug)` is both an authorization hole
  # (it crosses org boundaries) and a latent 500 (`get_by/3` raises
  # `Ecto.MultipleResultsError` on more than one match). The public
  # arity-1 `get_meeting_by_slug/1` that used to live here was removed
  # in task 019f9b14 stage 3 for exactly that reason; `meeting_authz_test`
  # and `meetings_test` both assert it cannot come back.
  #
  # Reach for one of these instead:
  #
  #   * `fetch_meeting_for_user/2` — user-facing reads. Scopes the query
  #     to the viewer's orgs in SQL and returns `{:error, :ambiguous}`
  #     rather than guessing when a slug matches in two of them.
  #   * `get_meeting_by_slug/2` — internal reads with an explicit
  #     `project_id` in hand (e.g. `dedupe_slug/4`). Not an
  #     authorization surface; the caller has already chosen the project.
  #   * `resolve_guest_invite/2` — the guest ingress. Authority is the
  #     signed token, whose payload now carries `meeting_id`; the
  #     slug-only fallback for legacy tokens refuses ambiguous matches
  #     instead of picking one.

  @doc """
  Fetch a meeting by URL slug **as a specific viewer**, scoped to the orgs
  that viewer belongs to. Preloads `:chat_space` on success.

  Returns `{:ok, meeting}`, `{:error, :not_found}`, or `{:error, :ambiguous}`.

  ## Why the context and not an `on_mount` hook

  The check lives here, in `Platform.Meetings`, rather than in a
  `PlatformWeb.LiveAuth` hook. Three reasons:

    1. The predicate needs the meeting row itself — it is the meeting's
       `project_id -> projects.org_id` that gets compared against membership.
       An `on_mount` gate would have to load the meeting to decide and then
       `handle_params/3` would load it again: two queries, two chances to
       drift apart.
    2. An `on_mount` protects exactly one route. This context is what every
       future caller (MCP tool, controller, agent path, LiveComponent)
       reaches for, so the gate is inherited rather than re-derived.
    3. The hook is silently bypassable. `/meetings` and `/meetings/:slug` are
       the same LiveView in the same `live_session :authenticated`. Today the
       index links out with `navigate=`, so a mount hook would re-run — but
       switching that one word to `patch=` stops `on_mount` firing and leaves
       only `handle_params/3`. A gate a one-word template edit disables is
       not a gate.

  ## Semantics

    * A `nil` user — or anything without a binary `:id` — is
      `{:error, :not_found}`. An anonymous mount is never authorized.
    * The org filter is applied **in the query**, not after the fetch, so the
      database is the enforcement point and there is no window in which an
      unauthorized row exists in memory.
    * The read uses `limit: 2` + `Repo.all/1` rather than `Repo.get_by/2`.
      `meetings` carries `unique_index(:meetings, [:project_id, :slug])` —
      slug is unique **per project**, not globally — so `Repo.get_by/2` raises
      `Ecto.MultipleResultsError` as soon as two projects pick the same slug.
      Two rows returns `{:error, :ambiguous}`; a slug-only URL genuinely
      cannot disambiguate and this function will not pick one for you.
    * Root (Fabrikam) **admins** bypass the org-membership filter — see
      `Platform.Chat` and `Platform.Chat.Sidebar` for the same precedent.
      Without it a root operator who is not an explicit member of a tenant org
      would lose access to that tenant's meetings. The ambiguity handling
      still applies to them.

  ## Why this is still hand-rolled, and not `Tenancy.scope/3`

  This is the one viewer-scoping site the tenancy consolidation left on its
  own query, on purpose. The two predicates are NOT the same:

    * here, the bypass is `Tenancy.fabrikam_admin?/1` — root membership at
      **admin** role;
    * `Tenancy.visibility/1` bypasses on `Tenancy.root_member?/1` — root
      membership at **any** role, which is strictly wider.

  Every new OIDC signup gets a plain `role: "member"` row in the root org, so
  routing this through the choke point would grant every signed-up user read
  access to every tenant's meetings. Four tests here and in
  `PlatformWeb.MeetingLiveTest` currently assert the opposite, including that
  a denial is indistinguishable from an absent slug.

  The project surface (`Platform.Tasks.list_projects_for_user/2`) already took
  the wider rule. The two surfaces therefore disagree today, and that
  disagreement is a decision someone has to make out loud — reconciling it
  changes who can read what. Do not "finish the consolidation" here by
  swapping the predicate silently.
    * External users are additionally narrowed by
      `Platform.Chat.ExternalScope.visible_space_id?/2` against the meeting's
      bound chat space. That helper is pass-through for non-external scopes,
      so internal users pay nothing. A failing external check returns
      `{:error, :not_found}`, not a distinct error — an external user must not
      learn that the meeting exists.

  ## Honest limit — this is org isolation, not project isolation

  There is no `project_members` table in this codebase. The finest membership
  grain that exists is `org_memberships`. Worse,
  `Platform.Accounts.find_or_create_from_oidc/1` gives **every** new user an
  `org_memberships` row in the Fabrikam root org. So this function does **not**
  create per-project isolation within a single org: every Fabrikam-org user can
  still read every Fabrikam-org meeting, by design.

  What it closes is the cross-**org** read — a Soylent user reading a
  Wayne-Tech meeting, an external user reading an internal one, an
  unauthenticated mount reading anything. Per-project ACLs are a separate ADR
  and are deliberately not invented here.
  """
  @spec fetch_meeting_for_user(map() | nil, String.t()) ::
          {:ok, Meeting.t()} | {:error, :not_found} | {:error, :ambiguous}
  def fetch_meeting_for_user(%{id: user_id} = user, slug)
      when is_binary(user_id) and is_binary(slug) do
    slug
    |> viewer_meeting_query(user_id, Platform.Tenancy.fabrikam_admin?(user))
    |> Repo.all()
    |> case do
      [] ->
        {:error, :not_found}

      [meeting] ->
        if ExternalScope.visible_space_id?(meeting.chat_space_id, ExternalScope.for_user(user)) do
          {:ok, Repo.preload(meeting, :chat_space)}
        else
          {:error, :not_found}
        end

      [_ | _] ->
        {:error, :ambiguous}
    end
  end

  def fetch_meeting_for_user(_user, _slug), do: {:error, :not_found}

  # NOT YET on `Tenancy.scope/3`, and deliberately so — see the "Why this is
  # still hand-rolled" section of the moduledoc. The bypass predicate here is
  # `fabrikam_admin?/1`; `visibility/1`'s is `root_member?/1`, which is strictly
  # wider. Swapping them is an access change, not a refactor.
  defp viewer_meeting_query(slug, _user_id, true = _root_admin?) do
    from(m in Meeting, where: m.slug == ^slug, limit: 2)
  end

  defp viewer_meeting_query(slug, user_id, false = _root_admin?) do
    viewer_org_ids = Platform.Tenancy.viewer_org_ids_query(user_id)

    from(m in Meeting,
      join: p in Platform.Tasks.Project,
      on: p.id == m.project_id,
      where: m.slug == ^slug and p.org_id in subquery(viewer_org_ids),
      limit: 2
    )
  end

  # ── Configuration ─────────────────────────────────────────────────────────

  @doc """
  Returns true when all required LiveKit env vars are set:
  LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.

  Used to gate the "Join Meeting" button in the UI.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = livekit_config()

    is_binary(config[:url]) and config[:url] != "" and
      is_binary(config[:api_key]) and config[:api_key] != "" and
      is_binary(config[:api_secret]) and config[:api_secret] != ""
  end

  @doc """
  Returns the LiveKit connection config, or `nil` when disabled.
  """
  @spec config() :: map() | nil
  def config do
    if enabled?() do
      config = livekit_config()

      %{
        url: config[:url],
        api_key: config[:api_key],
        api_secret: config[:api_secret]
      }
    end
  end

  @doc "Returns the configured LiveKit server URL."
  @spec livekit_url() :: String.t() | nil
  def livekit_url, do: livekit_config()[:url]

  # ── PubSub Topic Helpers ─────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a meeting room: `\"meetings:room:{room_id}\"`."
  @spec meeting_presence_topic(binary()) :: String.t()
  defdelegate meeting_presence_topic(room_id), to: MeetingsPubSub, as: :room_topic

  @doc "Returns the global presence summary topic: `\"meetings:presence_summary\"`."
  @spec meeting_presence_summary_topic() :: String.t()
  defdelegate meeting_presence_summary_topic(), to: MeetingsPubSub, as: :presence_summary_topic

  @doc "Subscribe to presence events for a specific meeting room."
  @spec subscribe_to_room_presence(binary()) :: :ok | {:error, term()}
  defdelegate subscribe_to_room_presence(room_id), to: MeetingsPubSub, as: :subscribe_room

  @doc "Subscribe to the global presence summary topic for sidebar indicators."
  @spec subscribe_to_presence_summary() :: :ok | {:error, term()}
  defdelegate subscribe_to_presence_summary(), to: MeetingsPubSub, as: :subscribe_presence_summary

  # ── Meetings (durable entity, ADR 0042) ──────────────────────────────────
  #
  # The `meetings` table is the persistent meeting record the Meeting
  # LiveView reads from. It is distinct from `meeting_rooms` (ephemeral
  # LiveKit call state, keyed 1:1 to a chat space): a `Meeting` is
  # project-scoped, has a slug + status lifecycle (scheduled → live →
  # ended), and embeds a backing chat space.

  @doc """
  Returns the PubSub topic for a project's meeting lifecycle events:
  `"projects:{project_id}:meetings"`.
  """
  @spec project_meetings_topic(binary()) :: String.t()
  def project_meetings_topic(project_id), do: "projects:#{project_id}:meetings"

  @doc """
  Returns the meta-topic broadcast on whenever a new
  `project_meetings_topic/1` topic gets a first meeting — the cue for
  long-lived subscribers (e.g. `Platform.Agents.MeetingHistorianHandler`)
  to dynamically subscribe to the new project's lifecycle stream so
  meetings created after the subscriber booted don't get missed.
  """
  @spec project_meetings_meta_topic() :: String.t()
  def project_meetings_meta_topic, do: "meetings:projects"

  @doc "Subscribe the calling process to a project's meeting lifecycle events."
  @spec subscribe_to_project_meetings(binary()) :: :ok | {:error, term()}
  def subscribe_to_project_meetings(project_id) do
    Phoenix.PubSub.subscribe(Platform.PubSub, project_meetings_topic(project_id))
  end

  @doc "Subscribe to the meta-topic for new project meetings topics."
  @spec subscribe_to_project_meetings_meta() :: :ok | {:error, term()}
  def subscribe_to_project_meetings_meta do
    Phoenix.PubSub.subscribe(Platform.PubSub, project_meetings_meta_topic())
  end

  @doc """
  Create a durable meeting.

  Required attrs: `:project_id`, `:name`.
  Optional: `:slug` (auto-generated from `:name` when omitted, with a
  numeric suffix appended if it collides within the project),
  `:host_participant_id`, `:scheduled_start_at`, `:scheduled_end_at`.

  `:scheduled_start_at` / `:scheduled_end_at` are the meeting's INTENDED
  time, as opposed to the `started_at` / `ended_at` actuals that
  `start_meeting/1` and `end_meeting/1` stamp. They are validated as a pair
  by `Meeting.changeset/2` — both nil or both present with the end strictly
  after the start — and a violation comes back as `{:error, changeset}`,
  rolling back the backing chat space with it.

  Omitting them is a supported state, not a defect: an ad-hoc meeting is one
  that was started but never scheduled, so both columns stay nil for its
  whole life. Nothing here synthesises a missing endpoint from the other —
  a caller that has only a start must choose an explicit end itself.

  Wraps the backing chat-space creation and the meeting insert in a single
  `Repo.transaction/1` — if either fails, neither is persisted. The
  `livekit_room_name` is derived from the meeting id per ADR 0030 room
  naming conventions (`"meeting-{uuid}"`).

  On success, broadcasts `{:meeting_created, meeting}` on the project's
  PubSub topic and returns `{:ok, meeting}`.
  """
  @spec create_meeting(map()) :: {:ok, Meeting.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_meeting(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    project_id = attrs[:project_id]
    name = attrs[:name]

    with :ok <- require_present(project_id, :project_id),
         :ok <- require_present(name, :name),
         :ok <- Platform.Tenancy.Lifecycle.ensure_project_writable(project_id) do
      slug = resolve_slug(project_id, attrs[:slug], name)

      result =
        Repo.transaction(fn ->
          # Generate the meeting id up front so the backing chat space can be
          # given a unique slug. The meeting's own `slug` is only unique within
          # its project; `chat_spaces.slug` is uniqueness-enforced for meeting
          # rows ONLY via the partial unique index `chat_spaces_meeting_slug`
          # (added 2026-06-29 — the older `chat_spaces_unique_slug` is on
          # `(workspace_id, slug)` and does NOT protect NULL-workspace meeting
          # rows). We derive the slug from the freshly-minted UUIDv7 — matching
          # the LiveKit room name convention (`"meeting-{uuid}"`). Without a slug
          # the discussion panel (gated on `@meeting.chat_space.slug`) cannot
          # mount the embedded chat and renders "No discussion bound to this
          # meeting."
          meeting_id = Platform.Types.UUIDv7.generate()
          chat_space_slug = "meeting-#{meeting_id}"

          # Scope the backing chat space to the project's org, through the same
          # two helpers `create_guest_chat_space/2` uses at `:1232`/`:1245` —
          # not a second derivation of meeting -> project -> org. The meeting
          # row does not exist yet, so `resolve_meeting_org_id/1` is handed the
          # struct it is about to be built from; it reads only `project_id`,
          # and `require_present/2` above has already established that this one
          # is a non-empty binary, so the nil clause is unreachable from here.
          #
          # `maybe_put_org_id/2` DROPS the key when the org does not resolve
          # rather than writing an explicit nil. That is deliberate and must
          # stay: a project with no org still gets its meeting a space. A
          # nil-org space is degraded; a meeting that cannot be created is
          # broken. `ExternalUserScope.system_prefix_fallback/1` keeps carrying
          # those rows, as it does for the `dm-` / `group-` kinds that are
          # cross-org by design and stay nil forever.
          space_attrs =
            %{
              name: name,
              slug: chat_space_slug,
              kind: "meeting",
              metadata: %{"project_id" => project_id}
            }
            |> maybe_put_org_id(resolve_meeting_org_id(%Meeting{project_id: project_id}))

          space =
            case Chat.create_space(space_attrs) do
              {:ok, space} -> space
              {:error, changeset} -> Repo.rollback(changeset)
            end

          meeting_attrs = %{
            project_id: project_id,
            host_participant_id: attrs[:host_participant_id],
            chat_space_id: space.id,
            slug: slug,
            name: name,
            status: "scheduled",
            livekit_room_name: "meeting-#{meeting_id}",
            # The intended-time pair has to be listed here explicitly: this map
            # is a whitelist, not `attrs`, so any key missing from it is
            # silently dropped before the changeset ever sees it. Passing nil
            # for both leaves the ad-hoc path byte-for-byte unchanged, since
            # `cast/3` treats nil for an already-nil field as no change.
            scheduled_start_at: attrs[:scheduled_start_at],
            scheduled_end_at: attrs[:scheduled_end_at]
          }

          changeset =
            %Meeting{}
            |> Meeting.changeset(meeting_attrs)
            |> Ecto.Changeset.put_change(:id, meeting_id)

          case Repo.insert(changeset) do
            {:ok, meeting} -> meeting
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, meeting} ->
          Phoenix.PubSub.broadcast(
            Platform.PubSub,
            project_meetings_topic(project_id),
            {:meeting_created, meeting}
          )

          # Announce on the meta-topic so long-lived subscribers can
          # subscribe to the project's lifecycle stream dynamically (the
          # MeetingHistorianHandler subscribes to existing-at-boot topics
          # via `Platform.Tasks.list_projects_unscoped/1` and uses this signal to
          # cover projects whose first meeting is created post-boot).
          Phoenix.PubSub.broadcast(
            Platform.PubSub,
            project_meetings_meta_topic(),
            {:project_meetings_topic_added, project_id}
          )

          {:ok, meeting}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Get a meeting by ID. Returns `nil` if not found — and also `nil` for a
  malformed id, which reaches here as `trigger_meta[:meeting_id]` off a
  responsibility payload. Platform.UUID.valid?/1, not a bare
  `Ecto.UUID.cast/1`: a bare cast accepts any 16-byte binary and the raise
  lands inside `Repo` regardless.
  """
  @spec get_meeting(term()) :: Meeting.t() | nil
  def get_meeting(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Meeting, id), else: nil
  end

  @doc """
  Return the most-recently-started `live` meeting bound to a chat space,
  or `nil` when the space has no live meeting.

  Meetings link to their backing chat space via `chat_space_id` (see
  `create_meeting/1`). The LiveKit join path (`MeetingHooks.do_join/1`)
  joins the `"space-<chat_space_id>"` room, so the `room_finished` webhook
  resolves the empty room's space id and uses this to find the live meeting
  to end. Returns the newest live meeting (by `started_at`) defensively in
  case more than one is live for the space.
  """
  @spec get_live_meeting_for_space(binary() | nil) :: Meeting.t() | nil
  def get_live_meeting_for_space(space_id) when is_binary(space_id) do
    Meeting
    |> where([m], m.chat_space_id == ^space_id and m.status == "live")
    |> order_by([m], desc: m.started_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_live_meeting_for_space(_space_id), do: nil

  @doc """
  Whether the meeting `id` is still `live`.

  The staleness predicate behind meeting inbox rows: live means the row is
  still actionable. One indexed EXISTS over the same `status == "live"` filter
  `get_live_meeting_for_space/1` uses — no row materialisation.

  A genuinely absent meeting is `false` (nothing left to join). An id we cannot
  resolve at all — a non-binary, or a binary that is not a UUID and so can
  never name a row — is `true`: ambiguity must never dismiss a row, so the
  caller errs toward leaving it in place.
  """
  @spec meeting_live?(binary()) :: boolean()
  def meeting_live?(id) when is_binary(id) do
    case Platform.UUID.cast(id) do
      {:ok, uuid} -> Repo.exists?(from(m in Meeting, where: m.id == ^uuid and m.status == "live"))
      :error -> true
    end
  end

  def meeting_live?(_id), do: true

  @doc """
  Whether a meeting row with `id` exists at all, whatever its status.

  Separates ABSENT from ENDED for `Platform.Inbox.reconcile_for_user/1`.
  `meeting_live?/1` answers `false` for both, and only the second is a positive
  confirmation that an inbox row's subject is dead; a meeting the reconciler
  cannot find at all leaves the row in place.

  One indexed EXISTS on the primary key. Deliberately uncast, matching the
  binary clause of `Platform.Tasks.plan_pending_review?/1`: the only caller
  passes an `inbox_items.source_id`, an `Ecto.UUID` column value.
  """
  @spec meeting_exists?(binary() | term()) :: boolean()
  def meeting_exists?(id) when is_binary(id) do
    Repo.exists?(from(m in Meeting, where: m.id == ^id))
  end

  def meeting_exists?(_id), do: false

  @doc "Get a meeting by its per-project slug. Returns `nil` if not found."
  @spec get_meeting_by_slug(binary(), String.t()) :: Meeting.t() | nil
  def get_meeting_by_slug(project_id, slug) do
    Repo.get_by(Meeting, project_id: project_id, slug: slug)
  end

  @doc "List all meetings for a project, newest first."
  @spec list_meetings_for_project(binary()) :: [Meeting.t()]
  def list_meetings_for_project(project_id) do
    Meeting
    |> where([m], m.project_id == ^project_id)
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  List every meeting across all projects, newest first. **Unscoped.**

  The `_unscoped` suffix is the point: this function takes no viewer and
  applies no org filter, so it returns meetings belonging to every org.
  Any surface that renders these rows to a human must resolve
  `Platform.Tenancy.visibility/1` and narrow with
  `Platform.Tenancy.scope/2` (or read through a scoped function such as
  `fetch_meeting_for_user/2`) before rendering. Calling this directly
  from a LiveView leaks foreign-org meeting titles.

  Legitimate unscoped callers exist and are why this is not simply
  deleted: the boot-time PubSub subscribers have no viewer at all.

  Used by the global `/meetings` index LV (no project context in the
  route). That caller is a KNOWN, still-open leak — see the
  `TODO(scope):` marker at its call site. When project-scoped routing
  arrives the index will narrow to `list_meetings_for_project/1`.
  """
  @spec list_all_meetings_unscoped() :: [Meeting.t()]
  def list_all_meetings_unscoped do
    Meeting
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  List the meetings *intended* to happen inside a time window, in intended
  order. This is the query a calendar grid places rows with, so its edges are
  part of its contract:

    * The window is HALF-OPEN — `[from, to)`. A meeting is returned when
      `scheduled_start_at >= from` and `scheduled_start_at < to`. Closed on
      both ends, a meeting sitting exactly on a day boundary would come back
      in BOTH adjacent day columns of a grid rendered by calling this once
      per day.

    * Only `scheduled_start_at` is compared. A meeting is placed by when it
      is meant to START; a long meeting overlapping the window but starting
      before `from` is NOT returned.

    * Rows with `scheduled_start_at IS NULL` — the ad-hoc "started, never
      scheduled" meetings — are excluded by construction, because a `>=`
      comparison against NULL is never true in SQL. That exclusion is
      INTENDED, not an oversight: a meeting with no intended time has no
      cell to sit in. Do not "fix" it with an `or is_nil(m.scheduled_start_at)`;
      `list_all_meetings_unscoped/0` is the query that still sees those rows.

    * Ordering is `asc: scheduled_start_at` — intended time first — with
      `asc: inserted_at` only as a deterministic tiebreak between two
      meetings intended at the same instant. `inserted_at` is never the
      primary sort here; it answers "when was this created", not "when is
      this".

  Options:

    * `:project_id` — when given, narrows to that project. When absent the
      query deliberately spans projects, matching the unscoped
      `meetings(scheduled_start_at)` index.

  ## No viewer scoping

  This function takes no viewer. With no `:project_id` it spans every org,
  so it carries the same hazard as `list_all_meetings_unscoped/0` and its
  calendar caller shares that function's open `TODO(scope):`. It is not
  named `*_unscoped` because `:project_id` makes the narrowed call a
  genuinely bounded read and the suffix would misdescribe it. Any surface
  rendering these rows to a human must resolve `Platform.Tenancy.visibility/1`
  and narrow with `Platform.Tenancy.scope/2` (or pass a `:project_id` the
  viewer is already known to be able to see).
  """
  @spec list_meetings_in_range(DateTime.t(), DateTime.t(), keyword()) :: [Meeting.t()]
  def list_meetings_in_range(%DateTime{} = from, %DateTime{} = to, opts \\ []) do
    Meeting
    |> where([m], m.scheduled_start_at >= ^from and m.scheduled_start_at < ^to)
    |> scope_range_to_project(Keyword.get(opts, :project_id))
    |> order_by([m], asc: m.scheduled_start_at, asc: m.inserted_at)
    |> Repo.all()
  end

  defp scope_range_to_project(query, nil), do: query

  defp scope_range_to_project(query, project_id),
    do: where(query, [m], m.project_id == ^project_id)

  @doc """
  List every meeting `user` may see, newest-created first.

  The viewer-scoped replacement for `list_all_meetings_unscoped/0`: same shape,
  same `desc: inserted_at` ordering, narrowed to the rows this viewer is
  allowed to read. The scoping rule is `viewer_listing_query/1` — one
  definition shared with `list_meetings_in_range_for_user/4` so the index and
  the calendar can never disagree about who sees what.

  A nil, non-map, or id-less viewer answers `[]` — the empty answer, never the
  unscoped one. That is an explicit clause rather than a fallthrough so a
  future edit cannot widen it by accident.
  """
  @spec list_meetings_for_user(term()) :: [Meeting.t()]
  def list_meetings_for_user(%{id: user_id} = user) when is_binary(user_id) do
    user
    |> viewer_listing_query()
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  def list_meetings_for_user(_user), do: []

  @doc """
  List the meetings `user` may see that are *intended* to happen inside a time
  window, in intended order.

  The viewer-scoped replacement for `list_meetings_in_range/3`. Every edge of
  that function's contract is preserved exactly, because a calendar grid places
  rows with it and those edges are pinned by tests:

    * half-open `[from, to)` on `scheduled_start_at`;
    * `scheduled_start_at IS NULL` rows excluded by construction;
    * `asc: scheduled_start_at` with `asc: inserted_at` as the tiebreak;
    * optional `:project_id` narrowing, via the same `scope_range_to_project/2`.

  The only difference is the viewer narrowing in front of them, which is the
  shared `viewer_listing_query/1`. A nil, non-map, or id-less viewer answers
  `[]`, as an explicit clause.
  """
  @spec list_meetings_in_range_for_user(term(), DateTime.t(), DateTime.t(), keyword()) ::
          [Meeting.t()]
  def list_meetings_in_range_for_user(user, from, to, opts \\ [])

  def list_meetings_in_range_for_user(
        %{id: user_id} = user,
        %DateTime{} = from,
        %DateTime{} = to,
        opts
      )
      when is_binary(user_id) do
    user
    |> viewer_listing_query()
    |> where([m], m.scheduled_start_at >= ^from and m.scheduled_start_at < ^to)
    |> scope_range_to_project(Keyword.get(opts, :project_id))
    |> order_by([m], asc: m.scheduled_start_at, asc: m.inserted_at)
    |> Repo.all()
  end

  def list_meetings_in_range_for_user(_user, _from, _to, _opts), do: []

  # The ONE viewer-scoping rule for meeting LISTINGS, rooted on `Meeting` so
  # every caller composes further `where`/`order_by` against binding `[m]`.
  #
  # Three branches, matching the detail route (`fetch_meeting_for_user/2`)
  # wherever a listing can:
  #
  #   * Fabrikam root ADMIN — everything. The bypass predicate is
  #     `Tenancy.fabrikam_admin?/1`, the same one `viewer_meeting_query/3` uses.
  #     NOT `root_member?/1`, which is strictly wider: every OIDC signup gets a
  #     plain `role: "member"` row in the root org, so swapping the predicate
  #     would hand every signed-up user every tenant's meetings. See the
  #     moduledoc's "Why this is still hand-rolled" section.
  #
  #   * External user — the meetings they hold a LIVE INVITE for. Invitation,
  #     not participation, and the distinction is load-bearing in both
  #     directions. Revoking an invite stamps `revoked_at`; it does NOT delete
  #     the meeting's chat participant row, so a participation-keyed listing
  #     would keep showing a revoked invitee their old meetings forever. In the
  #     other direction, an invite that was sent but never used is exactly the
  #     row the invitee needs to see in order to join. Where the two sets
  #     diverge, the invite decides. `invited_to_slug?/2` makes the same
  #     argument for the single-meeting case.
  #
  #   * Internal user — org membership, mirroring `viewer_meeting_query/3`:
  #     join the project and require its `org_id` among the viewer's orgs.
  defp viewer_listing_query(user) do
    cond do
      Platform.Tenancy.fabrikam_admin?(user) ->
        from(m in Meeting)

      Platform.Tenancy.external_user?(user) ->
        from(m in Meeting, where: m.id in subquery(invited_meeting_ids_query(user)))

      true ->
        from(m in Meeting,
          join: p in Platform.Tasks.Project,
          on: p.id == m.project_id,
          where: p.org_id in subquery(Platform.Tenancy.viewer_org_ids_query(user.id))
        )
    end
  end

  @doc """
  The meeting ids this user holds a LIVE invite for, as a subquery-able query
  selecting `meeting_invites.meeting_id`.

  Composed from `active_invite_query/1` — the one place the liveness
  conditions (not expired, not revoked) and the identity clause (`user_id`,
  OR a case-insensitive `email` match when the invite carries no `user_id`)
  are written — so `viewer_listing_query/1`, `Platform.Meetings.Archive`,
  `invited_to_slug?/2` and `invited_to_space?/2` can never drift apart.

  The email disjunct inside it is what makes the invite-an-address-then-they
  -sign-in flow work at all: `Platform.Accounts.ExternalAdmission` never
  backfills `meeting_invites.user_id`, so a listing keyed on `user_id` alone
  would show a freshly admitted external user nothing.

  Public only so the archive can compose the SAME rule rather than clone it.
  Intended for `where: m.id in subquery(...)`, never as a standalone read:
  `IN (subquery)` rather than a join, because an invitee holding two live
  invites to one meeting must produce one row, not two.
  """
  @spec invited_meeting_ids_query(map()) :: Ecto.Query.t()
  def invited_meeting_ids_query(user) do
    user
    |> active_invite_query()
    |> select([i, _m], i.meeting_id)
  end

  @doc """
  Was this meeting *meant* to have happened by `now`, and never started?

  This is a REPORT over the `(status, scheduled_start_at, started_at)`
  triple — NOT a state. Nothing writes a `"missed"` status; `@statuses` in
  `Platform.Meetings.Meeting` stays `~w(scheduled live ended)` and
  `Meeting.status_changeset/3` remains its sole writer. "Missed" is a
  question you ask a row, not a thing that happens to it.

  Deriving `status` from the clock instead was considered and rejected: a
  meeting would flip to `"live"` at its scheduled minute with nobody in the
  room, and `MeetingLive.maybe_start_meeting/1` — which pattern-matches
  `%{status: "scheduled"}` to decide whether to start — would never fire
  again. A fourth `"missed"` status was rejected for the same family of
  reasons: it would need a transition rule, a writer and a sweeper, and
  every existing three-way `status_bucket/1` clause would silently funnel it
  into `:upcoming`.

  All four clauses are load-bearing and each excludes a different row:

    * `status == "scheduled"` — a live or ended meeting is never missed.
    * `scheduled_start_at` non-nil — an ad-hoc meeting (no intended time)
      can't be missed, because nothing was ever intended.
    * `scheduled_start_at < now` — a meeting intended for the future is not
      missed yet, it is merely upcoming.
    * `started_at` is nil — a meeting that started is not missed, whatever
      its status column says.

  Clauses 1 and 4 overlap in practice: `start_meeting/1` flips the status
  and stamps `started_at` in a single update, so no row the application
  writes distinguishes them. They are kept separate deliberately, so the
  predicate stays correct against a row that acquired a `started_at` by any
  other path.

  `now` is injectable so callers (and tests) never have to sleep.
  """
  @spec missed?(Meeting.t(), DateTime.t()) :: boolean()
  def missed?(meeting, now \\ DateTime.utc_now())

  def missed?(%Meeting{} = meeting, %DateTime{} = now) do
    meeting.status == "scheduled" and
      not is_nil(meeting.scheduled_start_at) and
      DateTime.compare(meeting.scheduled_start_at, now) == :lt and
      is_nil(meeting.started_at)
  end

  @doc """
  The query counterpart of `missed?/2`: every meeting intended before `now`
  that never started, in intended order.

  Same caveat as `missed?/2` — this is a report, not a state transition. It
  reads rows; it writes nothing, and no row is marked as having been
  reported.

  The `where` clauses mirror `missed?/2` one-for-one so the two cannot drift.
  Note that `not is_nil(m.scheduled_start_at)` is *redundant in SQL*: under
  three-valued logic `NULL < now` is NULL, never true, so the ad-hoc rows are
  already excluded by the comparison alone. It is kept because deleting it
  from the Elixir predicate is a real bug (`DateTime.compare(nil, now)`
  raises), and a reader comparing the two implementations should see the same
  four clauses in the same order rather than having to re-derive the NULL
  semantics.

  Ordering is `asc: scheduled_start_at` — oldest missed intent first, which
  is the order a "you missed these" report wants to read in. Unlike
  `list_meetings_in_range/3` there is no `inserted_at` tiebreak, so two
  meetings intended at the same instant come back in an unspecified order.

  Options:

    * `:project_id` — when given, narrows to that project. When absent the
      query spans projects.
    * `:now` — the instant to compare against, defaulting to
      `DateTime.utc_now/0`. Injectable so tests never sleep.
  """
  @spec list_missed_meetings(keyword()) :: [Meeting.t()]
  def list_missed_meetings(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Meeting
    |> where([m], m.status == "scheduled")
    |> where([m], not is_nil(m.scheduled_start_at))
    |> where([m], m.scheduled_start_at < ^now)
    |> where([m], is_nil(m.started_at))
    |> scope_range_to_project(Keyword.get(opts, :project_id))
    |> order_by([m], asc: m.scheduled_start_at)
    |> Repo.all()
  end

  @doc """
  Transition a meeting from `scheduled` to `live`, stamping `started_at`.

  Returns `{:error, changeset}` (with an `:status` error) on any illegal
  transition — e.g. starting an already-ended meeting. On success broadcasts
  `{:meeting_started, meeting}` on the project's PubSub topic so the
  meetings index can re-group without a poll.
  """
  @spec start_meeting(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Ecto.Changeset.t()}
  def start_meeting(%Meeting{} = meeting) do
    case meeting
         |> Meeting.status_changeset("live", %{started_at: DateTime.utc_now()})
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          project_meetings_topic(updated.project_id),
          {:meeting_started, updated}
        )

        ok

      error ->
        error
    end
  end

  @doc """
  Atomically claim the right to notify subscribers about this meeting.

  Performs a compare-and-swap on `meetings.notified_at` via
  `UPDATE ... WHERE id = ? AND notified_at IS NULL`. The database
  guarantees at most one caller's update affects a row, so concurrent
  callers race the SQL — exactly one sees `{1, _}` (the winner) and the
  rest see `{0, _}` (already notified). No transaction or advisory lock
  needed.

  Returns:

    * `{:ok, meeting}` — caller WON the race; `meeting.notified_at` is
      stamped to `now`. The caller must fan out the notification.
    * `{:already_notified, meeting}` — somebody else already won; the
      caller must NOT fan out.

  See `Platform.Meetings.MeetingNotifier.handle_info({:meeting_started, _}, _)`
  for the production wire-in. Closes the `:auto_join` race where two
  clients hit the auto-join path for the same scheduled meeting within
  milliseconds and both broadcasts would otherwise pass
  `Meeting.status_changeset/3`'s `scheduled → live` validation.
  """
  @spec mark_notified(Meeting.t()) ::
          {:ok, Meeting.t()} | {:already_notified, Meeting.t()}
  def mark_notified(%Meeting{notified_at: nil} = meeting) do
    now = DateTime.utc_now()

    {count, _} =
      from(m in Meeting,
        where: m.id == ^meeting.id and is_nil(m.notified_at),
        update: [set: [notified_at: ^now]]
      )
      |> Repo.update_all([])

    case count do
      1 -> {:ok, %{meeting | notified_at: now}}
      0 -> {:already_notified, meeting}
    end
  end

  def mark_notified(%Meeting{} = meeting), do: {:already_notified, meeting}

  # ── Per-meeting intent mute (task 019fbaac stage 1) ───────────────────────
  #
  # A hold on the Meeting Producer for THIS meeting, so a human in a live
  # meeting can stop agents diving in on classified intent without
  # unassigning the org-wide `meeting_producer` role — which is the only
  # switch that existed before, and which silences every meeting on the
  # platform.
  #
  # The state is a nullable timestamp on `meetings`, not a key in
  # `meeting_rooms.config`: that map is keyed per chat SPACE, so a mute
  # placed in Monday's standup would still be in force next Monday. It is
  # also not ETS on the intent queue, which fails OPEN — `IntentQueue.list/1`
  # returns `[]` when no owner is running, so a queue-owner crash would
  # silently resume the agents. A hold switch must fail closed.

  @doc """
  Place or lift the per-meeting intent mute.

  Accepts a `%Meeting{}` or a meeting id. `muted? == true` stamps
  `intent_muted_at` with `DateTime.utc_now()`; `false` clears it to
  `nil`. Returns `{:ok, meeting}` with the updated row, or
  `{:error, :not_found}` for an unknown or malformed id.

  Re-muting an already-muted meeting does NOT move the timestamp — the
  hold was placed once and the record of when should not drift every
  time somebody clicks a toggle that is already on. It DOES still
  broadcast: a second client that missed the first event needs it, and
  suppressing the duplicate trades a cheap message for a permanently
  wrong badge on somebody else's screen.

  A `%Meeting{}` argument is re-read before the write rather than
  trusted (task 019fbaac stage 2). Callers hold this struct for a long
  time — `PlatformWeb.MeetingLive` loads it once at `handle_params` and
  keeps it in socket assigns for the life of the meeting — so by the
  time somebody clicks the toggle, `meeting.intent_muted_at` is
  whatever it was at mount. Acting on that stale field produced two
  wrong outcomes: unmuting from a struct that already read `nil` built
  an EMPTY changeset, which `Repo.update/1` answers `{:ok, stale}`
  without touching the row — a broadcast saying "unmuted", a badge that
  cleared, and a classifier that stayed muted forever. And re-muting
  from a stale `nil` re-clocked a timestamp the docs above promise not
  to move. One indexed primary-key read on a human-initiated toggle
  buys both invariants back.
  """
  @spec set_intent_muted(Meeting.t() | binary(), boolean()) ::
          {:ok, Meeting.t()} | {:error, term()}
  def set_intent_muted(%Meeting{id: id}, muted?) when is_boolean(muted?) do
    set_intent_muted(id, muted?)
  end

  def set_intent_muted(meeting_id, muted?) when is_boolean(muted?) do
    case get_meeting(meeting_id) do
      %Meeting{} = meeting -> write_intent_mute(meeting, muted?)
      nil -> {:error, :not_found}
    end
  end

  defp write_intent_mute(%Meeting{} = meeting, muted?) do
    muted_at =
      cond do
        not muted? -> nil
        # Already muted: keep the original stamp, don't re-clock it.
        not is_nil(meeting.intent_muted_at) -> meeting.intent_muted_at
        true -> DateTime.utc_now()
      end

    case meeting |> Meeting.intent_mute_changeset(muted_at) |> Repo.update() do
      {:ok, updated} ->
        MeetingsPubSub.broadcast_intent_mute_changed(updated.id, updated.intent_muted_at)
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  # ── Automation mode (task 01a03fba stage 1) ───────────────────────────────

  @automation_modes [:off, :automated]

  @doc """
  The per-meeting automation modes: `:off` and `:automated`.
  """
  @spec automation_modes() :: [atom()]
  def automation_modes, do: @automation_modes

  @doc """
  The meeting's automation mode.

  **This is a reader over `intent_muted_at`, deliberately not a second
  column.** The ticket asks for an off/automated master toggle, and
  `intent_muted_at` already IS one: it is persisted, PubSub-broadcast,
  fail-closed, checked by `IntentDispatcher.do_drain/2` before
  `claim_next/1`, and wired to a toggle in the meeting's intents bar. A
  second column beside it would be a second master switch on the same
  rail, and the interesting question would immediately become which one
  wins when they disagree — a question with no good answer and one that
  a reader of either column alone cannot even see.

  So there is one switch and two vocabularies over it. `:off` is
  "muted": no agent dispatch, and no candidate countdown either.
  `:automated` is the ordinary state.

  Returns `:automated` for an unknown or malformed meeting id, matching
  `intent_muted?/1`'s posture — this is read on hot paths from a
  transcript pump and must not raise there. The countdown's fail-closed
  guarantee is not weakened by that: an unknown meeting has no
  candidates to fire.
  """
  @spec automation_mode(term()) :: :off | :automated
  def automation_mode(meeting_id) do
    if intent_muted?(meeting_id), do: :off, else: :automated
  end

  @doc """
  Set the meeting's automation mode.

  Delegates to `set_intent_muted/2` — see `automation_mode/1` for why
  these are one switch and not two — so it inherits every property that
  toggle already has: the row is re-read before the write, an
  already-`:off` meeting keeps its original stamp rather than re-clocking
  it, and both directions broadcast `intent_mute_changed` so a second
  participant's badge follows.

  Returns `{:ok, meeting}` or `{:error, :not_found}` /
  `{:error, :invalid_mode}`.
  """
  @spec set_automation_mode(Meeting.t() | binary(), :off | :automated) ::
          {:ok, Meeting.t()} | {:error, term()}
  def set_automation_mode(meeting_or_id, mode) when mode in @automation_modes do
    set_intent_muted(meeting_or_id, mode == :off)
  end

  def set_automation_mode(_meeting_or_id, _mode), do: {:error, :invalid_mode}

  # ── Whiteboard (task 019fcfcf stage 1) ────────────────────────────────────

  @doc """
  Returns the meeting's whiteboard row, or `nil` when it has never been
  saved. A meeting with no board is the ordinary starting state, not an
  error — the editor opens on an empty scene.
  """
  @spec get_whiteboard(term()) :: Whiteboard.t() | nil
  def get_whiteboard(meeting_id) do
    if Platform.UUID.valid?(meeting_id) do
      Repo.get_by(Whiteboard, meeting_id: meeting_id)
    else
      nil
    end
  end

  @doc """
  Save a whiteboard scene under optimistic concurrency.

  Returns `{:ok, whiteboard}` with `scene_version` incremented by one,
  `{:error, :stale_version, current}` when `expected_version` is behind
  the stored version, or `{:error, changeset}`.

  ## Why a transaction with a row lock

  v1 is SINGLE-EDITOR — there is no operational transform, no CRDT and
  no element-level merge — so the counter is the whole of the safety
  story and it must not be checkable-then-wrong. Reading the version
  and writing `version + 1` in two statements lets two savers both read
  N and both write N+1, which is exactly the lost update the counter
  exists to catch. The compare and the write therefore happen inside
  one `Repo.transaction/1` with `SELECT ... FOR UPDATE` on the board
  row, so the second saver blocks until the first commits and then
  reads N+1 and is correctly rejected.

  The first-ever save has no row to lock. That race is caught instead
  by `unique_index(:meeting_whiteboards, [:meeting_id])`: the loser
  gets `{:error, changeset}` and retries against a row that now exists.

  A save whose `expected_version` is AHEAD of the stored one is also
  rejected as stale — it describes a state this server never produced,
  and accepting it would let a client dictate the counter.
  """
  @spec upsert_whiteboard_scene(binary(), binary() | nil, map(), integer()) ::
          {:ok, Whiteboard.t()}
          | {:error, :stale_version, Whiteboard.t()}
          | {:error, Ecto.Changeset.t() | :not_found}
  def upsert_whiteboard_scene(meeting_id, user_id, scene, expected_version)
      when is_binary(meeting_id) and is_map(scene) and is_integer(expected_version) do
    result =
      Repo.transaction(fn ->
        case lock_whiteboard(meeting_id) do
          nil ->
            insert_whiteboard(meeting_id, user_id, scene)

          %Whiteboard{scene_version: ^expected_version} = current ->
            update_whiteboard(current, user_id, scene)

          %Whiteboard{} = current ->
            Repo.rollback({:stale_version, current})
        end
      end)

    case result do
      {:ok, %Whiteboard{} = whiteboard} ->
        MeetingsPubSub.broadcast_whiteboard_scene_saved(
          whiteboard.meeting_id,
          whiteboard.scene_version,
          whiteboard.last_edited_by_user_id
        )

        {:ok, whiteboard}

      {:error, {:stale_version, current}} ->
        {:error, :stale_version, current}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_whiteboard(meeting_id) do
    from(w in Whiteboard, where: w.meeting_id == ^meeting_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp insert_whiteboard(meeting_id, user_id, scene) do
    %Whiteboard{}
    |> Whiteboard.changeset(%{
      meeting_id: meeting_id,
      last_edited_by_user_id: user_id,
      scene: scene,
      scene_version: 1
    })
    |> Repo.insert()
    |> unwrap_whiteboard()
  end

  defp update_whiteboard(%Whiteboard{} = current, user_id, scene) do
    current
    |> Whiteboard.changeset(%{
      last_edited_by_user_id: user_id,
      scene: scene,
      scene_version: current.scene_version + 1
    })
    |> Repo.update()
    |> unwrap_whiteboard()
  end

  defp unwrap_whiteboard({:ok, %Whiteboard{} = whiteboard}), do: whiteboard
  defp unwrap_whiteboard({:error, changeset}), do: Repo.rollback(changeset)

  @doc """
  Is the intent classifier muted for this meeting?

  Returns a plain boolean, and returns `false` — never raises — for
  `nil`, a malformed id, and a well-formed id with no row. That
  totality is load-bearing rather than defensive: the caller is
  `Platform.Meetings.IntentClassifier`, a singleton GenServer handling
  transcript chunks for every room on the node. A raise inside `Repo`
  reached from there kills classification for every meeting at once, and
  a transcript chunk whose space has no meeting (`meeting_id: nil`) is
  an ordinary occurrence, not an error.

  Reads the column directly rather than loading the row so the
  per-chunk cost is one indexed primary-key lookup. Deliberately NOT
  cached: a stale cache is a mute that does not take effect
  mid-meeting, which is the one requirement here that cannot be traded
  away.
  """
  @spec intent_muted?(term()) :: boolean()
  def intent_muted?(meeting_id) do
    if Platform.UUID.valid?(meeting_id) do
      from(m in Meeting, where: m.id == ^meeting_id, select: not is_nil(m.intent_muted_at))
      |> Repo.one()
      |> Kernel.==(true)
    else
      false
    end
  end

  @doc """
  Transition a meeting from `live` to `ended`, stamping `ended_at`.

  Returns `{:error, changeset}` on any illegal transition. On success
  broadcasts `{:meeting_ended, meeting}` on the project's PubSub topic
  so the meetings index can re-group without a poll.
  """
  @spec end_meeting(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Ecto.Changeset.t()}
  def end_meeting(%Meeting{} = meeting) do
    case meeting
         |> Meeting.status_changeset("ended", %{ended_at: DateTime.utc_now()})
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          project_meetings_topic(updated.project_id),
          {:meeting_ended, updated}
        )

        ok

      error ->
        error
    end
  end

  @doc """
  Call a meeting off, stamping `cancelled_at` and who did it.

  Legal from `scheduled` and from `live`. `ended → cancelled` returns
  `{:error, changeset}` with an error on `:status` — a meeting that already
  happened cannot be un-happened; see `Meeting.status_changeset/3`.

  On success broadcasts `{:meeting_cancelled, meeting}` on the project's
  PubSub topic, same shape as `end_meeting/1`. That broadcast is the ONLY
  thing that reaches `Platform.Meetings.MeetingNotifier`, which is what
  turns a cancellation into a notice to the people who were expecting to
  attend — so it is load-bearing, not telemetry.

  `cancelled_by_participant_id` is a `chat_participants` row id.
  """
  @spec cancel_meeting(Meeting.t(), binary() | nil) ::
          {:ok, Meeting.t()} | {:error, Ecto.Changeset.t()}
  def cancel_meeting(%Meeting{} = meeting, cancelled_by_participant_id) do
    attrs = %{
      cancelled_at: DateTime.utc_now(),
      cancelled_by_participant_id: cancelled_by_participant_id
    }

    case meeting
         |> Meeting.status_changeset("cancelled", attrs)
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          project_meetings_topic(updated.project_id),
          {:meeting_cancelled, updated}
        )

        ok

      error ->
        error
    end
  end

  @doc """
  Atomically claim the right to notify subscribers that this meeting is off.

  The exact analogue of `mark_notified/1`, against
  `meetings.cancellation_notified_at` instead of `meetings.notified_at`:
  a compare-and-swap via `UPDATE ... WHERE id = ? AND
  cancellation_notified_at IS NULL`, so concurrent callers race the SQL and
  exactly one sees `{1, _}`.

  A separate column from `notified_at` on purpose — a meeting that went live
  and was then called off has legitimately been notified about twice, for two
  different facts, and one column cannot carry both stamps.

  Returns:

    * `{:ok, meeting}` — caller WON; `meeting.cancellation_notified_at` is
      stamped and the caller must fan out.
    * `{:already_notified, meeting}` — somebody else won; do NOT fan out, and
      the stored stamp is the winner's, left untouched.
  """
  @spec mark_cancellation_notified(Meeting.t()) ::
          {:ok, Meeting.t()} | {:already_notified, Meeting.t()}
  def mark_cancellation_notified(%Meeting{cancellation_notified_at: nil} = meeting) do
    now = DateTime.utc_now()

    {count, _} =
      from(m in Meeting,
        where: m.id == ^meeting.id and is_nil(m.cancellation_notified_at),
        update: [set: [cancellation_notified_at: ^now]]
      )
      |> Repo.update_all([])

    case count do
      1 -> {:ok, %{meeting | cancellation_notified_at: now}}
      0 -> {:already_notified, meeting}
    end
  end

  def mark_cancellation_notified(%Meeting{} = meeting), do: {:already_notified, meeting}

  # ── Guest ingress (per-invite chat_space) ────────────────────────────────
  #
  # See `guest_livekit_token/2` (below) for the mint side. The per-invite
  # `chat_space` is IDENTITY BOOKKEEPING for the guest, not the LiveKit
  # routing space: the guest joins the SAME LiveKit room as the host
  # (`space-<meeting.chat_space_id>`, via `room_name_for_space/1`).
  # Rationale in ADR-style comment inline; short version: keeping guests
  # out of the host's chat_space avoids leaking presence/messages across
  # the audience boundary while still letting the phantom-fix guard
  # (`legit_room?/1`, which walks `Chat.get_space/1` on the LiveKit
  # room-derived space_id) admit the host's real chat_space.

  @doc """
  Create a per-invite guest chat space owned by the host.

  This is the identity-bookkeeping row that stage 4 will embed in the
  signed guest-invite payload (`guest_space_id`). It is NOT the space
  used for LiveKit routing — that stays `meeting.chat_space_id`, so the
  guest joins the host's LiveKit room, not a separate one.

  Attributes:
    * `name` — "Guest — <meeting.name>" so operators can eyeball the origin.
    * `slug` — `"guest-<8-char-random>"` (URL-safe base64), unique enough
      not to collide with the meeting's own `meeting-<uuid>` slugs.
    * `kind` — `"guest_meeting"` (dedicated kind so a 24h reaper can
      target it without accidentally sweeping real meeting spaces).
    * `metadata` — `%{"meeting_id" => ..., "host_user_id" => ...}` for
      forensics and for the eventual reaper's `meeting_id`-scoped
      cleanup.
    * `org_id` — inherited from the meeting's project so cross-tenant
      slug uniqueness stays scoped correctly. Preloads the project when
      it's not already loaded on the passed struct.

  Returns `{:ok, %Chat.Space{}}` on success, `{:error, changeset}` on
  changeset failure. Bubbles anything else raised by
  `Platform.Chat.create_space/1` unchanged.
  """
  @spec create_guest_chat_space(Meeting.t(), binary() | nil) ::
          {:ok, Platform.Chat.Space.t()} | {:error, Ecto.Changeset.t()}
  def create_guest_chat_space(%Meeting{} = meeting, host_user_id) do
    org_id = resolve_meeting_org_id(meeting)
    slug_suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    attrs =
      %{
        name: "Guest — #{meeting.name}",
        slug: "guest-#{String.downcase(slug_suffix)}",
        kind: "guest_meeting",
        metadata: %{
          "meeting_id" => meeting.id,
          "host_user_id" => host_user_id
        }
      }
      |> maybe_put_org_id(org_id)

    Chat.create_space(attrs)
  end

  @doc """
  Resolve — or mint — the chat space an EXTERNAL invitee can actually be
  reached in, and make sure both ends of the conversation are in it.

  Task `019fb955-6577-7fb0-8c97-c70d233bba23` stage 4. This is the
  collaborator behind `Platform.Meetings.InviteDelivery`'s external
  carrier; see that moduledoc for why chat is the only surface this
  audience has.

  ## The ticket's premise is only half true, and the other half is this function

  The ticket says the invitee "is scoped to that space by construction"
  because `guest_space_id` is already in the invite token. That holds for
  GUEST invites only. `invite_guest/2` mints a `kind: "guest_meeting"`
  space per link and signs its id into the token. An external QUALIFIED
  USER invite comes from `invite_user/3`, which mints no token and no
  space — so for that audience there is no pre-existing space to point at
  and one has to be resolved or created here.

  ## Why `create_guest_chat_space/2` and not a second constructor

  The space this audience needs has exactly the shape that function
  already builds: `kind: "guest_meeting"` (so the eventual 24h reaper
  targets it without sweeping real meeting spaces), org-scoped to the
  MEETING's project, and carrying `meeting_id` in `metadata` for
  forensics. A parallel constructor would be the same row with a second
  set of bugs.

  ## Order, and what each step buys

    1. `invite.delivery_space_id` set → load and return that space. A
       re-delivery reuses it and never mints a second, so a host who
       re-invites does not scatter one conversation across two rooms. A
       `delivery_space_id` naming a row that no longer exists answers
       `{:error, :delivery_space_missing}` rather than quietly minting a
       replacement — a space that was deleted out from under a recorded
       receipt is an operator event, and inventing a new one would hide
       it while splitting the thread.
    2. Otherwise mint via `create_guest_chat_space/2` and persist the id
       onto the invite. Persisting is what makes step 1 reachable.
    3. Ensure the SENDER's agent participant row.
       `Chat.add_agent_participant/3` is already get-or-insert
       (`chat.ex`'s `do_add_agent_participant/3`), so calling it on every
       delivery is safe and no guard is owed.
    4. Ensure the INVITEE's `participant_type: "user"` row. This is the
       step that makes the space reachable at all:
       `PlatformWeb.Plugs.ExternalUserScope` admits an external user to
       `/chat/:slug` only when `Chat.participant?/2` is true, and
       `Platform.Chat.ExternalScope` narrows every external read to
       `chat_participants` membership — so without this row the message
       is written and unreachable, which is the exact failure the whole
       stage exists to avoid.

  `Chat.add_participant/2` has NO get-or-insert branch and
  `chat_participants_unique` rejects a second insert, so step 4 is
  guarded by a `Repo.get_by/2` mirroring `do_add_agent_participant/3`.
  The `user_id` is checked with `Platform.UUID.valid?/1` first —
  `participant_id` is a `:binary_id`, and `Repo.get_by(_, participant_id:
  nil)` raises `ArgumentError` besides.

  Returns `{:ok, %Platform.Chat.Space{}}`, or `{:error, term}` for a
  missing space, a changeset failure, an archived space
  (`{:error, :space_archived}` out of `Chat.add_participant/2`) or an
  invite with no `user_id` — a guest never routes here.
  """
  @spec delivery_space_for_invite(Invite.t(), Meeting.t()) ::
          {:ok, Platform.Chat.Space.t()} | {:error, term()}
  def delivery_space_for_invite(%Invite{} = invite, %Meeting{} = meeting) do
    with {:ok, space} <- resolve_delivery_space(invite, meeting),
         {:ok, _sender} <- ensure_delivery_sender(space),
         {:ok, _invitee} <- ensure_delivery_invitee(space, invite.user_id) do
      {:ok, space}
    end
  end

  defp resolve_delivery_space(%Invite{delivery_space_id: space_id}, _meeting)
       when is_binary(space_id) do
    case Chat.get_space(space_id) do
      %Platform.Chat.Space{} = space -> {:ok, space}
      nil -> {:error, :delivery_space_missing}
    end
  end

  defp resolve_delivery_space(%Invite{} = invite, %Meeting{} = meeting) do
    with {:ok, space} <- create_guest_chat_space(meeting, invite.user_id),
         {:ok, _invite} <- persist_delivery_space(invite, space) do
      {:ok, space}
    end
  end

  defp persist_delivery_space(%Invite{} = invite, %Platform.Chat.Space{id: space_id}) do
    invite
    |> Invite.changeset(%{delivery_space_id: space_id})
    |> Repo.update()
  end

  # The seeded agent is an AUTHORSHIP IDENTITY and nothing more — no role
  # lookup, no runtime, no model. `SenderSeed.ensure!/0` is idempotent and
  # is called here rather than assumed, so a boot that has not seeded yet
  # (the flag flipped on after start-up) still delivers.
  defp ensure_delivery_sender(%Platform.Chat.Space{id: space_id}) do
    {:ok, agent} = Platform.Meetings.SenderSeed.ensure!()

    Chat.add_agent_participant(space_id, agent, display_name: agent.name)
  end

  defp ensure_delivery_invitee(%Platform.Chat.Space{}, nil), do: {:error, :no_invitee_user}

  defp ensure_delivery_invitee(%Platform.Chat.Space{id: space_id}, user_id)
       when is_binary(user_id) do
    if Platform.UUID.valid?(user_id) do
      case Repo.get_by(Platform.Chat.Participant,
             space_id: space_id,
             participant_type: "user",
             participant_id: user_id
           ) do
        %Platform.Chat.Participant{} = existing ->
          {:ok, existing}

        nil ->
          Chat.add_participant(space_id, %{
            participant_type: "user",
            participant_id: user_id,
            joined_at: DateTime.utc_now()
          })
      end
    else
      {:error, :invalid_user_id}
    end
  end

  @doc """
  Resolve a guest-invite URL (URL `slug` + signed `token`) into the
  state a guest ingress LiveView needs to render.

  Encapsulates the branching the guest ingress LiveView needs:

    * `GuestInvite.verify/1` — signature + expiry check.
    * URL-vs-payload `meeting_slug` tampering guard — payload slug must
      equal the URL slug (else `{:error, :invalid}`).
    * The `meeting_invites` row check — revocation and the row's own
      expiry (see the section below).
    * Meeting resolution + `:chat_space` preload (a deleted meeting whose
      token was signed pre-deletion resolves to `{:error, :invalid}`).
    * Display-name branching — `nil` in the payload signals the
      self-entry flow (`:name_entry`), a non-empty binary lands the guest
      straight `:in_meeting`.

  ## How the meeting is resolved, and why it is not a slug lookup

  Possession of a valid token IS the authority here — that is the design,
  and it is a sound one (dedicated signing key, `Plug.Crypto` `max_age`,
  an independent payload expiry, and the slug tamper guard above). Guests
  have no org memberships by definition, so there is deliberately no
  membership check on this path.

  What the token did not do until task 019f9b14 stage 3 is name its
  subject unambiguously. `meetings` is only `unique_index(:meetings,
  [:project_id, :slug])`, so `standup` can exist in two projects in two
  different orgs. Resolving by slug alone therefore either raised
  `Ecto.MultipleResultsError` (a 500 on a public, unauthenticated
  ingress) or — had it been "fixed" by taking the first match — would
  have admitted a guest holding org A's token into org B's meeting and
  its LiveKit room.

  So:

    * Token carries `meeting_id` (every token minted since that stage):
      resolve by id, then require the loaded row's `slug` to equal the
      URL slug. The id makes the subject exact; the slug re-check is
      defence in depth against a payload whose two identifiers disagree.
    * Token carries no `meeting_id` (legacy, pre-stage tokens): fall back
      to `resolve_meeting_by_slug_unambiguous/1`, which returns the
      meeting on exactly one match and `{:error, :invalid}` on zero or
      two-plus. An ambiguous legacy token is refused rather than gambling
      on a project, and the lookup never raises. With the 24h default
      expiry these age out within a day.

  ## Revocation lives here, not in the token module (task 019fb954)

  An HMAC is stateless: once signed it verifies until its embedded
  expiry passes, and nothing can un-issue it. `GuestInvite.verify/2` is
  a pure function with no `Repo` access and must stay that way, so
  revocation cannot live there. This function is already the
  `Repo`-backed resolver, so the gate goes here — after the signature
  clears, before the meeting is resolved.

  A token minted by `invite_guest/2` names a `meeting_invites` row via
  `:invite_id`. That row is the authority on whether the link still
  works:

    * row missing — `{:error, :invalid}`. A token naming an invite that
      no longer exists is not a capability.
    * `revoked_at` set — `{:error, :revoked}`.
    * row's `expires_at` in the past — `{:error, :expired}`. The row is
      authoritative and the token carries only a copy, so tampering with
      neither alone extends access: the token's expiry is checked by
      `verify/2` and the row's is checked here.
    * row's `meeting_id` disagrees with the payload's — `{:error,
      :invalid}`. `nil` disagrees with a uuid, so a payload carrying an
      `invite_id` but no `meeting_id` (a shape `invite_guest/2` never
      produces) is refused too.

  Because the token names a ROW, revoking one guest is a single-row
  `UPDATE` and touches no shared secret. Do NOT ever implement guest
  revocation by rotating `:meeting_guest_signing_key` or by stamping
  anything on the meeting — either kills every outstanding guest link at
  once, which is the opposite of what this exists to do.

  `invite_id: nil` (every token minted before this task, including
  everything the guest-link mint site in `MeetingLive` still produces)
  skips the lookup entirely and behaves exactly as it did before. That
  compatibility branch is load-bearing until those tokens age out.

  `PlatformWeb.MeetingLive` (with `chrome_mode: :none` on the `meet.`
  host scope) mounts against this resolver so guest-surface behavior
  can't drift from what `Meetings` intends to return. It maps `:revoked`
  onto the same rendered outcome as `:invalid` — a revoked guest is told
  the link does not work, not that it *used* to.

  Return shape:

    * `{:ok, %{state: :name_entry, meeting: %Meeting{}}}` — token
      verified, payload carried `display_name: nil`. The returned
      meeting has `:chat_space` preloaded (later `mint_guest_join_bundle`
      + `guest_join_event_payload` read `meeting.chat_space.slug`).
    * `{:ok, %{state: :in_meeting, meeting: %Meeting{},
      display_name: binary()}}` — token verified, payload carried a
      pre-provisioned display name. Caller should call
      `mint_guest_join_bundle/2` next.
    * `{:error, :expired}` — token past its own `expires_at`, or the
      named invite row past the row's.
    * `{:error, :revoked}` — the named invite row carries a `revoked_at`.
    * `{:error, :invalid}` — signature/shape check failed, slug mismatch,
      the meeting slug no longer resolves, the named invite row is gone,
      or the row and the payload name different meetings.
  """
  @spec resolve_guest_invite(String.t(), String.t()) ::
          {:ok, %{state: :name_entry, meeting: Meeting.t()}}
          | {:ok, %{state: :in_meeting, meeting: Meeting.t(), display_name: String.t()}}
          | {:error, :invalid | :expired | :revoked}
  def resolve_guest_invite(slug, token) when is_binary(slug) and is_binary(token) do
    case GuestInvite.verify(token) do
      {:error, :expired} ->
        {:error, :expired}

      {:error, :invalid} ->
        {:error, :invalid}

      {:ok, %{meeting_slug: payload_slug}} when payload_slug != slug ->
        # Slug tampering: URL says one meeting, payload says another.
        # Treat as invalid rather than trusting the payload — the URL is
        # what the host shared with the guest.
        {:error, :invalid}

      {:ok, %{meeting_slug: ^slug, display_name: display_name} = payload} ->
        # The row gate runs BEFORE the meeting is resolved: a revoked
        # link should not so much as read the meeting it used to admit to.
        with :ok <- check_invite_row(payload) do
          case resolve_invited_meeting(payload, slug) do
            {:error, :invalid} ->
              # Signature checked out but the target meeting has been
              # deleted, never existed, or (legacy slug-only token) the
              # slug matches more than one meeting and we refuse to guess.
              {:error, :invalid}

            {:ok, meeting} when is_binary(display_name) ->
              {:ok, %{state: :in_meeting, meeting: meeting, display_name: display_name}}

            {:ok, meeting} ->
              {:ok, %{state: :name_entry, meeting: meeting}}
          end
        end
    end
  end

  # Legacy token (anything minted before task 019fb954, which is every
  # token in the wild plus everything the `MeetingLive` guest-link mint
  # site still produces): it names no row, so there is nothing to check
  # and the answer must be exactly what it was before this stage. No
  # lookup, no new error. `verify/2` normalises the key in, so this is
  # `nil`-valued rather than absent by the time it reaches here.
  defp check_invite_row(%{invite_id: nil}), do: :ok

  # Row-bound token. The row — not the signature, and not the copy of
  # `expires_at` baked into the payload — decides whether this link still
  # works. See the `## Revocation lives here` section on
  # `resolve_guest_invite/2` for why each branch answers what it does.
  defp check_invite_row(%{invite_id: invite_id} = payload) when is_binary(invite_id) do
    case get_invite(invite_id) do
      nil ->
        {:error, :invalid}

      %Invite{revoked_at: %DateTime{}} ->
        {:error, :revoked}

      %Invite{} = invite ->
        cond do
          invite_row_expired?(invite) -> {:error, :expired}
          invite.meeting_id != Map.get(payload, :meeting_id) -> {:error, :invalid}
          true -> :ok
        end
    end
  end

  # Boundary lookup. `invite_id` comes out of a token payload: the HMAC
  # proves the payload was minted by a holder of the signing key, it does
  # NOT prove the value is a uuid. `Platform.UUID.valid?/1` and NOT
  # `Ecto.UUID.cast/1` — a bare cast hex-encodes any 16-byte binary into a
  # well-formed but INVENTED uuid, and a fabricated id is the last thing
  # you want deciding whether a capability was revoked. A malformed id
  # answers nil here, which the caller folds to `{:error, :invalid}`,
  # rather than raising `Ecto.Query.CastError` out of a public,
  # unauthenticated ingress.
  defp get_invite(invite_id) do
    if Platform.UUID.valid?(invite_id), do: Repo.get(Invite, invite_id), else: nil
  end

  defp invite_row_expired?(%Invite{expires_at: nil}), do: false

  defp invite_row_expired?(%Invite{expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  # Id-bearing token: the payload names its subject exactly. Still require
  # the row's slug to match the URL slug the host actually shared.
  defp resolve_invited_meeting(%{meeting_id: meeting_id}, slug) when is_binary(meeting_id) do
    case get_meeting(meeting_id) do
      %Meeting{slug: ^slug} = meeting -> {:ok, Repo.preload(meeting, :chat_space)}
      _ -> {:error, :invalid}
    end
  rescue
    # A tampered-but-resigned payload could carry a non-UUID id. Ecto
    # raises on the cast rather than returning nil; a public ingress must
    # not 500 on that.
    #
    # As of task 019fa129 stage 4 this rescue is belt-and-braces: the lookup
    # above now goes through the guarded `get_meeting/1`, which returns nil.
    # Kept because it also covers a cast error raised by `Repo.preload/2`.
    Ecto.Query.CastError -> {:error, :invalid}
  end

  defp resolve_invited_meeting(_payload, slug), do: resolve_meeting_by_slug_unambiguous(slug)

  # Legacy (pre-019f9b14) slug-only token. `limit: 2` + `Repo.all` so 0 / 1 /
  # many are distinguishable without `Repo.get_by/3`'s
  # `Ecto.MultipleResultsError`. Safe-fail on both 0 and 2+: an ambiguous
  # token is refused, never resolved to an arbitrary project's meeting.
  defp resolve_meeting_by_slug_unambiguous(slug) when is_binary(slug) do
    Meeting
    |> where([m], m.slug == ^slug)
    |> limit(2)
    |> Repo.all()
    |> case do
      [meeting] -> {:ok, Repo.preload(meeting, :chat_space)}
      _none_or_ambiguous -> {:error, :invalid}
    end
  end

  @doc """
  Mint a LiveKit join bundle for a guest in the given meeting.

  Thin, name-stable alias over `guest_livekit_token/2` — introduced
  during the shellless-meeting consolidation so the guest ingress in
  `MeetingLive` (under `chrome_mode: :none`) has a "mint bundle" call
  name that names its intent. Returns
  `{:ok, %{token, identity, room_name, livekit_url}}`.
  """
  @spec mint_guest_join_bundle(Meeting.t(), String.t()) ::
          {:ok,
           %{
             token: String.t(),
             identity: String.t(),
             room_name: String.t(),
             livekit_url: String.t() | nil
           }}
          | {:error, :livekit_not_configured | :missing_display_name}
  def mint_guest_join_bundle(%Meeting{} = meeting, display_name),
    do: guest_livekit_token(meeting, display_name)

  @doc """
  Build the `join-meeting` push_event payload for a guest.

  Returns the exact map `MeetingClient` (see meeting_client.js) consumes
  today: `token` + `url` are load-bearing; `room_name` + `space_slug` are
  surfaced for parity with the authenticated path and to aid debug
  logs. Kept public so `MeetingLive`'s guest branch can push the same
  shape without duplicating the map literal at the call site.
  """
  @spec guest_join_event_payload(
          %{
            required(:token) => String.t(),
            required(:livekit_url) => String.t() | nil,
            required(:room_name) => String.t(),
            optional(any()) => any()
          },
          Meeting.t()
        ) :: %{
          token: String.t(),
          url: String.t() | nil,
          room_name: String.t(),
          space_slug: String.t() | nil
        }
  def guest_join_event_payload(bundle, %Meeting{} = meeting) do
    %{
      token: bundle.token,
      url: bundle.livekit_url,
      room_name: bundle.room_name,
      space_slug: meeting.chat_space && meeting.chat_space.slug
    }
  end

  defp maybe_put_org_id(attrs, nil), do: attrs
  defp maybe_put_org_id(attrs, org_id) when is_binary(org_id), do: Map.put(attrs, :org_id, org_id)

  defp resolve_meeting_org_id(%Meeting{project_id: nil}), do: nil

  defp resolve_meeting_org_id(%Meeting{project_id: project_id}) when is_binary(project_id) do
    case Repo.get(Platform.Tasks.Project, project_id) do
      %Platform.Tasks.Project{org_id: org_id} -> org_id
      _ -> nil
    end
  end

  # ── Invites (task 019fb954) ──────────────────────────────────────────────
  #
  # "Invited" used to be an inference: `MeetingNotifier` derived recipients
  # from the human participants of the meeting's backing chat space. You could
  # therefore not invite anyone who was not already in that space, nor invite
  # anyone *before* that membership existed. `meeting_invites` is the
  # declaration; these four functions are the whole public surface over it.
  #
  # THE GUEST TOKEN BINDS TO THE ROW, NOT TO THE MEETING. `invite_guest/2`
  # mints exactly one token per `meeting_invites` row, and there is
  # deliberately NO meeting-wide invite-link function on this module. A single
  # forwardable link is unattributable: whoever walks through it cannot be told
  # apart from anyone else who was handed the same string, so their speech has
  # no speaker in the transcript and any action item extracted from it has no
  # principal to land on. Per-row tokens also make revocation granular — an
  # issued HMAC cannot be un-issued, so `revoke_invite/1` stamping one row is
  # the only way to kill one guest's link without invalidating every other
  # guest's at the same time. Do not add a `meeting_invite_link/1`.

  # Guest links expire in 24h unless the caller says otherwise, matching
  # `GuestInvite`'s own `@default_expiry_seconds` so the row's `expires_at`
  # (authoritative) and the token payload's copy agree by construction.
  @guest_invite_default_expiry_hours 24

  @doc """
  The expiry, in hours, `invite_guest/2` mints a link with when the caller
  names none.

  Exposed so a UI that PROMISES an expiry before the row exists — the
  create sheet stages guests and mints nothing until submit — reads the
  number it will actually get instead of restating it. Two copies of a
  policy number drift, and the drifting copy is the one a user reads.
  """
  @spec guest_invite_default_expiry_hours() :: pos_integer()
  def guest_invite_default_expiry_hours, do: @guest_invite_default_expiry_hours

  @doc """
  Declare a user as an invitee of `meeting`.

  Serves BOTH account-holding kinds. An internal user and an external
  qualified user produce the same row — external-ness is not stored here, it
  is a property of the user's org membership (`org_memberships.external`),
  which `Platform.Accounts.ExternalAdmission.admit/2` already wrote. This
  function deliberately does not re-check that membership: an invite is a
  *declaration*, admission is a separate gate, and conflating them would mean
  a host could not name someone before their access was provisioned — the
  exact limitation this table exists to remove.

  Idempotent on the partial `unique_index(:meeting_invites, [:meeting_id,
  :user_id])`: re-inviting returns the EXISTING row as `{:ok, invite}` rather
  than an error, so a double-submit does not 500 a caller. The insert is still
  attempted and its constraint error still handled, so two concurrent callers
  race to the same row instead of one of them blowing up.

  Options: `:display_name`, `:email` — both optional, both pass-through. The
  user's own record is authoritative for their name, so these are only useful
  when the host wants to record what they typed.

  A `user_id` that is not a well-formed UUID answers `{:error, changeset}` with
  the error on `:user_id`. It is checked with `Platform.UUID.valid?/1` before
  any query: `Repo.get_by/2` RAISES `Ecto.Query.CastError` on a malformed id
  rather than returning nil, and the host-facing UI downstream of this
  function will hand it a value straight out of a LiveView `params` map. An
  `Ecto.UUID.cast/1` guard would NOT do — it hex-encodes any 16-byte binary
  into a well-formed but invented UUID (see `RepoLookupBoundaryTest`).
  """
  @spec invite_user(Meeting.t(), binary(), keyword()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t()}
  def invite_user(%Meeting{} = meeting, user_id, opts \\ []) when is_binary(user_id) do
    attrs = %{
      meeting_id: meeting.id,
      user_id: user_id,
      display_name: Keyword.get(opts, :display_name),
      email: Keyword.get(opts, :email)
    }

    if Platform.UUID.valid?(user_id) do
      case upsert_user_invite(meeting, user_id, attrs) do
        {:ok, %Invite{} = invite} ->
          deliver_invite(invite, meeting)
          {:ok, invite}

        {:error, _changeset} = error ->
          error
      end
    else
      {:error,
       %Invite{}
       |> Invite.changeset(Map.delete(attrs, :user_id))
       |> Ecto.Changeset.add_error(:user_id, "is invalid")}
    end
  end

  defp upsert_user_invite(%Meeting{} = meeting, user_id, attrs) do
    case Repo.get_by(Invite, meeting_id: meeting.id, user_id: user_id) do
      %Invite{} = existing ->
        {:ok, existing}

      nil ->
        %Invite{}
        |> Invite.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, invite} ->
            {:ok, invite}

          {:error, changeset} ->
            # Lost a race with a concurrent invite of the same user: the
            # unique index fired between our lookup and our insert. The row
            # the other caller wrote is the answer, not an error.
            case Repo.get_by(Invite, meeting_id: meeting.id, user_id: user_id) do
              %Invite{} = existing -> {:ok, existing}
              nil -> {:error, changeset}
            end
        end
    end
  end

  @doc """
  Declare a guest — someone with no account — as an invitee, and mint the
  signed link that lets them in.

  Returns `{:ok, %{invite: %Invite{}, token: binary, url: binary}}`.

  `display_name` is required. The database's `meeting_invites_identity_check`
  enforces it (a row with neither `user_id` nor `display_name` is an
  unattributable invite), but it is validated in the changeset too so the
  caller gets `{:error, changeset}` instead of a raised `Postgrex.Error`.

  Optional `email` — the only address a guest can be reached at, since they
  have no account. Optional `expires_in_hours`, defaulting to
  #{@guest_invite_default_expiry_hours}.

  ## Order of operations, and why

  The row is inserted FIRST so its id exists to sign into the token. Then a
  per-invite guest chat space (`create_guest_chat_space/2` — identity
  bookkeeping, NOT the LiveKit routing space) and finally the token, carrying
  `invite_id`. That ordering is what makes the token revocable: the id it
  names is already durable when the signature is computed, so
  `revoke_invite/1` has a row to stamp and the resolver has a row to check.

  `expires_at` is written to the row AND copied into the token payload. The
  row is authoritative — a token's expiry cannot be shortened after issue,
  the row's can.

  One call, one row, one token. Calling this twice for two guests on one
  meeting yields two distinct tokens; there is no shared meeting-wide link
  (see the section comment above for why that matters).
  """
  @spec invite_guest(Meeting.t(), map() | keyword()) ::
          {:ok, %{invite: Invite.t(), token: binary(), url: binary()}}
          | {:error, Ecto.Changeset.t() | atom() | term()}
  def invite_guest(%Meeting{} = meeting, attrs) do
    if GuestInvite.guest_host_configured?() do
      do_invite_guest(meeting, attrs)
    else
      # Gate BEFORE any write. A row inserted here, or a guest chat space
      # minted here, would be an orphan: nothing can ever hand out a link
      # to it. Failing closed means no invite, no space, no token.
      Logger.warning(
        "refusing to mint a guest invite for meeting #{meeting.id}: " <>
          ":meeting_guest_host is not configured (set MEETING_GUEST_HOST)"
      )

      {:error, :guest_host_not_configured}
    end
  end

  defp do_invite_guest(%Meeting{} = meeting, attrs) do
    attrs = normalize_attrs(attrs)

    hours = Map.get(attrs, :expires_in_hours) || @guest_invite_default_expiry_hours
    expires_at = DateTime.add(DateTime.utc_now(), trunc(hours * 3600), :second)
    display_name = Map.get(attrs, :display_name)

    changeset =
      %Invite{}
      |> Invite.changeset(%{
        meeting_id: meeting.id,
        display_name: display_name,
        email: Map.get(attrs, :email),
        expires_at: expires_at
      })
      |> Ecto.Changeset.validate_required([:display_name])

    with {:ok, invite} <- Repo.insert(changeset),
         {:ok, guest_space} <-
           create_guest_chat_space(meeting, Map.get(attrs, :host_user_id)) do
      token =
        GuestInvite.sign(
          meeting.slug,
          DateTime.to_unix(expires_at),
          invite.display_name,
          guest_space_id: guest_space.id,
          meeting_id: meeting.id,
          # The whole point: this token names ONE row, so it can be revoked
          # on its own.
          invite_id: invite.id
        )

      deliver_invite(invite, meeting)

      {:ok, %{invite: invite, token: token, url: guest_invite_url(meeting, token)}}
    end
  end

  @doc """
  The personal join URL for a guest invite ROW that already exists.

  `invite_guest/2` returns a token once, at mint time, and nothing stores
  it — a signed token is a capability, not a record. The detail panel has
  to answer "what link do I send this person?" long after that call
  returned, so the answer is re-derived from the row rather than looked
  up.

  ## Re-minting is not re-issuing

  The new token carries a fresh `signed_at` and is therefore a different
  STRING from the one the host got at mint time, but it names the same
  `meeting_invites` row and the same expiry. Both links live and die
  together: `resolve_guest_invite/2` gates on the ROW's `revoked_at` and
  the ROW's `expires_at`, so revoking the invite kills every token ever
  minted for it. There is no way for this function to widen access — it
  can only restate a capability the row already grants.

  Two guests therefore still get two links that cannot be swapped: each
  token verifies back to its OWN `invite_id`, which is exactly the
  property a meeting-wide link destroys.

  ## `guest_space_id` is deliberately absent

  `invite_guest/2` signs the id of the per-link guest chat space it mints.
  Nothing in the codebase READS that key back out — `verify/2` normalises
  it and every consumer ignores it — and the invite row does not record
  which space it was, so there is nothing to re-sign here and no observable
  difference from omitting it. Recorded rather than papered over: if a
  reader for it ever lands, this function needs a persisted id first.

  ## Guest rows only

  There is no clause for an account-holding invitee (`user_id` set) or for
  an external row awaiting a grant (`expires_at` nil): neither has a signed
  link, so asking for one is a caller bug. It raises `FunctionClauseError`
  naming the shape rather than returning a URL that cannot admit anyone.

  ## No host, no link

  Returns `nil` when `:meeting_guest_host` is unset or blank. The caller
  (`MeetingLive`'s copy control) already treats `nil` as "this row has no
  link to copy", which is the truth in an environment where guest links
  do not resolve anywhere. Interpolating a `nil` host would yield
  `https:///slug/token` — malformed but still minted, which is not
  failing closed.
  """
  @spec guest_invite_link(Meeting.t(), Invite.t()) :: String.t() | nil
  def guest_invite_link(
        %Meeting{id: meeting_id} = meeting,
        %Invite{
          meeting_id: meeting_id,
          user_id: nil,
          expires_at: %DateTime{} = expires_at
        } = invite
      ) do
    token =
      GuestInvite.sign(
        meeting.slug,
        DateTime.to_unix(expires_at),
        invite.display_name,
        meeting_id: meeting.id,
        invite_id: invite.id
      )

    guest_invite_url(meeting, token)
  end

  # ── External invites (task 019fb955-1d7b, stage 2) ───────────────────────
  #
  # One input from the host's picker has to answer three questions — is this
  # a member, an external account-holder, or a stranger — and the stranger
  # branch has to survive a unique index that bites on the SECOND meeting,
  # not the first. `resolve_invite_candidates/2` answers the first question;
  # `invite_external_user/3` acts on the other two.

  # Deliberately the SAME predicate `Platform.Accounts.User.changeset/2`
  # validates `:email` with. The picker must not offer an address the
  # account schema would later refuse — that would be an invite that can
  # never resolve to a login.
  @invite_email_format ~r/^[^\s]+@[^\s]+$/

  @doc """
  Resolve one picker query into the two things a host may act on: the
  account-holders it matches, and — **only when it matches none** — the
  external address it could be.

  Returns `%{users: [User.t()], email: binary() | nil}`.

  ## The two are mutually exclusive by construction

  A query that matches a member must never also offer "invite as external
  guest": the host picks the wrong one, and a colleague who already has an
  account gets a staged external grant instead of the membership they
  have. Making that impossible in a template `:if` is one edit away from
  regressing, so it is enforced structurally here — `guest_option/3`
  dispatches on the users list and the non-empty head returns `nil` before
  the address is ever examined. There is no code path that populates both.

  ## Search is not re-implemented

  `users` comes from `Platform.Accounts.list_users/1`, which already ilikes
  name OR email and already drops `archived_at` rows. This mirrors
  `PlatformWeb.Live.Chat.NewConversationComponent`'s picker: the same
  server-side filter runs on open and on every keystroke, so a second
  search with its own drift is neither needed nor wanted.

  ## Options

    * `:exclude_user_ids` — user ids already invited or staged in this
      picker session. Dropped from `users`.
    * `:exclude_emails` — addresses already invited or staged. Dropped from
      `users` (matching on `User.email`) **and** suppressed as the `:email`
      option, so the same person cannot be added twice from either side of
      the fork.
  """
  @spec resolve_invite_candidates(binary() | nil, keyword()) ::
          %{users: [User.t()], email: binary() | nil}
  def resolve_invite_candidates(query, opts \\ []) do
    trimmed = query |> to_string() |> String.trim()

    excluded_ids = opts |> Keyword.get(:exclude_user_ids, []) |> MapSet.new()

    excluded_emails =
      opts
      |> Keyword.get(:exclude_emails, [])
      |> Enum.map(&String.trim(to_string(&1)))
      |> MapSet.new()

    matched = Accounts.list_users(query: trimmed)

    users =
      Enum.reject(matched, fn user ->
        MapSet.member?(excluded_ids, user.id) or MapSet.member?(excluded_emails, user.email)
      end)

    # The guest option is decided against the UNFILTERED match set, not the
    # post-exclusion one. Otherwise excluding an already-invited member
    # empties `users` and the fork re-opens on their own address — offering
    # to stage an external grant for a colleague who has an account. The
    # invariant is "this query matches a member", which exclusion does not
    # change.
    %{users: users, email: guest_option(trimmed, matched, excluded_emails)}
  end

  # A match on a member forecloses the external option. This head is the
  # enforcement — not a caller-side check.
  defp guest_option(_trimmed, [_ | _], _excluded), do: nil

  defp guest_option(trimmed, [], excluded) do
    if Regex.match?(@invite_email_format, trimmed) and
         not MapSet.member?(excluded, trimmed) do
      trimmed
    else
      nil
    end
  end

  @doc """
  Invite an email address that the host typed rather than picked, staging
  whatever access the invitee will need to actually arrive.

  Returns `{:ok, %Invite{}}` or `{:error, changeset | reason}`.

  ## Why a real grant row, not a note-to-self

  `PlatformWeb.Plugs.ExternalUserScope` is a fail-closed allowlist. An
  external user who signs in carrying no grant lands in the external
  holding view and can never reach `/meetings/:slug` — so an invite that
  merely *records intent* is an invite guaranteed to fail at the door.
  A staged `pending_external_grants` row is the least privilege this
  system can express (one space, role `member`, empty DM allowlist), and
  `Platform.Tenancy.ExternalGrants.apply_grant/2` materializes it on first
  login with no admin step in between. That is what lets the dropdown stay
  open to every host instead of routing through an operator.

  ## Three branches, one address

    1. **The address already has a `users` row.** Delegate to
       `invite_user/3` (idempotent on `[:meeting_id, :user_id]`) and seat
       them in this meeting's chat space with
       `ExternalGrants.add_space_participants/2`. That helper exists
       precisely so an already-provisioned external user does not get a
       second grant row — see its docstring; do not re-derive it.

    2. **No user, but a grant row exists for the address.** Widen the grant
       on file via `ExternalGrants.add_pending_space_grant/2` rather than
       inserting a second one.

    3. **Neither.** `ExternalGrants.create_grant/1` at the least-privileged
       shape, `target_org_id` resolved meeting -> project -> org.

  ## The index that forces branches 2 and 3 apart

  `pending_external_grants` carries `unique_index([:email]) WHERE email IS
  NOT NULL`, and it is **not** partial on `applied_at`. An applied grant
  still occupies the slot. So a naive `create_grant/1` for the same address
  on a SECOND meeting violates the index — and keeps violating it forever
  once the first grant has been applied.

  The branch is taken on `ExternalGrants.get_grant_by_email/1`, NOT on
  `lookup_by_email_or_sub/1`. The latter filters `applied_at IS NULL` and
  is therefore blind to exactly the rows that would kill the insert;
  branching on it is fail-open.

  ## The invite row

  Written in all three branches, because an invitee who does not render is
  not invited. Branch 1 sets `user_id`. Branches 2 and 3 write `email`
  with `user_id` NULL, `expires_at` NULL and no token — this is an
  external invite awaiting a login, NOT a guest with a signed link.

  Two consequences worth naming:

    * `display_name` is set (defaulting to the address) because
      `meeting_invites_identity_check` requires `user_id IS NOT NULL OR
      display_name IS NOT NULL`. An email-only row with a NULL
      `display_name` raises `Postgrex.Error`; it is not a legal row.
    * `Invite.kind/1` returns `:guest` for this row, since it dispatches on
      `user_id: nil`. Any UI tag distinguishing external-invite from guest
      must therefore NOT be derived from `kind/1` alone.

  Idempotent per `[meeting_id, email]`: there is no unique index covering
  that pair (the one on the table is partial on `user_id IS NOT NULL`, so
  it does not constrain these rows), so re-invites are deduped by lookup
  before insert.

  ## Options

    * `:display_name` — what the host typed, if anything. Defaults to the
      address.
  """
  @spec invite_external_user(Meeting.t(), binary(), keyword()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | term()}
  def invite_external_user(%Meeting{} = meeting, email, opts \\ []) when is_binary(email) do
    address = String.trim(email)
    space_grant = %{"space_id" => meeting.chat_space_id, "role" => "member"}

    case Repo.get_by(User, email: address) do
      %User{} = user ->
        # Branch 1. Seat them BEFORE the invite row so the delivery that
        # `invite_user/3` runs in-line has a space the recipient is in.
        with :ok <- ExternalGrants.add_space_participants(user, [space_grant]) do
          invite_user(meeting, user.id, Keyword.put(opts, :email, address))
        end

      nil ->
        with {:ok, _grant} <- stage_external_grant(meeting, address, space_grant) do
          upsert_external_invite(meeting, address, opts)
        end
    end
  end

  # Branches 2 and 3. Reads through `get_grant_by_email/1` — the
  # applied-blind `lookup_by_email_or_sub/1` would return nil for a row
  # that still owns the unique-index slot.
  defp stage_external_grant(%Meeting{} = meeting, address, space_grant) do
    case ExternalGrants.get_grant_by_email(address) do
      %PendingExternalGrant{} = grant ->
        ExternalGrants.add_pending_space_grant(grant, space_grant)

      nil ->
        ExternalGrants.create_grant(%{
          email: address,
          target_org_id: external_grant_org_id!(meeting),
          space_grants: [space_grant],
          dm_allowlist_org_ids: [],
          applied_at: nil
        })
    end
  end

  # `target_org_id` is NOT NULL and a grant staged into the wrong org is a
  # silent privilege error, so an unresolvable org RAISES rather than
  # defaulting. `meetings.project_id` is NOT NULL with an FK, so reaching
  # here means the project carries no `org_id` — a broken row, not a case
  # to paper over.
  defp external_grant_org_id!(%Meeting{} = meeting) do
    case resolve_meeting_org_id(meeting) do
      org_id when is_binary(org_id) ->
        org_id

      nil ->
        raise ArgumentError,
              "cannot stage an external grant for meeting #{meeting.id}: " <>
                "its project resolves to no org_id"
    end
  end

  # No unique index covers [meeting_id, email] for user_id-NULL rows, so
  # dedupe is a lookup. Scoped to `is_nil(user_id)` on purpose: branch 1
  # writes a row carrying BOTH a user_id and this address, and that row is
  # a different invite with a different owner.
  defp upsert_external_invite(%Meeting{} = meeting, address, opts) do
    result =
      Invite
      |> where([i], i.meeting_id == ^meeting.id and i.email == ^address and is_nil(i.user_id))
      |> order_by([i], asc: i.inserted_at)
      |> limit(1)
      |> Repo.one()
      |> case do
        %Invite{} = existing ->
          {:ok, existing}

        nil ->
          %Invite{}
          |> Invite.changeset(%{
            meeting_id: meeting.id,
            email: address,
            display_name: Keyword.get(opts, :display_name) || address
          })
          |> Repo.insert()
      end

    with {:ok, invite} <- result do
      deliver_invite(invite, meeting)
      {:ok, invite}
    end
  end

  @doc """
  Build the calendar-link path for `meeting`.

  Returns a PATH, not a URL — no scheme, no host. `core` is a public
  repository and nothing here hardcodes or threads a hostname; the caller
  that renders this into a UI or a message is responsible for absolutising
  it against its own endpoint.

  The token is a per-MEETING bearer capability minted by
  `Platform.Meetings.CalendarLink` — one meeting, one link, no expiry.
  Contrast `invite_guest/2`, whose token is per-invite and admits to a
  room; this one discloses calendar metadata only.
  """
  @spec calendar_link_path(Meeting.t()) :: String.t()
  def calendar_link_path(%Meeting{id: id}) when is_binary(id) do
    "/meetings/#{id}/invite.ics?token=#{CalendarLink.sign(id)}"
  end

  # Delivery runs SYNCHRONOUSLY AND IN-LINE on the success path of both
  # invite functions — not as a PubSub broadcast consumed by a GenServer.
  # "Cannot fail for want of a role" means the send sits in the same call
  # stack as the insert, with no runtime, no dispatcher and no role lookup
  # in between; a dropped subscription is invisible.
  #
  # It is a side effect and stays one: it never changes either function's
  # return shape, and a raise inside it never turns a committed invite row
  # into an error for the caller. Same posture as
  # `MeetingNotifier.emit_inbox_row/4`.
  defp deliver_invite(%Invite{} = invite, %Meeting{} = meeting) do
    InviteDelivery.deliver(invite, meeting)
  rescue
    error ->
      Logger.warning(
        "[Meetings] invite delivery raised — invite=#{invite.id} " <>
          "meeting=#{meeting.id}: #{inspect(error)}"
      )

      {:error, :delivery_raised}
  end

  @doc """
  List a meeting's declared invitees, oldest first.

  `include_revoked: false` by default — a revoked invitee is not an invitee,
  and every reader in v1 (the notifier above all) wants the live set. Pass
  `include_revoked: true` for an audit view.

  Ordered by `inserted_at`, with `id` as a tiebreak so the order is total
  rather than merely usually-stable; ids are UUIDv7, so the tiebreak sorts the
  same direction as the timestamp.

  A malformed `meeting_id` answers `[]`. `where: i.meeting_id == ^meeting_id`
  pins a UUID column, so it raises `Ecto.Query.CastError` on a bad id exactly
  as `Repo.get/2` would — an empty invitee list is the same answer the query
  would give for any id that names no meeting.
  """
  @spec list_invites(binary(), keyword()) :: [Invite.t()]
  def list_invites(meeting_id, opts \\ [])

  def list_invites(meeting_id, opts) when is_binary(meeting_id) do
    if Platform.UUID.valid?(meeting_id) do
      do_list_invites(meeting_id, opts)
    else
      []
    end
  end

  defp do_list_invites(meeting_id, opts) do
    query =
      from(i in Invite,
        where: i.meeting_id == ^meeting_id,
        order_by: [asc: i.inserted_at, asc: i.id]
      )

    query =
      if Keyword.get(opts, :include_revoked, false) do
        query
      else
        exclude_revoked(query)
      end

    Repo.all(query)
  end

  # The single definition of "not revoked" on this module. `do_list_invites/2`
  # and `active_invite_query/1` both compose it, so a change to what revocation
  # means cannot land in the listing and miss the access gate.
  defp exclude_revoked(query), do: from(i in query, where: is_nil(i.revoked_at))

  @doc """
  Does `user` hold a live invite to a meeting with this `slug`?

  The route-level half of external meeting access. `invited_to_space?/2` below
  answers the same question keyed on the meeting's backing chat space.

  ## Why this keys on the INVITE ROW and not on space membership

  `invite_external_user/3` already seats the invitee in `meeting.chat_space_id`,
  and `fetch_meeting_for_user/2` already authorises external users through
  `Chat.ExternalScope.visible_space_id?/2` against that participant row. So
  membership is the SECOND layer and it runs AFTER this one — the two are ANDed
  by being in series, and this function supplies the part membership cannot
  express.

  The direction that matters is revocation. `revoke_invite/1` stamps
  `revoked_at` and deliberately does NOT delete the participant row (the row is
  evidence, and tearing down space membership is a separate decision with its
  own blast radius). A membership-keyed gate would therefore keep admitting a
  revoked invitee forever. Keying on the row makes revocation effective at the
  route.

  The opposite divergence — an invite whose space grant never applied — fails
  safe: this function admits, `fetch_meeting_for_user/2` denies, nothing leaks.

  Do NOT relax this into `invited? or member?`. An OR reinstates exactly the
  revoked invitee the row check exists to exclude.

  ## Why the email disjunct is load-bearing rather than defensive

  `invite_external_user/3` writes `user_id: nil` plus `email` for an invitee who
  has no account yet, and stages a pending grant.
  `Platform.Accounts.ExternalAdmission` applies that grant at first login —
  minting the user, the external org membership and the chat participant row —
  but NOTHING backfills `meeting_invites.user_id`. A gate keyed on `user_id`
  alone would deny precisely the flow this stack was built for: invite an
  address, they log in, they attend. Hence the `is_nil(i.user_id) and
  lower(email) = lower(email)` branch, matched case-insensitively because
  neither column is normalised on write.

  Backfilling `user_id` at admission is NOT the fix: that is a shared login path
  owned by another stack, and it puts a write on a read gate.

  ## No slug resolution happens here

  `meetings.slug` is unique per PROJECT only (`unique_index(:meetings,
  [:project_id, :slug])`), so there is no such thing as "the meeting with this
  slug" — a slug-only `Repo.get_by/2` raises `Ecto.MultipleResultsError` the
  moment two projects pick the same one. The whole question is therefore asked
  as a single `Repo.exists?` over a join: does ANY live invite addressed to this
  user hang off ANY meeting carrying this slug? Existence is well-defined where
  identity is not.

  ## Totality

  Callers pass values straight off a session assign and a URL segment, so this
  answers `false` rather than raising for a nil or non-binary slug, a nil user,
  a user without a binary `:id`, and a user whose `:email` is nil — the last by
  building the query WITHOUT the email disjunct rather than letting `lower(NULL)`
  into SQL. `slug` is a plain string column, so no UUID cast is reachable.
  """
  @spec invited_to_slug?(term(), term()) :: boolean()
  def invited_to_slug?(slug, %{id: user_id} = user)
      when is_binary(slug) and is_binary(user_id) do
    user
    |> active_invite_query()
    |> where([_i, m], m.slug == ^slug)
    |> Repo.exists?()
  end

  def invited_to_slug?(_slug, _user), do: false

  @doc """
  Does `user` hold a live invite to the meeting backed by this chat space?

  Same predicate as `invited_to_slug?/2` — same rows, same liveness conditions,
  same email disjunct — asked with the meeting identified by
  `meetings.chat_space_id` instead of by slug. The join seam that consumes it
  has a space id in hand and no slug.

  `chat_space_id` is a uuid column, so a malformed id is filtered with
  `Platform.UUID.valid?/1` before it reaches `Repo` — the same guard
  `list_invites/2` uses — because a cast failure inside the query raises
  `Ecto.Query.CastError` instead of answering the boolean the caller asked for.

  A space that backs no meeting answers `false`: the join finds no meeting row,
  so there is nothing for the invite to hang off.
  """
  @spec invited_to_space?(term(), term()) :: boolean()
  def invited_to_space?(space_id, %{id: user_id} = user)
      when is_binary(space_id) and is_binary(user_id) do
    if Platform.UUID.valid?(space_id) do
      user
      |> active_invite_query()
      |> where([_i, m], m.chat_space_id == ^space_id)
      |> Repo.exists?()
    else
      false
    end
  end

  def invited_to_space?(_space_id, _user), do: false

  # The conditions shared by both entry points: a live invite row, joined to
  # its meeting, addressed to this user. The caller adds the clause that picks
  # the meeting out.
  #
  # The email disjunct is omitted entirely when the account carries no address,
  # rather than being compared against a nil parameter — `lower(NULL) =
  # lower(NULL)` is NULL, not true, but a nil binding also has no inferrable
  # type for the parameter, which is a raise rather than a `false`.
  defp active_invite_query(user) do
    user_id = user.id

    query =
      from(i in Invite,
        join: m in Meeting,
        on: m.id == i.meeting_id,
        where: is_nil(i.expires_at) or i.expires_at > ^DateTime.utc_now()
      )
      |> exclude_revoked()

    case Map.get(user, :email) do
      email when is_binary(email) ->
        where(
          query,
          [i, _m],
          i.user_id == ^user_id or
            (is_nil(i.user_id) and fragment("lower(?) = lower(?)", i.email, ^email))
        )

      _ ->
        where(query, [i, _m], i.user_id == ^user_id)
    end
  end

  @doc """
  Revoke an invite, by struct or by id. Returns `{:ok, invite}` with
  `revoked_at` stamped, or `{:error, :not_found}` for an unknown id.

  Idempotent, and idempotent against the ROW rather than against the struct
  the caller happens to be holding: the update is guarded by `is_nil(
  revoked_at)` in SQL, so a second revoke — even one passing a stale struct
  loaded before the first — returns the row with its ORIGINAL `revoked_at`
  rather than re-stamping it. That matters because `revoked_at` is evidence of
  when access was cut; silently moving it forward would rewrite that record.

  A malformed id answers `{:error, :not_found}` — the site's existing miss
  return — rather than raising. Both the guarded `UPDATE ... WHERE id = $1`
  and the `Repo.get/2` behind it pin a UUID column and so raise
  `Ecto.Query.CastError` on a bad id, and the revoke control that will call
  this is a `phx-value-` attribute: attacker-supplied by definition.
  """
  @spec revoke_invite(Invite.t() | binary()) :: {:ok, Invite.t()} | {:error, :not_found}
  def revoke_invite(%Invite{id: id}), do: revoke_invite(id)

  def revoke_invite(invite_id) when is_binary(invite_id) do
    if Platform.UUID.valid?(invite_id) do
      do_revoke_invite(invite_id)
    else
      {:error, :not_found}
    end
  end

  defp do_revoke_invite(invite_id) do
    now = DateTime.utc_now()

    query =
      from(i in Invite,
        where: i.id == ^invite_id and is_nil(i.revoked_at),
        select: i
      )

    case Repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, [invite]} ->
        {:ok, invite}

      {0, _} ->
        case Repo.get(Invite, invite_id) do
          %Invite{} = already_revoked -> {:ok, already_revoked}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc """
  Resolve who should be notified about `meeting`, and say which rule answered.

  Returns

      %{
        source: :invites | :chat_participants,
        user_ids: [binary()],
        chat_participants: [Platform.Chat.Participant.t()],
        invitee_count: non_neg_integer()
      }

  ## Why this is a context function and not private to `MeetingNotifier`

  The notifier is a supervised GenServer, so a rule living inside it can only
  be tested by booting it under `start_supervised/1` inside the Ecto sandbox
  and inferring the rule from its side effects. A plain context function is
  callable directly, which is what lets the fallback below be pinned on its
  own terms rather than through an inbox emit.

  ## The empty-invite fallback is the production path, not an edge case

  Every meeting that existed before `meeting_invites` has zero invite rows, and
  will keep having zero until a host declares one. So the `[]` branch has to
  reproduce the previous behaviour EXACTLY — `Chat.list_participants(
  chat_space_id, participant_type: "user")`, host dropped by chat-participant
  ROW id. If it does not, every pre-existing meeting silently stops notifying:
  an empty recipient list raises nothing, logs no error, and returns `:ok`.

  That is why `user_ids` on this branch is a bare `Enum.map/2` over
  `participant_id` with no `uniq/1` and no nil rejection. Both would look like
  tidying and neither is: they would change what the only path production
  currently takes does. Filtering belongs on the `:invites` branch, which is
  new and has no behaviour to preserve.

  ## `:invites` deliberately carries no chat participants

  `chat_participants: []` on the invite branch is not an omission. The point of
  a declared invitee set is that an invitee need not be in the meeting's chat
  space at all, so a caller reaching for a chat-participant row here would be
  reintroducing the bug this table exists to fix. There is nothing to hand it.

  `user_ids` excludes the host, resolved from `host_participant_id` — for a
  `participant_type: "user"` chat row, `participant_id` holds the `users.id`.
  A host does not need to be told about their own meeting.

  `invitee_count` counts every non-revoked invite except a host self-invite,
  **guests included**. A guest is an invitee even though they get no push and
  no inbox row (they have no account; their channel is the per-invite link), so
  the "N invited" a recipient reads has to match the list the host typed. It is
  therefore NOT `length(user_ids)`, and the two genuinely differ whenever a
  guest is invited.
  """
  @spec recipients_for_meeting(Meeting.t()) :: %{
          source: :invites | :chat_participants,
          user_ids: [binary()],
          chat_participants: [Chat.Participant.t()],
          invitee_count: non_neg_integer()
        }
  def recipients_for_meeting(%Meeting{} = meeting) do
    case list_invites(meeting.id) do
      [] -> recipients_from_chat_participants(meeting)
      invites -> recipients_from_invites(meeting, invites)
    end
  end

  defp recipients_from_chat_participants(%Meeting{} = meeting) do
    chat_participants = Chat.list_participants(meeting.chat_space_id, participant_type: "user")

    non_host = Enum.reject(chat_participants, &(&1.id == meeting.host_participant_id))

    %{
      source: :chat_participants,
      user_ids: Enum.map(non_host, & &1.participant_id),
      chat_participants: chat_participants,
      invitee_count: length(non_host)
    }
  end

  defp recipients_from_invites(%Meeting{} = meeting, invites) do
    host_user_id = host_user_id(meeting)

    non_host_invites =
      Enum.reject(invites, fn invite ->
        not is_nil(host_user_id) and invite.user_id == host_user_id
      end)

    user_ids =
      non_host_invites
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      source: :invites,
      user_ids: user_ids,
      chat_participants: [],
      invitee_count: length(non_host_invites)
    }
  end

  # Resolved by query rather than off a preload: callers hand us whatever
  # `%Meeting{}` they are holding, and a `%Ecto.Association.NotLoaded{}` here
  # would silently read as "no host" — which quietly re-invites the host.
  defp host_user_id(%Meeting{host_participant_id: nil}), do: nil

  defp host_user_id(%Meeting{host_participant_id: participant_id}) do
    case Chat.get_participant(participant_id) do
      %Chat.Participant{participant_type: "user", participant_id: user_id} -> user_id
      _ -> nil
    end
  end

  # Single choke point for guest URLs. `nil` out means "no such link in
  # this environment"; it never interpolates an absent host, because
  # "https://#{nil}/..." is `https:///slug/token` — malformed but still
  # minted, and still handed to a human as if it worked.
  defp guest_invite_url(%Meeting{} = meeting, token) do
    if GuestInvite.guest_host_configured?() do
      "https://#{GuestInvite.guest_host()}/#{meeting.slug}/#{token}"
    else
      Logger.warning(
        "no guest invite URL for meeting #{meeting.id}: " <>
          ":meeting_guest_host is not configured (set MEETING_GUEST_HOST)"
      )

      nil
    end
  end

  # ── Meeting helpers (private) ────────────────────────────────────────────

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> Map.new(attrs, fn {k, v} -> {k, v} end)
  end

  defp require_present(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_present(_value, field), do: {:error, {:missing, field}}

  # Resolves the slug for a new meeting: an explicit slug is used as-is
  # (the changeset's unique constraint still guards collisions), otherwise
  # the name is slugified and a numeric suffix appended until it is free
  # within the project.
  defp resolve_slug(_project_id, slug, _name) when is_binary(slug) and slug != "", do: slug

  defp resolve_slug(project_id, _slug, name) do
    base = slugify(name)
    dedupe_slug(project_id, base, base, 1)
  end

  defp dedupe_slug(project_id, candidate, base, n) do
    case get_meeting_by_slug(project_id, candidate) do
      nil -> candidate
      _ -> dedupe_slug(project_id, "#{base}-#{n + 1}", base, n + 1)
    end
  end

  defp slugify(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/u, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    if slug == "", do: "meeting", else: slug
  end

  # ── Rooms ────────────────────────────────────────────────────────────────

  @doc "Find or create a room by its LiveKit room name."
  @spec find_or_create_room(String.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_room(livekit_room_name) do
    case Repo.get_by(Room, livekit_room_name: livekit_room_name) do
      nil ->
        %Room{}
        |> Room.changeset(%{livekit_room_name: livekit_room_name})
        |> Repo.insert()

      room ->
        {:ok, room}
    end
  end

  @doc "Get a room by ID. `nil` for an absent id and for a malformed one."
  @spec get_room(term()) :: Room.t() | nil
  def get_room(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Room, id), else: nil
  end

  @doc "Get a room by LiveKit room name."
  @spec get_room_by_name(String.t()) :: Room.t() | nil
  def get_room_by_name(name), do: Repo.get_by(Room, livekit_room_name: name)

  # App-controlled LiveKit room names are always `space-<uuidv4>` — see
  # `room_name_for_space/1`. LiveKit's own auto-generated room names
  # (produced when a room is materialised without the app calling
  # `CreateRoom` first) look like `RM_<random>`. The guard below lets
  # webhook + transcript-persistence code cheaply reject events for
  # rooms this app never registered — including stray `room_started`
  # deliveries for phantom LiveKit rooms.
  @app_room_name_regex ~r/^space-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @doc """
  Whether a LiveKit room name is one this app registered.

  Returns `true` for names matching the canonical `space-<uuid>`
  pattern produced by `room_name_for_space/1`. Returns `false` for
  everything else — most notably LiveKit's auto-generated `RM_<random>`
  identifiers, which show up when a room materialises without a prior
  `CreateRoom` (e.g. a client with a stale/mis-scoped token, or a
  webhook replay after room GC).

  Pattern-only by design: the DB fallback lives in the second layer
  of defence (post-hoc cleanup on `room_finished`) so the hot webhook
  path stays cheap under bursty delivery.
  """
  @spec app_registered_room?(term()) :: boolean()
  def app_registered_room?(name) when is_binary(name) do
    Regex.match?(@app_room_name_regex, name)
  end

  def app_registered_room?(_), do: false

  @doc """
  Tightened room guard: name matches `space-<uuid>` AND the derived
  `space_id` resolves to a real row in `chat_spaces`.

  This is the second-generation guard added for task 019f3312 (phantom
  meeting flood). The regex-only `app_registered_room?/1` accepts any
  well-formed `space-<uuid>` name — including UUIDs that were never
  materialised as a Suite chat space. That leaves the webhook path
  open to attacker-crafted names of the form `space-<random-uuid>` that
  match the regex but point at nothing. `legit_room?/1` closes that
  hole by requiring the space actually exists.

  Accepts the LiveKit webhook room-payload shape
  `%{"name" => name, "sid" => sid}` (either key may be missing / nil).
  Returns `true` only when:

    * `name` is a binary matching the canonical `space-<uuid>` regex, AND
    * the extracted UUID resolves to a `Chat.Space` row via
      `Platform.Chat.get_space/1`.

  Any deviation — malformed payload, `RM_<random>` name, well-formed
  name for a non-existent space — returns `false`. Callers should
  route to the "ignored / unregistered room" branch on `false`.
  """
  @spec legit_room?(term()) :: boolean()
  def legit_room?(%{"name" => name}) when is_binary(name) do
    with true <- Regex.match?(@app_room_name_regex, name),
         "space-" <> uuid <- name,
         %Platform.Chat.Space{} <- Platform.Chat.get_space(uuid) do
      true
    else
      _ -> false
    end
  end

  def legit_room?(_), do: false

  @doc """
  Ensure a meeting room exists for a space.

  Uses `"space:{space_id}"` as the LiveKit room name. If a room already
  exists for this space, returns it; otherwise creates one. Also attempts
  to create the room on the LiveKit server via Twirp API (gracefully
  handles failure).
  """
  @spec ensure_room(binary()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def ensure_room(space_id) do
    room_name = room_name_for_space(space_id)

    case Repo.get_by(Room, space_id: space_id) do
      nil ->
        # Create room in LiveKit via Twirp API
        case ensure_livekit_room(room_name) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Meetings] LiveKit CreateRoom failed: #{inspect(reason)}, proceeding with DB only"
            )
        end

        %Room{}
        |> Room.changeset(%{livekit_room_name: room_name, space_id: space_id})
        |> Repo.insert()

      room ->
        {:ok, room}
    end
  end

  @doc "Get the active (non-idle) room for a space, if any."
  @spec get_active_room(binary()) :: Room.t() | nil
  def get_active_room(space_id) do
    Room
    |> where([r], r.space_id == ^space_id and r.status == "active")
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Update room status to active."
  @spec activate_room(Room.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def activate_room(%Room{} = room) do
    result =
      room
      |> Room.changeset(%{status: "active"})
      |> Repo.update()

    case result do
      {:ok, updated_room} ->
        MeetingsPubSub.broadcast_room(room.id, {:room_activated, updated_room})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated_room}

      error ->
        error
    end
  end

  @doc "Set room to idle and mark all active participants as left."
  @spec finish_room(Room.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def finish_room(%Room{} = room) do
    now = DateTime.utc_now()

    # Mark all active participants as left
    from(p in Participant,
      where: p.room_id == ^room.id and is_nil(p.left_at)
    )
    |> Repo.update_all(set: [left_at: now])

    result =
      room
      |> Room.changeset(%{status: "idle"})
      |> Repo.update()

    case result do
      {:ok, updated_room} ->
        MeetingsPubSub.broadcast_room(room.id, {:room_finished, updated_room})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated_room}

      error ->
        error
    end
  end

  # ── Participants ─────────────────────────────────────────────────────────

  @doc """
  Record a participant joining a room.

  Broadcasts `{:participant_joined, participant}` on the room topic and
  updates the presence summary for the sidebar.
  """
  @spec participant_joined(Room.t(), map()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def participant_joined(%Room{} = room, attrs) do
    result =
      %Participant{}
      |> Participant.changeset(
        Map.merge(attrs, %{
          room_id: room.id,
          joined_at: Map.get(attrs, :joined_at, DateTime.utc_now())
        })
      )
      |> Repo.insert()

    case result do
      {:ok, participant} ->
        MeetingsPubSub.broadcast_room(room.id, {:participant_joined, participant})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, participant}

      error ->
        error
    end
  end

  @doc """
  Record a participant leaving a room.

  Finds the most recent active participant record matching the identity,
  sets `left_at`, and broadcasts the change.
  """
  @spec participant_left(Room.t(), String.t()) ::
          {:ok, Participant.t()} | {:error, :not_found}
  def participant_left(%Room{} = room, display_name) do
    query =
      from(p in Participant,
        where: p.room_id == ^room.id and p.display_name == ^display_name and is_nil(p.left_at),
        order_by: [desc: p.joined_at],
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      participant ->
        {:ok, updated} =
          participant
          |> Participant.changeset(%{left_at: DateTime.utc_now()})
          |> Repo.update()

        MeetingsPubSub.broadcast_room(room.id, {:participant_left, updated})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated}
    end
  end

  @doc """
  Parse a LiveKit participant identity string into a typed FK tuple.

  Suite mints identities as `"user:<uuid>"` (human joiners, see
  `MeetingHooks.do_join/1`), `"agent:<uuid>"` (agent runtime), and
  `"guest:<random-uuid>"` (guest ingress via `meet.example.com`
  — see `guest_livekit_token/2`). Returns `{:user, uuid}` /
  `{:agent, uuid}` / `{:guest, uuid}` for a well-formed identity, or
  `:unknown` for anything else (no prefix, bad UUID, nil) — mirroring the
  defensive validation style of `space_id_from_room_name/1` in the webhook
  controller.

  Guest identities carry a randomly-minted UUID (not a Suite user or
  agent FK) — the `{:guest, _}` tuple downstream yields a nil-FK
  participant row that dedupes by display_name, so the guest surfaces in
  the participant rail with the name from the JWT `name` claim without
  attempting to resolve a bogus foreign key.
  """
  @spec parse_identity(String.t() | nil) ::
          {:user, binary()} | {:agent, binary()} | {:guest, binary()} | :unknown
  def parse_identity("user:" <> uuid), do: cast_identity(:user, uuid)
  def parse_identity("agent:" <> uuid), do: cast_identity(:agent, uuid)
  def parse_identity("guest:" <> uuid), do: cast_identity(:guest, uuid)
  def parse_identity(_), do: :unknown

  @doc """
  True when a LiveKit participant identity names a Suite AGENT.

  A deliberate PREFIX test, and deliberately NOT `parse_identity/1`.
  Suite mints agent identities in two different shapes and only one of
  them parses:

    * `generate_agent_token/3` mints `"agent:" <> agent.slug` — this is
      the identity on the token an agent actually joins a LiveKit room
      with, so it is the identity that would be stamped on any segment
      an agent's speech produced;
    * `MeetingLive` keys its participant tiles `"agent:" <> agent.id`.

  `parse_identity/1` casts the suffix as a UUID and therefore answers
  `:unknown` for the slug form. A guard written on `parse_identity/1`
  would pass agent speech straight through for exactly the identity the
  audio-publish path mints, and would do so silently — which is why
  this predicate exists as its own named function next to it rather
  than as a `{:agent, _}` match at the call site.

  Answers `false` for a bare `"agent:"` with no suffix (that names
  nobody), for `nil`, and for non-Suite prefixes such as
  `"transcriber:"` or the bare `"meeting-transcriber"` dispatch name —
  those are out-of-repo workers, not agents, and unlike agents they
  never publish speech.
  """
  @spec agent_identity?(term()) :: boolean()
  def agent_identity?("agent:" <> suffix) when byte_size(suffix) > 0, do: true
  def agent_identity?(_), do: false

  # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1. This is a FABRICATED-VALUE
  # bug, not a raise: `uuid` is the suffix of a LiveKit webhook `identity`
  # string, and a bare `Ecto.UUID.cast/1` hex-encodes any 16-byte suffix into
  # a well-formed but INVENTED uuid, which is then persisted as the
  # `meeting_participants.user_id` / `.agent_id` FOREIGN KEY. Nothing raises,
  # so an assert_raise-shaped test can never catch a regression here — assert
  # that `parse_identity/1` returns `:unknown` for a 16-character suffix.
  defp cast_identity(kind, uuid) do
    case Platform.UUID.cast(uuid) do
      {:ok, valid} -> {kind, valid}
      :error -> :unknown
    end
  end

  @doc """
  Idempotently upsert a `meeting_participants` row for a live LiveKit
  joiner identified by a webhook `participant_joined` event.

  Parses the LiveKit `identity` into a resolvable `user_id`/`agent_id`
  FK so the render path (`active_participants_for_space/1` →
  `resolve_identity/1`) shows the participant's real name instead of the
  literal "User". An identity that does not parse yields a nil-FK row
  carrying just the `name`.

  Find-or-reactivate: if an active (`left_at IS NULL`) row already exists
  for this room + identity, returns it unchanged — LiveKit re-fires
  `participant_joined` on reconnect, and we want one stable row, not a
  duplicate. Otherwise inserts via `participant_joined/2`, reusing its
  broadcast block.

  Match key: `(room_id, user_id)` when a user FK is present, else
  `(room_id, agent_id)`, else `(room_id, display_name)` so identityless
  rows still dedupe by name.
  """
  @spec upsert_live_participant(Room.t(), %{
          required(:identity) => String.t() | nil,
          required(:name) => String.t() | nil
        }) :: {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def upsert_live_participant(%Room{} = room, %{identity: identity} = attrs) do
    name = Map.get(attrs, :name)
    parsed = parse_identity(identity)
    fk = identity_fk(parsed)
    display_name = name || display_name_from_identity(parsed) || "User"

    # 019f498d re-dispatch: store the LiveKit `identity` in the row's
    # metadata so the render layer can produce a `data-participant`
    # attribute that matches the LiveKit identity the JS hook sees. This
    # matters most for guest rows (nil user/agent FK, random `guest:<id>`
    # identity that isn't derivable from the DB row otherwise), and is
    # a safe no-op for auth rows (metadata identity == "user:<uuid>" ==
    # what `gallery_identity/1` already produces from `:participant_id`).
    metadata =
      if is_binary(identity),
        do: %{"identity" => identity},
        else: %{}

    case find_active_participant(room.id, fk, display_name) do
      %Participant{} = existing ->
        maybe_backfill_identity(existing, metadata)

      nil ->
        case participant_joined(
               room,
               Map.merge(fk, %{display_name: display_name, metadata: metadata})
             ) do
          {:ok, _participant} = ok ->
            # Genuinely new active row = a real join (not a reconnect/backfill):
            # clear this user's meeting_starting inbox row for the space's live
            # meeting. Fire-and-forget — never fails the join.
            maybe_dismiss_meeting_inbox(room, parsed)
            ok

          error ->
            error
        end
    end
  end

  # Only a resolvable user identity dismisses; agent/guest/unknown are no-ops.
  # A nil live meeting is a safe no-op, and any dismissal error is swallowed so
  # it can't fail the join.
  defp maybe_dismiss_meeting_inbox(%Room{space_id: space_id}, {:user, user_id}) do
    case get_live_meeting_for_space(space_id) do
      %Meeting{} = meeting ->
        inbox_module().dismiss_by_source(user_id, "meeting", meeting.id)

      nil ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Meetings] inbox dismiss_by_source failed — user=#{user_id}: #{inspect(error)}"
      )

      :error
  end

  defp maybe_dismiss_meeting_inbox(_room, _parsed), do: :ok

  defp inbox_module do
    Application.get_env(:platform, :inbox_module, Platform.Inbox)
  end

  # Idempotently backfill `metadata["identity"]` on an existing active row
  # so a reconnect (or a guest-side upsert after the webhook already ran)
  # doesn't drop the identity we need to match tiles to LiveKit tracks.
  defp maybe_backfill_identity(%Participant{} = existing, metadata) do
    current = existing.metadata || %{}

    if map_size(metadata) > 0 and Map.get(current, "identity") != Map.get(metadata, "identity") do
      existing
      |> Participant.changeset(%{metadata: Map.merge(current, metadata)})
      |> Repo.update()
    else
      {:ok, existing}
    end
  end

  @doc """
  Mark a live participant as having left, resolving the same match key
  `upsert_live_participant/2` uses (user_id/agent_id first, then
  display_name). Generalizes `participant_left/2` (which matches only on
  display_name) so an identity-bearing leave is resolved by FK even when
  the LiveKit `name` differs from the stored `display_name`.

  Returns `{:error, :not_found}` when no active row matches (e.g. a leave
  for a participant we never recorded) — callers should tolerate this.
  """
  @spec mark_live_participant_left(Room.t(), %{
          required(:identity) => String.t() | nil,
          required(:name) => String.t() | nil
        }) :: {:ok, Participant.t()} | {:error, :not_found}
  def mark_live_participant_left(%Room{} = room, %{identity: identity} = attrs) do
    name = Map.get(attrs, :name)
    parsed = parse_identity(identity)
    fk = identity_fk(parsed)
    display_name = name || display_name_from_identity(parsed)

    case find_active_participant(room.id, fk, display_name) do
      %Participant{} = participant ->
        {:ok, updated} =
          participant
          |> Participant.changeset(%{left_at: DateTime.utc_now()})
          |> Repo.update()

        MeetingsPubSub.broadcast_room(room.id, {:participant_left, updated})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Fire-and-forget durable cleanup for an explicit user-initiated leave,
  callable from any surface (in-chat MeetingHooks event handler OR the
  persistent meeting mini-bar in `ShellLive`) without depending on the
  caller's LiveView assigns shape.

  Resolves the active room for `space_id`, then delegates to
  `mark_live_participant_left/2` with the canonical `"user:<uuid>"`
  identity that `upsert_live_participant/2` recorded on join. Returns
  `:ok` in every case — every nil/error branch (no active room, no
  participant row, etc.) is tolerated as a safe no-op so the helper can
  be called speculatively (e.g. by the mini-bar Leave button even when
  no meeting is active).

  See `MeetingHooks.stamp_local_left/1` for the leave-path contract and
  asymmetry-with-`on_terminate/1` rationale this helper preserves.
  """
  @spec leave_for_user(binary(), binary()) :: :ok
  def leave_for_user(space_id, user_id) when is_binary(space_id) and is_binary(user_id) do
    with %Room{} = room <- get_active_room(space_id) do
      mark_live_participant_left(room, %{identity: "user:#{user_id}", name: nil})
    end

    :ok
  end

  def leave_for_user(_space_id, _user_id), do: :ok

  # FK attrs map for a parsed identity — drives both insert attrs and the
  # match-key lookup. Guest identities carry a randomly-minted UUID (not a
  # Suite FK) so the map is empty — the resulting participant row dedupes
  # by display_name, matching the phone/SIP `:unknown` path.
  defp identity_fk({:user, uuid}), do: %{user_id: uuid}
  defp identity_fk({:agent, uuid}), do: %{agent_id: uuid}
  defp identity_fk({:guest, _uuid}), do: %{}
  defp identity_fk(:unknown), do: %{}

  defp display_name_from_identity(_), do: nil

  # Find an active (not-yet-left) participant by the strongest available
  # key: user_id, then agent_id, then display_name.
  defp find_active_participant(room_id, %{user_id: user_id}, _display_name)
       when is_binary(user_id) do
    Repo.one(
      from(p in Participant,
        where: p.room_id == ^room_id and p.user_id == ^user_id and is_nil(p.left_at),
        order_by: [desc: p.joined_at],
        limit: 1
      )
    )
  end

  defp find_active_participant(room_id, %{agent_id: agent_id}, _display_name)
       when is_binary(agent_id) do
    Repo.one(
      from(p in Participant,
        where: p.room_id == ^room_id and p.agent_id == ^agent_id and is_nil(p.left_at),
        order_by: [desc: p.joined_at],
        limit: 1
      )
    )
  end

  defp find_active_participant(_room_id, _fk, nil), do: nil

  defp find_active_participant(room_id, _fk, display_name) when is_binary(display_name) do
    Repo.one(
      from(p in Participant,
        where: p.room_id == ^room_id and p.display_name == ^display_name and is_nil(p.left_at),
        order_by: [desc: p.joined_at],
        limit: 1
      )
    )
  end

  @doc """
  List active (not yet left) participants in a room, preloading user and
  agent associations for display name and avatar resolution.
  """
  @spec active_participants(binary()) :: [Participant.t()]
  def active_participants(room_id) do
    from(p in Participant,
      where: p.room_id == ^room_id and is_nil(p.left_at),
      order_by: [asc: p.joined_at],
      preload: [:user, :agent]
    )
    |> Repo.all()
  end

  # ── Transcriber presence ─────────────────────────────────────────────────

  # Substrings matched against BOTH `display_name` and
  # `metadata["identity"]` of a `meeting_participants` row. The match is
  # case-insensitive by downcasing the haystacks only (see
  # `transcriber_marker?/1`), so every entry here must be lowercase.
  #
  # Both of those fields arrive on the LiveKit `participant_joined`
  # webhook and are minted by the external transcriber worker, which does
  # not live in this repo (ADR 0036). Nothing here produces either literal
  # on a participant row, so neither entry can be confirmed or refuted
  # from this codebase — do NOT prune one for looking speculative.
  # Narrowing this list silently restores the failure the check exists to
  # catch (an empty transcript reported as a cheerful success), and the
  # suite seeds its own rows, so tests staying green is not evidence.
  #
  # `parse_identity/1` returns `:unknown` for a `transcriber:` identity.
  # That is WHY such a participant lands as a nil-FK row and has to be
  # matched by these strings at all; it is not evidence that no worker
  # joins with that prefix. `parse_identity/1` only governs the
  # identities Suite itself mints (`user:` / `agent:` / `guest:`).
  #
  # `"meeting-transcriber"` is the literal the token/room-creation path
  # dispatches as `agentName` — a dispatch-rule name, which is not
  # necessarily the identity or display name the worker then joins with.
  #
  # Overridable at runtime (`transcriber_identity_markers/0`), so a row
  # shape observed in the field can be added without a deploy.
  @transcriber_identity_markers ["meeting-transcriber", "transcriber:"]

  # A transcriber emits its first segment within seconds of the first
  # speech, so a session that ran two minutes with a live transcriber and
  # produced literally nothing is a delivery failure, not silence. Below
  # this window an agent that connects and drops is indistinguishable
  # from a room nobody used, and a sub-two-minute meeting with no speech
  # is genuinely plausible.
  @transcriber_presence_threshold_seconds 120

  @doc """
  Longest presence window, in seconds, among transcriber-marker
  participants of the room a transcript belongs to.

  IMPORTANT: `meeting_transcripts.room_id` is a LiveKit room NAME
  (a string), while `meeting_participants.room_id` is the
  `meeting_rooms` UUID FK. They are not the same key — joining them
  directly returns `[]` silently. This resolves through
  `get_room_by_name/1` first and only then queries participants by
  `room.id`.

  A nil `left_at` is read as "still present, measure to now": at
  finalisation time `room_finished` can fire before every leave webhook
  lands, so nil is the normal case, not a bug.

  Returns `0` when the room does not resolve or no marker row matches.
  """
  @spec transcriber_presence_seconds(Transcript.t() | String.t() | nil) :: non_neg_integer()
  def transcriber_presence_seconds(%Transcript{room_id: room_name}),
    do: transcriber_presence_seconds(room_name)

  def transcriber_presence_seconds(room_name) when is_binary(room_name) do
    case get_room_by_name(room_name) do
      nil ->
        0

      room ->
        now = DateTime.utc_now()

        from(p in Participant, where: p.room_id == ^room.id)
        |> Repo.all()
        |> Enum.filter(&transcriber_marker?/1)
        |> Enum.map(fn p ->
          case p.joined_at do
            nil -> 0
            joined_at -> max(DateTime.diff(p.left_at || now, joined_at), 0)
          end
        end)
        |> Enum.max(fn -> 0 end)
    end
  end

  def transcriber_presence_seconds(_), do: 0

  @doc """
  Whether a transcriber was present in the transcript's room for at
  least the configured threshold (default
  #{@transcriber_presence_threshold_seconds} seconds).

  This is the discriminator between "nobody spoke" and "the transcriber
  was there and delivered nothing".
  """
  @spec transcriber_present_for_threshold?(Transcript.t() | String.t() | nil) :: boolean()
  def transcriber_present_for_threshold?(transcript) do
    transcriber_presence_seconds(transcript) >= transcriber_presence_threshold_seconds()
  end

  defp transcriber_marker?(%Participant{} = participant) do
    identity =
      case participant.metadata do
        %{"identity" => value} when is_binary(value) -> value
        _ -> nil
      end

    haystacks =
      [participant.display_name, identity]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)

    Enum.any?(transcriber_identity_markers(), fn marker ->
      Enum.any?(haystacks, &String.contains?(&1, marker))
    end)
  end

  defp transcriber_identity_markers do
    Application.get_env(:platform, :transcriber_identity_markers, @transcriber_identity_markers)
  end

  defp transcriber_presence_threshold_seconds do
    Application.get_env(
      :platform,
      :transcriber_presence_threshold_seconds,
      @transcriber_presence_threshold_seconds
    )
  end

  # ── Space-level presence queries ─────────────────────────────────────────

  @doc """
  List all active (connected) participants for a space's current meeting.
  Returns an empty list if no active meeting exists. Preloads user/agent.
  """
  @spec active_participants_for_space(binary()) :: [Participant.t()]
  def active_participants_for_space(space_id) do
    case get_active_room(space_id) do
      nil -> []
      room -> active_participants(room.id)
    end
  end

  @doc """
  Return the active (`left_at IS NULL`) participant row for a given user in
  a space's current meeting, or `nil`.

  Used by the LiveView reconnect path (`MeetingHooks.attach/1`) to detect
  that a user was already in the live meeting before a transient socket
  drop, so the reconnect mount can restore `:in_meeting` and re-push
  `join-meeting` instead of resetting state. Resolves the active room via
  `get_active_room/1` and matches on `user_id` (the FK the live join path
  records via `upsert_live_participant/2`).
  """
  @spec active_participant_for_user_in_space(binary(), binary()) :: Participant.t() | nil
  def active_participant_for_user_in_space(space_id, user_id)
      when is_binary(space_id) and is_binary(user_id) do
    case get_active_room(space_id) do
      nil ->
        nil

      room ->
        Repo.one(
          from(p in Participant,
            where: p.room_id == ^room.id and p.user_id == ^user_id and is_nil(p.left_at),
            order_by: [desc: p.joined_at],
            limit: 1
          )
        )
    end
  end

  def active_participant_for_user_in_space(_space_id, _user_id), do: nil

  @doc "Count active participants for a space's current meeting."
  @spec active_participant_count(binary()) :: non_neg_integer()
  def active_participant_count(space_id) do
    case get_active_room(space_id) do
      nil ->
        0

      room ->
        from(p in Participant,
          where: p.room_id == ^room.id and is_nil(p.left_at)
        )
        |> Repo.aggregate(:count)
    end
  end

  @doc """
  For a list of space IDs, return a map of `%{space_id => participant_count}`
  for spaces that have an active meeting with at least one participant.

  Used by the sidebar to show meeting indicators efficiently in a single query.
  """
  @spec active_meeting_counts([binary()]) :: %{binary() => non_neg_integer()}
  def active_meeting_counts([]), do: %{}

  def active_meeting_counts(space_ids) when is_list(space_ids) do
    Room
    |> join(:inner, [r], p in Participant, on: p.room_id == r.id and is_nil(p.left_at))
    |> where([r, _p], r.space_id in ^space_ids and r.status == "active")
    |> group_by([r, _p], r.space_id)
    |> select([r, p], {r.space_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ── Token Generation ─────────────────────────────────────────────────────

  @doc """
  Generate a LiveKit access token (JWT) for a user to join a room.

  The token is an HS256 JWT signed with `LIVEKIT_API_SECRET`, containing:
  - `iss` — the API key
  - `sub` — the user identity
  - `exp` — expiry (default 6 hours)
  - `video` — grant with room name and permissions

  Two clauses:

    * `generate_token(%Room{}, %{identity: _, name: _})` — takes the room
      struct and returns `{:ok, token_string}` or `{:error, reason}`.
    * `generate_token(room_name, identity)` when both are binaries — the
      room-name-string form, equivalent to `generate_token(room_name,
      identity, [])`. See `generate_token/3` for the available options.
  """
  @spec generate_token(Room.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def generate_token(%Room{} = room, %{identity: identity, name: name}) do
    config = livekit_config()
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      now = System.system_time(:second)
      ttl = 6 * 60 * 60

      claims =
        %{
          "iss" => api_key,
          "sub" => identity,
          "nbf" => now,
          "exp" => now + ttl,
          "jti" => Ecto.UUID.generate(),
          "name" => name,
          "video" => %{
            "room" => room.livekit_room_name,
            "roomJoin" => true,
            "canPublish" => true,
            "canSubscribe" => true,
            "canPublishData" => true
          }
        }
        |> maybe_put_room_config(room.livekit_room_name)

      {:ok, encode_jwt(claims, api_secret)}
    end
  end

  # Room-name-string form of `generate_token/2`; documented on the first clause
  # above, since @doc is per name/arity and a second one would be discarded.
  def generate_token(room_name, identity) when is_binary(room_name) and is_binary(identity) do
    generate_token(room_name, identity, [])
  end

  @doc """
  Generate a LiveKit access token from a room name string.

  Simpler API for cases where you have the room name directly
  (e.g. from `ensure_room/1` or `room_name_for_space/1`).

  Options:
    - `:name` — display name (defaults to identity)
    - `:ttl` — token TTL in seconds (default: 6 hours)

  Returns the signed JWT string.
  """
  def generate_token(room_name, identity, opts)
      when is_binary(room_name) and is_binary(identity) do
    config = livekit_config()
    name = Keyword.get(opts, :name, identity)
    ttl = Keyword.get(opts, :ttl, 21_600)

    now = System.system_time(:second)

    claims =
      %{
        "iss" => config[:api_key],
        "sub" => identity,
        "nbf" => now,
        "exp" => now + ttl,
        "jti" => :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false),
        "name" => name,
        "video" => %{
          "room" => room_name,
          "roomJoin" => true,
          "canPublish" => true,
          "canSubscribe" => true,
          "canPublishData" => true
        }
      }
      |> maybe_put_room_config(room_name)

    sign_jwt(claims, config[:api_secret])
  end

  # When the room is a meeting space (space-<uuid>), explicitly dispatch the
  # meeting-transcriber agent. This keeps the voice-assistant agent (which
  # handles phone-call rooms) out of meetings — LiveKit routes by agentName.
  defp maybe_put_room_config(claims, "space-" <> _) do
    Map.put(claims, "roomConfig", %{
      "agents" => [%{"agentName" => "meeting-transcriber"}]
    })
  end

  defp maybe_put_room_config(claims, _room_name), do: claims

  @doc """
  Generate a LiveKit access token for an agent worker.

  Agent tokens include `hidden: true` metadata so agent participants
  are not shown in the participant list by default.

  Returns `{:ok, jwt}` or `{:error, :livekit_not_configured}`.
  """
  @spec generate_agent_token(Room.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def generate_agent_token(%Room{} = room, %{identity: identity, name: name}) do
    config = livekit_config()
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      grants = %{
        "video" => %{
          "room" => room.livekit_room_name,
          "roomJoin" => true,
          "canPublish" => true,
          "canSubscribe" => true,
          "canPublishData" => true
        },
        "metadata" => Jason.encode!(%{"agent" => true, "hidden" => false})
      }

      {:ok, build_jwt(identity, name, grants)}
    end
  end

  # ── Guest LiveKit token ──────────────────────────────────────────────────

  # Guest tokens are short-TTL (30 min) — shorter than user tokens
  # (6h) because a guest invite is a single-use "click and join" ticket.
  # Rowan's note about the phantom-fix rotation of LIVEKIT_API_KEY /
  # LIVEKIT_API_SECRET applies here: tokens are minted ON-DEMAND at
  # click time (MeetingLive guest-mount branch), never pre-generated at
  # invite-generation time, so an API key rotation cannot invalidate an
  # in-hand invite URL.
  @guest_token_ttl_seconds 30 * 60

  @doc """
  Mint a LiveKit access token for a guest joining `meeting`'s room.

  The guest joins the SAME LiveKit room as the host — the room name is
  derived from `meeting.chat_space_id` via `room_name_for_space/1` so
  the phantom-fix guard (`legit_room?/1`, which validates
  `space-<uuid>` against `Chat.get_space/1`) admits the guest webhook
  path just like the host's.

  Token claims:

    * `iss` — the LiveKit API key
    * `sub` / `identity` — `"guest:<random-uuid>"` (random per mint;
      never a Suite user or agent FK)
    * `name` — `"<display_name> (guest)"` — the ` (guest)` suffix is an
      impersonation-guard mitigation that surfaces to every other
      participant's rail so an operator can eyeball guest vs member
      instantly.
    * `exp` — mint time + 30 minutes (short-TTL join ticket).
    * `video` — full participant grants (`canPublish`, `canSubscribe`,
      `canPublishData`) so the guest experience matches a regular
      joiner.

  The `roomConfig.agents` dispatch (via `maybe_put_room_config/2`) is
  preserved so a guest-triggered room-create still dispatches the
  `meeting-transcriber` — no-op on already-created rooms per the
  existing comment in that helper.

  Returns:

    * `{:ok, %{token: token, identity: identity, room_name: room_name,
      livekit_url: url}}` — every field the LiveView's `MeetingClient`
      hook context needs, in one hop.
    * `{:error, :livekit_not_configured}` — matches
      `generate_token/2`'s missing-config surface.
    * `{:error, :missing_display_name}` — the caller passed empty/nil
      instead of a non-empty binary; the token grants surface a
      display name to every other participant, so a nil name is a
      programmer error, not a runtime one.
  """
  @spec guest_livekit_token(Meeting.t(), String.t()) ::
          {:ok,
           %{
             token: String.t(),
             identity: String.t(),
             room_name: String.t(),
             livekit_url: String.t() | nil
           }}
          | {:error, :livekit_not_configured | :missing_display_name}
  def guest_livekit_token(%Meeting{chat_space_id: chat_space_id} = _meeting, display_name)
      when is_binary(chat_space_id) and is_binary(display_name) do
    trimmed = String.trim(display_name)

    cond do
      trimmed == "" ->
        {:error, :missing_display_name}

      true ->
        do_guest_livekit_token(chat_space_id, trimmed)
    end
  end

  def guest_livekit_token(%Meeting{}, _display_name), do: {:error, :missing_display_name}

  defp do_guest_livekit_token(chat_space_id, display_name) do
    config = livekit_config()
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(api_key) or api_key == "" or is_nil(api_secret) or api_secret == "" do
      {:error, :livekit_not_configured}
    else
      identity =
        "guest:" <>
          (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))

      room_name = room_name_for_space(chat_space_id)
      now = System.system_time(:second)

      claims =
        %{
          "iss" => api_key,
          "sub" => identity,
          "nbf" => now,
          "exp" => now + @guest_token_ttl_seconds,
          "jti" => Ecto.UUID.generate(),
          "name" => "#{display_name} (guest)",
          "video" => %{
            "room" => room_name,
            "roomJoin" => true,
            "canPublish" => true,
            "canSubscribe" => true,
            "canPublishData" => true
          }
        }
        |> maybe_put_room_config(room_name)

      {:ok,
       %{
         token: encode_jwt(claims, api_secret),
         identity: identity,
         room_name: room_name,
         livekit_url: config[:url]
       }}
    end
  end

  # ── Recordings ───────────────────────────────────────────────────────────

  @doc """
  Start a recording for a room. Creates a recording entry in `recording`
  status.

  Returns `{:ok, recording}` or `{:error, changeset | :meetings_disabled}`.
  """
  @spec start_recording(String.t(), map()) :: {:ok, Recording.t()} | {:error, term()}
  def start_recording(room_id, attrs \\ %{}) do
    with :ok <- guard_enabled() do
      room = Repo.get!(Room, room_id)

      recording_attrs =
        Map.merge(attrs, %{
          room_id: room_id,
          space_id: room.space_id,
          status: "recording"
        })

      result =
        %Recording{}
        |> Recording.changeset(recording_attrs)
        |> Repo.insert()

      with {:ok, _recording} <- result do
        room
        |> Room.changeset(%{status: "recording"})
        |> Repo.update()
      end

      result
    end
  end

  @doc """
  Stop a recording — transitions it from `recording` to `processing`.

  Returns `{:ok, recording}` or `{:error, :not_found | :meetings_disabled}`.
  """
  @spec stop_recording(String.t()) :: {:ok, Recording.t()} | {:error, term()}
  def stop_recording(recording_id) do
    # `recording_id` arrives on the egress webhook body and on meeting LiveView
    # events. Malformed folds into the existing :not_found contract.
    with :ok <- guard_enabled(),
         true <- Platform.UUID.valid?(recording_id) || {:error, :not_found} do
      case Repo.get(Recording, recording_id) do
        nil ->
          {:error, :not_found}

        %Recording{status: "recording"} = recording ->
          recording
          |> Recording.changeset(%{status: "processing"})
          |> Repo.update()

        _recording ->
          {:error, :invalid_status}
      end
    end
  end

  @doc """
  Mark a recording as completed with file details.

  Transitions the recording to `ready` status and stores duration,
  file URL, and file size.

  Returns `{:ok, recording}` or `{:error, :not_found | :meetings_disabled}`.
  """
  @spec recording_completed(String.t(), map()) :: {:ok, Recording.t()} | {:error, term()}
  def recording_completed(recording_id, attrs) do
    with :ok <- guard_enabled(),
         true <- Platform.UUID.valid?(recording_id) || {:error, :not_found} do
      case Repo.get(Recording, recording_id) do
        nil ->
          {:error, :not_found}

        %Recording{status: status} = recording when status in ~w(recording processing) ->
          recording
          |> Recording.changeset(Map.merge(attrs, %{status: "ready"}))
          |> Repo.update()

        _recording ->
          {:error, :invalid_status}
      end
    end
  end

  # ── Transcripts ────────────────────────────────────────────────────────────

  @doc """
  Create a new transcript record for a meeting room.
  """
  @spec create_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def create_transcript(attrs) do
    %Transcript{}
    |> Transcript.changeset(Map.put_new(attrs, :started_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  @doc """
  Get a transcript by ID.
  """
  @spec get_transcript(term()) :: Transcript.t() | nil
  def get_transcript(id) do
    # Reached with `trigger_meta[:transcript_id]` off responsibility payloads
    # AND with a URL path segment (controllers/transcript_controller.ex:23).
    if Platform.UUID.valid?(id), do: Repo.get(Transcript, id), else: nil
  end

  @doc """
  Get the active (recording-status) transcript for a room.

  Returns `nil` if no active transcript exists.
  """
  @spec get_transcript_for_room(String.t()) :: Transcript.t() | nil
  def get_transcript_for_room(room_id) do
    Transcript
    |> where([t], t.room_id == ^room_id and t.status == "recording")
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Return every transcript row for a room, oldest first, with no status filter.

  Deliberately unfiltered. `get_transcript_for_room/1` above answers only
  with rows still in `"recording"`, which is why a room can end up holding
  more than one row: once the first row moves to `processing`/`failed`,
  `ensure_transcript/1` sees nil and inserts a second one. Any question
  about a ROOM (does it hold content? which row should be summarised?) has
  to be asked over all of its rows, not over the newest recording one.
  """
  @spec list_transcripts_for_room(String.t()) :: [Transcript.t()]
  def list_transcripts_for_room(room_id) when is_binary(room_id) do
    from(t in Transcript,
      where: t.room_id == ^room_id,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  True when ANY transcript row for the room holds at least one segment.

  This is the whole-room predicate. A negative claim about a room — "no
  transcript arrived for this meeting" — is only true when it holds for
  every row of that room; checking a single row is the defect this exists
  to close.

  Expect `false` for the large majority of rooms. `segments` is
  `jsonb NOT NULL DEFAULT '[]'` and an empty transcript row is the normal
  state of the table, not a rare artifact (measured: ~84% of rows carry
  zero segments). A mostly-false answer here is the table's shape, not a
  broken query.
  """
  @spec room_has_segments?(String.t()) :: boolean()
  def room_has_segments?(room_id) when is_binary(room_id) do
    from(t in Transcript,
      where: t.room_id == ^room_id and fragment("jsonb_array_length(?) > 0", t.segments),
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> is_integer()
  end

  @doc """
  Return the transcript row a summary should be generated from for a room.

  Picks the row with the MOST segments; ties break toward the OLDEST
  `inserted_at`. Returns `nil` when the room has no rows at all.

  Ordering by segment count rather than recency is the point: the newest
  row for a room is frequently an empty shadow opened by a late rejoin
  after the real row left `recording`, and summarising it produces prose
  claiming the meeting had no transcribed content while a populated
  sibling sits beside it.

  Returns the row even when its status is `failed` or `complete` — whether
  a terminal row should be re-summarised is the caller's decision, not
  this query's.
  """
  @spec get_summarizable_transcript_for_room(String.t()) :: Transcript.t() | nil
  def get_summarizable_transcript_for_room(room_id) when is_binary(room_id) do
    from(t in Transcript,
      where: t.room_id == ^room_id,
      order_by: [
        desc: fragment("jsonb_array_length(?)", t.segments),
        asc: t.inserted_at
      ],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Diagnostic, read-only: every room holding more than one transcript row.

  Returns `%{room_id: String.t(), count: integer(), populated_count: integer()}`
  maps, noisiest room first. `populated_count` is how many of that room's rows
  actually carry segments, so a `count: 2, populated_count: 1` row is the
  shadow shape described on `get_summarizable_transcript_for_room/1`.
  """
  @spec list_rooms_with_multiple_transcripts() :: [
          %{room_id: String.t(), count: integer(), populated_count: integer()}
        ]
  def list_rooms_with_multiple_transcripts do
    from(t in Transcript,
      group_by: t.room_id,
      having: count(t.id) > 1,
      order_by: [desc: count(t.id), asc: t.room_id],
      select: %{
        room_id: t.room_id,
        count: count(t.id),
        populated_count: fragment("count(*) FILTER (WHERE jsonb_array_length(?) > 0)", t.segments)
      }
    )
    |> Repo.all()
  end

  @doc """
  Diagnostic, read-only: transcripts that failed silently.

  A row qualifies when it is `status: "failed"`, has a NULL `summary`, and
  holds at least one segment — i.e. the content arrived, no summary was ever
  produced, and nothing recorded why. Sizing that population is the point:

      Platform.Meetings.list_silently_failed_transcripts() |> length()

  Shipped as a tested function rather than a console script so the count is
  reproducible and the definition of "silently failed" lives in one place.
  """
  @spec list_silently_failed_transcripts() :: [Transcript.t()]
  def list_silently_failed_transcripts do
    from(t in Transcript,
      where:
        t.status == "failed" and is_nil(t.summary) and
          fragment("jsonb_array_length(?) > 0", t.segments),
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Get a transcript with its segments (same as get_transcript since segments
  are stored inline as JSONB, but named explicitly for clarity in the API).
  """
  @spec get_transcript_with_segments(term()) :: Transcript.t() | nil
  def get_transcript_with_segments(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Transcript, id), else: nil
  end

  @doc """
  Delete a transcript.

  Accepts either a `%Transcript{}` struct or a transcript UUID string.
  Returns `{:ok, transcript}` with the deleted struct on success and
  `{:error, :not_found}` when no transcript matches — including on
  malformed UUIDs and repeat deletes.

  Used by the `room_finished` cleanup path to drop empty transcripts
  that the webhook created optimistically but that never accumulated
  segments (phantom `RM_<random>` rooms, meetings that ended before
  any transcription arrived).
  """
  @spec delete_transcript(Transcript.t() | String.t()) ::
          {:ok, Transcript.t()} | {:error, :not_found}
  def delete_transcript(%Transcript{} = transcript) do
    case Repo.delete(transcript) do
      {:ok, deleted} -> {:ok, deleted}
      {:error, _changeset} -> {:error, :not_found}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  def delete_transcript(id) when is_binary(id) do
    case get_transcript(id) do
      nil -> {:error, :not_found}
      %Transcript{} = transcript -> delete_transcript(transcript)
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Returns completed transcripts whose `completed_at` falls within the window.

  Used by the Historian's activity digest. Only status="complete" transcripts
  are returned; in-progress or failed transcripts are skipped.

  ## Options

    * `:window_end` — upper bound (exclusive); default `DateTime.utc_now/0`
  """
  @spec list_transcripts_since(DateTime.t(), keyword()) :: [Transcript.t()]
  def list_transcripts_since(%DateTime{} = window_start, opts \\ []) do
    window_end = Keyword.get(opts, :window_end, DateTime.utc_now())

    opts
    |> digest_eligible_transcripts_query()
    |> where([t], t.completed_at >= ^window_start and t.completed_at < ^window_end)
    |> order_by([t], asc: t.completed_at)
    |> Repo.all()
  end

  @doc """
  The unbounded digest-eligibility predicate for the `transcripts` corpus —
  every filter that decides whether a `meeting_transcripts` row can ever
  reach a Historian digest, and nothing else. No time bound, no ordering.

  Mirror of `Platform.Chat.digest_eligible_messages_query/1`, and the same
  single seam on the transcript half: `list_transcripts_since/2` is this
  query plus `[window_start, window_end)` on `completed_at`, and the
  Historian's transcript byte-sizing (`sum_corpus_bytes("transcripts", …)`
  and `per_day_bytes_query("transcripts", …)`) is this query plus the same
  range and a `sum(octet_length(summary) + octet_length(segments::text))`.

  **The invariant:** any filter added here is inherited by the byte signal
  automatically. Adding one to only one side is a bug of the exact class
  task `019fa1cc` fixed on the `messages` corpus.

  Note `completed_at` — not `updated_at` — is the corpus clock on **both**
  sides. `completed_at <= updated_at` always (segments accumulate during a
  recording), so keying the byte signal on `updated_at` counted bytes into
  windows where the renderer would produce nothing: the same
  bytes-without-content shape that made the `messages` corpus fire spurious
  oversize windows.
  """
  @spec digest_eligible_transcripts_query(keyword()) :: Ecto.Query.t()
  def digest_eligible_transcripts_query(opts \\ []) do
    scope = Keyword.get(opts, :scope, :internal)

    from(t in Transcript,
      where: t.status == "complete" and not is_nil(t.completed_at)
    )
    |> apply_digest_scope(scope)
  end

  # External-space digest partition (stack member 12, rbac-external-users).
  # Mirrors `Chat.list_messages_since/2`'s `:scope` opt on the transcript
  # corpus: `:internal` (default) excludes external-user spaces from the
  # Fabrikam-internal digest; `{:external_spaces, ids}` restricts to an external
  # user's allowlisted spaces. See `Chat.external_space_ids/0`.
  defp apply_digest_scope(query, :internal) do
    exclude = Chat.external_space_ids()
    where(query, [t], t.space_id not in ^exclude)
  end

  defp apply_digest_scope(query, {:external_spaces, space_ids}) do
    where(query, [t], t.space_id in ^space_ids)
  end

  @doc """
  Reattach to the room's existing transcript, or create one if the room has
  no reusable row.

  Returns `{:ok, transcript}` in both cases.

  Reattachment, not "find the active row": a late rejoin or a reconnect
  after the call ended makes LiveKit re-emit `room_started` /
  `transcription` for the SAME room name. The previous implementation
  asked `get_transcript_for_room/1`, which only answers with rows still in
  `"recording"`, so once the real row moved to `processing`/`failed` the
  rejoin opened a fresh row that SHADOWED it — and every later consumer
  saw only the empty shadow. Rejoining after the end is legitimate;
  shadowing the row that holds the content is not.

  So: reuse any row for the room that is not `complete`, preferring the
  one with the most segments (ties toward the oldest), and reopen it to
  `recording` when it had already left that state. Only a room with no
  reusable row gets an insert.

  Rejected alternative — a database uniqueness constraint on `room_id`.
  It cannot be created while duplicates already exist (the existing
  population is real: rooms holding more than one row are enumerable via
  `list_rooms_with_multiple_transcripts/0`), and a legitimately separate
  second session for one room may be a shape we want later. The absence
  of that index is a decision, not an oversight.
  """
  @spec ensure_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def ensure_transcript(%{room_id: room_id} = attrs) do
    case get_reattachable_transcript_for_room(room_id) do
      nil -> create_transcript(attrs)
      %Transcript{status: "recording"} = transcript -> {:ok, transcript}
      %Transcript{} = transcript -> reopen_transcript(transcript)
    end
  end

  @doc """
  The row a rejoin should attach to: the room's non-`complete` row holding
  the most segments, ties toward the oldest `inserted_at`. `nil` when the
  room has no reusable row.

  Filters in Elixir over `list_transcripts_for_room/1` rather than issuing
  its own ordered `Repo.one` — a room holds a handful of rows at most, and
  the reuse decision is then expressed once, in one place.
  """
  @spec get_reattachable_transcript_for_room(String.t()) :: Transcript.t() | nil
  def get_reattachable_transcript_for_room(room_id) when is_binary(room_id) do
    room_id
    |> list_transcripts_for_room()
    |> Enum.reject(&(&1.status == "complete"))
    |> Enum.min_by(
      fn t -> {-length(t.segments), DateTime.to_unix(t.inserted_at, :microsecond)} end,
      fn -> nil end
    )
  end

  @doc """
  Reopen a transcript for recording after a rejoin, clearing the failure /
  completion timestamp so the reopened row is not read as terminal.
  """
  @spec reopen_transcript(Transcript.t()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def reopen_transcript(%Transcript{} = transcript) do
    transcript
    |> Transcript.changeset(%{status: "recording", completed_at: nil})
    |> Repo.update()
  end

  @doc """
  Stamp `router_dispatched_at` on a transcript row with the current UTC
  time. Returns the result of `Repo.update_all/3` — `{updated_count,
  nil}` on success, `{0, nil}` when no row matches the given id.

  Task 019f2566 stage 1 — foundation for the responsibility-router
  heartbeat + fallback path. `Summarizer.run_summary/1` (wired in
  stage 2) calls this at the exact point it fires the router so the
  SummarizerSweeper GenServer can identify dispatches that stalled
  without their agent ever picking the job up.

  Uses `update_all` (not `Repo.update`) so the caller doesn't need to
  hold a fresh struct — the Summarizer only knows the transcript id
  at the fire-and-forget dispatch site.
  """
  @spec stamp_router_dispatched(String.t()) :: {non_neg_integer(), nil}
  def stamp_router_dispatched(transcript_id) when is_binary(transcript_id) do
    from(t in Transcript, where: t.id == ^transcript_id)
    |> Repo.update_all(set: [router_dispatched_at: DateTime.utc_now()])
  end

  @doc """
  Atomically **claim** the `meeting:finished` router dispatch for a
  transcript. Task 019fa56b-c81f stage 2.

  One conditional statement — `UPDATE meeting_transcripts SET
  router_dispatched_at = now() WHERE id = $1 AND router_dispatched_at IS
  NULL` — so exactly one caller can ever observe the NULL → timestamp
  transition for a given row.

  ## Why this exists

  A meeting end produces TWO independent dispatch decisions for
  `meetings.summarize`: `PlatformWeb.LivekitWebhookController`
  `maybe_trigger_summary/1` calls `Summarizer.summarize_async/1` (whose
  `run_summary/1` fires the responsibility directly) *and* broadcasts
  `meeting:finished`, which — since task 019fa56b-c81f stage 1 repaired
  the Router's event_topic adapter — also fires it. Left alone that is
  two external dispatches, two LLM round-trips, and two
  `complete_transcript/2` writes racing on one row.

  ## Why a conditional UPDATE and not read-then-write

  The two dispatch paths run in different processes (the webhook's
  `Task.Supervisor` child vs the Router GenServer), so a
  `get_transcript/1` + `if is_nil(...)` + `stamp_router_dispatched/1`
  sequence would interleave and both callers would see NULL. A single
  guarded statement is already atomic under the row lock Postgres takes
  for the UPDATE — no advisory lock, no GenServer serialization point,
  and no change to the semantics
  `Platform.Meetings.SummarizerSweeper` reads off the same column.

  ## Return contract

    * `{:ok, :claimed}` — this caller won; it owns the dispatch.
    * `{:error, :already_dispatched}` — the row exists and somebody
      else already claimed it. The caller must NOT dispatch, and must
      not substitute a fallback either: the winner is handling it.
    * `{:error, :no_such_transcript}` — no row with that id, or the id
      is not even a UUID.

  The third value is deliberately distinct from the second even though
  `update_all` answers `0` for both. Collapsing them would make a
  deleted or typo'd transcript id look like a healthy dedupe and
  silently suppress a dispatch nobody is actually handling — the same
  "two situations, one value" defect class `Platform.Responsibilities.Providers`
  was written to kill.

  Note this is the FIRST production writer of `router_dispatched_at`:
  `stamp_router_dispatched/1` has no `lib/` call site, so the column has
  been NULL for every row and `SummarizerSweeper`'s stall-recovery
  branch has never been reachable. Taking the claim finally arms it.

  Unlike `stamp_router_dispatched/1`, this never re-stamps — the losing
  racer must not reset the sweeper's stall clock.
  """
  @spec claim_router_dispatch(term()) ::
          {:ok, :claimed} | {:error, :already_dispatched | :no_such_transcript}
  def claim_router_dispatch(transcript_id) when is_binary(transcript_id) do
    # `meeting_transcripts.id` is a UUIDv7 custom type: querying it with
    # a free-form string raises Ecto.Query.CastError. This function sits
    # on a dispatch path that must never raise, so a malformed id is
    # answered, not thrown. `Platform.UUID.valid?/1` and NOT a bare
    # `Ecto.UUID.cast/1` — the transcript_id arrives inside a PubSub
    # trigger payload an operator or a future publisher can shape, and
    # any 16-character binary clears a cast-only guard and still raises
    # inside Repo (see Platform.UUID's moduledoc).
    if Platform.UUID.valid?(transcript_id) do
      do_claim_router_dispatch(transcript_id)
    else
      {:error, :no_such_transcript}
    end
  end

  def claim_router_dispatch(_), do: {:error, :no_such_transcript}

  defp do_claim_router_dispatch(transcript_id) do
    {count, _} =
      from(t in Transcript,
        where: t.id == ^transcript_id and is_nil(t.router_dispatched_at)
      )
      |> Repo.update_all(set: [router_dispatched_at: DateTime.utc_now()])

    case count do
      1 ->
        {:ok, :claimed}

      0 ->
        # Disambiguate the two zero-row causes. Not racy in a way that
        # matters: an id that has no row now never will (ids are minted
        # at insert), so this read can only turn "no row" into "no row".
        if Repo.exists?(from(t in Transcript, where: t.id == ^transcript_id)) do
          {:error, :already_dispatched}
        else
          {:error, :no_such_transcript}
        end
    end
  end

  @doc """
  Return every `%Transcript{}` whose status is `"processing"` and whose
  `router_dispatched_at` is older than `stall_window_ms` milliseconds
  ago. Used by `Platform.Meetings.SummarizerSweeper` to identify router
  dispatches whose downstream agent never produced a summary.

  Task 019f2566 stage 2. Leans on the partial index shipped in stage 1
  (`meeting_transcripts_processing_router_dispatched_at_idx`) so the
  sweep is cheap even under a large historical transcripts table.

  A dispatch with `router_dispatched_at IS NULL` is intentionally NOT
  returned — the plan's stage-1 note says the belt-and-braces "router
  never fired" path is a stage 2+ decision; for now we only cover the
  "router fired but stalled" branch, matching the plan's stage 2 scope.
  """
  @spec list_stalled_router_dispatches(non_neg_integer()) :: [Transcript.t()]
  def list_stalled_router_dispatches(stall_window_ms) when is_integer(stall_window_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -stall_window_ms, :millisecond)

    from(t in Transcript,
      where:
        t.status == "processing" and
          not is_nil(t.router_dispatched_at) and
          t.router_dispatched_at < ^cutoff,
      order_by: [asc: t.router_dispatched_at]
    )
    |> Repo.all()
  end

  # ── Segment Accumulation ───────────────────────────────────────────────────

  @doc """
  The meeting a chat space is currently holding, as an id, or nil.

  A space accumulates meetings over its lifetime, so "the" meeting is
  ambiguous in general. It is not ambiguous for the caller that needs
  it — a transcript chunk arriving now belongs to whatever meeting is
  live now — so a `live` row wins, and we fall back to the most
  recently started (then most recently created) row for a space whose
  meeting has already been marked ended but whose transcript is still
  draining.

  Non-fatal by construction: a space with no meeting answers nil, and
  the caller decides what that means.
  """
  @spec meeting_id_for_space(binary() | nil) :: binary() | nil
  def meeting_id_for_space(nil), do: nil

  def meeting_id_for_space(space_id) when is_binary(space_id) do
    from(m in Meeting,
      where: m.chat_space_id == ^space_id,
      order_by: [
        asc: fragment("case when ? = 'live' then 0 else 1 end", m.status),
        desc_nulls_last: m.started_at,
        desc: m.inserted_at
      ],
      limit: 1,
      select: m.id
    )
    |> Repo.one()
  end

  @doc """
  Append a segment map to the transcript's JSONB segments array.

  Each segment should contain at minimum:
  - `participant_identity` — the speaker's identity string
  - `text` — the transcribed text
  - `start_time` — segment start timestamp in milliseconds
  - `end_time` — segment end timestamp in milliseconds

  Optional:
  - `language` — ISO language code
  - `speaker_name` — display name of the speaker
  """
  @spec append_segment(String.t(), map()) :: {:ok, Transcript.t()} | {:error, term()}
  def append_segment(transcript_id, segment) when is_map(segment) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        updated_segments = (transcript.segments || []) ++ [segment]

        transcript
        |> Ecto.Changeset.change(segments: updated_segments)
        |> Repo.update()
        |> tap(fn
          {:ok, updated} ->
            # Fire-and-forget: publish the chunk on the canonical
            # `meeting:transcript_chunk` topic (+ per-room mirror) so
            # the Meeting Producer's classifier can react.
            #
            # `meeting_id` is resolved HERE, from the transcript's
            # `space_id`, and is nil only when the space genuinely has
            # no meeting. Until task 019f70b8 stage 3 this field was
            # hardcoded nil with a comment saying the classifier would
            # enrich it — nothing ever did, which was harmless while a
            # room-keyed fallback queue existed. Stage 3 retired that
            # queue and made the intent queue meeting-keyed, so a nil
            # here now means the intent has nowhere to go.
            Platform.Meetings.PubSub.broadcast_transcript_chunk(
              updated.room_id,
              %{
                room_id: updated.room_id,
                transcript_id: updated.id,
                space_id: updated.space_id,
                segment: segment,
                meeting_id: meeting_id_for_space(updated.space_id)
              }
            )

          _error ->
            :ok
        end)
    end
  end

  # ── Transcript Status Transitions ─────────────────────────────────────────

  @doc """
  Transition a transcript to 'processing' status and return it.

  Called when a meeting ends to prepare the transcript for summary generation.
  """
  @spec finalize_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def finalize_transcript(transcript_id) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{status: "processing"})
        |> Repo.update()
    end
  end

  @doc """
  Mark a transcript as complete with the generated summary text.

  On successful update, opportunistically dispatches a `meeting_scribe_completion`
  attention signal to whichever agent currently holds the `meeting_scribe` role
  (via `Platform.Federation.dispatch_scribe_attention/2`). Progressive-enhancement
  contract: the dispatch is best-effort — a nil role assignment is a silent
  no-op, and every failure path inside the Federation call is swallowed there
  via telemetry (`[:platform, :meetings, :scribe_dispatch, :assignee_unresolvable]`),
  so this function's `{:ok, transcript} | {:error, term()}` contract to the
  Summarizer stays unchanged.
  """
  @spec complete_transcript(String.t(), String.t()) ::
          {:ok, Transcript.t()} | {:error, term()}
  def complete_transcript(transcript_id, summary) when is_binary(summary) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        result =
          transcript
          |> Transcript.changeset(%{
            status: "complete",
            summary: summary,
            completed_at: DateTime.utc_now()
          })
          |> Repo.update()

        case result do
          {:ok, updated} ->
            maybe_dispatch_scribe_attention(updated)
            {:ok, updated}

          error ->
            error
        end
    end
  end

  # Opportunistic dispatch to the `meeting_scribe` role-assigned agent's linked
  # runtime. Contract is best-effort: no role assignment = silent no-op; all
  # dispatch failures are swallowed inside `Federation.dispatch_scribe_attention/2`
  # via telemetry so `complete_transcript/2`'s callers (Summarizer, backfills,
  # tests) never see a spurious error.
  defp maybe_dispatch_scribe_attention(%Transcript{} = transcript) do
    case Platform.Roles.agent_id_for_role("meeting_scribe") do
      nil ->
        :ok

      agent_id when is_binary(agent_id) ->
        Platform.Federation.dispatch_scribe_attention(agent_id, %{
          space_id: transcript.space_id,
          room_id: transcript.room_id,
          transcript_id: transcript.id,
          reason: "meeting_scribe_completion"
        })
    end
  end

  @doc """
  Hook invoked by the scribe runtime handler after it creates a completion
  canvas for a meeting transcript. Resolves the `triage_officer` role and
  dispatches a `meeting_triage_dispatch` attention signal so the triage agent
  can pick up the canvas and convert action items into tasks.

  Progressive-enhancement contract: nil role assignment is a silent no-op
  (avoids audit noise for orgs that never assigned a triage_officer). All
  dispatch failures beyond that are swallowed inside
  `Federation.dispatch_triage_attention/2` via
  `[:platform, :meetings, :triage_dispatch, :assignee_unresolvable]` telemetry
  so the caller sees a clean `:ok` regardless.
  """
  @spec on_scribe_canvas_created(Transcript.t(), Platform.Chat.Canvas.t()) :: :ok
  def on_scribe_canvas_created(%Transcript{} = transcript, %Platform.Chat.Canvas{} = canvas) do
    case safe_agent_id_for_role("triage_officer") do
      nil ->
        :ok

      agent_id when is_binary(agent_id) ->
        Platform.Federation.dispatch_triage_attention(agent_id, %{
          reason: "meeting_triage_dispatch",
          space_id: transcript.space_id,
          room_id: transcript.room_id,
          transcript_id: transcript.id,
          canvas_id: canvas.id
        })
    end
  end

  # Same rescue shape as `Meetings.IntentDispatcher.safe_agent_id_for_role/1`
  # (line 698) — swallows sandbox-teardown race errors so the hook stays
  # best-effort. Nil return short-circuits the dispatch above.
  defp safe_agent_id_for_role(role_key) do
    Platform.Roles.agent_id_for_role(role_key)
  rescue
    DBConnection.OwnershipError -> nil
    Ecto.NoResultsError -> nil
  end

  @doc """
  Update the transcript summary text.
  """
  @spec update_transcript_summary(String.t(), String.t()) ::
          {:ok, Transcript.t()} | {:error, term()}
  def update_transcript_summary(transcript_id, summary) when is_binary(summary) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{summary: summary})
        |> Repo.update()
    end
  end

  @doc """
  Mark a transcript as failed, optionally recording a human-readable
  reason in the summary column.

  Uses the existing terminal `"failed"` status — `Transcript` already
  declares it and every consumer that switches on status already has a
  non-success branch, so no new state and no migration are needed. What
  was missing is not a state but a REASON: the arity-1 clause writes
  status + `completed_at` and no summary at all, leaving a failed row as
  mute as a cheerful one.

  Emits `[:platform, :meetings, :transcription_failed]` telemetry so a
  delivery outage shows up on a dashboard instead of in a log nobody
  greps. The arity-1 clause is preserved verbatim in behaviour for the
  existing error paths that call it.
  """
  @spec fail_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def fail_transcript(transcript_id), do: fail_transcript(transcript_id, nil, nil)

  @spec fail_transcript(String.t(), String.t() | nil) ::
          {:ok, Transcript.t()} | {:error, term()}
  def fail_transcript(transcript_id, summary), do: fail_transcript(transcript_id, summary, nil)

  @doc """
  Mark a transcript failed, recording BOTH a human-readable summary and
  a machine-shaped `failure_reason`. Task 019ff6f3 stage 3.

  ## Why a third argument and not a second

  The arity-2 clause above already means "summary" and has call sites
  (`Summarizer.handle_undelivered_transcript/1` passes user-facing prose
  through it). Overloading that same position with a reason term would
  have silently reclassified those strings, so the reason gets its own
  position and the two older arities delegate here unchanged.

  ## The invariant this exists to protect

  A transcript that HOLDS SEGMENTS must never end at `status: "failed"`
  with a NULL summary AND a NULL failure_reason. Before this column, the
  `{:llm_failed, _}` / `{:complete_failed, _}` / rescue branches all
  landed exactly there: a row with real content, a terminal failure
  status, and not one byte anywhere a human could find saying why. The
  reason is stored, not logged, because a log line is not a surface.

  `reason` is any term; it is `inspect/1`ed to fit the column. Truncated
  at 500 bytes — a reason is a lead, not a payload, and an unbounded
  `inspect` of an exception struct can carry the whole transcript.
  """
  @spec fail_transcript(String.t(), String.t() | nil, term()) ::
          {:ok, Transcript.t()} | {:error, term()}
  def fail_transcript(transcript_id, summary, reason) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        attrs = %{status: "failed", completed_at: DateTime.utc_now()}
        attrs = if is_binary(summary), do: Map.put(attrs, :summary, summary), else: attrs

        attrs =
          if is_nil(reason),
            do: attrs,
            else: Map.put(attrs, :failure_reason, format_failure_reason(reason))

        case transcript |> Transcript.changeset(attrs) |> Repo.update() do
          {:ok, failed} ->
            Logger.error(
              "[Meetings] Transcript #{failed.id} marked failed " <>
                "reason=#{inspect(failed.failure_reason)}"
            )

            :telemetry.execute(
              [:platform, :meetings, :transcription_failed],
              %{presence_seconds: transcriber_presence_seconds(failed)},
              %{transcript_id: failed.id, room_id: failed.room_id}
            )

            {:ok, failed}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # A reason is a lead for a human, not a payload. `inspect/1` so any term
  # (tuple, exception struct, atom) lands as something readable, then a hard
  # byte cap so an exception carrying a whole transcript can't blow the
  # column. Binary slice, not String.slice/3, so a multibyte cut can't
  # produce invalid UTF-8 the DB rejects — hence the `valid?` trim.
  @failure_reason_max_bytes 500
  defp format_failure_reason(reason) when is_binary(reason), do: truncate_reason(reason)
  defp format_failure_reason(reason), do: reason |> inspect() |> truncate_reason()

  defp truncate_reason(text) when byte_size(text) <= @failure_reason_max_bytes, do: text

  defp truncate_reason(text) do
    text
    |> binary_part(0, @failure_reason_max_bytes)
    |> trim_to_valid_utf8()
  end

  defp trim_to_valid_utf8(text) do
    if String.valid?(text),
      do: text,
      else: trim_to_valid_utf8(binary_part(text, 0, byte_size(text) - 1))
  end

  # ── Summary Posting ────────────────────────────────────────────────────────

  @doc """
  Post a meeting summary as a system message to the space.

  The message includes the formatted summary and a download link
  for the full transcript.
  """
  @spec post_summary_to_space(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def post_summary_to_space(space_id, transcript_id, summary)
      when is_binary(space_id) and is_binary(transcript_id) and is_binary(summary) do
    content = """
    📝 **Meeting Summary**

    #{summary}

    [📄 Full transcript](/api/transcripts/#{transcript_id}/download)
    """

    with {:ok, participant} <-
           Platform.Orchestration.ExecutionSpace.ensure_system_participant(space_id) do
      attrs = %{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: String.trim(content),
        metadata: %{"source" => "meeting_summarizer", "transcript_id" => transcript_id}
      }

      case Platform.Chat.post_message(attrs) do
        {:ok, _message} -> :ok
        {:error, reason} -> {:error, {:post_failed, reason}}
      end
    end
  end

  @doc """
  Post a transcription-failure notice as a system message to the space.

  Mirrors `post_summary_to_space/3` — same system-participant
  resolution, same `content_type: "system"` message shape — so the
  notice renders through the existing message renderer with no markup
  change. Without it a failed transcription is invisible: the only
  human-reachable signal is a status column nobody reads.
  """
  @spec post_transcription_failure_to_space(String.t(), String.t()) :: :ok | {:error, term()}
  def post_transcription_failure_to_space(space_id, transcript_id)
      when is_binary(space_id) and is_binary(transcript_id) do
    content = """
    **Meeting transcript unavailable**

    This meeting was recorded, but no transcript content arrived. No summary could be produced.
    """

    with {:ok, participant} <-
           Platform.Orchestration.ExecutionSpace.ensure_system_participant(space_id) do
      attrs = %{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: String.trim(content),
        metadata: %{
          "source" => "meeting_transcription_failure",
          "transcript_id" => transcript_id
        }
      }

      case Platform.Chat.post_message(attrs) do
        {:ok, _message} -> :ok
        {:error, reason} -> {:error, {:post_failed, reason}}
      end
    end
  end

  @doc """
  Post a meeting's extracted action items as a system message to the space
  (task 019fa56b-c81f stage 3).

  Modelled on `post_summary_to_space/3` — same space resolution
  (`ExecutionSpace.ensure_system_participant/1`), same message-insert path
  (`Platform.Chat.post_message/1`), same `{:error, reason}` shape.

  The items render as a markdown checklist under a short header.

  ## This is the POST-MEETING surface, not the live one

  It used to be described here as "the delivery surface for
  `meetings.action_items`". That stopped being true in task
  019fb90f-36e3, which retargeted that key to fire per utterance DURING
  the meeting. It now lands on a canvas the RECIPIENT maintains with its
  own `canvas_create` / `canvas_patch` tools — the platform-side
  reconciler that briefly sat behind that key is gone, and nothing in
  `Platform.Responsibilities.Handlers.MeetingActionItems` writes to a
  space any more. This
  function renders the WHOLE list every time it is called, so calling it
  per utterance would repost the entire list once per action item
  mentioned — each message superseding the last, none of them the
  current state.

  Nothing here changed and nothing about it is deprecated. A
  once-per-meeting caller wanting a flat, quotable checklist in the
  transcript of the space is exactly what it is for. There is still no
  `meeting_transcripts.action_items` column and this function does not
  add one.

  An empty list is a caller error rather than a no-op here — a meeting with
  no action items is a legitimate outcome, but the decision not to post is
  the caller's to make, so this function refuses rather than silently
  inserting an empty checklist.
  """
  @doc since: "task 019fa56b-c81f stage 3"
  @spec post_action_items_to_space(String.t(), String.t(), [String.t()]) ::
          :ok | {:error, term()}
  def post_action_items_to_space(space_id, transcript_id, [])
      when is_binary(space_id) and is_binary(transcript_id),
      do: {:error, :no_items}

  def post_action_items_to_space(space_id, transcript_id, items)
      when is_binary(space_id) and is_binary(transcript_id) and is_list(items) do
    checklist = Enum.map_join(items, "\n", fn item -> "- [ ] #{String.trim(item)}" end)

    content = """
    **Action Items**

    #{checklist}

    [Full transcript](/api/transcripts/#{transcript_id}/download)
    """

    with {:ok, participant} <-
           Platform.Orchestration.ExecutionSpace.ensure_system_participant(space_id) do
      attrs = %{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: String.trim(content),
        metadata: %{"source" => "meeting_action_items", "transcript_id" => transcript_id}
      }

      case Platform.Chat.post_message(attrs) do
        {:ok, _message} -> :ok
        {:error, reason} -> {:error, {:post_failed, reason}}
      end
    end
  end

  @doc """
  Post a "summary fallback fired" notice as a system message to the space.

  Called by `Platform.Meetings.SummarizerSweeper` after the legacy summary
  path completes (successfully or otherwise) for a stalled router dispatch.
  Names the previously-assigned summarizer agent (best-effort `@slug`
  mention) so an operator can jump straight to Control Center → Roles and
  reassign the responsibility away from the dead runtime.

  The `mode` argument is either `:completed` (legacy finished the summary)
  or `:also_failed` (legacy path also errored — human attention required).
  Both shapes are backend-only system messages; no @broadcast, no email.

  `previously_assigned_agent` may be `nil` — the notice degrades to
  "The assigned summarizer" rather than crashing. Agent → user_id mention
  resolution is skipped because `Platform.Agents.Agent` does not carry a
  `user_id` foreign key (agents belong to a workspace, not a user). Any
  legacy-format `@<slug>` still gets highlighted by
  `Platform.Chat.ContentRenderer.decorate_legacy_mentions/1`.

  ## Options

    * `:previously_assigned_agent` — agent slug string or `nil`
    * `:stalled_for_ms` — non-negative integer milliseconds; formatted to
      human-readable ("47 seconds", "12 minutes", "1 hour", "2 hours")
    * `:mode` — `:completed` (default) or `:also_failed`

  Task 019f2566 stage 5.
  """
  @doc since: "task 019f2566 stage 5"
  @spec post_fallback_notice(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def post_fallback_notice(space_id, transcript_id, opts)
      when is_binary(space_id) and is_binary(transcript_id) and is_map(opts) do
    previously_assigned_agent = Map.get(opts, :previously_assigned_agent)
    stalled_for_ms = Map.get(opts, :stalled_for_ms, 0)
    mode = Map.get(opts, :mode, :completed)

    content = fallback_notice_content(mode, previously_assigned_agent, stalled_for_ms)

    metadata = %{
      "source" => "meeting_summarizer_fallback",
      "transcript_id" => transcript_id,
      "mode" => Atom.to_string(mode),
      "previously_assigned_agent" => previously_assigned_agent,
      "stalled_for_ms" => stalled_for_ms
    }

    with {:ok, participant} <-
           Platform.Orchestration.ExecutionSpace.ensure_system_participant(space_id) do
      attrs = %{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: String.trim(content),
        metadata: metadata
      }

      case Platform.Chat.post_message(attrs) do
        {:ok, _message} -> :ok
        {:error, reason} -> {:error, {:post_failed, reason}}
      end
    end
  rescue
    # `Chat.add_participant/2` raises `Ecto.ConstraintError` on a missing
    # `spaces.id` FK rather than returning a changeset error. Coerce so
    # SummarizerSweeper can pattern-match `{:error, _}` without a
    # try/rescue of its own.
    error in Ecto.ConstraintError ->
      {:error, {:space_not_found, error.constraint}}
  end

  defp fallback_notice_content(:completed, previously_assigned_agent, stalled_for_ms) do
    assignee_phrase = fallback_notice_assignee_phrase(previously_assigned_agent)
    window = humanize_ms(stalled_for_ms)

    """
    ⚠️ **Summary fallback**

    #{assignee_phrase} did not respond within #{window}. This summary was generated by the legacy LLM path instead. To reassign the `meetings.summarize` responsibility, visit [Control Center → Roles](/control-center/roles).
    """
  end

  defp fallback_notice_content(:also_failed, previously_assigned_agent, stalled_for_ms) do
    assignee_phrase = fallback_notice_assignee_phrase(previously_assigned_agent)
    window = humanize_ms(stalled_for_ms)

    """
    ⚠️ **Summary fallback also failed**

    #{assignee_phrase} did not respond within #{window}, and the legacy LLM path also errored. Manual attention needed — visit [Control Center → Roles](/control-center/roles) to reassign `meetings.summarize`.
    """
  end

  defp fallback_notice_assignee_phrase(nil), do: "The assigned summarizer"

  defp fallback_notice_assignee_phrase(slug) when is_binary(slug) and slug != "" do
    "The assigned summarizer (`@#{slug}`)"
  end

  defp fallback_notice_assignee_phrase(_), do: "The assigned summarizer"

  # Human-readable "how long did we wait" formatter for the fallback
  # notice. Deliberately coarse — the reader only cares about the
  # order of magnitude, and the exact millisecond count lives in
  # message metadata for anyone who does.
  defp humanize_ms(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms < 1_000 -> "#{ms} ms"
      ms < 60_000 -> "#{div(ms, 1_000)} seconds"
      ms < 3_600_000 -> pluralize(div(ms, 60_000), "minute")
      true -> pluralize(div(ms, 3_600_000), "hour")
    end
  end

  defp humanize_ms(_), do: "the expected window"

  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(n, unit), do: "#{n} #{unit}s"

  # ── Agent Token Generation ────────────────────────────────────────

  @doc """
  Generate a LiveKit access token for an agent to join a room.

  Accepts either an `%Agent{}` struct or an agent ID string.
  Uses the agent's slug as identity and name for the token.

  ## Options

    * `:ttl` — Token TTL in seconds (default: 3600)
    * `:can_publish` — Whether the agent can publish (default: true)
    * `:can_subscribe` — Whether the agent can subscribe (default: true)
    * `:can_publish_data` — Whether the agent can publish data (default: true)
  """
  @spec generate_agent_token(Agent.t() | binary(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def generate_agent_token(agent_or_id, room_name, opts \\ [])

  def generate_agent_token(%Agent{} = agent, room_name, opts) do
    identity = "agent:#{agent.slug}"
    name = agent.name || agent.slug
    config = livekit_config()
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(api_key) or api_key == "" or is_nil(api_secret) or api_secret == "" do
      {:error, :livekit_not_configured}
    else
      ttl = Keyword.get(opts, :ttl, 3600)
      now = System.system_time(:second)

      claims = %{
        "iss" => api_key,
        "sub" => identity,
        "name" => name,
        "nbf" => now,
        "exp" => now + ttl,
        "jti" => Ecto.UUID.generate(),
        "video" => %{
          "room" => room_name,
          "roomJoin" => true,
          "canPublish" => Keyword.get(opts, :can_publish, true),
          "canSubscribe" => Keyword.get(opts, :can_subscribe, true),
          "canPublishData" => Keyword.get(opts, :can_publish_data, true)
        }
      }

      {:ok, encode_jwt(claims, api_secret)}
    end
  end

  def generate_agent_token(agent_id, room_name, opts) when is_binary(agent_id) do
    case resolve_agent(agent_id) do
      %Agent{} = agent -> generate_agent_token(agent, room_name, opts)
      nil -> {:error, :agent_not_found}
    end
  end

  # Resolve an agent by UUID *or* slug. `agent_id` reaches the three call sites
  # below from meeting-invite payloads and LiveView events, where an agent slug
  # is at least as likely as a UUID — so an unguarded `Repo.get(Agent, id)`
  # both raises on a slug and misses the agent the caller meant.
  #
  # Platform.UUID.valid?/1, NOT `Ecto.UUID.cast/1`: a bare cast hex-encodes any
  # 16-byte binary and returns {:ok, _}, so a 16-character slug would clear it,
  # skip the slug fallback, and raise inside Repo anyway. Branch structure
  # mirrors Platform.Agents.Orchestration.fetch_agent/1; the predicate does not.
  defp resolve_agent(agent_id) when is_binary(agent_id) do
    if Platform.UUID.valid?(agent_id) do
      Repo.get(Agent, agent_id)
    else
      Repo.get_by(Agent, slug: agent_id)
    end
  end

  defp resolve_agent(_other), do: nil

  # ── Meeting Join Dispatch ─────────────────────────────────────────

  @doc """
  Dispatch a `meeting_join` signal to an agent's runtime, instructing it
  to connect to a LiveKit room.

  Generates a LiveKit token for the agent, then broadcasts the signal
  via PubSub. The runtime is expected to use the token to connect
  its voice worker to the room.

  ## The topic is `runtime:<runtime_id>`, never `runtime:agent:<agent.id>`

  Until task 01a04f31 this function broadcast on `"runtime:agent:\#{agent.id}"`.
  No client can ever join that topic: `PlatformWeb.RuntimeChannel.join/3`
  matches `"runtime:" <> runtime_id` and requires it to equal
  `socket.assigns.runtime_id`, which `PlatformWeb.RuntimeSocket.connect/3`
  assigns from `AgentRuntime.runtime_id` — the external, human-readable
  STRING (`"rowan-claude-agent-1"`), not an agent UUID. Because
  `Phoenix.Endpoint.broadcast/3` returns `:ok` whether or not anyone is
  subscribed, the old code logged "dispatched" and delivered to nobody.

  `Platform.Meetings.IntentRuntimeAdapter`'s moduledoc names this exact
  hazard — "Using the agent UUID would publish into a topic with no
  subscribers: a silent, green-tests, zero-delivery failure." This
  function was the one place in `lib/` that still did it. It now resolves
  through `IntentRuntimeAdapter.resolve_target/1`, the module that
  already owns agent -> runtime -> topic resolution, rather than growing
  a second resolver alongside it.

  ## `persona` and `voice` (01a03f4f)

  `persona` shipped in this payload with no producer and no reader — a key
  that was always `nil` because nothing ever put `:persona` in `context`.
  Task 01a04cbc-e904 was opened to ask whether to drop it. It now has a
  producer: the agent's `VOICE.md` workspace file, via
  `Platform.Agents.Voice.personality_for/1`. An explicit `context[:persona]`
  still wins, so a caller that knows better than the stored file can override
  it; absent that, the agent's own spoken-register markdown is sent.

  `voice` is a SEPARATE key rather than more fields inside `persona`. A voice
  id is a provider selection, not a personality, and collapsing the two would
  leave a key named `persona` carrying a vendor's voice UUID. It is `nil` for
  an agent with no voice configured, which a worker reads as "stay muted" —
  distinct from a `%{}` that could be a half-written selection.

  ## No runtime is an error, not a silent success

  An agent with no linked `AgentRuntime` has nothing listening for it
  anywhere, so `{:error, :no_runtime}` is returned and logged at
  `error`. The previous behaviour — return `:ok` after a broadcast into
  the void — is precisely the failure mode this change exists to remove,
  so it is not preserved for compatibility.
  """
  @spec dispatch_meeting_join(Agent.t() | binary(), String.t(), map()) ::
          :ok | {:error, term()}
  def dispatch_meeting_join(agent_or_id, room_name, context \\ %{})

  def dispatch_meeting_join(%Agent{} = agent, room_name, context) do
    with {:ok, target} <- resolve_meeting_join_target(agent),
         {:ok, token} <- generate_agent_token(agent, room_name) do
      payload = %{
        room_name: room_name,
        token: token,
        agent_identity: "agent:#{agent.slug}",
        agent_name: agent.name || agent.slug,
        space_id: Map.get(context, :space_id),
        meeting_id: Map.get(context, :meeting_id),
        persona: Map.get(context, :persona) || Voice.personality_for(agent),
        voice: Voice.config_for(agent),
        livekit_url: livekit_url()
      }

      topic = target.topic

      case PlatformWeb.Endpoint.broadcast(topic, "meeting_join", payload) do
        :ok ->
          Logger.info(
            "[Meetings] dispatched meeting_join to agent=#{agent.slug} " <>
              "runtime=#{target.runtime_id} room=#{room_name}"
          )

          :ok

        {:error, reason} ->
          Logger.error("[Meetings] broadcast meeting_join failed to #{topic}: #{inspect(reason)}")

          {:error, :broadcast_failed}
      end
    end
  end

  def dispatch_meeting_join(agent_id, room_name, context) when is_binary(agent_id) do
    case resolve_agent(agent_id) do
      %Agent{} = agent -> dispatch_meeting_join(agent, room_name, context)
      nil -> {:error, :agent_not_found}
    end
  end

  @doc """
  The runtime topic a `meeting_join` for this agent would be broadcast on.

  Exposed so a caller — and a test — can name the topic without rebuilding
  the string, and so `invite_agent/3` can pre-flight the resolution before
  it writes a roster row. Delegates to
  `IntentRuntimeAdapter.resolve_target/1`; see this module's
  `dispatch_meeting_join/3` docs for why it is not a local reimplementation.
  """
  @spec meeting_join_topic(Agent.t()) :: {:ok, binary()} | {:error, :no_runtime}
  def meeting_join_topic(%Agent{} = agent) do
    with {:ok, target} <- resolve_meeting_join_target(agent), do: {:ok, target.topic}
  end

  # `resolve_target/1` distinguishes :no_target_agent / :agent_not_found /
  # :no_runtime; reaching it from an `%Agent{}` struct in hand, only the
  # last is possible, so the error is normalised to that one fact.
  defp resolve_meeting_join_target(%Agent{} = agent) do
    case IntentRuntimeAdapter.resolve_target(agent) do
      {:ok, target} ->
        {:ok, target}

      {:error, _reason} ->
        Logger.error(
          "[Meetings] meeting_join NOT dispatched: agent=#{agent.slug} id=#{agent.id} " <>
            "has no linked AgentRuntime, so no runtime can receive a join"
        )

        {:error, :no_runtime}
    end
  end

  # ── Agent Meeting Participation ──────────────────────────────────

  @doc """
  Invite an agent to join a meeting room.

  Authorizes `inviting_user` as a writer of the room's space, records the
  agent as a participant, and dispatches a `meeting_join` signal to the
  agent's runtime.

  ## Authorization

  `Platform.Chat.SpaceAccess.authorize_writer/2` — the repo's single
  space-write choke point, composed HERE rather than in the LiveView for the
  reason that module's moduledoc gives: a guard in the handler protects one
  caller, a guard in the context protects every caller not yet written. This
  function had no caller at all until task 01a04c2f, so the check and the
  first call site arrive together and no caller predates it.

  `inviting_user` accepts anything `SpaceAccess` normalises — a
  `%Platform.Accounts.User{}` (what a LiveView holds), `{:user, id}` or
  `{:agent, id}`. Anything else, `nil` included, is no principal and DENIES;
  the parameter was previously ignored outright.

  The pre-flight `generate_agent_token/2` whose result is discarded is
  deliberate and predates this change: it fails the invite BEFORE a
  participant row is written when LiveKit is unconfigured, so a meeting
  cannot acquire a roster entry for an agent that could never be dispatched.
  `dispatch_meeting_join/3` mints the token actually sent.

  ## An agent with no runtime is refused, for that same reason

  `meeting_join_topic/1` is pre-flighted alongside the token, and for the
  identical argument: an agent with no linked `AgentRuntime` has nothing
  listening on any topic, so it "could never be dispatched" in exactly the
  sense the LiveKit pre-flight already guards against. Writing a
  `meeting_participants` row for it would put a name on the roster that can
  never speak, and — because the row makes the agent no longer *invitable*
  — would remove the control that is the only way to try again. So
  `{:error, :no_runtime}` is returned before any row is written.

  The double resolution (here and again inside `dispatch_meeting_join/3`)
  is deliberate and follows the precedent
  `IntentRuntimeAdapter`'s moduledoc sets for the same shape of problem: it
  is one extra `Repo.get/2` on a human-speed path, and it keeps
  `dispatch_meeting_join/3` a self-contained function that every other
  caller can use without knowing to pre-resolve.

  ## A second invite reuses the first invite's row (01a04e0f)

  The guard above stops short of the case that actually hurt: an agent
  whose runtime resolves but whose voice worker is not connected. Nothing
  is listening on the topic, `Phoenix.Endpoint.broadcast/3` returns `:ok`
  anyway, and the invite is lost — a failure that is not detectable here,
  at broadcast time, or anywhere else on this path. Retrying is therefore
  the only recovery, and `PlatformWeb.MeetingLive` now keeps offering the
  control until the agent actually publishes into the room.

  So this function must be safe to call twice. `participant_joined/2` is a
  plain insert, so it is called only when no active row exists for this
  room + agent; a retry reuses the row it already wrote and re-dispatches.
  Same find-or-reuse shape, and the same reason, as
  `upsert_live_participant/2`: one stable row per participant, not one per
  delivery attempt.
  """
  @spec invite_agent(Room.t(), Agent.t(), SpaceAccess.actor()) ::
          {:ok, Participant.t()} | {:error, term()}
  def invite_agent(%Room{} = room, %Agent{} = agent, inviting_user) do
    with {:ok, _writer} <- SpaceAccess.authorize_writer(room.space_id, inviting_user),
         {:ok, _topic} <- meeting_join_topic(agent),
         {:ok, _token} <-
           generate_agent_token(agent, room.livekit_room_name),
         {:ok, participant} <- invite_participant_row(room, agent) do
      # Dispatch to agent runtime
      dispatch_meeting_join(agent, room.livekit_room_name, %{space_id: room.space_id})
      {:ok, participant}
    end
  end

  # Find-or-insert the invited agent's roster row. Deliberately writes no
  # `metadata` — `metadata["identity"]` is what `upsert_live_participant/2`
  # stamps when a worker really publishes into the LiveKit room, and
  # `PlatformWeb.MeetingLive` reads its absence as "invited, never arrived".
  # Putting anything identity-shaped here would make a dispatch nobody
  # received look exactly like a join, which is the defect 01a04e0f is about.
  defp invite_participant_row(%Room{} = room, %Agent{} = agent) do
    case find_active_participant(room.id, %{agent_id: agent.id}, agent.name) do
      %Participant{} = existing -> {:ok, existing}
      nil -> participant_joined(room, %{display_name: agent.name, agent_id: agent.id})
    end
  end

  @doc """
  The capability a client must declare to be offered a seat in a call.

  Matches the string `Platform.Meetings.IntentRuntimeAdapter` dispatches
  against and that `suite-voice-worker` sends in its join payload. It is a
  plain string on purpose: `RuntimeChannel` deliberately keeps `features` an
  open set rather than a server-side allowlist, so a new client capability
  must not need a core deploy before it can be reported.
  """
  @voice_feature "meeting_voice"
  def voice_feature, do: @voice_feature

  @doc """
  Whether this agent's runtime can join a LiveKit room: `:capable`,
  `:incapable`, or `:unknown`.

  ## Three values, because two would throw away the distinction core paid for

  `PlatformWeb.RuntimeChannel.persist_client_info/2` writes `features` on
  every declared join, INCLUDING as `[]`, and its `declared?` gate skips the
  write entirely for a client that sends no `client_info` at all. Its own
  comment says why: so *"never told us"* stays distinguishable from *"told us
  it lacks the feature"*. Collapsing this to a boolean would discard that at
  the first consumer.

  The two answers differ in what they license:

  - `:incapable` is **positive evidence**. The client declared its features
    and voice was not among them. Excluding it from the invite list removes a
    control that could only ever have failed.
  - `:unknown` is **absence of evidence** — a legacy bridge, or a client that
    has not reconnected since the field existed. It is still offered. Hiding a
    client we have never heard from would be the same defect as task 01a0554f
    in a new place: a thing the user cannot see, cannot try, and gets no
    reason for. Since that task the failing ack reports itself, so an
    optimistic offer here is recoverable rather than a dead end.

  ## An agent with no linked runtime is `:unknown`, not `:incapable`

  Tempting to call it incapable — `dispatch_meeting_join/3` refuses it with
  `{:error, :no_runtime}`, so a join cannot land. But this function answers
  *what has this client declared about itself*, and an agent with no runtime
  has declared nothing. The two failures also differ in kind, which is the
  part that matters to whoever is looking at the screen:

  - **no runtime** is transient and actionable. The runtime can reconnect a
    second later, and `PlatformWeb.MeetingLive` already flashes *"That agent
    has no connected runtime, so it cannot join the meeting."* — added by task
    01a04f31 precisely because it is the one failure a human can do something
    about. Hiding the control would take that message away.
  - **declared without voice** is a property of the build that is running. No
    amount of waiting changes it, and there is nothing to tell the user
    except that the control was never real.

  So this returns `:unknown` and the no-runtime path keeps its own, better
  error.
  """
  @spec join_capability(Agent.t()) :: :capable | :incapable | :unknown
  def join_capability(%Agent{} = agent) do
    case Federation.get_runtime_for_agent(agent) do
      %AgentRuntime{metadata: metadata} -> capability_from_metadata(metadata)
      _ -> :unknown
    end
  end

  def join_capability(_other), do: :unknown

  # Read through `metadata["client_info"]["features"]`, the shape
  # `persist_client_info/2` writes. A `client_info` that exists but carries no
  # `features` key is treated as undeclared rather than empty: only a list
  # that is actually present is evidence about what the client can do.
  defp capability_from_metadata(metadata) when is_map(metadata) do
    with %{} = client_info <- Map.get(metadata, "client_info"),
         features when is_list(features) <- Map.get(client_info, "features") do
      if @voice_feature in features, do: :capable, else: :incapable
    else
      _ -> :unknown
    end
  end

  defp capability_from_metadata(_), do: :unknown

  @doc """
  Record a runtime's answer to a `meeting_join` dispatch.

  ## Why this exists: the ack already came back and nothing read it

  `PlatformWeb.RuntimeChannel.handle_in("meeting_join_ack", ...)` logged the
  ack, emitted `[:platform, :meetings, :agent_join_ack]`, and returned
  `{:noreply, socket}`. So when a runtime answered `status: "error"` — as a
  text-only agent with no voice worker does — core *knew* the join had failed
  and the meeting screen went on saying "… is joining the meeting."
  indefinitely. Five test meetings were sat through on the strength of that
  flash (task 01a0554f).

  This is a different defect from the silent ones around it. The corrective
  signal was not missing, it was **unconsumed**. So the fix is not another
  detector: it is reading the receipt that already arrives.

  ## Only a FAILING ack is surfaced

  A `"joined"` ack means the worker accepted the dispatch, NOT that it
  published into the LiveKit room — those come apart exactly the way
  `invite_participant_row/2` documents. Arrival is already evidenced by
  `upsert_live_participant/2` stamping `metadata["identity"]`, which is what
  `PlatformWeb.MeetingLive.pending_invite_agent_ids/1` reads. Broadcasting a
  success here would let an accepted-but-never-arrived join render as arrival
  and re-open 01a04e0f from the other side.

  So: failure is news, success is not.

  ## The roster row is deliberately left in place

  A failed join does not remove the participant row `invite_agent/3` wrote.
  Retrying is the documented recovery for a lost dispatch, `invite_agent/3`
  is safe to call twice, and `MeetingLive` keeps offering the control until
  the agent actually publishes. Clearing the row here would take the retry
  away at the moment it is most wanted.

  Returns `:ok` in every case, including an unknown room: an ack for a room
  that has ended is a late receipt, not a caller error.
  """
  @spec record_agent_join_ack(binary() | nil, String.t(), String.t()) :: :ok
  def record_agent_join_ack(agent_id, room_name, status)
      when is_binary(room_name) and is_binary(status) do
    if join_ack_success?(status) do
      :ok
    else
      broadcast_agent_join_failure(agent_id, room_name, status)
    end
  end

  def record_agent_join_ack(_agent_id, _room_name, _status), do: :ok

  # "joined" is the documented success token and the default RuntimeChannel
  # applies when a client omits `status` entirely. Anything else — "error",
  # a client's own spelling of failure, a token added by a future worker — is
  # treated as a failure and shown.
  #
  # That default direction is the deliberate one. An unrecognised token
  # rendering as "could not join" is a visible, retryable wrong answer; the
  # same token silently rendering as success is the defect this function
  # exists to remove.
  defp join_ack_success?(status), do: String.downcase(String.trim(status)) == "joined"

  defp broadcast_agent_join_failure(agent_id, room_name, status) do
    case get_room_by_name(room_name) do
      %Room{} = room ->
        agent = if is_binary(agent_id), do: resolve_agent(agent_id), else: nil

        MeetingsPubSub.broadcast_room(
          room.id,
          {:agent_join_failed,
           %{
             agent_id: agent_id,
             agent_name: (agent && agent.name) || "That agent",
             room_name: room_name,
             status: status
           }}
        )

      nil ->
        Logger.info("[Meetings] meeting_join_ack status=#{status} for unknown room #{room_name}")

        :ok
    end
  end

  @doc """
  Dismiss an agent from a meeting room.

  Records the agent's participant as having left.
  """
  @spec dismiss_agent(Room.t(), binary()) :: {:ok, Participant.t()} | {:error, :not_found}
  def dismiss_agent(%Room{} = room, agent_id) do
    agent = resolve_agent(agent_id)
    name = if agent, do: agent.name, else: "Agent"
    participant_left(room, name)
  end

  # ── Presence Broadcasting (private) ──────────────────────────────────────

  @doc """
  Broadcast a presence change for a room.

  Sends `{:meeting_presence, %{room_id, event}}` on the room topic AND
  `{:meeting_presence_summary, %{space_id}}` on the summary topic.
  Also sends a `{:meeting_presence_update, %{space_id, active, count}}`
  on the per-space presence topic.
  """
  @spec broadcast_presence_change(binary(), binary() | nil) :: :ok
  def broadcast_presence_change(_room_id, nil), do: :ok

  def broadcast_presence_change(room_id, space_id) when is_binary(space_id) do
    count = active_participant_count_for_room(room_id)
    active = count > 0

    # Per-space presence topic (ChatLive header)
    MeetingsPubSub.broadcast_presence(
      space_id,
      {:meeting_presence_update, %{space_id: space_id, active: active, count: count}}
    )

    # Global summary topic (sidebar)
    MeetingsPubSub.broadcast_presence_summary(space_id)

    :ok
  end

  def broadcast_presence_change(_room_id, _space_id), do: :ok

  # ── Private helpers ──────────────────────────────────────────────────────

  defp guard_enabled do
    if enabled?(), do: :ok, else: {:error, :meetings_disabled}
  end

  @doc false
  def room_name_for_space(space_id) do
    "space-#{space_id}"
  end

  defp livekit_config do
    app_config = Application.get_env(:platform, :livekit)

    if is_list(app_config) and app_config != [] do
      app_config
    else
      # Fall back to System env vars for backward compatibility
      url = System.get_env("LIVEKIT_URL")
      key = System.get_env("LIVEKIT_API_KEY")
      secret = System.get_env("LIVEKIT_API_SECRET")

      if url || key || secret do
        [url: url, api_key: key, api_secret: secret]
      else
        []
      end
    end
  end

  @doc false
  # Public so test helpers (`Platform.LivekitTestHelpers`) can mint fixture
  # JWTs without duplicating the HS256 machinery. Not part of the stable
  # API — treat as test-support only.
  def encode_jwt(claims, secret) do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload_b64 = claims |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = "#{header_b64}.#{payload_b64}"
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)
    sig_b64 = Base.url_encode64(signature, padding: false)

    "#{signing_input}.#{sig_b64}"
  end

  defp sign_jwt(claims, secret) do
    encode_jwt(claims, secret)
  end

  @doc """
  Verify a LiveKit webhook JWT against the raw request body.

  LiveKit signs webhooks with HS256 under the configured API secret and
  embeds a `sha256` claim that is the **base64-standard-encoded SHA256
  hash of the raw request body**. Verification therefore requires three
  things: signature validity, body-hash match, and unexpired `exp`.

  ## Return values

    * `:ok` — signature valid, hash matches, unexpired.
    * `{:error, :missing_secret}` — `LIVEKIT_API_SECRET` unset.
    * `{:error, :malformed}` — token missing, not three segments, or
      claim payload undecodable.
    * `{:error, :bad_signature}` — HS256 signature mismatch.
    * `{:error, :body_hash_mismatch}` — `sha256` claim doesn't match the
      body's SHA256.
    * `{:error, :expired}` — `exp` claim in the past.

  Timing-safe compares (`Plug.Crypto.secure_compare/2`) are used for
  both signature and body-hash checks so remote callers can't distinguish
  "bad sig" vs "bad hash" by response latency.
  """
  @doc since: "fix: LiveKit webhook signature verification (task 019f3312 stage 2)"
  @spec verify_livekit_jwt(String.t() | nil, binary()) ::
          :ok
          | {:error,
             :missing_secret | :malformed | :bad_signature | :body_hash_mismatch | :expired}
  def verify_livekit_jwt(token, raw_body) when is_binary(raw_body) do
    config = livekit_config()
    secret = config[:api_secret]

    cond do
      is_nil(secret) or secret == "" ->
        {:error, :missing_secret}

      not is_binary(token) or token == "" ->
        {:error, :malformed}

      true ->
        do_verify_livekit_jwt(token, raw_body, secret)
    end
  end

  defp do_verify_livekit_jwt(token, raw_body, secret) do
    # Compare signatures TEXTUALLY against our canonical `Base.url_encode64`
    # output rather than decoding `sig_b64` to bytes and byte-comparing.
    #
    # Why: HMAC-SHA256 emits 32 bytes → 43 base64url chars, and the last char
    # holds 4 data bits + 2 unused padding bits. `Base.url_decode64/2` (non-
    # strict) accepts any of the four textual encodings that only differ in
    # those unused bits (e.g. "…A", "…B", "…C", "…D" all decode identically
    # when the trailing data nibble is 0000). Decoding-then-byte-comparing
    # would therefore accept ~4 textually-distinct JWT strings per valid
    # signature and let an attacker replay any intercepted webhook N times
    # under textually-different tokens. Comparing the canonical encoding
    # keeps the JWT one-canonical-string-per-signature invariant intact.
    with [header_b64, payload_b64, sig_b64] <- String.split(token, ".", parts: 3),
         signing_input = "#{header_b64}.#{payload_b64}",
         expected_b64 =
           :crypto.mac(:hmac, :sha256, secret, signing_input)
           |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(expected_b64, sig_b64) || :bad_signature,
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, claims} <- Jason.decode(payload_json) do
      check_claims(claims, raw_body)
    else
      :bad_signature -> {:error, :bad_signature}
      _ -> {:error, :malformed}
    end
  end

  defp check_claims(%{} = claims, raw_body) do
    with :ok <- check_exp(claims["exp"]),
         :ok <- check_body_hash(claims["sha256"], raw_body) do
      :ok
    end
  end

  defp check_claims(_, _), do: {:error, :malformed}

  defp check_exp(exp) when is_integer(exp) do
    if exp < System.system_time(:second), do: {:error, :expired}, else: :ok
  end

  # LiveKit historically always includes `exp`; be strict — a token
  # without `exp` is malformed for our purposes.
  defp check_exp(_), do: {:error, :malformed}

  defp check_body_hash(claim_hash, raw_body) when is_binary(claim_hash) do
    computed = :crypto.hash(:sha256, raw_body) |> Base.encode64()

    if Plug.Crypto.secure_compare(computed, claim_hash) do
      :ok
    else
      {:error, :body_hash_mismatch}
    end
  end

  defp check_body_hash(_, _), do: {:error, :malformed}

  defp build_jwt(identity, name, grants) do
    config = livekit_config()
    now = System.system_time(:second)
    ttl = 6 * 60 * 60

    claims =
      Map.merge(grants, %{
        "iss" => config[:api_key],
        "sub" => identity,
        "nbf" => now,
        "exp" => now + ttl,
        "jti" => Ecto.UUID.generate(),
        "name" => name
      })

    encode_jwt(claims, config[:api_secret])
  end

  @doc """
  Build the JSON body sent to LiveKit's `RoomService/CreateRoom` Twirp endpoint.

  Includes the `agents` field so LiveKit dispatches the `meeting-transcriber`
  worker at room-creation time. The agent dispatch MUST live on the CreateRoom
  call because `ensure_livekit_room/1` runs server-side before any participant
  joins — the JWT `roomConfig.agents` path silently no-ops on an existing room.

  Note: LiveKit's REST/Twirp CreateRoom uses snake_case `agent_name`; the JWT
  `roomConfig.agents` path uses camelCase `agentName`. Two different LiveKit
  serialization conventions — do not normalize.
  """
  @doc since: "fix: transcriber dispatch (task 019ee053)"
  def build_create_room_body(room_name) when is_binary(room_name) do
    Jason.encode!(%{
      "name" => room_name,
      "empty_timeout" => 300,
      "agents" => [%{"agent_name" => "meeting-transcriber"}]
    })
  end

  defp ensure_livekit_room(room_name) do
    config = livekit_config()
    url = config[:url]
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(url) or is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      token =
        service_token(api_key, api_secret)

      body = build_create_room_body(room_name)

      twirp_url =
        url
        |> String.replace_prefix("wss://", "https://")
        |> String.replace_prefix("ws://", "http://")

      case Req.post("#{twirp_url}/twirp/livekit.RoomService/CreateRoom",
             body: body,
             headers: [
               {"content-type", "application/json"},
               {"authorization", "Bearer #{token}"}
             ],
             receive_timeout: 10_000
           ) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp service_token(api_key, api_secret) do
    now = System.system_time(:second)

    claims = %{
      "iss" => api_key,
      "nbf" => now,
      "exp" => now + 600,
      "video" => %{"roomCreate" => true}
    }

    encode_jwt(claims, api_secret)
  end

  defp active_participant_count_for_room(room_id) do
    from(p in Participant,
      where: p.room_id == ^room_id and is_nil(p.left_at)
    )
    |> Repo.aggregate(:count)
  end
end
