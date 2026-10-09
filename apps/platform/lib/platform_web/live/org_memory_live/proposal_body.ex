defmodule PlatformWeb.OrgMemoryLive.ProposalBody do
  @moduledoc """
  Shared rendering of a `Platform.Memory.MemoryProposal` body as an
  additive diff (task 01a1170a stage 1).

  Both proposal surfaces call into this module so the clamp rule, the
  line splitting and the line tokens cannot drift between them:

    * the mobile card (`PlatformWeb.OrgMemoryLive.MobileShell`), and
    * the desktop expandable panel row
      (`PlatformWeb.OrgMemoryLive.ProposalsPane`).

  Line tokens (Saru, canvas 01a1170b "Org memory proposals: desktop
  review"): every added line sits on a faint success band
  (`bg-success/10`, `/15` in dark) with `text-base-content` text. The
  previous mobile rendering used `text-success` as the TEXT colour,
  which is about 2.5:1 on white and fails AA; the band + base-content
  text replaces it on both surfaces. The removed-line slot Saru reserved
  is deliberately not built: no proposal body has a removed line today,
  so it would be an unexercised branch.

  No fixed DOM ids are emitted. The desktop and mobile branches render
  into the SAME document (CSS-hidden, not absent), so a fixed id here
  would be duplicated. Callers key everything on `data-role`.
  """

  use Phoenix.Component

  alias Platform.Memory.Proposals

  # Mobile clamp: over 320 chars or over 8 hard lines.
  @default_clamp_lines 8
  @default_clamp_chars 320

  @doc """
  Target wiki page the body promotes into: the ingest-time
  `target_page_key`, falling back to the same derivation the promotion
  pipeline uses when the column is nil (pre-column rows).
  """
  def target_key(%{target_page_key: key}) when is_binary(key) and key != "", do: key

  def target_key(%{category: category, evidence: evidence, body: body}),
    do: Proposals.derive_target_page_key(category, evidence, body)

  @doc "Split a body into its hard lines. `nil` (or any non-binary) is no lines."
  def diff_lines(body) when is_binary(body), do: String.split(body, "\n")
  def diff_lines(_), do: []

  @doc """
  A proposal body is "long" (worth clamping behind a Show-full-diff
  expander) when it has more than `max_lines` hard lines, or more than
  `max_chars` characters (enough to wrap past the clamp height).

  Mobile uses the defaults (8 lines / 320 chars). Desktop passes 12
  lines and a character budget sized to its 96ch measure: one helper,
  per-surface count (Saru's open question 1).
  """
  def long_body?(body, max_lines \\ @default_clamp_lines, max_chars \\ @default_clamp_chars)

  def long_body?(body, max_lines, max_chars) when is_binary(body),
    do: String.length(body) > max_chars or length(String.split(body, "\n")) > max_lines

  def long_body?(_, _, _), do: false

  @doc "True when the body has nothing to render (nil, empty, or whitespace only)."
  def blank_body?(body) when is_binary(body), do: String.trim(body) == ""
  def blank_body?(_), do: true

  # Desktop measure is capped at 96ch, so 12 full lines of it.
  @desktop_clamp_lines 12
  @desktop_clamp_chars 12 * 96

  @doc "Desktop clamp line count."
  def desktop_clamp_lines, do: @desktop_clamp_lines

  attr(:proposal, :map, required: true)
  attr(:expanded?, :boolean, default: false, doc: "true when the full diff is shown")
  attr(:surface, :atom, values: [:mobile, :desktop], required: true)

  attr(:clamp_lines, :integer,
    default: nil,
    doc: "hard-line clamp; nil takes the surface default (mobile 8, desktop 12)"
  )

  attr(:line_prefix, :string,
    default: "",
    doc: "text prepended to every line (mobile renders `\"+ \" <> line`)"
  )

  @doc """
  Renders the diff block, the fade over a clamped body, and the
  Show full diff / Show less toggle (`phx-click="toggle_proposal_diff"`,
  server-held in the LiveView's `expanded_diffs` MapSet).
  """
  def proposal_diff(%{surface: :mobile} = assigns) do
    clamp_lines = assigns.clamp_lines || @default_clamp_lines

    assigns =
      assign(assigns, :long?, long_body?(assigns.proposal.body, clamp_lines))

    ~H"""
    <div class="relative">
      <div
        class={[
          "whitespace-pre-wrap break-words rounded-lg border border-edge bg-base-200/40 p-2 font-mono text-xs leading-relaxed",
          if(@long? and not @expanded?,
            do: "max-h-64 overflow-hidden",
            else: "overflow-x-auto"
          )
        ]}
        data-role="mobile-proposal-diff"
      >
        <%!-- phx-no-format: the parent is whitespace-pre-wrap, so the
             formatter's layout (expression on its own indented line) would
             paint a tinted blank row above and below every line. --%>
        <div
          :for={line <- diff_lines(@proposal.body)}
          class="bg-success/10 text-base-content dark:bg-success/15"
          data-role="mobile-proposal-diff-line"
          phx-no-format
        >{@line_prefix <> line}</div>
      </div>
      <div
        :if={@long? and not @expanded?}
        class="pointer-events-none absolute inset-x-0 bottom-0 h-12 rounded-b-lg bg-gradient-to-t from-base-100 to-transparent"
      >
      </div>
    </div>
    <button
      :if={@long?}
      phx-click="toggle_proposal_diff"
      phx-value-id={@proposal.id}
      class="flex min-h-11 items-center gap-1 text-xs font-medium text-primary"
      data-role="mobile-diff-toggle"
    >
      <span class={["hero-chevron-down", "size-4 transition-transform", @expanded? && "rotate-180"]} />
      {if @expanded?, do: "Show less", else: "Show full diff"}
    </button>
    """
  end

  def proposal_diff(%{surface: :desktop} = assigns) do
    clamp_lines = assigns.clamp_lines || @desktop_clamp_lines
    lines = diff_lines(assigns.proposal.body)

    assigns =
      assigns
      |> assign(:lines, lines)
      |> assign(:long?, long_body?(assigns.proposal.body, clamp_lines, @desktop_clamp_chars))

    ~H"""
    <div class="relative max-w-[96ch]">
      <div
        class={[
          "rounded-lg border border-edge p-2 font-mono text-[13px] leading-relaxed",
          (@long? and not @expanded?) && "max-h-[17rem] overflow-hidden"
        ]}
        data-role="proposal-diff"
      >
        <div
          :for={line <- @lines}
          class="flex bg-success/10 text-base-content dark:bg-success/15"
          data-role="proposal-diff-line"
        >
          <%!-- phx-no-format on the text span: it is whitespace-pre-wrap, so
               the formatter's preferred layout (expression on its own line)
               would render a blank line above and below every diff line. --%>
          <span
            class="w-6 shrink-0 select-none text-center text-base-content/60"
            data-role="proposal-diff-gutter"
          >
            +
          </span>
          <span
            class="min-w-0 flex-1 whitespace-pre-wrap break-words"
            data-role="proposal-diff-text"
            phx-no-format
          >{@line_prefix <> line}</span>
        </div>
      </div>
      <div
        :if={@long? and not @expanded?}
        class="pointer-events-none absolute inset-x-0 bottom-0 h-12 rounded-b-lg bg-gradient-to-t from-base-100 to-transparent"
      >
      </div>
    </div>
    <button
      :if={@long?}
      type="button"
      phx-click="toggle_proposal_diff"
      phx-value-id={@proposal.id}
      class="mt-1 inline-flex min-h-8 items-center gap-1 text-xs font-medium text-secondary hover:underline focus-visible:underline"
      data-role="proposal-diff-toggle"
    >
      <span class={["hero-chevron-down", "size-4 transition-transform", @expanded? && "rotate-180"]} />
      {if @expanded?, do: "Show less", else: "Show full diff (#{length(@lines)} lines)"}
    </button>
    """
  end
end
