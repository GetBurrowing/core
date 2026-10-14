defmodule Platform.Chat.Canvas.Kinds.EmbedRenderIdentityTest do
  @moduledoc """
  Byte-identity guard for the `scripts` false/absent branch of the `embed`
  kind (task 01a1316b-677a stage 1).

  The fixtures under `test/support/fixtures/canvas/embed_render_*.html` were
  captured with `rendered_to_string/1` from the module as it was BEFORE this
  task touched it (identical to origin/main ea0137bee, `git diff ea0137bee
  32f23bcf4 -- .../kinds/embed.ex` is empty), on the moon rig. Adding
  `scripts: true` must not move one byte of the markup every existing embed
  renders.

  The guard was shown to fire before its silence was trusted: with one extra
  attribute (`data-x="1"`) added to the srcdoc branch's wrapper, all four
  tests below failed (moon, 2026-10-13, 22/26 in that run).
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Chat.Canvas.Kinds.Embed

  @fixtures Path.expand("../../../../support/fixtures/canvas", __DIR__)

  @srcdoc_only %{
    "id" => "embed-a",
    "type" => "embed",
    "props" => %{
      "srcdoc" =>
        "<!doctype html><html><body><h1 style=\"color:#123\">Static &amp; \"quoted\"</h1></body></html>"
    }
  }

  @sized %{
    "id" => "embed-b",
    "type" => "embed",
    "props" => %{
      "srcdoc" =>
        "<!doctype html><html><head><title>B</title></head><body><p>mockup</p></body></html>",
      "height" => 640,
      "width" => 1280,
      "min_scale" => 0.5
    }
  }

  defp render_node(node) do
    assigns = %{node: node}

    ~H"""
    <Embed.render node={@node} />
    """
    |> rendered_to_string()
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp with_scripts_false(node), do: put_in(node, ["props", "scripts"], false)

  test "srcdoc only: main's markup, byte for byte" do
    assert render_node(@srcdoc_only) == fixture("embed_render_srcdoc_only.html")
  end

  test "srcdoc + height, width and min_scale: main's markup, byte for byte" do
    assert render_node(@sized) == fixture("embed_render_sized.html")
  end

  test "an explicit scripts: false renders exactly what an absent one does" do
    assert render_node(with_scripts_false(@srcdoc_only)) ==
             fixture("embed_render_srcdoc_only.html")

    assert render_node(with_scripts_false(@sized)) == fixture("embed_render_sized.html")
  end

  test "a prototype_ref on a plain embed changes nothing either" do
    ref = %{"prototype_id" => Ecto.UUID.generate(), "version" => 1, "sha256" => "x"}

    assert render_node(put_in(@srcdoc_only, ["props", "prototype_ref"], ref)) ==
             fixture("embed_render_srcdoc_only.html")
  end
end
