defmodule Platform.Chat.Canvas.Kinds.PrototypeTest do
  @moduledoc """
  The `prototype` canvas kind's registration and props (task 01a1316b-4e46
  stage 2). Rendering is a LiveComponent that reads the database, so it is
  covered by `PlatformWeb.Components.Canvases.PrototypeFrameTest`.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.Kinds.Embed
  alias Platform.Chat.Canvas.Kinds.Prototype

  @id "01a1316b-4e46-7001-b60d-4c499dd4672e"

  describe "registry" do
    test "prototype is a registered kind and list_kinds describes it" do
      assert "prototype" in Kinds.names()
      assert Kinds.get("prototype") == Prototype

      summary = Enum.find(Kinds.summaries(), &(&1.kind == "prototype"))
      assert summary.description =~ "sandbox"
      assert summary.description =~ "prototype_id"
      assert summary.accepts_children == "none"
      assert summary.props["prototype_id"] =~ "required"
      assert summary.props["version"] =~ "integer"
    end

    test "it opts out of click-to-open, because the bar and frame take clicks" do
      assert Prototype.inline_opens_canvas?() == false
    end
  end

  describe "validate_props/1" do
    test "accepts a bare prototype_id (embed's defaults apply)" do
      assert Prototype.validate_props(%{"prototype_id" => @id}) == :ok
    end

    test "accepts embed's default and boundary sizes, a version and a min_scale" do
      assert Prototype.validate_props(%{
               "prototype_id" => @id,
               "version" => 3,
               "height" => 100,
               "width" => 2400,
               "min_scale" => 0.5
             }) == :ok

      assert Prototype.validate_props(%{
               "prototype_id" => @id,
               "height" => 2000,
               "width" => 320
             }) == :ok
    end

    test "refuses a missing or non-UUID prototype_id" do
      assert {:error, msg} = Prototype.validate_props(%{})
      assert msg =~ "prototype_id"
      assert {:error, _} = Prototype.validate_props(%{"prototype_id" => "not-a-uuid"})
      assert {:error, _} = Prototype.validate_props(%{"prototype_id" => 42})
    end

    test "refuses out-of-range height and width, exactly where embed does" do
      for {key, bad} <- [{"height", 99}, {"height", 2001}, {"width", 319}, {"width", 2401}] do
        props = %{"srcdoc" => "<p>x</p>", key => bad}

        assert {:error, _} = Prototype.validate_props(Map.put(props, "prototype_id", @id)),
               "prototype accepted #{key}=#{bad}"

        assert {:error, _} = Embed.validate_props(props),
               "embed accepted #{key}=#{bad}, so the ranges no longer match"
      end
    end

    test "refuses a version below 1 or not an integer, and a bad min_scale" do
      assert {:error, _} = Prototype.validate_props(%{"prototype_id" => @id, "version" => 0})
      assert {:error, _} = Prototype.validate_props(%{"prototype_id" => @id, "version" => "2"})
      assert {:error, _} = Prototype.validate_props(%{"prototype_id" => @id, "min_scale" => 1.5})
    end

    test "the size clamps fall back to embed's defaults" do
      assert Prototype.height(%{}) == 400
      assert Prototype.width(%{}) == 1080
      assert Prototype.height(%{"height" => 5000}) == 400
      assert Prototype.width(%{"width" => 800}) == 800
    end

    test "refuses any preview key: only the history projection sets it (task 01a18834 stage 2)" do
      for value <- [true, false, nil, "true"] do
        assert Prototype.validate_props(%{"prototype_id" => @id, "preview" => value}) ==
                 {:error, "preview is set by the server"}
      end

      node = %{
        "id" => "p",
        "type" => "prototype",
        "props" => %{"prototype_id" => @id, "version" => 2, "preview" => true}
      }

      assert {:error, [reason]} = Kinds.validate_node(node)
      assert reason =~ "preview is set by the server"
    end

    test "a node with a bad prototype_id fails whole-node validation" do
      node = %{"id" => "p", "type" => "prototype", "props" => %{"prototype_id" => "x"}}
      assert {:error, [reason]} = Kinds.validate_node(node)
      assert reason =~ "prototype_id"
    end
  end
end
