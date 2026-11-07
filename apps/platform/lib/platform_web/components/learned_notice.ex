defmodule PlatformWeb.Components.LearnedNotice do
  @moduledoc """
  The acted-for-you notice (learned defaults rung 3, task 01a1b6a1 stage 4;
  direction canvas 01a1b6a2 nodes `layout`, `pal` and `crit`, mockup canvas
  01a1b6ad section C; `0061-learned-defaults.md` § 5).

  When the habits engine asked someone for attention on the author's behalf,
  the author sees this under the message, for as long as the message exists.
  It is rendered from data (`Platform.Habits.act_notices/2`, attached as the
  message's virtual `:learned_notice` by `MessagesHooks`), so it survives a
  reload, and it is NEVER a flash or toast: a toast is gone before you notice
  something was done for you.

  ## States (`data-state`)

    * `shown`: "✦ Asked <name> for attention, as you usually do here.", the
      orange Undo (`undo_learned_action`) and the ··· menu holding "Stop doing
      this automatically" (`stop_learned_action`), "Ask someone else…" (the
      picker) and "Learned defaults" (Settings).
    * `stopped`: the inline confirmation of Stop, in place. The ask itself
      stays, so Undo stays.
    * `undone`: quiet and dashed; the request is withdrawn and the notice
      offers the picker.

  No success colour anywhere: an automatic action is not a celebration
  (direction `pal`). No confidence number.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @settings_path "/settings?sheet=learned_defaults"

  @doc "The Settings → Learned defaults path every learned surface links to."
  @spec settings_path() :: String.t()
  def settings_path, do: @settings_path

  attr(:message_id, :string, required: true)
  attr(:notice, :map, required: true)
  attr(:read_only, :boolean, default: false)

  def learned_notice(assigns) do
    assigns =
      assigns
      |> assign(:state, state(assigns.notice))
      |> assign(:name, assigns.notice[:name] || "someone")
      |> assign(:menu_id, "learned-notice-menu-#{assigns.message_id}")
      |> assign(:settings_path, @settings_path)

    ~H"""
    <div
      id={"learned-notice-#{@message_id}"}
      data-role="learned-notice"
      data-state={@state}
      class={[
        "relative mb-1.5 ml-1.5 mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1.5 rounded-box border border-edge py-2 pl-2.5 pr-2 lg:max-w-[560px]",
        if(@state == "undone", do: "border-dashed bg-transparent", else: "bg-base-100")
      ]}
    >
      <p
        data-role="learned-notice-text"
        class={[
          "min-w-0 flex-[1_1_180px] text-[13px] leading-[18px]",
          if(@state == "undone", do: "text-subtle", else: "text-base-content")
        ]}
      >
        <%= case @state do %>
          <% "undone" -> %>
            Undone. {@name} isn’t asked on this message.
          <% "stopped" -> %>
            <span data-role="learned-mark" class="mr-[3px] text-info" aria-hidden="true">✦</span><span data-role="learned-notice-confirm">Got it. Won’t ask {@name} for you here again. {@name} stays first in your list.</span>
            <.link
              navigate={@settings_path}
              data-role="learned-notice-settings"
              class="font-semibold text-base-content underline underline-offset-2"
            >
              Learned defaults
            </.link>
          <% _ -> %>
            <span data-role="learned-mark" class="mr-[3px] text-info" aria-hidden="true">✦</span>Asked {@name} for attention, as you usually do here.
        <% end %>
      </p>
      <span :if={!@read_only} class="ml-auto flex items-center gap-1">
        <button
          :if={@state != "undone"}
          type="button"
          data-role="learned-notice-undo"
          phx-click="undo_learned_action"
          phx-value-message-id={@message_id}
          class="h-[30px] rounded-[var(--radius-field)] bg-primary px-3.5 text-[13px] font-semibold text-primary-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          Undo
        </button>
        <button
          :if={@state == "undone"}
          type="button"
          data-role="learned-notice-ask"
          phx-click="open_message_attention"
          phx-value-message-id={@message_id}
          class="h-[30px] rounded-[var(--radius-field)] px-2.5 text-[13px] font-semibold text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          Ask someone
        </button>
        <button
          :if={@state == "shown"}
          type="button"
          data-role="learned-notice-menu-toggle"
          aria-label="More"
          aria-haspopup="menu"
          aria-controls={@menu_id}
          phx-click={JS.toggle(to: "##{@menu_id}")}
          class="flex h-[30px] w-[30px] items-center justify-center rounded-[var(--radius-field)] text-base font-bold tracking-[1px] text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          ···
        </button>
      </span>
      <div
        :if={@state == "shown" and !@read_only}
        id={@menu_id}
        role="menu"
        data-role="learned-notice-menu"
        phx-click-away={JS.hide(to: "##{@menu_id}")}
        class="absolute bottom-[calc(100%+4px)] right-1.5 z-30 hidden min-w-[244px] rounded-box border border-edge bg-base-100 p-1 shadow-lg"
      >
        <button
          type="button"
          role="menuitem"
          data-role="learned-notice-stop"
          phx-click={JS.hide(to: "##{@menu_id}") |> JS.push("stop_learned_action")}
          phx-value-message-id={@message_id}
          class={menu_item_class()}
        >
          Stop doing this automatically
          <small class="text-xs font-normal text-subtle">
            Back to suggesting {@name} first here
          </small>
        </button>
        <button
          type="button"
          role="menuitem"
          data-role="learned-notice-ask-other"
          phx-click={JS.hide(to: "##{@menu_id}") |> JS.push("open_message_attention")}
          phx-value-message-id={@message_id}
          class={menu_item_class()}
        >
          Ask someone else…
        </button>
        <.link
          role="menuitem"
          navigate={@settings_path}
          data-role="learned-notice-menu-settings"
          class={menu_item_class()}
        >
          Learned defaults
        </.link>
      </div>
    </div>
    """
  end

  @doc "The notice's state: `undone`, `stopped` or `shown`."
  @spec state(map()) :: String.t()
  def state(%{undone?: true}), do: "undone"
  def state(%{stopped?: true}), do: "stopped"
  def state(_notice), do: "shown"

  defp menu_item_class,
    do:
      "flex w-full flex-col items-start rounded-[var(--radius-field)] px-2.5 py-2 text-left text-sm font-medium text-base-content hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
end
