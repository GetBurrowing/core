defmodule PlatformWeb.PageController do
  use PlatformWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/chat")
  end
end
