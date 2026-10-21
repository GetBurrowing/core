defmodule PlatformWeb.Components.Canvases.CanvasExplorer do
  @moduledoc """
  The canvas explorer: a grouped, collapsible, BOUNDED list of canvases
  (task `01a0740d-b081`, stage 2).

  ## What problem this actually solves

  At 409 canvases the failure is **disambiguation, not navigation**. A
  search for "approval" returns *Approval flow*, *Approval flow v2*,
  *Approval flow v3*, *Approval flow (3)* and *Approval flow — final*, all
  equally plausible. Finding them was never the cost; telling them apart
  is. So the **search row's second line is the signature element** of this
  component and everything else here is ordinary grouping.

  The second line reads **recency, then creator, then lineage**, in that
  order, and the order is pinned by test. Design canvas
  `01a088e5-bd58-7001-8399-37b64d016c32` ("FE-6: the second line is the
  whole ticket", advisory per ADR-0046) settled it against the ticket
  body, on the ticket's own worked example: one person made all five
  variants, so a second line leading with the author repeats the same name
  five times and teaches the reader to stop reading second lines.
  `updated_at` separates them — `Canvas.Server.do_persist/5` bumps it on
  every patch, and 228 of 818 production canvases carry
  `updated_at > inserted_at`.

  ### `created_by_display_name` is the CREATOR, not the last editor

  There is no `last_edited_by` column on `chat_canvases`; that is a
  separate unlanded ticket. The name is rendered plainly, with no label
  implying it is who touched the canvas last. The recency phrase says
  "Edited", the name does not — a canvas someone else has been working in
  all afternoon still shows the person who made it, and pretending
  otherwise would be a lie this component is in no position to tell.

  ### Lineage says WHICH parent

  A bare `clone` badge disambiguates nothing: in a near-duplicate cluster
  most rows are clones. So the line names the direction — `cloned from
  ‹parent title›`, and `cloned from a deleted canvas` when the parent
  resolves to the `:deleted` marker `Platform.Chat.canvas_parent_titles/1`
  returns. The line is rendered whenever `cloned_from` is set, in every
  branch: a row that sometimes has a third line and sometimes does not is
  harder to scan than one that always does.

  ## Recency wording: the shared helper, not a fifth spelling

  Recency is `PlatformWeb.Components.ChatHelpers.relative_time/1`, so this
  reads `Edited 2h ago`. The design canvas' wireframe spells it out as
  "Edited 2 hours ago"; the *design call* it makes is about which token
  LEADS the line and which field it comes from, and that is honoured
  exactly. The spelling is deliberately the house one: four
  implementations of relative time already exist in this app, the drawer
  this explorer will replace already renders `· 2h ago` on the same rows,
  and `Components.Meetings.CandidateDisplay.said_ago/2` argues at length
  that two spellings of the same phrase on one screen is its own small lie.
  A fifth spelling would be drift, and the reader would gain nothing:
  "2h ago" and "6d ago" separate five near-duplicates exactly as well as
  the long form does. The `title` attribute carries the absolute
  timestamps for the moment a reader stops scanning and starts caring.

  ## Structure, and what the component does NOT decide

  It renders what it is handed, in the order it is handed:

    * `pinned_groups` first, verbatim and in the caller's order. Stage 3
      supplies "In this meeting" and "On this task". This component never
      resolves them — it does not know what a meeting is.
    * then `space_groups`, which `Platform.Chat.list_canvas_groups/2`
      already returns **alphabetically by space name**. Not by canvas
      count: a count sort is tidy and it moves the list under the user
      between visits, and alphabetical means the same canvas is in the
      same place every time.

  It owns no search field. The caller's form does — the drawer's shipped
  one, with its 300ms `phx-debounce` and the `canvas-search-indexing-state`
  caveat line, which stays where it is. This component only reads the
  resulting `query`.

  Browse/search mode is derived from `query` through
  `PlatformWeb.ChatLive.CanvasHooks.search_active?/1`, the same predicate
  the event handler asks. Split in two, the pane that renders and the
  branch that queries could disagree about what "searching" means.

  ## Collapse is structural, not a class

  A collapsed group renders **no rows at all** — not rows behind
  `class="hidden"`. That matters for more than tidiness: `class="hidden"`
  present is not the same fact as "the group is collapsed", and a test
  asserting the class would pass against a component that renders 400
  rows into a hidden div. Here the row count IS the behaviour.

  **Search opens every group holding a match.** In search mode a group is
  expanded if and only if it has at least one matching row; `expanded_keys`
  is ignored. A collapsed group with matches inside reads as no result,
  which is the exact defect this ticket names. Groups with no match stay
  collapsed and their header reads `0 of 41`.

  ## Bounds

  Every group renders at most `page_size` rows, in BOTH modes, whatever
  length list it was handed. A caller mistake must not turn into 400
  rendered rows. The pager appears in browse mode only: search results
  arrive in `ts_rank_cd` order from `Chat.search_canvases/3` and are
  already bounded by its own `:limit`, and paging a ranked list is the
  same category of offer-that-does-nothing the drawer refused when it kept
  its sort control out of results mode.

  ## Palette, and one measurement worth recording

  Semantic token slots only, never a raw hex.

    * Row ground `base-100`. Rows are **not cards**: at 400 rows card
      chrome is 400 borders competing with the text they surround.
    * `base-200` for the group-header ground and for the band behind a
      search hit.
    * The rule under a group header is `border-edge` (`--edge`), not
      `base-300` — task 01a0740b split `--edge` out precisely because dark
      `base-300` renders at ~1.05:1 against the surface.
    * Title `base-content`; second line, lineage line and group counts
      `base-content/60`, not `/40`, which is the disabled treatment.
    * The active-filter dot is `--color-info`, the slot already ruled for
      the meeting rail's unread dot, so the two read as one vocabulary.
    * The search hit is marked by **semibold weight plus a `base-200`
      band**, never `--color-primary`: cyan is never text on white, and a
      highlighted substring is text. Weight also survives the case hue
      cannot — a match inside a title that is already truncated.

  **Measured, and flagged for the design review rather than quietly
  changed:** in dark, `--color-base-200` is `#111214` and
  `--color-base-100` is `#191b20` (Burrow, task 01a120c5; it was ≈1.22:1
  before), so the hit band is DARKER than the row it sits on (1.0879:1),
  not lighter. It is discriminable — the `--edge`
  ticket accepted 1.1966:1 for a hairline whose whole job is to be seen —
  and it is what the design canvas ruled, so it is what ships here. But
  `conversation.ex` chose `bg-base-content/5` for its snippet ground over
  exactly this non-monotonic dark ladder, so the two surfaces now disagree
  about which slot lifts a band in dark. That is a design question, not an
  implementation one.

  ## Events it emits (the caller handles them)

    * `"canvas_open"` with `phx-value-canvas-id` — the shipped drawer event,
      reused so wiring is a drop-in rather than a rename.
    * `"canvas_explorer_toggle_group"` with `phx-value-key`.
    * `"canvas_explorer_page"` with `phx-value-key` and `phx-value-offset`.
    * `"canvas_explorer_expand"`, optionally with `phx-value-focus="search"`
      — the strip's search icon opens the list AND asks the caller to focus
      its field, because the field is the caller's.
    * `"canvas_explorer_collapse"`.

  All of them carry `phx-target={@target}` when a target is given.
  """

  use Phoenix.Component

  import PlatformWeb.Components.ChatHelpers, only: [present?: 1, relative_time: 1]
  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.ChatLive.CanvasHooks, only: [search_active?: 1]
  import PlatformWeb.ChatLive.RenderHelpers, only: [marked_text: 1, split_marked_snippet: 1]

  @default_page_size 20

  @doc """
  The explorer.

  ## Group maps

  A `pinned_groups` entry is `%{key:, label:, rows:, total_count:}`. A
  `space_groups` entry is a `t:Platform.Chat.canvas_group/0` —
  `%{space_id:, space_name:, total_count:, rows:}` — and its key is
  derived as `"space:" <> space_id`. Either kind may carry two optional
  keys:

    * `:offset` — how many rows of this group the caller skipped, so the
      pager can say `21–40 of 41` and ask for the right next page.
      Defaults to `0`.
    * `:matched_count` — in search mode, how many canvases in this group
      matched, when that is more than the page handed over. Defaults to
      `length(rows)`, which is right whenever the match set fits.

  ## Row maps

  A row is a `t:Platform.Chat.canvas_group_row/0`: `:id`, `:title`,
  `:updated_at`, `:created_by_display_name`, `:cloned_from` (and the
  `:space_id`/`:inserted_at` this component does not read). Deliberately
  NOT a `%Canvas{}` — a struct would drag `document`, a node tree, into a
  list that renders titles.
  """
  attr(:id, :string, required: true)

  attr(:query, :string,
    default: "",
    doc: "the caller's active search term. Blank means browse mode."
  )

  attr(:collapsed, :boolean, default: false, doc: "render the 44px strip instead of the list")

  attr(:pinned_groups, :list,
    default: [],
    doc: "ordered, rendered verbatim above the space groups"
  )

  attr(:space_groups, :list,
    default: [],
    doc: "`Chat.list_canvas_groups/2` output, already alphabetical by space name"
  )

  attr(:expanded_keys, :list,
    default: [],
    doc: "group keys the user has opened. Ignored in search mode, which opens on matches."
  )

  attr(:parent_titles, :map,
    default: %{},
    doc: "`Chat.canvas_parent_titles/1` output: parent id => title | nil | :deleted"
  )

  attr(:page_size, :integer, default: @default_page_size)

  attr(:active_canvas_id, :any, default: nil)

  attr(:archive_count, :any,
    default: nil,
    doc: """
    The number on the collapsed strip. Defaults to the sum of the space
    groups' `total_count`, which is the archive's real size; pinned groups
    are deliberately NOT added in, because a canvas pinned to this meeting
    is also a canvas in its space and would be counted twice.
    """
  )

  attr(:changed_ids, :list,
    default: [],
    doc: """
    Row ids to mark with a small changed-since-seen dot, next to the title.
    Meaning is entirely the caller's: this component tracks no revisions and
    no "seen" state of its own -- it renders whichever ids it is handed.
    """
  )

  attr(:target, :any, default: nil, doc: "`phx-target` for every event this emits")
  attr(:class, :any, default: nil)

  def canvas_explorer(assigns) do
    assigns =
      assigns
      |> assign(:searching?, search_active?(assigns.query))
      |> assign(:changed_id_set, MapSet.new(assigns.changed_ids))
      |> assign_groups()

    ~H"""
    <div id={@id} data-role="canvas-explorer" class={@class}>
      <.collapsed_strip
        :if={@collapsed}
        id={@id}
        count={@strip_count}
        searching?={@searching?}
        target={@target}
      />

      <div :if={!@collapsed} data-role="canvas-explorer-open" class="bg-base-100">
        <div class="flex items-center gap-2 px-3 py-1.5">
          <button
            type="button"
            phx-click="canvas_explorer_collapse"
            phx-target={@target}
            aria-label="Collapse the canvas list"
            data-role="canvas-explorer-collapse"
            class="flex items-center gap-1 text-[12.5px] font-semibold text-base-content"
          >
            <.icon name="hero-chevron-left" class="size-3.5" />
            <span>Canvases</span>
          </button>
          <span class="text-[12.5px] font-semibold text-subtle">
            · {@strip_count}
          </span>
        </div>

        <%!-- Pinned first, in the caller's order, then the space groups.
             Two `:for` loops rather than one over a concatenation so that
             the pinned block cannot be reordered by a later change to how
             space groups are sorted. --%>
        <.explorer_group
          :for={group <- @groups}
          group={group}
          searching?={@searching?}
          expanded={expanded?(group, @searching?, @expanded_keys)}
          query={@query}
          page_size={@page_size}
          parent_titles={@parent_titles}
          active_canvas_id={@active_canvas_id}
          changed_id_set={@changed_id_set}
          target={@target}
          id_prefix={@id}
        />

        <p
          :if={@groups == []}
          data-role="canvas-explorer-empty"
          class="px-3 py-4 text-[12.5px] text-subtle"
        >
          No canvases here yet.
        </p>

        <%!-- The no-results line, separate from the no-groups line above
             because they are opposite facts: one says the archive is
             empty, the other says the filter is. It deliberately does NOT
             claim anything about what is indexed — the drawer's shipped
             `canvas-search-indexing-state` line owns that caveat and is
             true where this would not be. --%>
        <p
          :if={@searching? && @groups != [] && @match_total == 0}
          data-role="canvas-explorer-no-matches"
          class="px-3 py-4 text-[12.5px] text-subtle"
        >
          Nothing matched “{@query}”.
        </p>
      </div>
    </div>
    """
  end

  # ── The 44px strip ─────────────────────────────────────────────────────
  #
  # The count, a folder icon that opens the list, and a search icon that
  # opens it with the field focused. The dot on the search icon is the
  # whole point of the strip: an invisible filter is one you forget you
  # set, and then a nine-item list reads as the whole archive.
  attr(:id, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:searching?, :boolean, required: true)
  attr(:target, :any, default: nil)

  defp collapsed_strip(assigns) do
    ~H"""
    <div
      data-role="canvas-explorer-strip"
      class="flex w-11 flex-col items-center gap-3 border-r border-edge bg-base-200 py-3"
    >
      <button
        type="button"
        phx-click="canvas_explorer_expand"
        phx-target={@target}
        aria-label="Open the canvas list"
        data-role="canvas-explorer-strip-open"
        class="text-subtle"
      >
        <.icon name="hero-folder" class="size-4" />
      </button>

      <button
        type="button"
        phx-click="canvas_explorer_expand"
        phx-value-focus="search"
        phx-target={@target}
        aria-label={
          if @searching?,
            do: "Open the canvas list and search — a filter is still set",
            else: "Open the canvas list and search"
        }
        data-role="canvas-explorer-strip-search"
        class="relative text-subtle"
      >
        <.icon name="hero-magnifying-glass" class="size-4" />
        <%!-- `--color-info`, the meeting rail's unread-dot slot, so a dot
             means the same thing on both surfaces. Rendered ONLY while a
             filter is set: a dot that is always there says nothing. --%>
        <span
          :if={@searching?}
          data-role="canvas-explorer-filter-dot"
          class="absolute -right-1 -top-1 size-2 rounded-full bg-info"
        >
        </span>
      </button>

      <span
        data-role="canvas-explorer-strip-count"
        class="text-[12.5px] font-semibold text-subtle"
      >
        {@count}
      </span>
    </div>
    """
  end

  # ── One group ──────────────────────────────────────────────────────────
  attr(:group, :map, required: true)
  attr(:searching?, :boolean, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:query, :string, required: true)
  attr(:page_size, :integer, required: true)
  attr(:parent_titles, :map, required: true)
  attr(:active_canvas_id, :any, default: nil)
  attr(:changed_id_set, :any, default: MapSet.new())
  attr(:target, :any, default: nil)
  attr(:id_prefix, :string, required: true)

  defp explorer_group(assigns) do
    group = assigns.group
    shown = Enum.take(group.rows, assigns.page_size)
    offset = Map.get(group, :offset, 0)

    assigns =
      assigns
      |> assign(:key, group.key)
      |> assign(:label, group.label)
      |> assign(:shown, shown)
      |> assign(:offset, offset)
      |> assign(:rows_id, "#{assigns.id_prefix}-group-#{group.key}")
      |> assign(:count_text, count_text(group, shown, assigns.searching?))
      |> assign(:pager, pager(group, shown, offset, assigns.searching?))

    ~H"""
    <section data-role="canvas-explorer-group" data-group-key={@key}>
      <%!-- The count is part of the header SENTENCE, not a chip beside it:
           it carries no size or colour class of its own, so it can never
           drift from the label's. --%>
      <h3 class="m-0">
        <button
          type="button"
          phx-click="canvas_explorer_toggle_group"
          phx-value-key={@key}
          phx-target={@target}
          aria-expanded={to_string(@expanded)}
          aria-controls={@rows_id}
          data-role="canvas-explorer-group-header"
          class="flex w-full items-center gap-1 border-b border-edge bg-base-200 px-3 py-1.5 text-left text-[12.5px] font-semibold text-subtle"
        >
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-3 shrink-0"
          />
          <span data-role="canvas-explorer-group-label" class="truncate">{@label}</span>
          <span data-role="canvas-explorer-group-count">· {@count_text}</span>
        </button>
      </h3>

      <%!-- A collapsed group renders NO rows. Not hidden rows: absent
           ones. See the moduledoc — the rendered row count is the
           behaviour under test, and `class="hidden"` is not that fact. --%>
      <div
        :if={@expanded}
        id={@rows_id}
        data-role="canvas-explorer-group-rows"
        class="bg-base-100"
      >
        <.explorer_row
          :for={row <- @shown}
          row={row}
          searching?={@searching?}
          query={@query}
          parent_titles={@parent_titles}
          active_canvas_id={@active_canvas_id}
          changed_id_set={@changed_id_set}
          target={@target}
        />

        <p
          :if={@shown == []}
          data-role="canvas-explorer-group-empty"
          class="px-3 py-3 text-[12.5px] text-subtle"
        >
          Nothing in here.
        </p>

        <%!-- Paging, browse mode only. The range readout is not
             decoration: a pager with no "where am I" leaves the reader
             unable to tell page 2 from page 3 of five near-identical
             titles, which is the very confusion this component exists to
             end. --%>
        <div
          :if={@pager}
          data-role="canvas-explorer-pager"
          class="flex items-center gap-3 border-b border-edge px-3 py-1.5 text-[12.5px] text-subtle"
        >
          <span data-role="canvas-explorer-page-range">{@pager.range}</span>
          <button
            :if={@pager.prev_offset}
            type="button"
            phx-click="canvas_explorer_page"
            phx-value-key={@key}
            phx-value-offset={@pager.prev_offset}
            phx-target={@target}
            data-role="canvas-explorer-prev-page"
            class="font-semibold"
          >
            Previous
          </button>
          <button
            :if={@pager.next_offset}
            type="button"
            phx-click="canvas_explorer_page"
            phx-value-key={@key}
            phx-value-offset={@pager.next_offset}
            phx-target={@target}
            data-role="canvas-explorer-next-page"
            class="font-semibold"
          >
            Next {@pager.next_size}
          </button>
        </div>
      </div>
    </section>
    """
  end

  # ── One row ────────────────────────────────────────────────────────────
  attr(:row, :map, required: true)
  attr(:searching?, :boolean, required: true)
  attr(:query, :string, required: true)
  attr(:parent_titles, :map, required: true)
  attr(:active_canvas_id, :any, default: nil)
  attr(:changed_id_set, :any, default: MapSet.new())
  attr(:target, :any, default: nil)

  defp explorer_row(assigns) do
    row = assigns.row

    assigns =
      assigns
      |> assign(:title_runs, title_runs(display_title(row), assigns.query, assigns.searching?))
      |> assign(:meta, meta_line(row))
      |> assign(:lineage, lineage_line(row, assigns.parent_titles))
      |> assign(:selected?, assigns.active_canvas_id && assigns.active_canvas_id == row.id)
      |> assign(:changed?, MapSet.member?(assigns.changed_id_set, row.id))
      |> assign(:absolute, absolute_title(row))
      |> assign(:snippet, Map.get(row, :snippet))

    ~H"""
    <button
      type="button"
      phx-click="canvas_open"
      phx-value-canvas-id={@row.id}
      phx-target={@target}
      data-role="canvas-explorer-row"
      data-canvas-id={@row.id}
      aria-current={@selected? && "true"}
      class={[
        "block w-full border-l-2 px-3 py-1.5 text-left",
        @selected? && "border-primary bg-primary/5",
        !@selected? && "border-transparent bg-base-100"
      ]}
    >
      <%!-- The title yields space to the changed-dot; the dot never yields
           to the title. A caller-supplied signal (`@changed?`) about a row
           this component otherwise has no memory of -- see `changed_ids`'s
           own doc above. --%>
      <div class="flex items-center gap-1.5">
        <%!-- `phx-no-format` is load-bearing here, the same hazard
             `conversation.ex` records on `canvas_result_snippet/1`: left to
             itself the HEEx formatter puts each run on its own line, which
             lands a newline and an indent INSIDE the title between two runs.
             Every markup assertion still passes on that, and the title a
             reader compares against four near-identical siblings quietly
             grows whitespace it does not have.

             `<mark>` for the match, matching the snippet's element choice —
             it is what a search hit IS. Its UA yellow is overridden by the
             `base-200` band, and the weight is the signal that survives
             truncation. --%>
        <span
          phx-no-format
          data-role="canvas-explorer-row-title"
          title={@absolute}
          class="block min-w-0 flex-1 truncate text-sm font-normal text-base-content"
        ><%= for {kind, text} <- @title_runs do %><mark
            :if={kind == :match}
            data-role="canvas-explorer-title-match"
            class="rounded-[3px] bg-base-200 px-[1px] font-semibold text-base-content"
          >{text}</mark><span :if={kind == :plain}>{text}</span><% end %></span>
        <span
          :if={@changed?}
          data-role="canvas-changed-dot"
          data-canvas-id={@row.id}
          class="size-2 shrink-0 rounded-full bg-secondary"
          aria-hidden="true"
        >
        </span>
      </div>

      <%!-- WHY THIS ROW MATCHED, when the title does not say so.

           Carried over from the drawer's shipped results row (task 01a07402,
           `Conversation.canvas_result_snippet/1`) rather than dropped when
           this component took that markup over. Dropping it would have been a
           silent regression of a shipped feature, and a body match whose title
           contains none of the query is the one row a reader cannot place at
           all without it — the same disambiguation problem the second line
           exists for, one layer down.

           The RULE is not restated here, deliberately. `Chat.search_canvases/3`
           already returns `snippet: nil` unless the body matched and the title
           did NOT, enforced in Elixir after the query, so rendering on the
           snippet's mere presence keeps ONE source of truth for it. A second
           copy of that condition in this template is exactly the kind of pair
           that drifts. A row map with no `:snippet` key at all — every browse
           row, and both pinned groups — is `nil` here and renders nothing.

           Above the second line, matching the shipped row order. --%>
      <.explorer_row_snippet :if={@searching? && present?(@snippet)} snippet={@snippet} />

      <%!-- THE SIGNATURE ELEMENT. Browse rows stop at the title: the
           group header has already said where you are. A search row earns
           this line because search is the only context where that has
           been lost — and because five titles that differ by a suffix are
           told apart here or not at all.

           Order is load-bearing and pinned by test: recency, then
           creator. Leading with the creator is what fails on the worked
           example. --%>
      <span
        :if={@searching? && @meta}
        data-role="canvas-explorer-row-meta"
        class="mt-0.5 block truncate text-[12.5px] text-subtle"
      >
        {@meta}
      </span>

      <span
        :if={@searching? && @lineage}
        data-role="canvas-explorer-row-lineage"
        class="block truncate text-[12.5px] text-subtle"
      >
        {@lineage}
      </span>
    </button>
    """
  end

  # ── The body-match snippet ─────────────────────────────────────────────
  #
  # MOVED HERE VERBATIM from `Conversation.canvas_result_snippet/1` (task
  # 01a07402 stages 5–7) when this component took over the drawer's results
  # markup. It is not a reimplementation: the data-roles, the class lists and
  # the `phx-no-format` are the shipped ones, because `app.css` carries two
  # rules keyed off `[data-role="canvas-result-snippet"]` and
  # `[data-role="canvas-result-snippet-leading"]`, and the drawer's own tests
  # assert this exact three-part structure. Renaming any of it would have
  # turned a move into a rewrite with no test able to tell.
  #
  # THE SNIPPET IS THREE PARTS IN A ROW, NOT ONE TRUNCATING STRING.
  #
  # The brand rule: the last thing allowed to truncate is the most meaningful.
  # On this row that is the MATCH, and the surrounding context is the
  # expendable part — the title above already failed to disambiguate, which is
  # the whole reason the snippet line exists. So the match is held at
  # `shrink-0 whitespace-nowrap` and the two context runs are `min-w-0
  # truncate` and yield around it. It holds at every width by construction:
  # there is no breakpoint to tune, no second server-side fragment
  # configuration, and no viewport for the server to guess at.
  #
  # Measured before that split, at 375px: the snippet box's right edge sat at
  # x=286 and the `<mark>` at x=317-377, entirely past it. A phone reader got
  # "… until their manager r…" — context without the word they searched for.
  # At 1440px the mark ended at 825 inside a box ending at 943, which is why
  # nobody reviewing on a laptop saw it.
  #
  # LEFT-SIDE CLIPPING on the leading run, because `truncate` clips from the
  # right and would keep the words FURTHEST from the match — the wrong half.
  # `direction: rtl` moves the clip and the ellipsis to the left edge (the CSS
  # rule is in `app.css`, scoped to the leading role), and the `<bdi>` inside
  # keeps the text itself in logical order.
  #
  # Never `raw/1` on this — the body is user-written. `marked_text/1` escapes
  # the whole fragment and then re-enables only the `<mark>` pair
  # `ts_headline` was asked for.
  #
  # `bg-base-content/5` for the lifted ground, NOT `base-200`: the dark ladder
  # is not monotonic and `base-200` renders as a near-black band there. This is
  # the disagreement the moduledoc flags — the title hit band above IS
  # `base-200` because the design canvas ruled it, and this line kept the slot
  # it shipped with. One surface, two answers, recorded rather than smoothed
  # over so the design review can pick one.
  attr(:snippet, :string, required: true)

  defp explorer_row_snippet(assigns) do
    {leading, match, trailing} = split_marked_snippet(assigns.snippet)

    assigns = assign(assigns, leading: leading, match: match, trailing: trailing)

    ~H"""
    <%!-- `phx-no-format` is load-bearing, not tidiness. Left to itself the HEEx
         formatter puts each interpolation on its own line, which lands a
         newline and an indent INSIDE the run — so the leading run's last text
         node becomes whitespace instead of the character next to the match.
         Every markup assertion still passes on that, and the browser
         measurement reads the last character's rect, so it would be measuring
         a space. --%>
    <span
      phx-no-format
      data-role="canvas-result-snippet"
      class="mt-0.5 flex min-w-0 items-baseline gap-1 overflow-hidden rounded bg-base-content/5 px-1.5 py-0.5 text-xs font-normal text-base-content"
    ><%= if @match do %><span
        :if={@leading}
        data-role="canvas-result-snippet-leading"
        class="min-w-0 truncate"
      ><bdi>{@leading}</bdi></span><mark
        data-role="canvas-result-snippet-match"
        class="max-w-full shrink-0 truncate whitespace-nowrap"
      >{@match}</mark><span
        :if={@trailing}
        data-role="canvas-result-snippet-trailing"
        class="min-w-0 truncate"
      >{@trailing}</span><% else %><%!-- No mark in the fragment: nothing to
        protect, so this is the single truncating span it always was. --%><span
        class="min-w-0 truncate"
      >{marked_text(@snippet)}</span><% end %></span>
    """
  end

  # ── Derivations ────────────────────────────────────────────────────────

  # Pinned groups verbatim and first, then space groups normalised onto the
  # same shape. `strip_count` sums the SPACE groups only; see the attr doc.
  defp assign_groups(assigns) do
    pinned = Enum.map(assigns.pinned_groups, &normalise_pinned/1)
    spaces = Enum.map(assigns.space_groups, &normalise_space/1)
    groups = pinned ++ spaces

    strip_count =
      assigns.archive_count ||
        Enum.reduce(spaces, 0, fn group, acc -> acc + group.total_count end)

    assigns
    |> assign(:groups, groups)
    |> assign(:strip_count, strip_count)
    |> assign(:match_total, Enum.reduce(groups, 0, fn g, acc -> acc + length(g.rows) end))
  end

  defp normalise_pinned(group) do
    %{
      key: to_string(group.key),
      label: group.label,
      rows: group.rows,
      total_count: group.total_count,
      offset: Map.get(group, :offset, 0),
      matched_count: Map.get(group, :matched_count)
    }
  end

  defp normalise_space(group) do
    %{
      key: "space:" <> to_string(group.space_id),
      label: group.space_name || "Untitled space",
      rows: group.rows,
      total_count: group.total_count,
      offset: Map.get(group, :offset, 0),
      matched_count: Map.get(group, :matched_count)
    }
  end

  # In SEARCH mode a group is open if and only if it holds a match, and
  # `expanded_keys` is ignored: a collapsed group with matches inside reads
  # as no result. In browse mode the user's own toggles decide.
  defp expanded?(group, true = _searching?, _expanded_keys), do: group.rows != []
  defp expanded?(group, false = _searching?, expanded_keys), do: group.key in expanded_keys

  # Browse: "41". Search: "3 of 41" — matches against the group's real
  # size, which is why `total_count` had to be a COUNT rather than
  # `length(rows)` back in stage 1.
  defp count_text(group, shown, true = _searching?) do
    matched = group.matched_count || length(shown)
    "#{matched} of #{group.total_count}"
  end

  defp count_text(group, _shown, false = _searching?), do: to_string(group.total_count)

  # `nil` when there is nothing to page. Browse mode only — see the
  # moduledoc on why a ranked result set gets no pager.
  defp pager(_group, _shown, _offset, true = _searching?), do: nil

  defp pager(group, shown, offset, false = _searching?) do
    count = length(shown)
    last = offset + count

    if count > 0 and (offset > 0 or last < group.total_count) do
      %{
        range: "#{offset + 1}–#{last} of #{group.total_count}",
        prev_offset: offset > 0 && max(offset - count, 0),
        next_offset: last < group.total_count && last,
        next_size: min(count, group.total_count - last)
      }
    end
  end

  defp display_title(%{title: title}) when is_binary(title) do
    if String.trim(title) == "", do: "Untitled canvas", else: title
  end

  defp display_title(_row), do: "Untitled canvas"

  # ── The second line ────────────────────────────────────────────────────

  # Recency FIRST, creator second. The whole design call is in this order,
  # and `second_line_leads_with_recency` pins it.
  #
  # "Edited" labels the timestamp as `updated_at`; the name is never
  # labelled, because `created_by_display_name` is the CREATOR and there is
  # no last-editor column to read.
  defp meta_line(row) do
    [recency(row), creator(row)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp recency(%{updated_at: %DateTime{} = at}), do: "Edited #{relative_time(at)}"
  defp recency(_row), do: nil

  defp creator(%{created_by_display_name: name}) when is_binary(name) do
    if String.trim(name) == "", do: nil, else: name
  end

  defp creator(_row), do: nil

  # Always a line when `cloned_from` is set, and the four outcomes are four
  # different sentences. `Map.fetch/2`, not `Map.get/2`: a parent the
  # caller never resolved is not a deleted parent, and saying "deleted"
  # about a canvas that is alive is the mutation this file's test 4 exists
  # to catch.
  defp lineage_line(%{cloned_from: parent_id}, parent_titles) when is_binary(parent_id) do
    case Map.fetch(parent_titles, parent_id) do
      {:ok, :deleted} -> "cloned from a deleted canvas"
      {:ok, title} when is_binary(title) -> lineage_from_title(title)
      {:ok, nil} -> "cloned from an untitled canvas"
      :error -> "cloned from another canvas"
    end
  end

  defp lineage_line(_row, _parent_titles), do: nil

  defp lineage_from_title(title) do
    if String.trim(title) == "",
      do: "cloned from an untitled canvas",
      else: "cloned from #{title}"
  end

  defp absolute_title(%{updated_at: %DateTime{} = updated} = row) do
    case row do
      %{inserted_at: %DateTime{} = inserted} -> "updated #{updated} · created #{inserted}"
      _ -> "updated #{updated}"
    end
  end

  defp absolute_title(_row), do: nil

  # ── Marking the match ──────────────────────────────────────────────────

  # Split a title into `{:plain, text}` and `{:match, text}` runs on the
  # query's terms, case-insensitively.
  #
  # Returns runs, never HTML: HEEx escapes every interpolation, so a canvas
  # titled `<script>` cannot become one. Nothing here goes near `raw/1`.
  #
  # The match is marked by WEIGHT plus a `base-200` band, never by hue.
  # Cyan is never text on white, and a highlighted substring is text; and
  # weight is the only signal that survives a match inside a title the row
  # has already truncated, which is precisely when the reader needs it.
  defp title_runs(title, _query, false = _searching?), do: [{:plain, title}]

  defp title_runs(title, query, true = _searching?) do
    terms =
      query
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(&1 == ""))

    case terms do
      [] ->
        [{:plain, title}]

      terms ->
        pattern =
          terms
          |> Enum.map(&Regex.escape/1)
          |> Enum.join("|")
          |> Regex.compile!("iu")

        downcased = MapSet.new(terms, &String.downcase/1)

        pattern
        |> Regex.split(title, include_captures: true, trim: true)
        |> Enum.map(fn run ->
          if MapSet.member?(downcased, String.downcase(run)),
            do: {:match, run},
            else: {:plain, run}
        end)
        |> case do
          [] -> [{:plain, title}]
          runs -> runs
        end
    end
  end
end
