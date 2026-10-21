defmodule PlatformWeb.Components.EmptyState do
  @moduledoc """
  Three layouts of empty state, per `docs/design-system/02-components.md` §2.13:

    * `:minimal`        — centered text only. Used on Activity per the designer's
                          2026-05-09 pin: "the activity feed empty state is
                          fine to stay empty at start, we don't need to
                          force content."
    * `:standard`       — icon + headline + body + actions. Generic
                          fallback used for filtered no-result states like
                          search.
    * `:conversational` — V3 pattern: optional system message + Saru bot
                          bubble + chip CTAs. Used on chat sidebar, chat
                          space, tasks per `03-voice.md` §5.1, §5.2, §5.3.

  Spec: `~/projects/core/docs/design-system/components/empty_state.md`.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr :variant, :atom,
    default: :standard,
    values: [:minimal, :standard, :conversational]

  attr :icon_name, :string,
    default: nil,
    doc: "Heroicon name (`hero-...`). Optional. Used by the :standard variant."

  slot :title
  slot :body, required: true
  slot :actions, doc: "CTA buttons. Used by :standard."

  slot :chips,
    doc:
      "Chip CTAs for :conversational. Each chip has :label + :event attrs. :event may be a string event name OR a Phoenix.LiveView.JS struct (for chained operations like JS.push(\"foo\") |> JS.push(\"bar\"))." do
    attr :label, :string, required: true
    attr :event, :any, required: true
  end

  slot :system_message, doc: "Above the bot bubble. Used by :conversational."

  def empty_state(%{variant: :minimal} = assigns) do
    ~H"""
    <div class="empty-state empty-minimal">
      <p class="empty-body">
        {render_slot(@body)}
      </p>
    </div>
    """
  end

  def empty_state(%{variant: :standard} = assigns) do
    ~H"""
    <div class="empty-state empty-standard">
      <div :if={@icon_name} class="empty-icon-wrapper">
        <.icon name={@icon_name} class="size-8 text-subtle" />
      </div>
      <h2 :if={@title != []} class="empty-title">
        {render_slot(@title)}
      </h2>
      <p class="empty-body">
        {render_slot(@body)}
      </p>
      <div :if={@actions != []} class="empty-actions">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  def empty_state(%{variant: :conversational} = assigns) do
    ~H"""
    <div class="empty-state empty-conversational">
      <p :if={@system_message != []} class="empty-system-msg">
        {render_slot(@system_message)}
      </p>
      <div class="empty-bot-bubble">
        <span class="empty-bot-author">Saru · suggested</span>
        {render_slot(@body)}
      </div>
      <button
        :for={chip <- @chips}
        type="button"
        phx-click={chip.event}
        phx-value-label={chip.label}
        class="empty-chip focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
      >
        {chip.label}
      </button>
    </div>
    """
  end
end
