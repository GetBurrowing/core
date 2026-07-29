defmodule Platform.Chat.Canvas.LinksTest do
  @moduledoc """
  Task 019e2c4b stage 5 — the canvas URL is built once, from endpoint
  configuration, on the path stage 3 actually registered.

  The three properties asserted here are the ones that break silently:
  a hardcoded host ships a link that works in dev and 404s in production,
  a hand-built path drifts the day the route is renamed, and a second
  builder in the web layer diverges from the one the MCP tools use.
  """
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas.Links

  # A real UUIDv7 (this task's own id) rather than a placeholder — the router
  # matches `:id` as a free segment, but a well-formed id keeps the fixture
  # honest about what production values look like.
  @canvas_id "019e2c4b-de35-7b14-99c6-47c91eb43c41"

  describe "view_url/1" do
    test "is the endpoint URL plus the canvas path" do
      assert Links.view_url(@canvas_id) ==
               PlatformWeb.Endpoint.url() <> "/canvases/" <> @canvas_id
    end

    test "takes its host from endpoint configuration, not a hardcoded string" do
      assert String.starts_with?(Links.view_url(@canvas_id), PlatformWeb.Endpoint.url())
    end

    test "is absolute and carries no query string, so it is safe to paste verbatim" do
      %URI{scheme: scheme, host: host, path: path, query: query} =
        URI.parse(Links.view_url(@canvas_id))

      assert scheme in ["http", "https"]
      assert is_binary(host)
      assert path == "/canvases/" <> @canvas_id

      # A token form would arrive as a query param or a path suffix. The
      # canonical form has neither, and that is the invariant: this string is
      # never a bearer credential.
      assert is_nil(query)
    end

    test "the path it builds resolves to the route stage 3 registered" do
      %URI{path: path} = URI.parse(Links.view_url(@canvas_id))

      info = Phoenix.Router.route_info(PlatformWeb.Router, "GET", path, "localhost")

      refute info == :error
      assert info.route == Links.path_prefix() <> ":id"
      assert info.path_params == %{"id" => @canvas_id}
      assert info.plug == Phoenix.LiveView.Plug
      assert info.plug_opts == :show
      assert info |> Map.fetch!(:phoenix_live_view) |> elem(0) == PlatformWeb.CanvasLive
    end

    test "raises on a non-binary id rather than emitting a malformed link" do
      assert_raise FunctionClauseError, fn -> Links.view_url(nil) end
    end
  end

  describe "PlatformWeb.CanvasLive.canvas_url/1" do
    test "delegates to the same builder the MCP tools use" do
      assert PlatformWeb.CanvasLive.canvas_url(@canvas_id) == Links.view_url(@canvas_id)
    end
  end
end
