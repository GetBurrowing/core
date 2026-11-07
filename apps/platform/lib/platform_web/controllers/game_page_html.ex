defmodule PlatformWeb.GamePageHTML do
  use PlatformWeb, :html
  def voice_url(user, space_id) do
    path = "/chat/" <> space_id
    if Platform.Tenancy.external_user?(user), do: PlatformWeb.ExternalRedirect.chat_url(path), else: path
  end

  embed_templates("game_page_html/*")
end
