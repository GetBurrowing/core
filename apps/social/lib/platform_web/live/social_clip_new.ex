defmodule PlatformWeb.SocialClipNew do
  @moduledoc """
  The Clips tab's "New clip from episode" mount point (Clip Studio 3/9,
  task 01a16662-8c00): an empty, hidden shell mounted by
  `PlatformWeb.SocialLive` in the clips pane.

  Clip Studio 8/9 fills it, in THIS file; it never edits `social_live.ex`.
  """
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div id="social-clip-new" data-role="clip-new" class="hidden"></div>
    """
  end
end
