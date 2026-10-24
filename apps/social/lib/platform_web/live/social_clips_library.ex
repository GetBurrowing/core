defmodule PlatformWeb.SocialClipsLibrary do
  @moduledoc """
  The Clips tab's Library view (Clip Studio 3/9, task 01a16662-8c00): an
  empty shell mounted by `PlatformWeb.SocialLive` when the clips view is
  "library".

  Clip Studio 7/9 fills it, in THIS file; it never edits `social_live.ex`.
  """
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div id="social-clips-library" data-role="clips-library"></div>
    """
  end
end
