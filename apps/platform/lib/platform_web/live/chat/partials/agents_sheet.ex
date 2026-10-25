defmodule PlatformWeb.ChatLive.Partials.AgentsSheet do
  @moduledoc """
  The Agents sheet (task 01a1557a-8f80 stage 2): the space's master switch
  ('Agents awake'), its attention policy and one awake/silenced switch per
  agent. It replaces the header agent eye.

  `agents_sheet/1` renders one of two surfaces from the same assigns:

    * `surface={:sheet}` — the phone bottom sheet (`<.sheet>`, `lg:hidden`),
      opened from the space sheet's Agents row.
    * `surface={:popover}` — the desktop popover (`hidden lg:flex`), rendered
      in the details panel right under its Agents row (Burrow redesign 22
      stage 4; it sat under a header button before), in the panel's flow so
      the scrolling panel body does not clip it. Closed by a click outside or
      Esc.

  Every control applies at once through `PlatformWeb.ChatLive.AgentsSheetHooks`;
  there is no Save button.

  Palette (the plan's binding rules): `bg-base-100` surface, `active:bg-base-200`
  pressed rows (`lg:hover:` only on the desktop popover), `border-edge`
  hairlines, text `text-base-content` / `text-subtle`. An awake agent's avatar
  ring and name take its rung-3 slot through `data-agent-slot` (app.css's
  pointer rules point `--ag` / `--ag-text` at the slot); a silenced or paused
  row withholds the accent: `border-subtle` ring, `text-subtle` name. Switches
  are `toggle toggle-primary`; the policy radio is a base-content `radio`,
  never primary, with a `border-subtle` ring when unselected. The ring and
  the radio left `--edge` and daisyUI's 20% ring because both measured under
  3:1 on base-100 (stage 4, `agents_members_sheets_contrast_guard_test.exs`).
  """

  use Phoenix.Component

  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Platform.Agents.ColorPalette
  alias PlatformWeb.ChatLive.AgentsSheetHooks

  @title "Agents in this space"

  # The masters' order (direction m2's order is overruled).
  @policies [
    {"on_mention", "On-mention", "reply only when @mentioned"},
    {"directed", "Directed", "reply only when a human directs them"},
    {"collaborative", "Collaborative", "may join in"}
  ]

  attr(:surface, :atom, values: [:sheet, :popover], required: true)
  attr(:open, :boolean, required: true)
  attr(:state, :any, required: true, doc: "`Chat.agent_attention_state/1`, or nil")
  attr(:active_space, :any, required: true)

  def agents_sheet(%{surface: :sheet} = assigns) do
    ~H"""
    <.sheet
      id="agents-sheet"
      open={@open && @state != nil}
      placement={:bottom}
      on_close="agents_close"
      class="agents-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>{title()}</:title>
      <div :if={@state} class="flex flex-col pb-2" data-role="agents-sheet-body">
        <p class="px-4 pb-1 text-base font-semibold text-base-content" aria-hidden="true">
          {title()}
        </p>
        <.body surface={:sheet} state={@state} active_space={@active_space} />
      </div>
    </.sheet>
    """
  end

  def agents_sheet(%{surface: :popover} = assigns) do
    ~H"""
    <div
      :if={@open && @state}
      id="agents-popover"
      role="dialog"
      aria-labelledby="agents-popover-title"
      phx-click-away="agents_close"
      phx-window-keydown="agents_close"
      phx-key="Escape"
      class="relative z-10 mx-1 my-1 hidden flex-col rounded-box border border-edge bg-base-100 py-2 shadow lg:flex"
    >
      <p id="agents-popover-title" class="px-4 pb-1 text-base font-semibold text-base-content">
        {title()}
      </p>
      <.body surface={:popover} state={@state} active_space={@active_space} />
    </div>
    """
  end

  attr(:surface, :atom, required: true)
  attr(:state, :map, required: true)
  attr(:active_space, :any, required: true)

  defp body(assigns) do
    assigns =
      assigns
      |> assign(:policies, @policies)
      |> assign(:policy_rows?, assigns.active_space.kind in ["channel", "group"])

    ~H"""
    <label
      data-role="agents-awake-row"
      class={["flex min-h-11 items-center gap-3 px-4 py-2", row_press(@surface)]}
    >
      <span class="flex min-w-0 flex-1 flex-col">
        <span class="text-[15px] text-base-content">Agents awake</span>
        <span class="text-[13px] text-subtle">arm / clear all agents</span>
      </span>
      <input
        type="checkbox"
        role="switch"
        data-role="agents-awake-switch"
        class="toggle toggle-primary"
        checked={@state.agents_awake}
        aria-checked={to_string(@state.agents_awake)}
        aria-label={"Agents awake, #{if @state.agents_awake, do: "on", else: "off"}"}
        phx-click="agents_awake_toggle"
      />
    </label>

    <div :if={@policy_rows?} class="mt-2 border-t border-edge pt-2">
      <p class="px-4 pb-1 text-[13px] font-semibold text-subtle">Attention policy</p>
      <div role="radiogroup" aria-label="Attention policy" data-role="agent-policy-group">
        <label
          :for={{value, label, meta} <- @policies}
          data-role="agent-policy-row"
          data-policy={value}
          class={["flex min-h-11 items-center gap-3 px-4 py-2", row_press(@surface)]}
        >
          <input
            type="radio"
            name={"agent-policy-#{@surface}"}
            value={value}
            class="radio radio-sm border-subtle text-base-content"
            checked={@state.effective_policy == value}
            phx-click="agent_policy_set"
            phx-value-policy={value}
          />
          <span class="flex min-w-0 flex-1 flex-col">
            <span class="text-[15px] text-base-content">{label}</span>
            <span class="text-[13px] text-subtle">{meta}</span>
          </span>
          <span
            :if={@state.effective_policy == value}
            data-role="agent-policy-current"
            class="text-[13px] text-subtle"
          >
            current
          </span>
        </label>
      </div>
    </div>

    <div class="mt-2 border-t border-edge pt-2">
      <p class="px-4 pb-1 text-[13px] font-semibold text-subtle">Agents</p>
      <.agent_row
        :for={agent <- @state.agents}
        agent={agent}
        paused?={!@state.agents_awake}
        surface={@surface}
      />
    </div>
    """
  end

  attr(:agent, :map, required: true)
  attr(:paused?, :boolean, required: true)
  attr(:surface, :atom, required: true)

  defp agent_row(assigns) do
    assigns =
      assign(assigns, :row_state, row_state(assigns.agent.silenced, assigns.paused?))

    ~H"""
    <label
      data-role="agent-row"
      data-participant-id={@agent.participant_id}
      data-state={@row_state}
      data-agent-slot={@row_state == "awake" && ColorPalette.slot_for(@agent.slot)}
      class={["flex min-h-11 items-center gap-3 px-4 py-2", row_press(@surface)]}
    >
      <span
        aria-hidden="true"
        class={[
          "flex size-7 shrink-0 items-center justify-center rounded-full border-2 bg-base-200 text-xs font-semibold",
          if(@row_state == "awake",
            do: "border-(--ag) text-(--ag-text)",
            else: "border-subtle text-subtle"
          )
        ]}
      >
        {initial(@agent.name)}
      </span>
      <span class="flex min-w-0 flex-1 flex-col">
        <span class={[
          "truncate text-[15px]",
          if(@row_state == "awake", do: "text-(--ag-text)", else: "text-subtle")
        ]}>
          {@agent.name}
        </span>
        <span class="text-[13px] text-subtle">{row_meta(@row_state)}</span>
      </span>
      <input
        type="checkbox"
        role="switch"
        data-role="agent-silence-switch"
        class="toggle toggle-primary"
        checked={!@agent.silenced}
        aria-checked={to_string(!@agent.silenced)}
        aria-label={"#{@agent.name}, #{if @agent.silenced, do: "silenced", else: "awake"}"}
        disabled={@paused?}
        phx-click="agent_silence_toggle"
        phx-value-participant_id={@agent.participant_id}
      />
    </label>
    """
  end

  @doc "The sheet's title and accessible name."
  def title, do: @title

  @doc """
  The header entry and space-sheet meta: `{awake, total}`. With the master
  switch off nothing is awake, whatever the per-agent values say.
  """
  @spec awake_counts(map() | nil) :: {non_neg_integer(), non_neg_integer()}
  def awake_counts(%{agents_awake: awake?, agents: agents}) do
    awake = if awake?, do: Enum.count(agents, &(!&1.silenced)), else: 0
    {awake, length(agents)}
  end

  def awake_counts(_state), do: {0, 0}

  @doc "`\"2/4 awake\"`."
  @spec awake_label(map() | nil) :: String.t()
  def awake_label(state) do
    {awake, total} = awake_counts(state)
    "#{awake}/#{total} awake"
  end

  @doc """
  The space sheet's Agents row meta, the masters' '2/4 awake · on-mention'.
  Spaces the policy does not apply to (execution) carry the count alone.
  """
  @spec entry_meta(map() | nil, map()) :: String.t()
  def entry_meta(%{effective_policy: policy} = state, %{kind: kind})
      when kind in ["channel", "group"],
      do: awake_label(state) <> " · " <> AgentsSheetHooks.policy_word(policy)

  def entry_meta(state, _space), do: awake_label(state)

  defp row_state(_silenced, true), do: "paused"
  defp row_state(true, false), do: "silenced"
  defp row_state(false, false), do: "awake"

  defp row_meta("paused"), do: "Paused for this space"
  defp row_meta("silenced"), do: "silenced"
  defp row_meta("awake"), do: "awake"

  # Phone rows press; only the desktop popover gets a hover fill.
  defp row_press(:sheet), do: "cursor-pointer active:bg-base-200"
  defp row_press(:popover), do: "cursor-pointer active:bg-base-200 lg:hover:bg-base-200"

  defp initial(name) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp initial(_name), do: "A"
end
