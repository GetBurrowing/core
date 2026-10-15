defmodule PlatformWeb.AccessDeniedController do
  use PlatformWeb, :controller

  alias Platform.Access.Registry

  def show(conn, params) do
    module_label =
      Enum.find_value(Registry.rail_entries(), fn entry ->
        if Atom.to_string(entry.key) == params["module"] do
          entry.key |> Atom.to_string() |> Phoenix.Naming.humanize()
        end
      end)

    conn
    |> put_status(:forbidden)
    |> put_view(html: PlatformWeb.ErrorHTML)
    |> render(:"403", module_label: module_label)
  end
end
