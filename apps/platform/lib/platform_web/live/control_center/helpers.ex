defmodule PlatformWeb.ControlCenter.Helpers do
  @moduledoc """
  Shared rendering helpers for ControlCenter components.

  Pure functions for badge classes, humanization, and formatting —
  no socket or assign access.
  """

  def agent_badge_class("active"),
    do: "rounded-full bg-success/15 px-2 py-1 text-[11px] font-semibold text-success"

  def agent_badge_class("paused"),
    do: "rounded-full bg-warning/15 px-2 py-1 text-[11px] font-semibold text-warning"

  def agent_badge_class("archived"),
    do: "rounded-full bg-base-200 px-2 py-1 text-[11px] font-semibold text-base-content/60"

  def agent_badge_class(_status),
    do: "rounded-full bg-base-200 px-2 py-1 text-[11px] font-semibold text-base-content/60"

  def source_badge_class(:workspace),
    do: "rounded-full bg-info/15 px-2 py-1 text-[11px] font-semibold text-info"

  def source_badge_class(:database),
    do: "rounded-full bg-base-200 px-2 py-1 text-[11px] font-semibold text-base-content/60"

  def source_badge_class(_source),
    do: "rounded-full bg-base-200 px-2 py-1 text-[11px] font-semibold text-base-content/60"

  def runtime_badge_class(:working),
    do: "rounded-full bg-success/15 px-3 py-1 text-xs font-semibold text-success"

  def runtime_badge_class(:idle),
    do: "rounded-full bg-base-200 px-3 py-1 text-xs font-semibold text-base-content/65"

  def runtime_badge_class(:paused),
    do: "rounded-full bg-warning/15 px-3 py-1 text-xs font-semibold text-warning"

  def runtime_badge_class(_status),
    do: "rounded-full bg-base-200 px-3 py-1 text-xs font-semibold text-base-content/65"

  def session_badge_class("running"),
    do: "rounded-full bg-info/15 px-2 py-1 text-[11px] font-semibold text-info"

  def session_badge_class("completed"),
    do: "rounded-full bg-success/15 px-2 py-1 text-[11px] font-semibold text-success"

  def session_badge_class("failed"),
    do: "rounded-full bg-error/15 px-2 py-1 text-[11px] font-semibold text-error"

  def session_badge_class("cancelled"),
    do: "rounded-full bg-warning/15 px-2 py-1 text-[11px] font-semibold text-warning"

  def session_badge_class(_status),
    do: "rounded-full bg-base-200 px-2 py-1 text-[11px] font-semibold text-base-content/60"

  def humanize_memory_type(type), do: humanize_value(type)

  def humanize_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> humanize_value()

  def humanize_value(value) when is_binary(value) do
    value
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize_value(value), do: to_string(value)

  def format_datetime(nil), do: "—"

  def format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %I:%M %p")
  end

  def format_datetime(%NaiveDateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %I:%M %p")
  end

  def format_datetime(_value), do: "—"

  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def short_id(_id), do: "—"
end
