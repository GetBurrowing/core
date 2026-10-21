defmodule PlatformWeb.Components.ChatMessageEditor do
  @moduledoc """
  Inline editor that replaces a chat message bubble while the user is
  editing it (task 019e0f29 Stage 5, editable-messages contract
  Section d.3 + Section F.4).

  Mounted by `chat_message.ex` when `@editing_message_id == @msg.id`.
  Hooked to the `MessageEditor` JS module (assets/js/hooks/
  message_editor.js) which handles Cmd/Ctrl+Enter to submit, Escape to
  cancel, and live detection of shortened-or-removed content so the
  LV's `save_edit` handler can decide whether to surface the removal
  warning modal before firing the PATCH.

  The form fires `phx-submit="save_edit"` with the message id, the new
  body text, and a `removes_content` flag the JS hook keeps in sync.
  Cancel buttons fire `phx-click="cancel_edit"` which restores the
  bubble.
  """

  use Phoenix.Component

  attr :msg, :map, required: true, doc: "the message being edited"

  def chat_message_editor(assigns) do
    ~H"""
    <form
      id={"msg-editor-#{@msg.id}"}
      phx-hook="MessageEditor"
      phx-submit="save_edit"
      data-original-content={@msg.content || ""}
      class="flex flex-col gap-2 rounded-2xl border border-primary/40 bg-base-100 p-3 shadow-md"
    >
      <input type="hidden" name="message_id" value={@msg.id} />
      <input type="hidden" name="removes_content" value="false" />

      <textarea
        name="body"
        rows="3"
        aria-label="Edit message"
        class="min-w-0 w-full resize-y rounded-lg border border-base-content/10 bg-base-200/40 px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        style="field-sizing:content;min-height:48px;max-height:400px"
      ><%= @msg.content || "" %></textarea>

      <div class="flex items-center justify-between gap-2">
        <p class="text-xs text-subtle">
          <kbd class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-[10px]">⌘</kbd>
          <kbd class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-[10px]">⏎</kbd>
          to save · <kbd class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-[10px]">Esc</kbd>
          to cancel
        </p>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="cancel_edit"
            class="rounded-md px-3 py-1.5 text-sm text-base-content/70 hover:bg-base-300 hover:text-base-content transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:bg-primary/90 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            Save
          </button>
        </div>
      </div>
    </form>
    """
  end
end
