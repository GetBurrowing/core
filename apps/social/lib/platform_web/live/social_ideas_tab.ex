defmodule PlatformWeb.SocialIdeasTab do
  @moduledoc """
  The Ideas tab: a stub, switched off (Social authoring 1/11). Authoring
  7/11 owns this file: it fills `pane/1` (and `load/1`, `events/0`,
  `handle_event/3` as needed) and flips `enabled?/0` to true. Nothing in
  `social_live.ex` changes for it; `PlatformWeb.SocialTabs` already lists
  this module between Queue and Calendar.
  """

  use PlatformWeb.SocialTab

  @impl true
  def enabled?, do: false

  @impl true
  def all_brands?, do: true

  @impl true
  def pane(assigns) do
    ~H"""
    <div data-role="social-ideas"></div>
    """
  end
end
