defmodule Platform.Chat.Canvas.ToolsTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas.Tools
  alias Platform.Chat.Canvas.Kinds

  describe "definitions/0" do
    test "returns the three canvas tools" do
      defs = Tools.definitions()
      names = Enum.map(defs, & &1["name"])

      assert "canvas_create" in names
      assert "canvas_patch" in names
      assert "canvas_describe" in names
    end

    test "canvas_create requires space_id and document" do
      defn = Enum.find(Tools.definitions(), &(&1["name"] == "canvas_create"))
      required = defn["parameters"]["required"]

      assert "space_id" in required
      assert "document" in required
    end

    test "canvas_patch requires canvas_id, base_revision, and operations" do
      defn = Enum.find(Tools.definitions(), &(&1["name"] == "canvas_patch"))
      required = defn["parameters"]["required"]

      assert "canvas_id" in required
      assert "base_revision" in required
      assert "operations" in required
    end
  end

  # Task 019e2c4b stage 5, acceptance criterion 4. The value of the sentence is
  # that it is ACCURATE, so these assertions pin the two claims an agent would
  # act on: which grants open a link, and that no token mechanism exists to
  # widen one.
  describe "sharing_boundary/0" do
    test "names every grant path the code actually enforces" do
      boundary = Tools.sharing_boundary()

      assert boundary =~ "participant of its space"
      assert boundary =~ "AGENT assigned to a LIVE task the canvas is attached to"
      assert boundary =~ "member of the org that owns such a task"
      assert boundary =~ "when the canvas lives in a NON-ARCHIVED channel"
    end

    # `:task_agent` (task 019fb01b stage 2) is keyed on a different column from
    # the three human grants — `phase_assignees` rather than
    # `org_memberships.user_id` — so it needs its own clause. Without it the
    # sentence reads as "no agent gets in from outside its own spaces", which
    # is now false and would have an agent conclude a working link is broken.
    test "names the agent task path separately from the human org paths" do
      boundary = Tools.sharing_boundary()

      assert boundary =~ "AGENT"
      refute boundary =~ "phase_assignees"
    end

    # Both qualifiers are enforced, not hedging: `:task_reader` drops
    # soft-deleted tasks and `:org_reader` runs through `space_accessible?/1`,
    # which excludes archived spaces. An archived channel is still
    # `kind == "channel"`, so dropping the word would promise org members a
    # canvas they get 403 on.
    test "qualifies the two grants that a bare noun would overstate" do
      boundary = Tools.sharing_boundary()

      assert boundary =~ "LIVE task"
      assert boundary =~ "NON-ARCHIVED channel"
    end

    # An external user can hold `:member` and still be halted before mount by
    # `ExternalUserScope`, so the grant list alone would overpromise.
    test "does not promise the page to external users, who never reach it" do
      assert Tools.sharing_boundary() =~ "External users never reach the page"
    end

    test "states that no share-token mechanism exists rather than pointing at one" do
      boundary = Tools.sharing_boundary()

      assert boundary =~ "canonical Suite links, never share tokens"
      assert boundary =~ "No share-token mechanism exists"
    end

    test "tells the agent how to make an execution-space canvas readable" do
      boundary = Tools.sharing_boundary()

      assert boundary =~ "execution space"
      assert boundary =~ "task_attach_canvas"
    end

    test "every canvas tool that hands out a URL carries it verbatim" do
      boundary = Tools.sharing_boundary()
      defs = Tools.definitions()

      for name <- ["canvas_create", "canvas_describe", "canvas_versions"] do
        defn = Enum.find(defs, &(&1["name"] == name))
        assert defn, "#{name} missing from definitions/0"

        assert defn["description"] =~ boundary,
               "#{name} description does not carry the sharing boundary"
      end
    end

    test "canvas_create and canvas_describe advertise the view_url they return" do
      defs = Tools.definitions()

      for name <- ["canvas_create", "canvas_describe"] do
        defn = Enum.find(defs, &(&1["name"] == name))
        assert defn["description"] =~ "view_url"
      end
    end
  end

  describe "document_schema/0" do
    test "is a JSON-schema object with version, revision, root" do
      schema = Tools.document_schema()

      assert schema["type"] == "object"
      assert "version" in schema["required"]
      assert "revision" in schema["required"]
      assert "root" in schema["required"]
    end

    test "version is constrained to 1" do
      schema = Tools.document_schema()
      assert schema["properties"]["version"]["const"] == 1
    end
  end

  describe "node_schema/0" do
    test "is a discriminated union with one entry per registered kind" do
      schema = Tools.node_schema()
      one_of = schema["oneOf"]

      assert is_list(one_of)
      assert length(one_of) == length(Kinds.all())

      kind_consts =
        Enum.map(one_of, fn s -> s["properties"]["type"]["const"] end)
        |> Enum.sort()

      assert kind_consts == Enum.sort(Kinds.names())
    end

    test "kinds whose children == :none do not declare a children property" do
      schema = Tools.node_schema()
      text_entry = Enum.find(schema["oneOf"], &(&1["properties"]["type"]["const"] == "text"))
      refute Map.has_key?(text_entry["properties"], "children")
    end

    test "kinds with child rules declare children array" do
      schema = Tools.node_schema()
      stack_entry = Enum.find(schema["oneOf"], &(&1["properties"]["type"]["const"] == "stack"))
      assert stack_entry["properties"]["children"]["type"] == "array"
    end
  end
end
