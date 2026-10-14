defmodule PlatformWeb.ControlCenter.NativeFiles do
  @moduledoc """
  "Agent files" on a native agent's detail pane (task 01a10322 stage 5): the
  editor for the files the agent host writes into the agent's work dir on
  every start (`CLAUDE.md`, `.claude/settings.json`, ...).

  Copy and states follow the design canvas
  01a10325-8f2d-7001-b858-b92639451ceb ("Agent files"):

    * intro "Changes apply the next time <Name> starts.";
    * a dot beside a file with unsaved edits;
    * an info bar ABOVE the editor, "Saved. <Name> is still running the
      earlier version.", with Restart now, while the running agent has not
      picked up the selected file;
    * Save (neutral) and Save and restart (primary); when the agent is not
      up, Save alone, and after a save "Saved. <Name> will use this the next
      time it starts.";
    * a `.json` file that does not parse shows an error line with its line
      number, and both saves are disabled for that file;
    * below `md` (so at 375px): a select instead of the list, the file
      read-only, and "Edit files on a larger screen.".

  A person who cannot manage the agent sees none of the files, only "Only
  the agent's owner or an admin can edit its files.". That is an affordance:
  `PlatformWeb.ControlCenter.NativeFileEvents` and
  `Platform.Agents.NativeAgents.save_file/5` refuse a non-manager's save
  whatever the page shows.

  Pure rendering: no socket, no DB.
  """
  use Phoenix.Component

  @locked "Only the agent's owner or an admin can edit its files."

  @doc "What a non-manager sees in place of the editor."
  def locked_message, do: @locked

  attr :agent, :map, required: true
  attr :can_manage?, :boolean, required: true
  # The agent's process is up (running, starting, needs login): Save and
  # restart is offered, and a save may not be what it runs.
  attr :live?, :boolean, required: true
  # Keys the running agent has not picked up (NativeAgents.pending_file_keys/2).
  attr :pending_keys, :list, default: []
  # The host has reported what it applied (files_applied is a map).
  attr :applied_known?, :boolean, default: false
  attr :workspace_files, :list, required: true
  attr :selected_workspace_file, :map, default: nil
  attr :form, :map, required: true
  attr :dirty?, :boolean, default: false
  attr :json_error, :any, default: nil
  # The key saved last on this page, for the "Saved." notices.
  attr :saved_key, :string, default: nil
  attr :restarting?, :boolean, default: false

  def editor(assigns) do
    selected_key = assigns.selected_workspace_file && assigns.selected_workspace_file.file_key

    applied_bar? =
      assigns.live? and is_binary(selected_key) and
        (selected_key in assigns.pending_keys or
           (assigns.saved_key == selected_key and not assigns.applied_known?))

    assigns =
      assigns
      |> assign(:selected_key, selected_key)
      |> assign(:applied_bar?, applied_bar? and not assigns.restarting?)
      |> assign(:stopped_hint?, not assigns.live? and assigns.saved_key == selected_key)
      |> assign(:can_save?, is_nil(assigns.json_error))

    ~H"""
    <section
      id="native-files"
      class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm"
      data-dirty={to_string(@dirty?)}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-lg font-semibold text-base-content">Agent files</h2>
          <p class="mt-1 text-sm text-base-content/60">
            Changes apply the next time {@agent.name} starts.
          </p>
        </div>
        <button
          :if={@can_manage?}
          id="native-files-new"
          type="button"
          phx-click="new_workspace_file"
          class="btn btn-ghost btn-sm hidden md:inline-flex"
        >
          New file
        </button>
      </div>

      <p
        :if={!@can_manage?}
        id="native-files-locked"
        class="mt-4 rounded-box border border-edge bg-base-200/50 px-4 py-3 text-sm text-base-content/70"
      >
        {locked_message()}
      </p>

      <%!-- Above the editor at every width: it describes the selected file. --%>
      <div
        :if={@can_manage? and @applied_bar?}
        id="native-files-applied-bar"
        role="status"
        class="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-box bg-info px-4 py-2 text-sm text-info-content"
      >
        <span>Saved. {@agent.name} is still running the earlier version.</span>
        <button
          id="native-files-restart-now"
          type="button"
          phx-click="native_restart"
          phx-value-agent_id={@agent.id}
          class="btn btn-sm"
        >
          Restart now
        </button>
      </div>

      <%!-- Narrow screens (375px): a select and the file, read-only. --%>
      <div :if={@can_manage?} id="native-files-narrow" class="mt-4 md:hidden">
        <form id="native-files-pick" phx-change="select_workspace_file">
          <label for="native-files-select" class="mb-1 block text-sm text-base-content/70">
            File
          </label>
          <select id="native-files-select" name="file_key" class="select select-bordered w-full">
            <option
              :for={file <- @workspace_files}
              value={file.file_key}
              selected={file.file_key == @selected_key}
            >
              {file.file_key}
            </option>
          </select>
        </form>
        <pre
          :if={@selected_workspace_file}
          id="native-files-readonly"
          class="mt-3 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-box border border-edge bg-base-200/40 p-3 font-mono text-[13px] leading-5 text-base-content"
        >{@selected_workspace_file.content}</pre>
        <p class="mt-2 text-sm text-base-content/60">Edit files on a larger screen.</p>
      </div>

      <div
        :if={@can_manage?}
        id="native-files-wide"
        class="mt-4 hidden gap-4 md:grid md:grid-cols-[220px_minmax(0,1fr)]"
      >
        <nav class="flex flex-col gap-2" aria-label="Agent files">
          <button
            :for={file <- @workspace_files}
            id={"native-file-#{file_dom_id(file.file_key)}"}
            type="button"
            phx-click="select_workspace_file"
            phx-value-file_key={file.file_key}
            aria-current={file.file_key == @selected_key && "true"}
            class={[
              "flex items-center gap-2 rounded-2xl border px-3 py-2 text-left transition-colors",
              file.file_key == @selected_key && "border-primary bg-primary/5 text-base-content",
              file.file_key != @selected_key && "border-edge bg-base-100 hover:border-primary/30"
            ]}
          >
            <span class="min-w-0 flex-1 truncate text-sm font-semibold">{file.file_key}</span>
            <span
              :if={@dirty? and file.file_key == @selected_key}
              data-role="unsaved-dot"
              class="inline-block h-2 w-2 flex-shrink-0 rounded-full bg-base-content/70"
              title="Unsaved changes"
            >
              <span class="sr-only">Unsaved changes</span>
            </span>
          </button>
          <div
            :if={@workspace_files == []}
            class="rounded-2xl border border-dashed border-edge px-3 py-4 text-sm text-base-content/60"
          >
            No files yet.
          </div>
        </nav>

        <div class="flex min-w-0 flex-col gap-3">
          <.form
            for={@form}
            id="native-file-form"
            phx-change="native_file_change"
            phx-submit="native_file_save"
            class="flex flex-col gap-3"
          >
            <div :if={is_nil(@selected_workspace_file)}>
              <label for="native-file-key" class="mb-1 block text-sm text-base-content/70">
                File name
              </label>
              <input
                id="native-file-key"
                type="text"
                name={@form[:file_key].name}
                value={@form[:file_key].value || ""}
                class="input input-bordered w-full font-mono text-[13px] leading-5 md:max-w-sm"
                placeholder="CLAUDE.md"
                autocomplete="off"
              />
            </div>
            <input
              :if={@selected_workspace_file}
              type="hidden"
              name={@form[:file_key].name}
              value={@selected_workspace_file.file_key}
            />

            <textarea
              id="native-file-content"
              name={@form[:content].name}
              rows="18"
              phx-debounce="250"
              spellcheck="false"
              aria-label={"Contents of #{@selected_key || "the new file"}"}
              aria-invalid={@json_error && "true"}
              aria-describedby={@json_error && "native-files-json-error"}
              class={[
                "textarea textarea-bordered h-80 w-full font-mono text-[13px] leading-5",
                @json_error && "border-error"
              ]}
            >{@form[:content].value || ""}</textarea>

            <p
              :if={@json_error}
              id="native-files-json-error"
              class="flex items-center gap-2 text-sm text-base-content"
            >
              <span
                class="hero-exclamation-circle h-4 w-4 flex-shrink-0 text-error"
                aria-hidden="true"
              /> This file is not valid JSON (line {@json_error}). Fix it to save.
            </p>

            <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <p id="native-files-meta" class="text-xs text-base-content/60" role="status">
                <%= cond do %>
                  <% @stopped_hint? -> %>
                    Saved. {@agent.name} will use this the next time it starts.
                  <% @selected_workspace_file -> %>
                    {edited_label(@selected_workspace_file)}
                  <% true -> %>
                    New file
                <% end %>
              </p>
              <div class="flex gap-2">
                <button
                  id="native-file-save"
                  type="submit"
                  name="intent"
                  value="save"
                  class="btn btn-sm"
                  disabled={!@can_save?}
                >
                  Save
                </button>
                <button
                  :if={@live?}
                  id="native-file-save-restart"
                  type="submit"
                  name="intent"
                  value="save_restart"
                  class="btn btn-primary btn-sm"
                  disabled={!@can_save?}
                >
                  Save and restart
                </button>
              </div>
            </div>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  @doc "A DOM-safe id fragment for a file key."
  def file_dom_id(key) when is_binary(key),
    do: key |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

  @doc "\"Edited 2 min ago\" for a file's last save."
  def edited_label(%{updated_at: %DateTime{} = at}), do: "Edited " <> ago(at)
  def edited_label(_), do: ""

  defp ago(at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> plural(div(seconds, 3_600), "hour") <> " ago"
      true -> plural(div(seconds, 86_400), "day") <> " ago"
    end
  end

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(n, unit), do: "#{n} #{unit}s"
end
