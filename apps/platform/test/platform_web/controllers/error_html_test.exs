defmodule PlatformWeb.ErrorHTMLTest do
  use PlatformWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 403.html with the access message" do
    html = render_to_string(PlatformWeb.ErrorHTML, "403", "html", [])
    assert html =~ "You don't have access, ask an admin"
    assert html =~ ~s(href="/")
    refute html =~ "Module:"
  end

  test "renders 404.html" do
    assert render_to_string(PlatformWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(PlatformWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
