defmodule Platform.Chat.Canvas.LinksCanonicalHostTest do
  @moduledoc """
  Burrow rename (task 01a18dab stage 3): with the endpoint's URL on the
  `burrow.` host and the old `suite.` host configured as an alias
  (example.net stand-ins; the real domain is on the install-identity
  denylist),

    * a new canvas link is minted on burrow (`Links.view_url/1` follows the
      endpoint, no code change);
    * an old suite canvas link is still an in-app canvas and renders
      path-relative, so it opens on whichever host the reader is on;
    * the VAPID subject's default follows the endpoint host.

  The endpoint URL is swapped by replacing the persistent term Phoenix reads
  `url/0`, `struct_url/0` and `host/0` from, and restored afterwards. That is
  process-global, so this module is `async: false` (ExUnit runs it after
  every async module has finished).
  """
  use ExUnit.Case, async: false

  alias Platform.Chat.Canvas.Links
  alias Platform.Chat.LinkTargets

  @burrow "burrow.example.net"
  @suite "suite.example.net"
  @canvas_id "01a18db1-c86e-7002-b5a9-d476efa42822"

  setup do
    key = {Phoenix.Endpoint, PlatformWeb.Endpoint}
    saved = :persistent_term.get(key)
    struct_url = %URI{scheme: "https", host: @burrow, port: 443}

    :persistent_term.put(key, %{
      saved
      | struct_url: struct_url,
        url: URI.to_string(struct_url),
        host: @burrow
    })

    on_exit(fn -> :persistent_term.put(key, saved) end)
    :ok
  end

  test "the swap took: the endpoint URL is burrow" do
    assert PlatformWeb.Endpoint.url() == "https://#{@burrow}"
  end

  test "a new canvas view_url is minted on burrow" do
    assert Links.view_url(@canvas_id) == "https://#{@burrow}/canvases/#{@canvas_id}"
  end

  test "an old suite canvas link is an in-app canvas when suite is an alias, and renders path-relative" do
    href = "https://#{@suite}/canvases/#{@canvas_id}"

    assert LinkTargets.classify(href, aliases: [@suite]) == {:canvas, @canvas_id, nil}
    assert LinkTargets.in_app?(href, aliases: [@suite])
    assert LinkTargets.relative_href(href, aliases: [@suite]) == "/canvases/#{@canvas_id}"
  end

  test "without the alias the same suite link is an external link (negative control)" do
    href = "https://#{@suite}/canvases/#{@canvas_id}"

    assert {:link, nil, nil} = LinkTargets.classify(href, aliases: [])
    assert LinkTargets.relative_href(href, aliases: []) == href
  end

  test "the VAPID subject default is a mailto on the endpoint host" do
    assert Platform.Push.vapid_subject([]) == "mailto:push@#{@burrow}"

    assert Platform.Push.vapid_subject(subject: "mailto:ops@example.net") ==
             "mailto:ops@example.net"
  end
end
