defmodule Platform.Skills.ToolHandlersTest do
  use Platform.DataCase, async: true

  alias Platform.Skills
  alias Platform.Skills.ToolHandlers

  describe "skill.list" do
    test "returns summaries for every registered skill" do
      {:ok, _} = Skills.create_skill(%{name: "Alpha Playbook", content: "alpha body"})
      {:ok, _} = Skills.create_skill(%{name: "Beta Playbook", content: "beta body"})

      assert {:ok, %{count: count, skills: summaries}} = ToolHandlers.list(%{}, %{})

      assert count >= 2
      names = Enum.map(summaries, & &1.name)
      assert "Alpha Playbook" in names
      assert "Beta Playbook" in names

      first = List.first(summaries)
      assert Map.has_key?(first, :content_size)
      refute Map.has_key?(first, :content)
    end

    test "filters by query (case-insensitive substring across name/slug/description)" do
      {:ok, _} =
        Skills.create_skill(%{
          name: "Canvas Wizard",
          content: "...",
          description: "How to compose canvases"
        })

      {:ok, _} =
        Skills.create_skill(%{
          name: "Unrelated Thing",
          content: "...",
          description: "Not about canvases"
        })

      {:ok, %{count: count, skills: filtered}} = ToolHandlers.list(%{"query" => "canvas"}, %{})

      assert count >= 1
      names = Enum.map(filtered, & &1.name)
      assert "Canvas Wizard" in names
      assert "Unrelated Thing" in names
      # "Unrelated Thing" matches because its description says "canvases"
    end

    test "blank query is treated as no filter" do
      {:ok, _} = Skills.create_skill(%{name: "Blank Query Test", content: "..."})
      assert {:ok, %{skills: with_blank}} = ToolHandlers.list(%{"query" => "   "}, %{})
      assert {:ok, %{skills: without}} = ToolHandlers.list(%{}, %{})
      assert length(with_blank) == length(without)
    end
  end

  describe "skill.get" do
    test "returns full content by slug" do
      {:ok, skill} = Skills.create_skill(%{name: "Get Me", content: "the body"})

      assert {:ok, payload} = ToolHandlers.get(%{"slug" => skill.slug}, %{})
      assert payload.name == "Get Me"
      assert payload.content == "the body"
    end

    test "returns full content by id" do
      {:ok, skill} = Skills.create_skill(%{name: "Get Me Too", content: "b"})

      assert {:ok, payload} = ToolHandlers.get(%{"id" => skill.id}, %{})
      assert payload.id == skill.id
    end

    test "error when neither slug nor id provided" do
      assert {:error, payload} = ToolHandlers.get(%{}, %{})
      assert payload.recoverable == true
      assert payload.error =~ "slug"
    end

    test "error when skill not found" do
      assert {:error, payload} = ToolHandlers.get(%{"slug" => "nonexistent"}, %{})
      assert payload.recoverable == false
      assert payload.error =~ "not found"
    end
  end

  describe "skill.upsert" do
    test "creates a new skill when slug doesn't exist" do
      assert {:ok, payload} =
               ToolHandlers.upsert(
                 %{"name" => "Upsert New", "content" => "fresh body"},
                 %{}
               )

      assert payload.action == :created
      assert payload.slug == "upsert-new"
      assert payload.content == "fresh body"
    end

    test "updates an existing skill when slug exists" do
      {:ok, _} = Skills.create_skill(%{name: "Upsert Existing", content: "v1"})

      assert {:ok, payload} =
               ToolHandlers.upsert(
                 %{
                   "name" => "Upsert Existing",
                   "content" => "v2",
                   "description" => "refined"
                 },
                 %{}
               )

      assert payload.action == :updated
      assert payload.content == "v2"
      assert payload.description == "refined"
    end

    test "rejects missing required fields" do
      assert {:error, p1} = ToolHandlers.upsert(%{"name" => "No Content"}, %{})
      assert p1.error =~ "content"
      assert p1.recoverable == true

      assert {:error, p2} = ToolHandlers.upsert(%{"content" => "No Name"}, %{})
      assert p2.error =~ "name"
    end
  end
end
