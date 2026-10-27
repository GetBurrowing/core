defmodule PlatformWeb.AgentConfig.SessionStrip do
  @moduledoc """
  The session strip (task 01a17b1c stage 5, direction canvas
  01a17b1c-bf31 node m2): whether the running session matches what is saved,
  and the Restart session button. Drawn on the configuration screen and,
  standalone, on the agent page (rule 6), from the same `session` map
  `PlatformWeb.AgentConfig.Session` keeps.

  States, verbatim from the canvas:

    * up to date: "Session is up to date" + a quiet (secondary) Restart;
    * pending: a `warning` dot, "N saved changes apply on next session" and
      Restart session as the primary button, unless the open file has unsaved
      edits (then Save holds the primary: one primary at a time);
    * restarting: "Restarting…" with a spinner; editing stays available;
    * after restart: "Restarted HH:MM · Tools A → B: +tool, −tool" for 10 s,
      then it collapses and the diff stays under "Last restart".

  A harness that cannot resume says "Starts a fresh conversation" next to the
  button BEFORE the click. A restart while the agent is mid-task asks first
  (rule 4). No toast anywhere: pending is persistent state.

  Pure rendering.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :session, :map, required: true
  # The open file has unsaved edits: Save is the primary, not Restart.
  attr :dirty?, :boolean, default: false

  def strip(assigns) do
    s = assigns.session

    assigns =
      assigns
      |> assign(:s, s)
      |> assign(:primary?, s.pending > 0 and not assigns.dirty? and s.phase != :restarting)

    ~H"""
    <section
      id={@id}
      class="border-b border-edge bg-base-100 px-4 py-3 text-sm text-base-content"
      data-phase={@s.phase}
      data-pending={@s.pending}
      aria-live="polite"
    >
      <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
        <div class="min-w-0 flex-1">
          <p :if={@s.phase == :restarting} id={"#{@id}-restarting"} class="flex items-center gap-2">
            <span class="loading loading-spinner loading-xs text-base-content" aria-hidden="true">
            </span>
            Restarting…
          </p>

          <div :if={@s.phase == :restarted and @s.diff} id={"#{@id}-restarted"}>
            <.diff_line id={"#{@id}-diff"} diff={@s.diff} />
          </div>

          <p
            :if={@s.phase == :idle and @s.pending > 0}
            id={"#{@id}-pending"}
            class="flex items-center gap-2"
          >
            <span class="inline-block size-2 shrink-0 rounded-full bg-warning" aria-hidden="true">
            </span>
            {pending_copy(@s.pending)}
          </p>

          <p :if={@s.phase == :idle and @s.pending == 0} id={"#{@id}-up-to-date"} class="text-subtle">
            Session is up to date
          </p>

          <p :if={@s.error} id={"#{@id}-error"} class="mt-1 flex items-center gap-2 text-error">
            <span class="inline-block size-2 shrink-0 rounded-full bg-error" aria-hidden="true">
            </span>
            {@s.error}
          </p>
        </div>

        <div :if={@s.restart?} class="flex items-center gap-3">
          <span :if={not @s.resumes?} id={"#{@id}-fresh"} class="text-xs text-subtle">
            Starts a fresh conversation
          </span>
          <button
            id={"#{@id}-restart"}
            type="button"
            phx-click="session_restart"
            disabled={@s.phase == :restarting}
            data-primary={to_string(@primary?)}
            class={[
              "btn btn-sm",
              if(@primary?, do: "btn-primary", else: "btn-ghost border border-subtle")
            ]}
          >
            Restart session
          </button>
        </div>
      </div>

      <details
        :if={@s.phase != :restarted and @s.last}
        id={"#{@id}-last"}
        class="mt-2 text-xs text-subtle"
      >
        <summary class="cursor-pointer select-none">Last restart</summary>
        <div class="mt-2 text-sm text-base-content">
          <.diff_line id={"#{@id}-last-diff"} diff={@s.last} />
        </div>
      </details>

      <div
        :if={@s.confirm}
        id={"#{@id}-confirm"}
        class="fixed inset-0 z-50 flex items-end justify-center bg-base-content/40 p-4 sm:items-center"
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-confirm-copy"}
      >
        <div class="w-full max-w-md rounded-2xl border border-edge bg-base-100 p-5 shadow-lg">
          <p id={"#{@id}-confirm-copy"} class="text-sm text-base-content">
            {confirm_copy(@s)}
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <button
              id={"#{@id}-confirm-cancel"}
              type="button"
              phx-click="session_restart_cancel"
              class="btn btn-sm btn-ghost border border-subtle"
            >
              Cancel
            </button>
            <button
              id={"#{@id}-confirm-restart"}
              type="button"
              phx-click="session_restart_confirm"
              class="btn btn-sm btn-primary"
            >
              Restart session
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :diff, :map, required: true

  defp diff_line(assigns) do
    ~H"""
    <div id={@id}>
      <p class="flex flex-wrap items-center gap-x-2 gap-y-1">
        <span>
          Restarted
          <time
            id={"#{@id}-at"}
            phx-hook="LocalTime"
            datetime={DateTime.to_iso8601(@diff.restarted_at)}
          >
            {Calendar.strftime(@diff.restarted_at, "%H:%M")}
          </time>
          · Tools {count(@diff.before)} → {count(@diff.after)}{if @diff.added != [] or
                                                                    @diff.removed != [],
                                                                  do: ":"}
        </span>
        <span
          :for={tool <- @diff.added}
          class="inline-flex items-center gap-1 font-mono text-xs"
          data-diff="added"
        >
          <span class="inline-block size-2 rounded-full bg-success" aria-hidden="true"></span> +{tool}
        </span>
        <span
          :for={tool <- @diff.removed}
          class="inline-flex items-center gap-1 font-mono text-xs text-subtle line-through"
          data-diff="removed"
        >
          −{tool}
        </span>
      </p>
      <p :if={@diff.before_basis == "now"} id={"#{@id}-basis"} class="mt-1 text-xs text-subtle">
        The tool list before this restart was taken just now, so earlier changes may not show.
      </p>
      <p :if={@diff.resumed == false} id={"#{@id}-fresh-started"} class="mt-1 text-xs text-subtle">
        This restart started a fresh conversation.
      </p>
    </div>
    """
  end

  defp count(nil), do: "?"
  defp count(list) when is_list(list), do: length(list)

  @doc "The pending line: \"N saved changes apply on next session\"."
  def pending_copy(1), do: "1 saved change applies on next session"
  def pending_copy(n), do: "#{n} saved changes apply on next session"

  @doc "The mid-task confirm copy (canvas rule 4)."
  def confirm_copy(%{confirm: %{title: title}, agent_name: name, resumes?: true}),
    do:
      "#{name} is working on '#{title}'. Restarting resumes the conversation, " <>
        "but the step in progress may need to be redone."

  def confirm_copy(%{confirm: %{title: title}, agent_name: name}),
    do:
      "#{name} is working on '#{title}'. Restarting starts a fresh conversation, " <>
        "and the step in progress may need to be redone."
end
