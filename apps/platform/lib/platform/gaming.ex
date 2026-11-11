defmodule Platform.Gaming do
  @moduledoc "Opt-in game presentation; existing authorization and accounts stay authoritative."
  def enabled?, do: Platform.Branding.get().experience == "gaming"
  def home_path(game), do: if(enabled?(), do: "/play", else: "/games/" <> game["slug"])
end
