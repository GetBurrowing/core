defmodule PlatformWeb.SocialComposer do
  @moduledoc """
  The composer's header entry point: a stub, switched off (Social authoring
  1/11). `PlatformWeb.SocialTopBar` renders `button/1` only while
  `enabled?/0` is true. Authoring 6/11 owns this file: it builds the
  composer behind the "New idea" button and flips `enabled?/0` to true,
  without editing the top bar or `social_live.ex`.
  """

  use PlatformWeb, :html

  @doc ~s(Whether the header shows the "New idea" button.)
  def enabled?, do: false

  @doc ~s(The header's "New idea" button.)
  def button(assigns) do
    ~H"""
    <button type="button" class="btn btn-primary btn-sm whitespace-nowrap" data-role="social-new-idea">
      <.icon name="hero-plus-micro" class="size-4" /> New idea
    </button>
    """
  end
end
