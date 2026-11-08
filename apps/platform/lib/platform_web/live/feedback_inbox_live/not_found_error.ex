defmodule PlatformWeb.FeedbackInboxLive.NotFoundError do
  @moduledoc """
  Raised by `PlatformWeb.FeedbackInboxLive.mount/3` to answer 404 on an
  install that is not the broker host, or for a viewer who is not an org
  admin (task 01a1b678 stage 4).
  """
  defexception message: "not found", plug_status: 404
end
