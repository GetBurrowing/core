defmodule PlatformWeb.Components.ChatVersionHistory do
  @moduledoc """
  Version history for an edited chat message (task 019e0f29 Stage 6,
  contract Section D.2; redesign rung 9 stage 4, masters stub 'Version
  history' / MD `openPop`, direction canvas 01a1666e node m3 rule 7).
  Opens when the user clicks the `(edited)` affix.

  ONE assign, two frames, like the message actions: the phone bottom sheet
  (`#version-history-sheet`, `lg:hidden`) and the desktop popover
  (`#version-history-popover`, `hidden lg:block`, anchored to the message by
  the `MessageActionsPopover` hook, closed by click-away or Esc). Both render
  `version_list/1` from the LV's `@version_history` assign,
  `%{message_id, versions}`.

  Versions are listed newest FIRST: the newest is 'Current' with the meta
  'edited <time>', the oldest is 'Original' with its time, and any version
  between shows its time. Every version but the original shows the word
  diff against the version before it, computed here on the server by the
  pure `word_diff/2`: removed words in `<del>` (struck through, subtle),
  added words in `<ins>` (no underline, on base-300). It is read-only.
  """

  use Phoenix.Component

  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias PlatformWeb.Components.ChatHelpers

  @typedoc "One run of a word diff: kept, removed or added text."
  @type diff_op :: {:eq | :del | :ins, String.t()}

  @doc """
  The word diff from `old` to `new`, as runs of kept (`:eq`), removed
  (`:del`) and added (`:ins`) text. Pure.

  Both strings are split into words and the whitespace between them (the
  whitespace is kept as its own token, so joining every run's text in
  order rebuilds either side exactly), and the token lists are compared
  with `List.myers_difference/2`.

      iex> PlatformWeb.Components.ChatVersionHistory.word_diff("ship it today", "ship it tomorrow")
      [{:eq, "ship it "}, {:del, "today"}, {:ins, "tomorrow"}]
  """
  @spec word_diff(String.t() | nil, String.t() | nil) :: [diff_op()]
  def word_diff(old, new) do
    old
    |> tokens()
    |> List.myers_difference(tokens(new))
    |> Enum.map(fn {op, toks} -> {op, Enum.join(toks)} end)
  end

  defp tokens(text), do: Regex.split(~r/(\s+)/u, text || "", include_captures: true, trim: true)

  @doc """
  The rows to render, newest first: `%{id, label, meta, at, diff}` where
  `diff` is the `word_diff/2` against the previous version (the original's
  diff is its whole text, kept).
  """
  @spec rows([map()]) :: [map()]
  def rows(versions) do
    newest_first = Enum.sort_by(versions, & &1.version_number, :desc)
    last = length(newest_first) - 1
    older = Enum.drop(newest_first, 1) ++ [nil]

    newest_first
    |> Enum.zip(older)
    |> Enum.with_index()
    |> Enum.map(fn {{v, prev}, i} ->
      %{
        id: v.id,
        label: row_label(i, last),
        meta: row_meta(i, last, v.edited_at),
        at: v.edited_at,
        diff: if(prev, do: word_diff(prev.content, v.content), else: [{:eq, v.content || ""}])
      }
    end)
  end

  defp row_label(_i, 0), do: "Original"
  defp row_label(0, _last), do: "Current"
  defp row_label(i, i), do: "Original"
  defp row_label(_i, _last), do: nil

  defp row_meta(i, last, at) when i == last, do: ChatHelpers.relative_time(at)
  defp row_meta(_i, _last, at), do: "edited " <> ChatHelpers.relative_time(at)

  attr :version_history, :any,
    required: true,
    doc: "nil when closed; %{message_id, versions} when open"

  def chat_version_history(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        if(assigns.version_history, do: rows(assigns.version_history.versions), else: [])
      )

    ~H"""
    <.sheet
      :if={@version_history}
      id="version-history-sheet"
      open={true}
      placement={:bottom}
      on_close="close_version_history"
      class="lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Version history</:title>
      <p class="px-4 pb-2 text-base font-semibold text-base-content" aria-hidden="true">
        Version history
      </p>
      <.version_list id="version-history-sheet-list" rows={@rows} />
    </.sheet>
    <div
      :if={@version_history}
      id="version-history-popover"
      role="dialog"
      aria-label="Version history"
      tabindex="-1"
      phx-hook="MessageActionsPopover"
      phx-click-away="close_version_history"
      phx-window-keydown="close_version_history"
      phx-key="Escape"
      data-anchor-message-id={@version_history.message_id}
      class="fixed left-1/2 top-24 z-40 hidden max-h-[60vh] w-80 max-w-[calc(100vw-1rem)] overflow-y-auto rounded-box border border-edge bg-base-100 p-3 shadow-lg focus:outline-none lg:block"
    >
      <p class="pb-1 text-[13px] font-semibold text-base-content">Version history</p>
      <.version_list id="version-history-popover-list" rows={@rows} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true

  defp version_list(assigns) do
    ~H"""
    <ol id={@id} class="flex flex-col gap-3 px-1 pb-2" data-role="version-list">
      <li :for={row <- @rows} class="flex flex-col gap-1 px-3" data-role="version-row">
        <div class="flex items-baseline gap-2 text-[13px]">
          <span :if={row.label} class="font-semibold text-base-content">{row.label}</span>
          <time
            class="text-subtle"
            datetime={row.at && DateTime.to_iso8601(row.at)}
            title={row.at && DateTime.to_iso8601(row.at)}
          >
            {row.meta}
          </time>
        </div>
        <%!-- One line, unformatted: the paragraph keeps whitespace
             (pre-wrap, so a multi-line message keeps its breaks), so any
             template indentation between the runs would paint. --%>
        <p phx-no-format class="whitespace-pre-wrap break-words text-[15px] text-base-content"><%= for {op, text} <- row.diff do %><span :if={op == :eq}>{text}</span><del :if={op == :del} class="text-subtle line-through">{text}</del><ins :if={op == :ins} class="rounded-sm bg-base-300 text-base-content no-underline">{text}</ins><% end %></p>
      </li>
      <li :if={@rows == []} class="px-3 py-6 text-center text-[13px] text-subtle">
        No prior versions on record.
      </li>
    </ol>
    """
  end
end
