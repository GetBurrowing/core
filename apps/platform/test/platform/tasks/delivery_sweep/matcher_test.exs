defmodule Platform.Tasks.DeliverySweep.MatcherTest do
  # Task 01a044b0 stage 2. DataCase only for resolve_prefix/1; nothing
  # here calls GitHub.
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeliverySweep.Matcher
  alias Platform.Tasks.Task

  @uuid "01a044b0-8ee4-769e-992d-aed7e666f32c"
  @sha "8bcdfd3015c79596d544c43bef529b6137b671ae"

  describe "id_references/1" do
    test "a full UUID in a PR title" do
      assert Matcher.id_references("Close the record (#{@uuid}) (#1140)") ==
               %{full: [@uuid], prefixes: []}
    end

    test "an uppercase full UUID is downcased" do
      assert Matcher.id_references("Fixes #{String.upcase(@uuid)}").full == [@uuid]
    end

    test "a UUID inside a URL path" do
      text = "See https://suite.example.net/tasks/#{@uuid}/plan for context"
      assert Matcher.id_references(text).full == [@uuid]
    end

    test "duplicates are removed" do
      assert Matcher.id_references("#{@uuid} and again #{@uuid}").full == [@uuid]
    end

    test "a UUID embedded in a longer hex/hyphen run is not a reference" do
      refs_after = Matcher.id_references("#{@uuid}-0123 trailing")
      refs_before = Matcher.id_references("ab-#{@uuid} leading")
      refs_hex = Matcher.id_references("f#{@uuid}")

      assert refs_after.full == []
      assert refs_before.full == []
      assert refs_hex.full == []
    end

    test "a standalone 8-hex prefix" do
      assert Matcher.id_references("task 01a044b0 stage 1: done") ==
               %{full: [], prefixes: ["01a044b0"]}
    end

    test "an uppercase 8-hex prefix is downcased" do
      assert Matcher.id_references("(01A044B0)").prefixes == ["01a044b0"]
    end

    test "the 8-hex head of a full UUID is not double-counted" do
      assert Matcher.id_references("Fixes #{@uuid}") == %{full: [@uuid], prefixes: []}

      # Also when the same 8 hex appears standalone elsewhere in the text.
      assert Matcher.id_references("01a044b0: fixes #{@uuid}") ==
               %{full: [@uuid], prefixes: []}
    end

    test "a 40-char sha yields no prefix" do
      assert Matcher.id_references("merged as #{@sha}") == %{full: [], prefixes: []}
    end

    test "a 12-hex run yields no prefix" do
      assert Matcher.id_references("tail aed7e666f32c here") == %{full: [], prefixes: []}
    end

    test "nil text yields nothing" do
      assert Matcher.id_references(nil) == %{full: [], prefixes: []}
    end
  end

  describe "resolve_prefix/1" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Delivery sweep matcher"})
      %{project: project}
    end

    defp same_prefix_ids do
      base = Ecto.UUID.generate()
      prefix = binary_part(base, 0, 8)
      other = prefix <> binary_part(Ecto.UUID.generate(), 8, 28)
      refute other == base
      {prefix, base, other}
    end

    defp insert_task!(project, id, status) do
      Repo.insert!(%Task{id: id, project_id: project.id, title: "t #{id}", status: status})
    end

    test "two tasks sharing a prefix are ambiguous", %{project: project} do
      {prefix, a, b} = same_prefix_ids()
      insert_task!(project, a, "backlog")
      insert_task!(project, b, "backlog")

      assert {:ambiguous, ids} = Matcher.resolve_prefix(prefix)
      assert Enum.sort(ids) == Enum.sort([a, b])
    end

    test "POSITIVE CONTROL: a task with a distinct prefix is unique", %{project: project} do
      {prefix, a, b} = same_prefix_ids()
      insert_task!(project, a, "backlog")
      insert_task!(project, b, "backlog")

      third = Ecto.UUID.generate()
      refute binary_part(third, 0, 8) == prefix
      insert_task!(project, third, "backlog")

      assert Matcher.resolve_prefix(binary_part(third, 0, 8)) == {:unique, third}
      assert {:ambiguous, _} = Matcher.resolve_prefix(prefix)
    end

    test "a done task sharing a prefix with an open task is still ambiguous",
         %{project: project} do
      {prefix, open_id, done_id} = same_prefix_ids()
      insert_task!(project, open_id, "in_progress")
      insert_task!(project, done_id, "done")

      assert {:ambiguous, ids} = Matcher.resolve_prefix(prefix)
      assert done_id in ids
    end

    test "a cancelled task alone is still found", %{project: project} do
      id = Ecto.UUID.generate()
      insert_task!(project, id, "cancelled")

      assert Matcher.resolve_prefix(binary_part(id, 0, 8)) == {:unique, id}
    end

    test "an unused prefix is :none" do
      assert Matcher.resolve_prefix(binary_part(Ecto.UUID.generate(), 0, 8)) == :none
    end

    test "an uppercase prefix resolves like its lowercase form", %{project: project} do
      id = Ecto.UUID.generate()
      insert_task!(project, id, "backlog")

      assert Matcher.resolve_prefix(String.upcase(binary_part(id, 0, 8))) == {:unique, id}
    end

    test "a non-hex argument (a LIKE wildcard) is refused" do
      assert_raise ArgumentError, fn -> Matcher.resolve_prefix("0000000%") end
      assert_raise ArgumentError, fn -> Matcher.resolve_prefix("01a044b") end
    end
  end

  describe "evidence_line/2" do
    test "returns the first matching line, trimmed" do
      text = "Summary\n  Fixes #{@uuid} for good  \nmore #{@uuid}"
      assert Matcher.evidence_line(text, @uuid) == "Fixes #{@uuid} for good"
    end

    test "matches case-insensitively" do
      assert Matcher.evidence_line("FIXES #{String.upcase(@uuid)}", @uuid) ==
               "FIXES #{String.upcase(@uuid)}"
    end

    test "caps the line at 300 chars" do
      line = @uuid <> String.duplicate("x", 400)
      assert String.length(Matcher.evidence_line(line, @uuid)) == 300
    end

    test "nil when absent or text is nil" do
      assert Matcher.evidence_line("nothing here", @uuid) == nil
      assert Matcher.evidence_line(nil, @uuid) == nil
    end
  end

  describe "defect_tokens/1" do
    test "strips a trailing arity and ()" do
      body = "Calls `Tasks.close_as_delivered/3` and `DeliveryReference.runner()`."

      assert Matcher.defect_tokens(body) == [
               "Tasks.close_as_delivered",
               "DeliveryReference.runner"
             ]
    end

    test "keeps snake_case, :: and CamelCase tokens" do
      body = "`task_close_as_delivered` `Foo::Bar` `closeAsDelivered`"

      assert Matcher.defect_tokens(body) == [
               "task_close_as_delivered",
               "Foo::Bar",
               "closeAsDelivered"
             ]
    end

    test "drops short tokens and prose tokens" do
      body = "`a_b` `x.y` `done` `status` `the task is closed.` `Tasks` `backlog`"
      assert Matcher.defect_tokens(body) == []
    end

    test "caps at 5 tokens" do
      body = Enum.map_join(1..8, " ", &"`token_number_#{&1}`")

      assert Matcher.defect_tokens(body) ==
               Enum.map(1..5, &"token_number_#{&1}")
    end

    test "a UUID or hex run in backticks is not a token" do
      body = "`#{@uuid}` `#{@sha}` `01a044b0` `real_token`"
      assert Matcher.defect_tokens(body) == ["real_token"]
    end

    test "nil description yields no tokens" do
      assert Matcher.defect_tokens(nil) == []
    end
  end
end
