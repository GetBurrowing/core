defmodule PlatformWeb.Components.TabSwitchCache do
  @moduledoc """
  The mount point for the tab-switch loading behaviour (redesign; reference
  canvas 01a16eb5 options 5 "cached-first" and 2 "shimmer skeleton"). The
  behaviour itself is `assets/js/hooks/tab_switch_cache.js`.

  On a tab tap (phone tab bar, More sheet rows, desktop sidebar rows) the main
  pane shows, before the server answers, the destination as it looked when it
  was last left, inert and with an "Updating" chip; or, on a first visit, a
  shimmer skeleton shaped like it. This component renders what the hook needs
  and nothing visible:

    * `data-current`: the destination key of the page on screen (the rails'
      longest-prefix matcher over every destination plus the Settings
      paths), so a snapshot is filed under the page being left;
    * `data-user`: the viewer's id. The in-memory cache is cleared whenever it
      differs from the one the cache was filled under;
    * `data-masked`: the mask-names state. Masking is a server render, so a
      change clears the cache and a snapshot is only shown in the state it
      was taken in;
    * one `<template data-skeleton>` per shape: `chat` rows, `tasks` rows,
      `inbox` cards and a `generic` list.

  Skeleton fills are `bg-base-300` on the pane's ground and on a
  `bg-base-200` card; the shimmer sweep and the 80ms reveal live in app.css
  ("Tab switch placeholder").
  """
  use Phoenix.Component

  alias PlatformWeb.Components.IconRail

  attr(:current_path, :string, default: "/")
  attr(:user, :any, default: nil, doc: "the viewer's `%User{}` record (only its id is read)")
  attr(:masked?, :boolean, default: false)

  def tab_switch_cache(assigns) do
    assigns =
      assigns
      |> assign(:current_key, current_key(assigns[:current_path]))
      |> assign(:user_id, user_id(assigns[:user]))

    ~H"""
    <div
      id="tab-switch-cache"
      phx-hook="TabSwitchCache"
      class="hidden"
      aria-hidden="true"
      data-current={@current_key}
      data-user={@user_id}
      data-masked={to_string(@masked? == true)}
    >
      <template data-skeleton="chat">
        <div class="tsc-head">
          <div class="tsc-sk h-4 w-24"></div>
        </div>
        <%= for {section, rows} <- chat_sections() do %>
          <div class="px-4.5 pt-4 pb-2" data-skeleton-section={section}>
            <div class="tsc-sk h-2.5 w-16"></div>
          </div>
          <div :for={{a, b} <- rows} class="tsc-row" data-skeleton-row>
            <div class="tsc-sk size-10.5 shrink-0 rounded-full"></div>
            <div class="tsc-lines">
              <div class="tsc-sk h-3.5" style={"width: #{a}"}></div>
              <div class="tsc-sk h-3" style={"width: #{b}"}></div>
            </div>
            <div class="tsc-sk mt-1 h-2.5 w-8.5 self-start"></div>
          </div>
        <% end %>
      </template>

      <template data-skeleton="tasks">
        <div class="tsc-head">
          <div class="tsc-sk h-4 w-36"></div>
        </div>
        <div class="tsc-sk mx-4 mb-2 h-10 rounded-box"></div>
        <div class="flex gap-1.5 pb-2 pl-4">
          <div class="tsc-sk h-8 w-24 rounded-box"></div>
          <div class="tsc-sk h-8 w-16 rounded-box"></div>
          <div class="tsc-sk h-8 w-20 rounded-box"></div>
        </div>
        <div :for={{a, b} <- task_rows()} class="tsc-row items-start" data-skeleton-row>
          <div class="tsc-sk mt-1.5 size-2.5 shrink-0 rounded-full"></div>
          <div class="tsc-lines">
            <div class="tsc-sk h-3.5" style={"width: #{a}"}></div>
            <div class="tsc-sk h-3" style={"width: #{b}"}></div>
          </div>
          <div class="tsc-sk mt-1 h-3 w-11"></div>
        </div>
      </template>

      <template data-skeleton="inbox">
        <div class="tsc-head">
          <div class="tsc-sk h-4 w-20"></div>
        </div>
        <div class="flex flex-col gap-2.5 px-3.5 py-1">
          <div
            :for={{a, b} <- inbox_cards()}
            class="rounded-box border border-edge bg-base-200 px-3.5 py-3"
            data-skeleton-row
          >
            <div class="flex items-center gap-2">
              <div class="tsc-sk size-6 rounded-full"></div>
              <div class="tsc-sk h-3 w-30"></div>
              <div class="tsc-sk ml-auto h-3 w-8.5"></div>
            </div>
            <div class="tsc-lines my-3">
              <div class="tsc-sk h-3" style={"width: #{a}"}></div>
              <div :if={b} class="tsc-sk h-3" style={"width: #{b}"}></div>
            </div>
            <div class="flex gap-1.5">
              <div class="tsc-sk h-7 w-15.5 rounded-full"></div>
              <div class="tsc-sk h-7 w-14 rounded-full"></div>
            </div>
          </div>
        </div>
      </template>

      <template data-skeleton="generic">
        <div class="tsc-head">
          <div class="tsc-sk h-4 w-28"></div>
        </div>
        <div :for={w <- generic_rows()} class="tsc-row gap-3.5 px-5 py-3.5" data-skeleton-row>
          <div class="tsc-sk size-5.5 shrink-0"></div>
          <div class="tsc-sk h-3" style={"width: #{w}"}></div>
        </div>
      </template>
    </div>
    """
  end

  # Widths copied from the reference mockup's skeletons, so the rows read as
  # text of uneven length rather than a ruled grid.
  defp chat_sections do
    [
      {"pinned", [{"38%", "62%"}, {"52%", "30%"}]},
      {"spaces", [{"30%", "78%"}, {"34%", "70%"}, {"40%", "58%"}, {"26%", "64%"}]},
      {"direct", [{"22%", "72%"}]}
    ]
  end

  defp task_rows do
    [
      {"58%", "36%"},
      {"44%", "30%"},
      {"62%", "38%"},
      {"50%", "34%"},
      {"70%", "28%"},
      {"46%", "40%"},
      {"56%", "32%"},
      {"40%", "36%"},
      {"64%", "30%"}
    ]
  end

  defp inbox_cards, do: [{"84%", "52%"}, {"90%", "40%"}, {"70%", nil}, {"88%", "60%"}]

  defp generic_rows, do: ["30%", "40%", "22%", "36%", "28%", "34%", "30%"]

  @doc """
  The destination key for `current_path`: the rails' matcher over every
  destination plus the Settings paths, as a string, or nil off the map.
  Access does not matter here, only which destination the path is under.
  """
  @spec current_key(String.t() | nil) :: String.t() | nil
  def current_key(current_path) when is_binary(current_path) do
    case IconRail.more_sheet_current_key(IconRail.destinations(root_user: true), current_path) do
      nil -> nil
      key -> to_string(key)
    end
  end

  def current_key(_current_path), do: nil

  defp user_id(%{id: id}) when is_binary(id), do: id
  defp user_id(_user), do: ""
end
