defmodule PlatformWeb.GamingHTML do
  use PlatformWeb, :html
  import PlatformWeb.Components.GamingShell, only: [shell: 1]
  embed_templates("gaming_html/*")
end
