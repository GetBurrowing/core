defmodule PlatformWeb.Canvases.HistoryComponents do
  @moduledoc "Responsive standalone history chrome (task 01a1557a, rung 17)."
  use PlatformWeb, :html
  import PlatformWeb.Components.Sheet, only: [sheet: 1]
  alias PlatformWeb.Components.ChatVersionHistory

  attr :rows, :list, required: true
  attr :open, :boolean, required: true

  def panel(assigns) do
    ~H"""
    <.sheet
      :if={@open}
      id="canvas-history-sheet"
      open={true}
      placement={:right}
      on_close="canvas_history_close"
    >
      <:title>History</:title>
      <ol id="canvas-history-list" class="flex flex-col gap-1 p-3">
        <li
          :for={row <- @rows}
          id={"canvas-history-row-#{row.revision}"}
          data-role="canvas-history-row"
          data-revision={row.revision}
          data-current={to_string(row.current?)}
        >
          <button
            type="button"
            id={"canvas-history-select-#{row.revision}"}
            phx-click={if row.current?, do: "canvas_history_current", else: "canvas_history_select"}
            phx-value-revision={row.revision}
            class={[
              "w-full rounded-box px-3 py-3 text-left text-[13px] text-base-content hover:bg-base-200 focus-visible:outline",
              row.current? && "bg-base-200"
            ]}
          >
            <span :if={row.current?} class="mr-2 font-semibold">Current</span>
            <time class="tabular-nums" datetime={iso(row.written_at)}>
              {ChatVersionHistory.history_time(row.written_at)}
            </time>
            <span class="ml-2 text-subtle">{row.written_by["display_name"] || "Unknown author"}</span>
            <span
              :if={row.restored_from}
              class="mt-1 block text-subtle tabular-nums"
              data-role="canvas-history-restored-from"
            >
              Restored from {ChatVersionHistory.clock(row.source_at)}
            </span>
          </button>
        </li>
      </ol>
    </.sheet>
    """
  end

  attr :preview, :any, required: true
  attr :can_restore, :boolean, required: true
  attr :error, :any, default: nil

  def banner(assigns) do
    ~H"""
    <section
      :if={@preview}
      id="canvas-version-preview-banner"
      class="border-b border-edge bg-base-200 px-4 py-3 text-[13px] text-base-content"
    >
      <div class="mx-auto flex max-w-[880px] flex-wrap items-center gap-3">
        <p class="grow tabular-nums">Viewing {ChatVersionHistory.clock(@preview.at)} version</p>
        <button
          id="canvas-history-back-current"
          type="button"
          phx-click="canvas_history_current"
          class="btn btn-ghost btn-sm text-base-content"
        >
          Back to current
        </button>
        <button
          :if={@can_restore}
          id="canvas-history-restore"
          type="button"
          phx-click="canvas_history_restore_prompt"
          class="btn btn-primary btn-sm text-primary-content"
        >
          Restore this version
        </button>
      </div>
    </section>
    <p
      :if={@error}
      id="canvas-history-error"
      role="alert"
      class="mx-auto w-full max-w-[880px] px-4 py-3 text-[13px] text-base-content"
    >
      {@error}
    </p>
    """
  end

  attr :confirm, :any, required: true

  def confirmation(assigns) do
    ~H"""
    <div
      :if={@confirm}
      id="canvas-restore-confirmation"
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby="canvas-restore-confirmation-title"
      phx-window-keydown="canvas_history_restore_cancel"
      phx-key="Escape"
    >
      <div class="modal-box border border-edge bg-base-100 text-base-content">
        <h2 id="canvas-restore-confirmation-title" class="text-[15px] font-semibold">
          Restore this version? The current version stays in history.
        </h2>
        <div class="modal-action">
          <button
            id="canvas-restore-cancel"
            type="button"
            phx-click="canvas_history_restore_cancel"
            class="btn btn-ghost"
          >
            Cancel
          </button>
          <button
            id="canvas-restore-confirm"
            type="button"
            phx-click="canvas_history_restore_confirm"
            phx-disable-with="Restoring…"
            class="btn btn-primary text-primary-content"
          >
            Restore this version
          </button>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click="canvas_history_restore_cancel"
        aria-label="Cancel restore"
      >
      </button>
    </div>
    """
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_), do: nil
end
