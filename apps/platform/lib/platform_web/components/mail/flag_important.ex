defmodule PlatformWeb.Components.Mail.FlagImportant do
  @moduledoc """
  The "Flag important email" row on each Email account card (task 01a1f5cc
  stage 3), moved out of `PlatformWeb.EmailLive` (stage 4). Pure render: the
  LiveView owns `assign_flag_important/3` and the `flag_pick`,
  `flag_cancel` and `flag_confirm` events; this component only draws the
  saved agent, the picker and the +/- access ledger.
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias Phoenix.LiveView.JS

  # ── Flag important email (task 01a1f5cc stage 3) ──────────────────────
  # Design canvas 01a1f5cf-0843-7000-8c0b-c934fb9fc141. The picker always
  # shows the SAVED agent; a pick opens the access ledger and nothing is
  # written until Give access / Turn off. A listbox popover at md and up, a
  # bottom sheet below md (the Access panel's sheet classes).

  attr(:account, :map, required: true)
  attr(:manage?, :boolean, required: true)
  attr(:readable?, :boolean, required: true)
  attr(:agent, :any, required: true)
  attr(:activity, :any, required: true)
  attr(:choices, :list, required: true)
  attr(:pending, :any, required: true)

  def flag_important(assigns) do
    %{account: account, agent: agent, pending: pending, choices: choices} = assigns
    pending = if(match?(%{account_id: id} when id == account.id, pending), do: pending)

    new_agent =
      case pending do
        %{agent_id: id} when is_binary(id) -> Enum.find(choices, &(&1.id == id))
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:id, account.id)
      |> assign(:state, flag_state(assigns))
      |> assign(:pending, pending)
      |> assign(:new_agent, new_agent)
      |> assign(:saved_id, agent && agent.id)

    ~H"""
    <div
      class="flex flex-col gap-2 border-t border-edge pt-3"
      data-role="flag-important"
      data-account-id={@id}
      data-state={@state}
    >
      <%= if @state in ["owner-only", "readonly", "no-agents"] do %>
        <p class="text-sm font-semibold text-base-content">Flag important email</p>
        <p
          :if={@state == "owner-only"}
          class="text-sm text-base-content"
          data-role="flag-important-owner-only"
        >
          Only the mailbox owner can set this.
        </p>
        <p
          :if={@state == "no-agents"}
          class="text-sm text-base-content"
          data-role="flag-important-no-agents"
        >
          No agents available to you yet
        </p>
        <%= if @state == "readonly" do %>
          <p
            :if={@agent && @agent.status == "active"}
            class="flex items-start gap-2 text-sm text-base-content"
            data-role="flag-important-readonly"
          >
            <span class="mt-1.5 size-2 shrink-0 rounded-full bg-info" aria-hidden="true"></span>
            <span>{@agent.name} reads this mailbox for you · set by this mailbox's admins</span>
          </p>
          <p
            :if={@agent && @agent.status != "active"}
            class="flex items-start gap-2 text-sm text-base-content"
            data-role="flag-important-readonly"
          >
            <span class="hero-exclamation-circle size-4 shrink-0 text-error" aria-hidden="true">
            </span>
            <span>Stopped: {@agent.name} can no longer read this mailbox.</span>
          </p>
          <p
            :if={is_nil(@agent)}
            class="text-sm text-base-content"
            data-role="flag-important-readonly"
          >
            <span data-role="flag-important-off">Off: no agent flags important email here.</span>
          </p>
        <% end %>
      <% else %>
        <div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between md:gap-4">
          <p id={"flag-label-#{@id}"} class="text-sm font-semibold text-base-content">
            Flag important email
          </p>
          <div class="relative w-full md:w-64 md:shrink-0">
            <button
              type="button"
              id={"flag-picker-#{@id}"}
              class="btn btn-sm min-h-11 w-full justify-between gap-2 border-edge bg-base-100 font-normal text-base-content md:min-h-9"
              aria-haspopup="listbox"
              aria-labelledby={"flag-label-#{@id} flag-picker-#{@id}"}
              data-role="flag-important-picker"
              phx-click={flag_open_sheet(@id)}
            >
              <span class="flex min-w-0 items-center gap-2">
                <.agent_avatar
                  :if={@agent}
                  name={@agent.name}
                  avatar_url={@agent.avatar_url}
                  size="xs"
                />
                <span class="truncate">{if(@agent, do: @agent.name, else: "Off")}</span>
              </span>
              <span class="hero-chevron-down size-4 shrink-0" aria-hidden="true"></span>
            </button>

            <div
              id={"flag-sheet-#{@id}"}
              class="fixed inset-0 z-40 hidden items-end justify-center clears-tab-bar md:absolute md:inset-auto md:right-0 md:top-full md:z-30 md:mt-1 md:w-72"
              data-role="flag-important-sheet"
              phx-window-keydown={flag_close_sheet(@id)}
              phx-key="Escape"
            >
              <div
                class="absolute inset-0 bg-black/40 md:hidden"
                phx-click={flag_close_sheet(@id)}
                aria-hidden="true"
              >
              </div>
              <div
                role="listbox"
                id={"flag-listbox-#{@id}"}
                aria-labelledby={"flag-label-#{@id}"}
                class="relative flex max-h-[75vh] w-full max-w-lg flex-col overflow-y-auto rounded-t-2xl bg-base-100 py-2 pb-[env(safe-area-inset-bottom)] shadow-2xl md:max-h-80 md:max-w-none md:rounded-box md:border md:border-edge md:pb-2 md:shadow-lg"
              >
                <p class="px-4 py-2 text-xs font-semibold text-subtle md:hidden">
                  Flag important email
                </p>
                <button
                  type="button"
                  role="option"
                  aria-selected={to_string(is_nil(@saved_id))}
                  class="flex min-h-11 w-full items-center gap-3 px-4 py-2 text-left text-sm text-base-content hover:bg-base-200 focus:bg-base-200 focus:outline-none"
                  data-role="flag-important-option"
                  data-agent-id="off"
                  phx-click={flag_choose(@id, "off")}
                >
                  <span class="hero-no-symbol size-5 shrink-0 text-subtle" aria-hidden="true"></span>
                  <span class="min-w-0 flex-1">Off: no agent flags important email here</span>
                  <span
                    :if={is_nil(@saved_id)}
                    class="hero-check size-4 shrink-0"
                    aria-hidden="true"
                  >
                  </span>
                </button>
                <button
                  :for={choice <- @choices}
                  type="button"
                  role="option"
                  aria-selected={to_string(choice.id == @saved_id)}
                  class="flex min-h-11 w-full items-center gap-3 px-4 py-2 text-left text-sm text-base-content hover:bg-base-200 focus:bg-base-200 focus:outline-none"
                  data-role="flag-important-option"
                  data-agent-id={choice.id}
                  phx-click={flag_choose(@id, choice.id)}
                >
                  <.agent_avatar name={choice.name} avatar_url={choice.avatar_url} size="sm" />
                  <span class="shrink-0">{choice.name}</span>
                  <span class="min-w-0 flex-1 truncate text-xs text-subtle">
                    {flag_role_line(choice)}
                  </span>
                  <span
                    :if={choice.id == @saved_id}
                    class="hero-check size-4 shrink-0"
                    aria-hidden="true"
                  >
                  </span>
                </button>
              </div>
            </div>
          </div>
        </div>

        <%= case @state do %>
          <% "on" -> %>
            <p class="text-xs text-subtle">
              This agent reads new email in this mailbox and puts what needs you at the top of your morning briefing, with a reply drafted. It never sends anything.
            </p>
            <p
              class="flex items-start gap-2 text-sm text-base-content"
              data-role="flag-important-status"
            >
              <span class="mt-1.5 size-2 shrink-0 rounded-full bg-info" aria-hidden="true"></span>
              <span>
                On · {@agent.name} reads new mail in this mailbox only and flags what's important in your briefing.
              </span>
            </p>
            <p class="pl-4 text-xs text-subtle" data-role="flag-important-activity">
              {flag_activity_text(@activity)}
            </p>
          <% "stopped" -> %>
            <p
              class="flex items-start gap-2 text-sm text-base-content"
              data-role="flag-important-stopped"
            >
              <span
                class="hero-exclamation-circle mt-0.5 size-4 shrink-0 text-error"
                aria-hidden="true"
              >
              </span>
              <span>
                Stopped: {@agent.name} can no longer read this mailbox.
                <button
                  type="button"
                  class="text-base-content underline underline-offset-2"
                  phx-click={flag_open_sheet(@id)}
                >
                  Choose an agent
                </button>
              </span>
            </p>
          <% _ -> %>
            <p class="text-sm text-base-content" data-role="flag-important-off">
              Off: no agent flags important email here.
            </p>
        <% end %>

        <div
          :if={@pending}
          id={"flag-ledger-#{@id}"}
          class="flex flex-col gap-2 rounded-box border border-edge bg-base-200 p-3"
          role="group"
          aria-labelledby={"flag-ledger-heading-#{@id}"}
          data-role="flag-important-ledger"
          phx-window-keydown="flag_cancel"
          phx-key="Escape"
          phx-mounted={JS.focus(to: "#flag-ledger-heading-#{@id}")}
        >
          <h3
            id={"flag-ledger-heading-#{@id}"}
            tabindex="-1"
            class="text-sm font-semibold text-base-content focus:outline-none"
          >
            {flag_ledger_heading(@new_agent, @agent)}
          </h3>
          <p
            :if={@new_agent}
            class="flex gap-2 text-sm font-medium text-base-content"
            data-role="flag-important-ledger-plus"
          >
            <span class="w-3 shrink-0 font-mono text-base-content">+</span>
            <span>{@new_agent.name} can read new mail in this mailbox</span>
          </p>
          <p
            :if={@agent}
            class="flex gap-2 text-sm font-medium text-base-content"
            data-role="flag-important-ledger-minus"
          >
            <span class="w-3 shrink-0 font-mono text-base-content">−</span>
            <span>{@agent.name} stops reading it for you</span>
          </p>
          <p :if={@agent && @new_agent} class="pl-5 text-sm font-medium text-base-content">
            {@agent.name} keeps any other access you gave it
          </p>
          <div class="flex flex-col gap-2 pt-1 min-[360px]:flex-row min-[360px]:justify-end">
            <button
              type="button"
              phx-click="flag_cancel"
              class="btn btn-ghost btn-sm min-h-11 w-full min-[360px]:w-auto md:min-h-8"
              data-role="flag-important-cancel"
            >
              Cancel
            </button>
            <button
              type="button"
              phx-click="flag_confirm"
              phx-value-account_id={@id}
              phx-value-agent_id={if(@new_agent, do: @new_agent.id, else: "off")}
              class={[
                "btn btn-sm min-h-11 w-full min-[360px]:w-auto md:min-h-8",
                if(@new_agent,
                  do: "btn-primary",
                  else: "border-edge bg-base-100 text-base-content"
                )
              ]}
              data-role="flag-important-confirm"
            >
              {if(@new_agent, do: "Give access", else: "Turn off")}
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp flag_state(%{manage?: false, readable?: false}), do: "owner-only"
  defp flag_state(%{manage?: false}), do: "readonly"
  defp flag_state(%{choices: [], agent: nil}), do: "no-agents"
  defp flag_state(%{agent: nil}), do: "off"
  defp flag_state(%{agent: %{status: "active"}}), do: "on"
  defp flag_state(_assigns), do: "stopped"

  defp flag_ledger_heading(%{name: new}, nil), do: "Choose #{new}? (not saved yet)"
  defp flag_ledger_heading(%{name: new}, _old), do: "Switch to #{new}? (not saved yet)"
  defp flag_ledger_heading(nil, %{name: old}), do: "Turn off #{old}? (not saved yet)"
  defp flag_ledger_heading(_new, _old), do: "Turn off? (not saved yet)"

  defp flag_open_sheet(id) do
    JS.show(to: "#flag-sheet-#{id}", display: "flex")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#flag-picker-#{id}")
    |> JS.focus_first(to: "#flag-listbox-#{id}")
  end

  defp flag_close_sheet(id) do
    JS.hide(to: "#flag-sheet-#{id}")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#flag-picker-#{id}")
  end

  defp flag_choose(id, agent_id) do
    id
    |> flag_close_sheet()
    |> JS.push("flag_pick", value: %{account_id: id, agent_id: agent_id})
  end

  defp flag_role_line(%{metadata: %{"role" => role}}) when is_binary(role) and role != "",
    do: role

  defp flag_role_line(_agent), do: nil

  # UTC, like every other time on this page (the inbox rows, `full_time/1`).
  defp flag_last_read(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  defp flag_activity_text(%{last_at: at, count: 1}),
    do: "Last read #{flag_last_read(at)} · 1 new email"

  defp flag_activity_text(%{last_at: at, count: n}),
    do: "Last read #{flag_last_read(at)} · #{n} new emails"

  defp flag_activity_text(_), do: "Waiting for new email"
end
