defmodule PlatformWeb.Components.ChatVersionHistory do
  @moduledoc """
  Version history popover for an edited chat message (task 019e0f29
  Stage 6, contract Section D.2). Opens when the user clicks the
  `(edited)` affix; closes via the dismiss button or by clicking the
  scrim.

  Renders a list of prior versions newest-first. Each row shows:
    * the version's body (truncated to 6 lines via line-clamp)
    * who edited it (denormalized display name from `edited_by_display_name`)
    * relative timestamp ("2 minutes ago" / "yesterday" / etc.)

  Mounted by `chat_live.html.heex` as a fixed-position overlay when
  the LV's `@version_history` assign is set to `%{message_id, versions}`.
  On desktop the overlay is a small centered dialog; on mobile it lifts
  into a bottom sheet (same Tailwind treatment as the message-actions
  sheet from Stage 3).
  """

  use Phoenix.Component

  alias PlatformWeb.Components.ChatHelpers

  attr :open, :boolean, default: false
  attr :versions, :list, default: []

  def chat_version_history(assigns) do
    ~H"""
    <div
      :if={@open}
      id="chat-version-history-overlay"
      class="fixed inset-0 z-40 flex items-center justify-center bg-black/50 backdrop-blur-sm safe-area-x"
      phx-click="close_version_history"
      phx-window-keydown="close_version_history"
      phx-key="escape"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="version-history-title"
        phx-click-away="close_version_history"
        class="w-full max-w-md max-h-[80vh] overflow-hidden flex flex-col rounded-2xl border border-base-content/10 bg-base-100 shadow-xl mx-4"
      >
        <header class="flex items-center justify-between border-b border-base-content/10 px-5 py-3 flex-shrink-0">
          <h2 id="version-history-title" class="text-sm font-semibold text-base-content">
            Edit history
          </h2>
          <button
            type="button"
            phx-click="close_version_history"
            aria-label="Close edit history"
            class="rounded-lg p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            <span class="hero-x-mark size-4"></span>
          </button>
        </header>

        <ul class="flex-1 overflow-y-auto divide-y divide-base-content/10">
          <li
            :for={v <- @versions}
            class="px-5 py-3 flex flex-col gap-1"
          >
            <div class="flex items-center justify-between text-[11px] text-base-content/50">
              <span class="font-semibold">
                v{v.version_number}
                <span class="text-base-content/40">·</span>
                {v.edited_by_display_name || "(unknown)"}
              </span>
              <time
                datetime={DateTime.to_iso8601(v.edited_at)}
                title={DateTime.to_iso8601(v.edited_at)}
              >
                {ChatHelpers.relative_time(v.edited_at)}
              </time>
            </div>
            <p class="text-sm text-base-content break-words whitespace-pre-wrap line-clamp-6">
              {v.content || ""}
            </p>
          </li>
          <li :if={@versions == []} class="px-5 py-8 text-center text-sm text-base-content/40">
            No prior versions on record.
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
