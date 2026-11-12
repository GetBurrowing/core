defmodule PlatformWeb.GamePageHTML do
  use PlatformWeb, :html
  import PlatformWeb.Components.GamingShell, only: [shell: 1]

  embed_templates("game_page_html/*")
end
