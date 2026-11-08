defmodule PlatformWeb.Components.SharingCard do
  @moduledoc """
  "Sharing with Burrow": the owner's view of what this install sends, with a
  switch for each part (task 01a1b678 stage 5; design direction canvas
  01a1b678-ebbd, layout node).

  ## Rendered from the registry

  `sharing_card/1` renders one row per `Platform.Sharing.registry/0` entry:
  its title, its one-line description, its own switch and a link that opens
  "Exactly what's sent". A new registry entry appears here with no template
  change. The panel lists `Platform.Sharing.UsageEvents.events/0` verbatim,
  each entry's `exactly_sent` lines and `Platform.Sharing.never_sent/0`, so
  the copy cannot drift from what the code sends.

  Two places render it:

    * Settings → Help (`PlatformWeb.SettingsLive`), always, whether or not
      feedback is on, so an owner can turn a part back on;
    * the setup disclosure on `/setup/connect-ai` (`PlatformWeb.ConnectAiLive`)
      with `variant={:setup}`: the heading "This install shares a little with
      Burrow." and one primary Continue.

  ## Who can switch

  `editable` is `Platform.Sharing.admin?/1` for the viewer. Anyone else sees
  every switch's state, disabled. `set/2` re-checks the rule on the server,
  so a forged `set_sharing` event from a non-admin changes nothing. Every
  change goes through `Platform.Sharing.set/3`, which writes an audit row.

  ## Colour

  Switches use the standard toggle (`bg-primary` track when on). Nothing here
  uses a warning or error colour: on-by-default sharing is a decision, not an
  alert. The copy never says "telemetry" or "analytics".
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Platform.Sharing
  alias Platform.Sharing.UsageEvents

  @failed "Couldn't save. Your setting hasn't changed."

  attr :id, :string, required: true
  attr :switches, :map, required: true, doc: "`Platform.Sharing.switches/0`"
  attr :editable, :boolean, default: false
  attr :variant, :atom, default: :settings, values: [:settings, :setup]
  attr :error, :string, default: nil
  attr :class, :any, default: nil

  @doc "The card: heading, one row per registry entry, and the panel."
  def sharing_card(assigns) do
    assigns =
      assigns
      |> assign(:entries, Sharing.registry())
      |> assign(:events, UsageEvents.events())
      |> assign(:never_sent, Sharing.never_sent())

    ~H"""
    <section
      id={@id}
      data-role="sharing-card"
      data-variant={@variant}
      aria-labelledby={"#{@id}-heading"}
      class={["rounded-box bg-base-100 text-base-content", @class]}
    >
      <div class="px-[18px] pt-4 pb-1">
        <h2
          :if={@variant == :settings}
          id={"#{@id}-heading"}
          data-role="sharing-heading"
          class="text-[15px] font-semibold text-base-content"
        >
          Sharing with Burrow
        </h2>
        <h2
          :if={@variant == :setup}
          id={"#{@id}-heading"}
          data-role="sharing-heading"
          class="text-base font-semibold text-base-content"
        >
          This install shares a little with Burrow.
        </h2>
        <p data-role="sharing-subhead" class="mt-0.5 text-[13px] text-subtle">
          Helps us decide what to build next. Each part can be turned off.
        </p>
      </div>

      <ul class="divide-y divide-edge" data-role="sharing-rows">
        <li
          :for={entry <- @entries}
          data-role="sharing-row"
          data-key={entry.key}
          class="flex items-start justify-between gap-3 px-[18px] py-3.5"
        >
          <div class="min-w-0">
            <p id={"#{@id}-#{entry.key}-title"} class="text-[15px] text-base-content">
              {entry.title}
            </p>
            <p data-role="sharing-description" class="text-[13px] text-subtle">
              {entry.description}
            </p>
            <button
              type="button"
              data-role="sharing-exactly-link"
              phx-click={open_panel(@id)}
              aria-controls={"#{@id}-exactly"}
              class="-mb-3 inline-flex min-h-11 cursor-pointer items-center text-[13px] text-base-content underline underline-offset-2 active:no-underline focus-visible-ring"
            >
              Exactly what's sent
            </button>
          </div>
          <button
            type="button"
            role="switch"
            aria-checked={to_string(Map.get(@switches, entry.key, false))}
            aria-labelledby={"#{@id}-#{entry.key}-title"}
            disabled={!@editable}
            phx-click={@editable && "set_sharing"}
            phx-value-key={entry.key}
            phx-value-enabled={to_string(!Map.get(@switches, entry.key, false))}
            data-role="sharing-switch"
            data-key={entry.key}
            data-readonly={to_string(!@editable)}
            class={[
              "mt-0.5 flex min-h-11 shrink-0 items-start focus-visible-ring",
              @editable && "cursor-pointer",
              !@editable && "cursor-default opacity-70"
            ]}
          >
            <span class={track_class(Map.get(@switches, entry.key, false))} aria-hidden="true">
              <span class={knob_class(Map.get(@switches, entry.key, false))}></span>
            </span>
          </button>
        </li>
      </ul>

      <p :if={!@editable} data-role="sharing-readonly-note" class="px-[18px] pb-2 text-xs text-subtle">
        Only an install admin can change these.
      </p>
      <p :if={@error} data-role="sharing-error" class="px-[18px] pb-2 text-xs text-subtle">
        {@error}
      </p>

      <details
        id={"#{@id}-exactly"}
        data-role="sharing-exactly"
        phx-mounted={JS.ignore_attributes(["open"])}
        class="group px-[18px] pb-4"
      >
        <summary
          data-role="sharing-exactly-summary"
          class="flex min-h-11 cursor-pointer list-none items-center gap-1.5 text-[13px] font-medium text-base-content focus-visible-ring [&::-webkit-details-marker]:hidden"
        >
          <span
            class="hero-chevron-right size-4 shrink-0 text-subtle transition-transform group-open:rotate-90 motion-reduce:transition-none"
            aria-hidden="true"
          >
          </span>
          Exactly what's sent
        </summary>
        <div data-role="sharing-exactly-panel" class="space-y-3 rounded-box bg-base-200 p-3.5">
          <div>
            <p class="text-xs font-semibold text-base-content">Sent</p>
            <ul data-role="sharing-events" class="mt-1 flex flex-wrap gap-x-1.5 gap-y-1">
              <li
                :for={{event, i} <- Enum.with_index(@events)}
                class="flex items-baseline gap-x-1.5 text-xs text-base-content"
              >
                <span data-role="sharing-event" class="font-mono">{event}</span>
                <span :if={i < length(@events) - 1} class="text-subtle" aria-hidden="true">·</span>
              </li>
            </ul>
            <dl class="mt-2 space-y-2">
              <div :for={entry <- @entries} data-role="sharing-sent-entry" data-key={entry.key}>
                <dt class="text-xs font-medium text-base-content">{entry.title}</dt>
                <dd :for={line <- entry.exactly_sent} class="text-xs text-subtle">{line}</dd>
              </div>
            </dl>
          </div>
          <div>
            <p class="text-xs font-semibold text-base-content">Never sent</p>
            <p data-role="sharing-never-sent" class="mt-1 text-xs text-subtle">
              {Enum.join(@never_sent, " · ")}
            </p>
          </div>
          <p data-role="sharing-install-id-line" class="text-xs text-base-content">
            Your install id is random and isn't linked to your account.
          </p>
        </div>
      </details>

      <div :if={@variant == :setup} class="px-[18px] pb-4">
        <button
          type="button"
          phx-click="sharing_continue"
          data-role="sharing-continue"
          class="btn btn-primary min-h-11 w-full sm:w-auto"
        >
          Continue
        </button>
      </div>
    </section>
    """
  end

  @doc """
  The `set_sharing` event, shared by both pages: parse the key against the
  registry (never `String.to_atom/1`), re-check `Platform.Sharing.admin?/1`
  for `user`, and call `Platform.Sharing.set/3`. Returns
  `{:ok, switches}` with the stored state read back, or `{:error, message}`.
  """
  @spec set(map(), term()) :: {:ok, %{atom() => boolean()}} | {:error, String.t()}
  def set(params, user) do
    with %{"key" => raw} <- params,
         key when not is_nil(key) <- Enum.find(Sharing.keys(), &(Atom.to_string(&1) == raw)),
         true <- Sharing.admin?(user),
         {:ok, _row} <- Sharing.set(key, params["enabled"] in ["true", true], {:user, user.id}) do
      {:ok, Sharing.switches()}
    else
      _ -> {:error, @failed}
    end
  end

  defp open_panel(id) do
    JS.set_attribute({"open", ""}, to: "##{id}-exactly")
    |> JS.focus(to: "##{id}-exactly summary")
  end

  defp track_class(on?) do
    [
      "relative inline-flex h-[26px] w-11 shrink-0 rounded-full transition-colors motion-reduce:transition-none",
      if(on?, do: "bg-primary", else: "bg-subtle")
    ]
  end

  defp knob_class(on?) do
    [
      "absolute top-[3px] left-[3px] size-5 rounded-full transition-transform motion-reduce:transition-none",
      if(on?, do: "translate-x-[18px] bg-primary-content", else: "bg-base-100")
    ]
  end
end
