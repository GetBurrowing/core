defmodule PlatformWeb.AgentPortraitTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias Platform.Agents.{Agent, Archetypes}
  alias PlatformWeb.AgentPortrait

  defp render(attrs) do
    assigns = %{attrs: attrs}

    ~H"""
    <AgentPortrait.agent_portrait {@attrs} />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp attr(html, sel, name), do: html |> LazyHTML.query(sel) |> LazyHTML.attribute(name)

  test "each of the eight portraits renders its SVG, painted through the slot" do
    for id <- Archetypes.portraits() do
      html = render(%{portrait: id, color: "indigo", size: 64})

      assert attr(html, ".ba-por", "data-portrait") == [id]
      assert attr(html, ".ba-por", "data-agent-slot") == ["indigo"]
      assert attr(html, ".ba-por", "data-portrait-mode") == ["svg"]
      assert attr(html, ".ba-por svg", "viewBox") == ["0 0 100 100"]
      assert html |> LazyHTML.query(".ba-por svg circle.bg") |> Enum.count() == 1
      assert html |> LazyHTML.query(".ba-por img") |> Enum.count() == 0
    end
  end

  test "no colour inherits the container's slot; an unknown portrait is orbit" do
    html = render(%{portrait: "dragon"})
    assert attr(html, ".ba-por", "data-agent-slot") == []
    assert attr(html, ".ba-por", "data-portrait") == ["orbit"]
  end

  test "an uploaded image wins over the generated face" do
    agent = %Agent{
      name: "Lark",
      color: "teal",
      avatar_url: "/uploads/agent-avatars/lark.png",
      metadata: %{"character" => %{"archetype" => "scout", "portrait" => "fox"}}
    }

    html = render(%{agent: agent})
    assert attr(html, ".ba-por", "data-portrait-mode") == ["image"]
    assert attr(html, ".ba-por img", "src") == ["/uploads/agent-avatars/lark.png"]
    assert html |> LazyHTML.query(".ba-por svg") |> Enum.count() == 0
  end

  test "an agent without an upload shows its character's portrait in its slot" do
    agent = %Agent{
      name: "Lark",
      color: "teal",
      metadata: %{"character" => %{"archetype" => "scout", "portrait" => "fox"}}
    }

    html = render(%{agent: agent})
    assert attr(html, ".ba-por", "data-portrait") == ["fox"]
    assert attr(html, ".ba-por", "data-agent-slot") == ["teal"]

    # A character with no portrait stored falls back to its class's.
    plain = %{agent | metadata: %{"character" => %{"archetype" => "scout"}}}

    assert render(%{agent: plain}) |> attr(".ba-por", "data-portrait") == [
             "owl"
           ]
  end
end
