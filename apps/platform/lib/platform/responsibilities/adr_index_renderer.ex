defmodule Platform.Responsibilities.ADRIndexRenderer do
  @moduledoc """
  Renders the `:adr_index` context slot into the prompt block both
  architecture handlers interpolate.

  This module is a **renderer and nothing else**: no regexes, no
  `File.*`, no second opinion about what an ADR is.
  `Platform.Responsibilities.ContextProviders` owns the single parse of
  `docs/decisions/` — directory resolution, header extraction, number /
  title collision detection and the supersession map. If a caller needs
  a field that is not on the slot, the fix is to extend the provider,
  not to re-derive it here.

  It exists because two handlers render the same slot.
  `architecture.review_plan` consumed the provider; `architecture.cron_sweep`
  still walked the filesystem itself and emitted a bare `- <filename>`
  list with no status and no supersession, collapsing to an empty list
  with no reason on every failure path. That made the architect's ADR
  drift check unrunnable from the cron path: a model handed a bare list
  of filenames cannot tell a live decision from a retired one, and a
  model handed an empty list reads it as "this codebase has no
  architectural decisions".
  """

  @typedoc "The `:adr_index` slot as returned by `ContextProviders.gather_context/2`."
  @type index :: map()

  @doc """
  The shape callers fall back to when the slot returns something
  unrecognised. Kept in sync with `ContextProviders.unavailable_index/2`.
  """
  @spec unavailable_index() :: index()
  def unavailable_index do
    %{
      available?: false,
      reason: :adr_dir_unreachable,
      dir: nil,
      total: 0,
      shown: 0,
      truncated?: false,
      dropped: 0,
      dropped_files: [],
      number_collisions: %{},
      title_collisions: %{},
      entries: []
    }
  end

  @doc """
  Render the slot as a prompt block.

  An unreadable index must arrive as an INSTRUCTION, not as silence. A
  model handed an empty ADR block reads it as "this codebase has no
  architectural decisions" and reasons from that; handed this line it
  knows the walk failed and that any ADR it names would be invented.
  """
  @spec format_adr_index(index()) :: String.t()
  def format_adr_index(%{available?: false} = payload) do
    "(ADR index unavailable — #{adr_unavailable_reason(Map.get(payload, :reason))}. " <>
      "Do not cite ADRs by number or filename in this pass; say the index was unavailable " <>
      "instead of naming a decision you cannot see.)"
  end

  def format_adr_index(%{entries: entries} = payload) when is_list(entries) do
    Enum.join([format_adr_index_header(payload) | Enum.map(entries, &format_adr_entry/1)], "\n")
  end

  def format_adr_index(_payload),
    do: "(ADR index unavailable — the slot returned an unrecognised shape)"

  @doc "Prose for each of the provider's three unavailability reasons."
  @spec adr_unavailable_reason(atom()) :: String.t()
  def adr_unavailable_reason(:adr_dir_empty),
    do: "`docs/decisions/` resolved but holds no `.md` files"

  def adr_unavailable_reason(:adr_dir_unreadable),
    do: "`docs/decisions/` exists but could not be listed"

  # Not "release images do not ship docs/" — they do now, into the app's
  # `priv/`, with `config/runtime.exs` pointing `:adr_dir` at it. Naming a
  # cause that has been fixed sends the next reader to the wrong place, so
  # this states the resolution order and lets them check each step.
  def adr_unavailable_reason(_reason),
    do:
      "the ADR corpus could not be resolved — no readable directory from " <>
        "`:platform, :adr_dir`, from the packaged corpus under the app's `priv/`, " <>
        "or from a `docs/decisions/` directory in any ancestor of the working tree"

  @doc """
  The header carries the one instruction that makes the block usable:
  cite by filename. `docs/decisions/` holds four numbers that name two
  different ADRs each, so "ADR-0044" is not a reference — it is a coin
  flip the model has no way of knowing it is making.
  """
  @spec format_adr_index_header(index()) :: String.t()
  def format_adr_index_header(payload) do
    collisions = map_size(Map.get(payload, :number_collisions) || %{})
    total = Map.get(payload, :total, 0)
    shown = Map.get(payload, :shown, total)

    # The directory as RESOLVED, not as assumed. In a release it is the
    # packaged corpus under `priv/`, not `docs/decisions/`; a prompt that
    # names a path the image does not have teaches the model a false fact
    # about where these decisions live.
    dir = Map.get(payload, :dir) || "the ADR corpus directory"

    counts =
      if Map.get(payload, :truncated?) do
        "Showing the #{shown} highest-numbered of #{total} ADRs in `#{dir}` " <>
          "(#{Map.get(payload, :dropped, 0)} older ADR(s) omitted: " <>
          "#{Enum.join(Map.get(payload, :dropped_files) || [], ", ")})."
      else
        "All #{total} ADRs in `#{dir}`."
      end

    ambiguity =
      if collisions > 0 do
        " CITE ADRs BY FILENAME, NOT BY NUMBER — #{collisions} number(s) in this directory " <>
          "are each shared by more than one ADR, and the shared entries are flagged below."
      else
        " Cite ADRs by filename."
      end

    counts <> ambiguity
  end

  @doc "One entry: filename, title, status, then its ambiguity and supersession flags."
  @spec format_adr_entry(map()) :: String.t()
  def format_adr_entry(entry) do
    title = Map.get(entry, :title) || "(title not recorded)"
    status = Map.get(entry, :status) || "(status not recorded)"

    header = "- #{Map.get(entry, :file, "(unknown)")} — #{title} [#{status}]"

    Enum.join([header | adr_entry_flags(entry)], "\n")
  end

  @doc "Ambiguity + supersession flag lines for a single entry."
  @spec adr_entry_flags(map()) :: [String.t()]
  def adr_entry_flags(entry) do
    number_flag =
      if Map.get(entry, :number_ambiguous) do
        ["  ⚠ number #{Map.get(entry, :number)} is shared by another ADR — cite by filename"]
      else
        []
      end

    title_flag =
      if Map.get(entry, :title_ambiguous) do
        ["  ⚠ another ADR carries this same title — cite by filename"]
      else
        []
      end

    number_flag ++
      title_flag ++ Enum.map(Map.get(entry, :superseded_by) || [], &adr_supersession/1)
  end

  @doc """
  A partial supersession is rendered as one, with the superseding
  document's own words attached. ADR-0013 retired the attention-routing
  SECTIONS of ADR-0008; reporting 0008 as dead would retire a live
  decision, which is the same lie in the opposite direction.
  """
  @spec adr_supersession(map()) :: String.t()
  def adr_supersession(%{partial?: true} = ref) do
    "  ⚠ partially superseded by #{Map.get(ref, :file)} — #{Map.get(ref, :note)}"
  end

  def adr_supersession(ref) do
    "  ⚠ superseded by #{Map.get(ref, :file)}" <> adr_supersession_source(ref)
  end

  @doc "Attribution suffix for a whitelisted (prose-sourced) supersession."
  @spec adr_supersession_source(map()) :: String.t()
  def adr_supersession_source(%{source: :manual, note: note}) when is_binary(note),
    do: " (#{note})"

  def adr_supersession_source(_ref), do: ""
end
