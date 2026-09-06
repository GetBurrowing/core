defmodule PlatformWeb.Components.Meetings.InviteControl do
  @moduledoc """
  The invite surface shared by the meeting CREATE sheet and the meeting
  DETAIL panel (task 019fb955-1d7b stage 3, canvas `019fb914-0842`
  revision 20 — the create-sheet frame, the detail panel in frame 1, and
  mobile frames 2 and 3).

  Function components rather than a LiveComponent on purpose: both
  surfaces have to render byte-identical markup, and the two differ only
  in where the state lives. A LiveComponent would have to own that state
  and then be told which of two owners it was standing in for.

  ## The mode flag is not cosmetic

  At create time no `meetings` row exists, so `Meetings.invite_guest/2`
  and friends cannot be called at all — there is nothing to hang an
  invite row off. That is a hard structural difference, not a styling
  one, so it is an explicit `:mode` rather than an inferred nil-check:

  | | `:draft` (create sheet) | `:live` (detail panel) |
  |---|---|---|
  | backing row | none — entries live in a socket assign | a `meeting_invites` row per entry |
  | selecting an option | stages an entry in the list | calls `invite_guest/2` / `invite_user/3` / `invite_external_user/3` |
  | the row's `X` | UNSTAGES (drops from the assign list); nothing is written and nothing is revoked | absent |
  | copy control | absent — no token has been minted, so there is no link to copy | present on guest rows |
  | `Add people` row | absent — the search box is already open above the list | present |
  | event names | `meeting_create_invite_*` | `meeting_invite_*` |

  ## No revoke control, deliberately

  The canvas draws no remove/revoke affordance on ANY invitee row in the
  detail panel (frame 1) or the mobile detail sheet (frame 2). The only
  `X` in any frame is the create sheet's, and that is an unstage.
  `Platform.Meetings.revoke_invite/1` therefore gets no caller here.

  That is also the safe answer to an unresolved product question rather
  than an aesthetic one. `Meetings.recipients_for_meeting/1` falls back
  to the backing space's CHAT PARTICIPANTS when `list_invites/2` returns
  empty, and `list_invites/2` excludes revoked rows — so revoking the
  last invitee WIDENS the notified audience to every human in the space.
  A revoke button shipped before the sponsor rules on that ships the
  widening. Surfaced, not resolved.

  ## The tag is NOT `Invite.kind/1`

  This is the one place the stored model and the rendered model
  genuinely disagree, so the table lives here rather than in a template
  `:if`. `Invite.kind/1` answers "does this row name an account", which
  is two-valued; the canvas draws four tags. Worse, stage 2's
  `invite_external_user/3` deliberately writes an interim row with a
  NULL `user_id` and an `email` for an address that has no account yet —
  `kind/1` calls that `:guest`, and the canvas calls it `external`.

  | `agent` | `user_id` | `external` | `expires_at` | `email` | tag |
  |---|---|---|---|---|---|
  | `true` | — | — | — | — | `:agent` |
  | `false` | set | `true` | — | — | `:external` |
  | `false` | set | `false` | — | — | `:internal` |
  | `false` | `nil` | — | set | — | `:guest` |
  | `false` | `nil` | — | `nil` | set | `:external` (pending grant) |

  Any other shape RAISES naming the shape. There is no catch-all
  defaulting to `:guest`: a mislabelled row is a lie about whether
  someone will need an org grant, and a fallback would file no bug
  report.

  ## Entry contract

  Entries are plain maps built by the calling LiveView (stages 4 and 5),
  not `%Invite{}` structs — the create sheet has no rows to build structs
  from, and `:external` is a property of the user's org membership
  (`org_memberships.external`), which is not on the invite row at all.

    * `:id` — stable identifier for `phx-value-id` and DOM ids. A
      `meeting_invites` id in `:live`, a client-side staging key in
      `:draft`.
    * `:name` — display name.
    * `:subtitle` — `nil`, or one line of STATE: the invitee's address
      for an external, `expires in 24h` for a guest, `host` for the
      host, `meeting producer` for the agent row. Never explanation.
    * `:user_id`, `:email`, `:expires_at`, `:external`, `:agent` — the
      tag derivation inputs above.
    * `:avatar_url` — passed through to `human_avatar/1`.
    * `:removable` / `:copy_url` — read by `invite_list/1` only, which
      accesses them with `.` so a caller that omits one gets a
      `KeyError` rather than a silently missing control.

  ## Tag tones — a documented deviation

  The stage text asks for "secondary tint for external, neutral for
  agent". In this theme `--color-secondary` is `oklch(30% 0.01 0)`, a
  grey chromatically indistinguishable from `--chip-neutral`, so the two
  tags would render the same and colour would stop carrying the
  distinction. External is rendered `info` instead — the nearest
  approved slot that stays distinct — and the same slot is used for the
  external OPTION's icon square so the option and the tag it produces
  agree. All four go through `CoreComponents.chip/1` so they stay on the
  approved soft-tint re-skin formula; no raw hex, no daisyUI `badge-*`.

  ## DOM contract

  Every assertable element carries a `data-role` in the
  `meeting-invite-*` namespace, owned by this module. Tests key on those,
  never on a Tailwind class — a class reshuffle must not be able to break
  a test. Where the canvas draws two copies of one string (a long desktop
  form and a short 375px form) BOTH are rendered, split by
  `sm:hidden` / `hidden sm:inline` and distinguished by
  `data-viewport="narrow" | "wide"`, so the row cannot wrap at 375px and
  neither string is quietly dropped.

  Hero icons only, no emoji. Every interactive element is at least a
  44px tap target (`min-h-11`); the two dropdown options are `52px` rows
  below `sm`, per the canvas, where they are a static tappable list
  rather than a floating menu.
  """

  use PlatformWeb, :html

  @tag_keys ~w(agent user_id external expires_at email)a

  # ── Event names are DERIVED FROM `:mode`, not hard-coded ───────────────
  #
  # Both surfaces live in the same LiveView (`PlatformWeb.MeetingLive`), so
  # one shared event name would arrive at one `handle_event/3` clause that
  # could not tell a create-sheet click from a detail-panel click. Rather
  # than have that clause re-derive the mode from socket state — which is
  # the same guess by another name — the mode picks the event, and the two
  # sets of handlers are structurally separate.
  #
  # There is ONE stage event per mode carrying `phx-value-kind`, not three
  # per-option events. The three options differ in what they stage, not in
  # whether they stage, and a caller that handled two of the three would
  # otherwise fail silently on the third.
  @events %{
    draft: %{
      search: "meeting_create_invite_search",
      stage: "meeting_create_invite_stage",
      unstage: "meeting_create_invite_unstage"
    },
    live: %{
      search: "meeting_invite_search",
      stage: "meeting_invite_stage",
      add_people: "meeting_invite_add_people"
    }
  }

  @doc """
  The `phx-` event name a control emits in `mode`.

  Raises on a pair no mode owns — `:draft` has no `Add people` row and
  `:live` has no unstage, so asking for one is a template bug, and a
  fallback would wire a live control to an event nothing handles.
  """
  @spec event(atom(), atom()) :: binary()
  def event(mode, name) do
    case @events do
      %{^mode => %{^name => event}} ->
        event

      _ ->
        raise ArgumentError,
              "no #{inspect(name)} event exists in invite mode #{inspect(mode)}"
    end
  end

  @tag_tones %{
    internal: "primary",
    external: "info",
    guest: "warning",
    agent: "neutral"
  }

  @doc """
  The four tag values this surface can render, in the canvas's order.
  """
  @spec tags() :: [atom()]
  def tags, do: [:internal, :external, :guest, :agent]

  @doc """
  Derives an entry's tag. See the moduledoc's table — this is that table.

  Raises `ArgumentError` on an entry missing a derivation input or on a
  row shape no clause covers. Both are bugs in the caller, and a default
  would render one of them as a plausible-looking wrong tag.
  """
  @spec tag(map()) :: :internal | :external | :guest | :agent
  def tag(entry) when is_map(entry) do
    case Enum.reject(@tag_keys, &Map.has_key?(entry, &1)) do
      [] ->
        derive_tag(entry)

      missing ->
        raise ArgumentError,
              "invite entry is missing tag derivation key(s) #{inspect(missing)}; " <>
                "got keys #{inspect(entry |> Map.keys() |> Enum.sort())}"
    end
  end

  defp derive_tag(%{agent: true}), do: :agent

  defp derive_tag(%{agent: false, user_id: user_id, external: true}) when is_binary(user_id),
    do: :external

  defp derive_tag(%{agent: false, user_id: user_id, external: false}) when is_binary(user_id),
    do: :internal

  defp derive_tag(%{agent: false, user_id: nil, expires_at: %DateTime{}}), do: :guest

  defp derive_tag(%{agent: false, user_id: nil, expires_at: nil, email: email})
       when is_binary(email),
       do: :external

  defp derive_tag(entry) do
    raise ArgumentError,
          "no tag derivation covers this invite entry shape: " <>
            "agent=#{inspect(entry.agent)} user_id=#{inspect(entry.user_id)} " <>
            "external=#{inspect(entry.external)} expires_at=#{inspect(entry.expires_at)} " <>
            "email=#{inspect(entry.email)}"
  end

  @doc """
  The `CoreComponents.chip/1` tone for a tag. See the moduledoc on why
  `external` is `info` rather than `secondary`.
  """
  @spec tag_tone(atom()) :: binary()
  def tag_tone(tag) when is_map_key(@tag_tones, tag), do: Map.fetch!(@tag_tones, tag)

  # ── invite_control/1 ───────────────────────────────────────────────────

  attr(:mode, :atom, required: true, values: [:draft, :live])
  attr(:query, :string, default: "")
  attr(:candidates, :list, required: true)
  attr(:email_option, :string, default: nil)
  attr(:target, :any, default: nil)
  attr(:id, :string, default: "meeting-invite-control")
  attr(:dropdown, :atom, default: :floating, values: [:floating, :inline])

  @doc """
  The search box plus its dropdown.

  `@candidates` and `@email_option` are the two halves of
  `Meetings.resolve_invite_candidates/2`'s return, which that function
  makes mutually exclusive by construction — a query matching a member
  never also offers "invite as external". This template does not re-check
  that: `dropdown/1` dispatches on the candidate list, so there is no
  path that renders both.

  ## `@dropdown` is a geometry decision, and it was measured

  `:floating` is the create sheet's: at `sm` and up the list is absolutely
  positioned over the content below it, which is what a dropdown should do
  inside a roomy modal.

  `:inline` is the DETAIL surface's, and it is not a preference. That
  surface is a capped `overflow-hidden` column whose body is the single
  scroll region, and the control sits at the END of that body. Measured in
  a headless browser at 1440x900 with the body scrolled fully down, a
  FLOATING dropdown was clipped by the panel's cap with its second option —
  `Invite as an external member` — cut off and unreachable at any scroll
  position, because absolute positioning takes it out of the flow the
  scroll height is computed from. Rendered in flow it lengthens the body
  instead, and the body scrolls to it.

  A dropdown whose second option cannot be reached is a fork with one
  prong, which is the whole decision this control exists to present.
  """
  def invite_control(assigns) do
    ~H"""
    <div class="relative" data-role="meeting-invite-control" data-mode={@mode}>
      <label class="flex items-center gap-2 rounded-lg border border-edge bg-base-100 px-3 min-h-11 focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20">
        <span class="hero-magnifying-glass size-4 shrink-0 text-base-content/40" aria-hidden="true">
        </span>
        <input
          type="text"
          id={"#{@id}-search"}
          data-role="meeting-invite-search"
          class="w-full min-w-0 border-0 bg-transparent p-0 text-sm focus:outline-none focus:ring-0"
          placeholder="Name or email"
          aria-label="Invite someone"
          autocomplete="off"
          phx-keyup={event(@mode, :search)}
          phx-debounce="120"
          phx-target={@target}
          value={@query}
        />
      </label>

      <.dropdown
        candidates={@candidates}
        email_option={@email_option}
        mode={@mode}
        target={@target}
        dropdown={@dropdown}
      />
    </div>
    """
  end

  # Members present: the two options are structurally ABSENT, not hidden
  # behind an `:if` one edit away from regressing. Offering "invite as
  # external" for someone who already has an account stages a grant
  # instead of the membership they hold.
  defp dropdown(%{candidates: [_ | _]} = assigns) do
    ~H"""
    <div
      class={dropdown_class(@dropdown)}
      data-role="meeting-invite-dropdown"
      data-dropdown-position={@dropdown}
      data-dropdown-kind="candidates"
    >
      <button
        :for={user <- @candidates}
        type="button"
        data-role="meeting-invite-candidate"
        data-user-id={user.id}
        class="flex w-full items-center gap-2.5 border-b border-edge px-3 py-2 text-left last:border-b-0 min-h-[52px] sm:min-h-11 hover:bg-base-200"
        phx-click={event(@mode, :stage)}
        phx-value-kind="user"
        phx-value-id={user.id}
        phx-target={@target}
      >
        <.human_avatar name={user.name || user.email} seed={user.id} size="sm" />
        <span class="min-w-0 flex-1">
          <span
            class="block truncate text-sm font-medium"
            data-role="meeting-invite-candidate-name"
          >
            {user.name || user.email}
          </span>
          <span
            :if={user.name}
            class="block truncate text-xs text-base-content/50"
            data-role="meeting-invite-candidate-email"
          >
            {user.email}
          </span>
        </span>
      </button>
    </div>
    """
  end

  # Nothing matched and the query is not an address the account schema
  # would accept: no dropdown at all, rather than an empty panel.
  defp dropdown(%{candidates: [], email_option: nil} = assigns) do
    ~H""
  end

  defp dropdown(%{candidates: []} = assigns) do
    ~H"""
    <div
      class={dropdown_class(@dropdown)}
      data-role="meeting-invite-dropdown"
      data-dropdown-position={@dropdown}
      data-dropdown-kind="options"
    >
      <%!-- Row 1 — the highlighted default. The canvas draws this one
           `.hi` with a return-key hint, so the fast path for an address
           that matched nobody is "give them a link". --%>
      <button
        type="button"
        data-role="meeting-invite-option"
        data-option="guest"
        data-default="true"
        class="flex w-full items-center gap-2.5 border-b border-edge bg-primary/10 px-3 py-2 text-left min-h-[52px] sm:min-h-11 hover:bg-primary/15"
        phx-click={event(@mode, :stage)}
        phx-value-kind="guest"
        phx-value-email={@email_option}
        phx-target={@target}
      >
        <span class="flex size-[30px] shrink-0 items-center justify-center rounded-lg bg-warning/15 text-warning">
          <span class="hero-link size-4" aria-hidden="true"></span>
        </span>
        <span class="min-w-0 flex-1">
          <span
            class="block text-sm font-semibold"
            data-role="meeting-invite-option-title"
          >
            Invite as a guest
          </span>
          <span
            class="block text-xs text-base-content/50"
            data-role="meeting-invite-option-detail"
          >
            <span class="sm:hidden" data-viewport="narrow">Personal link · 24h · no account</span>
            <span class="hidden sm:inline" data-viewport="wide">
              Personal link · expires in 24h · no account
            </span>
          </span>
        </span>
        <kbd class="hidden shrink-0 rounded border border-edge px-1.5 py-0.5 font-mono text-[10px] text-base-content/40 sm:inline-block">
          ⏎
        </kbd>
      </button>

      <%!-- Row 2 — the account-holding path. Costs an org grant, which
           is why it is second and why the detail line says so. --%>
      <button
        type="button"
        data-role="meeting-invite-option"
        data-option="external"
        class="flex w-full items-center gap-2.5 px-3 py-2 text-left min-h-[52px] sm:min-h-11 hover:bg-base-200"
        phx-click={event(@mode, :stage)}
        phx-value-kind="external"
        phx-value-email={@email_option}
        phx-target={@target}
      >
        <span class="flex size-[30px] shrink-0 items-center justify-center rounded-lg bg-info/15 text-info">
          <span class="hero-sparkles size-4" aria-hidden="true"></span>
        </span>
        <span class="min-w-0 flex-1">
          <span
            class="block text-sm font-semibold"
            data-role="meeting-invite-option-title"
          >
            <span class="sm:hidden" data-viewport="narrow">Invite as external member</span>
            <span class="hidden sm:inline" data-viewport="wide">Invite as an external member</span>
          </span>
          <span
            class="block text-xs text-base-content/50"
            data-role="meeting-invite-option-detail"
          >
            <span class="sm:hidden" data-viewport="narrow">Signs in · needs an org grant</span>
            <span class="hidden sm:inline" data-viewport="wide">
              Signs in as themselves · needs an org grant
            </span>
          </span>
        </span>
      </button>
    </div>
    """
  end

  # `sm:absolute` is the ONLY difference, and it is the one that decides
  # whether the list is clipped by an ancestor's cap. Everything else is
  # shared so the two positions cannot drift in any other respect.
  defp dropdown_class(:inline),
    do: "mt-1 overflow-hidden rounded-lg border border-edge bg-base-100"

  defp dropdown_class(:floating),
    do:
      "mt-1 overflow-hidden rounded-lg border border-edge bg-base-100 " <>
        "sm:absolute sm:z-20 sm:w-full sm:shadow-lg"

  # ── invite_row/1 ───────────────────────────────────────────────────────

  attr(:entry, :map, required: true)
  attr(:mode, :atom, required: true, values: [:draft, :live])
  attr(:removable, :boolean, default: false)
  attr(:copy_url, :string, default: nil)
  attr(:target, :any, default: nil)
  attr(:id_prefix, :string, default: "meeting-invite")

  @doc """
  One invitee row: avatar, name, optional state sub-line, tag, optional
  trailing control.

  The trailing control is gated on `@mode` as well as on its own attr.
  `:draft` can only unstage and `:live` can only copy, so a caller that
  passes a `copy_url` into a draft row gets no control rather than a
  button that would copy a token nobody minted.

  `@id_prefix` namespaces the copy button's DOM id. It exists because the
  detail surface renders this row TWICE — once in the desktop panel, once
  in the mobile sheet — and the copy button carries `phx-hook`, which
  LiveView keys by id. Two elements sharing one id means one of the two
  hooks never mounts and that button silently copies nothing. The default
  keeps the single-instance create sheet unchanged.
  """
  def invite_row(assigns) do
    assigns = assign(assigns, :tag, tag(assigns.entry))

    ~H"""
    <div
      class="mb-1.5 flex items-center gap-2 rounded-lg border border-edge bg-base-200/40 px-2 py-1.5 min-h-11"
      data-role="meeting-invite-row"
      data-entry-id={@entry.id}
      data-tag={@tag}
    >
      <%!-- Every entry builder sets `:agent`, and exactly one row is ever true:
           the meeting producer from `MeetingLive.producer_rows/0`. It was going
           through `human_avatar/1` like everyone else, which gave the producer
           two initials over the seeded human palette — the agent branch was the
           last place in the roster where an agent still wore a human's face. --%>
      <.agent_avatar
        :if={@entry.agent}
        name={@entry.name}
        avatar_url={@entry.avatar_url}
        size="sm"
        class="shrink-0"
      />
      <.human_avatar
        :if={!@entry.agent}
        name={@entry.name}
        avatar_url={@entry.avatar_url}
        seed={@entry.id}
        size="sm"
        class="shrink-0"
      />

      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm font-medium" data-role="meeting-invite-row-name">
          {@entry.name}
        </span>
        <span
          :if={@entry.subtitle}
          class="block truncate text-[11px] text-base-content/50"
          data-role="meeting-invite-row-subtitle"
        >
          {@entry.subtitle}
        </span>
      </span>

      <.chip
        tone={tag_tone(@tag)}
        class="shrink-0 font-mono text-[10px]"
        data-role="meeting-invite-tag"
      >
        {@tag}
      </.chip>

      <button
        :if={@mode == :draft and @removable}
        type="button"
        data-role="meeting-invite-unstage"
        data-entry-id={@entry.id}
        class="flex shrink-0 items-center justify-center rounded-lg text-base-content/40 min-h-11 min-w-11 hover:bg-base-300 hover:text-base-content"
        aria-label={"Remove #{@entry.name}"}
        title="Remove"
        phx-click={event(@mode, :unstage)}
        phx-value-id={@entry.id}
        phx-target={@target}
      >
        <span class="hero-x-mark size-4" aria-hidden="true"></span>
      </button>

      <button
        :if={@mode == :live and @copy_url}
        type="button"
        id={"#{@id_prefix}-copy-#{@entry.id}"}
        phx-hook="CopyToClipboard"
        data-clipboard-text={@copy_url}
        data-role="meeting-invite-copy"
        data-entry-id={@entry.id}
        class="flex shrink-0 items-center justify-center gap-1 rounded-lg border border-warning/35 bg-warning/10 px-2 text-[11px] font-semibold text-warning min-h-11 min-w-11 hover:bg-warning/20"
        aria-label={"Copy the personal link for #{@entry.name}"}
        title="Copy link"
      >
        <span class="hero-link size-3.5" aria-hidden="true"></span>
        <span>Link</span>
      </button>
    </div>
    """
  end

  # ── invite_list/1 ──────────────────────────────────────────────────────

  attr(:entries, :list, required: true)
  attr(:mode, :atom, required: true, values: [:draft, :live])
  attr(:target, :any, default: nil)
  attr(:id_prefix, :string, default: "meeting-invite")

  @doc """
  The `Invited · N` header, the rows, and — in `:live` only — the
  `Add people` row.

  The `Add people` row replaced a meeting-level toolbar button in the
  canvas precisely so there is no meeting-wide invite affordance
  anywhere; every invite is minted per person.

  Each entry supplies its own `:removable` and `:copy_url`, read with
  `.` so an entry built without them raises rather than rendering a row
  that silently lost its control.
  """
  def invite_list(assigns) do
    ~H"""
    <div data-role="meeting-invite-list" data-mode={@mode}>
      <h4
        class="mb-1.5 text-[10px] font-semibold uppercase tracking-widest text-base-content/50"
        data-role="meeting-invite-list-header"
      >
        Invited · {length(@entries)}
      </h4>

      <.invite_row
        :for={entry <- @entries}
        entry={entry}
        mode={@mode}
        removable={entry.removable}
        copy_url={entry.copy_url}
        target={@target}
        id_prefix={@id_prefix}
      />

      <button
        :if={@mode == :live}
        type="button"
        data-role="meeting-invite-add-people"
        class="flex w-full items-center gap-2 rounded-lg border border-dashed border-edge px-2 py-1.5 text-left text-sm font-medium text-primary min-h-11 hover:bg-primary/5"
        phx-click={event(@mode, :add_people)}
        phx-target={@target}
      >
        <span class="hero-plus size-4 shrink-0" aria-hidden="true"></span>
        <span>Add people</span>
      </button>
    </div>
    """
  end
end
