defmodule PlatformWeb.LegacyPipelineController do
  @moduledoc "Redirects the old pipeline URL to its Tasks module route."

  use PlatformWeb, :controller

  def show(conn, _params), do: redirect(conn, to: ~p"/tasks/pipeline")
end
