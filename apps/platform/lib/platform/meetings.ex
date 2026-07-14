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

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings.{Meeting, Participant, Recording, Room, Transcript}
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  require Logger

  # ── Meeting records (ADR 0042) ────────────────────────────────────────────
  #
  # SCAFFOLD: the authoritative Meeting context API is owned by sibling
  # task 019e2474-11c1 ("Meetings: schema, context, MCP create_meeting
  # tool") in the meeting-module-basic-v2 stack. The function below is
  # the minimal read surface that `PlatformWeb.MeetingLive` (this stack
  # member's embedded chat panel) binds against. At rollup, reconcile
  # with the sibling's broader context API.

  @doc """
  Fetch a meeting by its URL slug, preloading the bound `:chat_space`.

  Returns the `%Meeting{}` (with `:chat_space` populated) or `nil` when
  no meeting matches. `MeetingLive` treats `nil` as a clean not-found
  and redirects rather than crashing. The chat space's `slug` is needed
  to drive the embedded `live_render(ChatLive)` panel.

  Sibling task 019e2474-11c1 ships a project-scoped `(project_id,
  slug)` arity. This single-arg lookup is what the `/meetings/:slug`
  route binds against pre-rollup; at rollup we reconcile to the
  project-scoped version.
  """
  @spec get_meeting_by_slug(String.t()) :: Meeting.t() | nil
  def get_meeting_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Meeting, slug: slug) do
      nil -> nil
      meeting -> Repo.preload(meeting, :chat_space)
    end
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
  `:host_participant_id`.

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
         :ok <- require_present(name, :name) do
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

          space =
            case Chat.create_space(%{
                   name: name,
                   slug: chat_space_slug,
                   kind: "meeting",
                   metadata: %{"project_id" => project_id}
                 }) do
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
            livekit_room_name: "meeting-#{meeting_id}"
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
          # via `Platform.Tasks.list_projects/0` and uses this signal to
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

  @doc "Get a meeting by ID. Returns `nil` if not found."
  @spec get_meeting(binary()) :: Meeting.t() | nil
  def get_meeting(id), do: Repo.get(Meeting, id)

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
  List every meeting across all projects, newest first.

  Used by the global `/meetings` index LV (no project context in the
  route). When project-scoped routing arrives the index will narrow to
  `list_meetings_for_project/1`.
  """
  @spec list_all_meetings() :: [Meeting.t()]
  def list_all_meetings do
    Meeting
    |> order_by([m], desc: m.inserted_at)
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
  Resolve a guest-invite URL (URL `slug` + signed `token`) into the
  state a guest ingress LiveView needs to render.

  Encapsulates the branching the guest ingress LiveView needs:

    * `GuestInvite.verify/1` — signature + expiry check.
    * URL-vs-payload `meeting_slug` tampering guard — payload slug must
      equal the URL slug (else `{:error, :invalid}`).
    * `get_meeting_by_slug/1` — meeting existence + `:chat_space` preload
      (a deleted meeting whose token was signed pre-deletion resolves to
      `{:error, :invalid}`).
    * Display-name branching — `nil` in the payload signals the
      self-entry flow (`:name_entry`), a non-empty binary lands the guest
      straight `:in_meeting`.

  `PlatformWeb.MeetingLive` (with `chrome_mode: :none` on the `meet.`
  host scope) mounts against this resolver so guest-surface behavior
  can't drift from what `Meetings` intends to return.

  Return shape:

    * `{:ok, %{state: :name_entry, meeting: %Meeting{}}}` — token
      verified, payload carried `display_name: nil`. The returned
      meeting has `:chat_space` preloaded (later `mint_guest_join_bundle`
      + `guest_join_event_payload` read `meeting.chat_space.slug`).
    * `{:ok, %{state: :in_meeting, meeting: %Meeting{},
      display_name: binary()}}` — token verified, payload carried a
      pre-provisioned display name. Caller should call
      `mint_guest_join_bundle/2` next.
    * `{:error, :expired}` — token past its `expires_at`.
    * `{:error, :invalid}` — signature/shape check failed, slug mismatch,
      or the meeting slug no longer resolves.
  """
  @spec resolve_guest_invite(String.t(), String.t()) ::
          {:ok, %{state: :name_entry, meeting: Meeting.t()}}
          | {:ok, %{state: :in_meeting, meeting: Meeting.t(), display_name: String.t()}}
          | {:error, :invalid | :expired}
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

      {:ok, %{meeting_slug: ^slug, display_name: display_name}} ->
        case get_meeting_by_slug(slug) do
          nil ->
            # Signature checked out but the target meeting has been
            # deleted or the slug never existed. Treat as invalid.
            {:error, :invalid}

          meeting when is_binary(display_name) ->
            {:ok, %{state: :in_meeting, meeting: meeting, display_name: display_name}}

          meeting ->
            {:ok, %{state: :name_entry, meeting: meeting}}
        end
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

  @doc "Get a room by ID."
  @spec get_room(binary()) :: Room.t() | nil
  def get_room(id), do: Repo.get(Room, id)

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

  defp cast_identity(kind, uuid) do
    case Ecto.UUID.cast(uuid) do
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
        participant_joined(
          room,
          Map.merge(fk, %{display_name: display_name, metadata: metadata})
        )
    end
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

  Returns `{:ok, token_string}` or `{:error, reason}`.
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

  @doc """
  Generate a LiveKit access token from a room name string with default options.
  """
  def generate_token(room_name, identity) when is_binary(room_name) and is_binary(identity) do
    generate_token(room_name, identity, [])
  end

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
    with :ok <- guard_enabled() do
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
    with :ok <- guard_enabled() do
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
  @spec get_transcript(String.t()) :: Transcript.t() | nil
  def get_transcript(id), do: Repo.get(Transcript, id)

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
  Get a transcript with its segments (same as get_transcript since segments
  are stored inline as JSONB, but named explicitly for clarity in the API).
  """
  @spec get_transcript_with_segments(String.t()) :: Transcript.t() | nil
  def get_transcript_with_segments(id), do: Repo.get(Transcript, id)

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

    from(t in Transcript,
      where:
        t.status == "complete" and
          not is_nil(t.completed_at) and
          t.completed_at >= ^window_start and
          t.completed_at < ^window_end,
      order_by: [asc: t.completed_at]
    )
    |> Repo.all()
  end

  @doc """
  Find the active transcript for a room, or create one if none exists.

  Returns `{:ok, transcript}` in both cases.
  """
  @spec ensure_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def ensure_transcript(%{room_id: room_id} = attrs) do
    case get_transcript_for_room(room_id) do
      nil -> create_transcript(attrs)
      transcript -> {:ok, transcript}
    end
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
            # the Meeting Producer's classifier can react. `meeting_id`
            # is nil here — a `Meeting` row may not exist yet at first
            # chunk (segments key on LiveKit `room_id` string; Meeting
            # rows are created out-of-band). The classifier enriches.
            Platform.Meetings.PubSub.broadcast_transcript_chunk(
              updated.room_id,
              %{
                room_id: updated.room_id,
                transcript_id: updated.id,
                segment: segment,
                meeting_id: nil
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
  Mark a transcript as failed.
  """
  @spec fail_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def fail_transcript(transcript_id) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Repo.update()
    end
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
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent -> generate_agent_token(agent, room_name, opts)
      nil -> {:error, :agent_not_found}
    end
  end

  # ── Meeting Join Dispatch ─────────────────────────────────────────

  @doc """
  Dispatch a `meeting_join` signal to an agent's runtime, instructing it
  to connect to a LiveKit room.

  Generates a LiveKit token for the agent, then broadcasts the signal
  via PubSub. The runtime is expected to use the token to connect
  its voice worker to the room.
  """
  @spec dispatch_meeting_join(Agent.t() | binary(), String.t(), map()) ::
          :ok | {:error, term()}
  def dispatch_meeting_join(agent_or_id, room_name, context \\ %{})

  def dispatch_meeting_join(%Agent{} = agent, room_name, context) do
    with {:ok, token} <- generate_agent_token(agent, room_name) do
      payload = %{
        room_name: room_name,
        token: token,
        agent_identity: "agent:#{agent.slug}",
        agent_name: agent.name || agent.slug,
        space_id: Map.get(context, :space_id),
        meeting_id: Map.get(context, :meeting_id),
        persona: Map.get(context, :persona),
        livekit_url: livekit_url()
      }

      topic = "runtime:agent:#{agent.id}"

      case PlatformWeb.Endpoint.broadcast(topic, "meeting_join", payload) do
        :ok ->
          Logger.info(
            "[Meetings] dispatched meeting_join to agent=#{agent.slug} room=#{room_name}"
          )

          :ok

        {:error, reason} ->
          Logger.error("[Meetings] broadcast meeting_join failed to #{topic}: #{inspect(reason)}")

          {:error, :broadcast_failed}
      end
    end
  end

  def dispatch_meeting_join(agent_id, room_name, context) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent -> dispatch_meeting_join(agent, room_name, context)
      nil -> {:error, :agent_not_found}
    end
  end

  # ── Agent Meeting Participation ──────────────────────────────────

  @doc """
  Invite an agent to join a meeting room.

  Generates a token, records the agent as a participant, and dispatches
  a `meeting_join` signal to the agent's runtime.
  """
  @spec invite_agent(Room.t(), Agent.t(), any()) ::
          {:ok, Participant.t()} | {:error, term()}
  def invite_agent(%Room{} = room, %Agent{} = agent, _inviting_user) do
    with {:ok, _token} <-
           generate_agent_token(agent, room.livekit_room_name),
         {:ok, participant} <-
           participant_joined(room, %{
             display_name: agent.name,
             agent_id: agent.id
           }) do
      # Dispatch to agent runtime
      dispatch_meeting_join(agent, room.livekit_room_name, %{space_id: room.space_id})
      {:ok, participant}
    end
  end

  @doc """
  Dismiss an agent from a meeting room.

  Records the agent's participant as having left.
  """
  @spec dismiss_agent(Room.t(), binary()) :: {:ok, Participant.t()} | {:error, :not_found}
  def dismiss_agent(%Room{} = room, agent_id) do
    agent = Repo.get(Agent, agent_id)
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
    with [header_b64, payload_b64, sig_b64] <- String.split(token, ".", parts: 3),
         signing_input = "#{header_b64}.#{payload_b64}",
         {:ok, sig} <- Base.url_decode64(sig_b64, padding: false),
         expected = :crypto.mac(:hmac, :sha256, secret, signing_input),
         true <- Plug.Crypto.secure_compare(expected, sig) || :bad_signature,
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
