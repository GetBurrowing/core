defmodule PlatformWeb.GoalsSettings do
  @moduledoc "Owner check-in settings, built from the audience sheet's parts."
  use Phoenix.Component
  alias PlatformWeb.Components.Sheet
  alias PlatformWeb.GoalsOpenUp

  attr :settings, :map, required: true
  attr :coach_name, :string, default: nil

  def settings_sheet(assigns) do
    ~H"""
    <Sheet.sheet
      id="goals-settings-sheet"
      open
      placement={:right}
      on_close="close_settings"
      class={GoalsOpenUp.sheet_class()}
      data-role="settings-sheet"
    >
      <:title>How we check in</:title>
      <.group
        field="rhythm"
        title="Check-in"
        selected={@settings["rhythm"]}
        options={[
          {"daily", "Every day"},
          {"weekdays", "Weekdays"},
          {"weekly", "Weekly"},
          {"biweekly", "Every other week"}
        ]}
      />
      <.group
        :if={@settings["rhythm"] in ["weekly", "biweekly"]}
        field="rhythm_weekday"
        title="Day"
        selected={to_string(@settings["rhythm_weekday"] || 1)}
        options={
          Enum.with_index(~w(Mon Tue Wed Thu Fri Sat Sun), 1)
          |> Enum.map(fn {label, day} -> {to_string(day), label} end)
        }
      />
      <.group
        field="outreach"
        title="Nudges"
        selected={@settings["outreach"]}
        options={[{"off", "Off"}, {"gentle", "Gentle"}, {"pushy", "Pushy"}]}
      />
      <.group
        :if={@coach_name}
        field="agent_mode"
        title={"#{@coach_name}'s part"}
        selected={@settings["agent_mode"]}
        options={[{"do", "Does the work"}, {"advise", "Advises"}, {"coach", "Coaches"}]}
      />
      <:actions>
        <button type="button" phx-click="save_settings" class="btn btn-primary">Save</button>
      </:actions>
    </Sheet.sheet>
    """
  end

  attr :field, :string, required: true
  attr :title, :string, required: true
  attr :selected, :string, required: true
  attr :options, :list, required: true

  defp group(assigns) do
    ~H"""
    <fieldset class="mb-5">
      <legend class="mb-2 text-sm font-semibold text-base-content">{@title}</legend>
      <div class="flex flex-wrap gap-1.5">
        <button
          :for={{value, label} <- @options}
          type="button"
          phx-click="settings_select"
          phx-value-field={@field}
          phx-value-value={value}
          value={value}
          aria-pressed={to_string(@selected == value)}
          class={GoalsOpenUp.chip_class(@selected == value)}
        >
          {label}
        </button>
      </div>
    </fieldset>
    """
  end
end
