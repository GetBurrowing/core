defmodule PlatformWeb.PageController do
  use PlatformWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
