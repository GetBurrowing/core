defmodule PlatformWeb.ExtensionPageLive.NotFoundError do
  @moduledoc "Raised by `PlatformWeb.ExtensionPageLive.mount/3` to answer 404."
  defexception message: "not found", plug_status: 404
end
