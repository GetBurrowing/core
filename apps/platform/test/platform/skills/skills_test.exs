defmodule Platform.SkillsTest do
  @moduledoc "Integration tests for the Platform.Skills context module."
  use Platform.DataCase, async: true

  alias Platform.Skills
  alias Platform.Skills.Skill
  alias Platform.Tasks

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_skill!(attrs \\ %{}) do
    defaults = %{
      name: "test-skill-#{System.unique_integer([:positive])}",
      content: "# Guide\nContent"
    }

    {:ok, skill} = Skills.create_skill(Map.merge(defaults, attrs))
    skill
  end

  defp create_project!(name \\ "Test Project") do
    {:ok, project} =
      Tasks.create_project(%{name: name <> " #{System.unique_integer([:positive])}"})

    project
  end

  defp create_hierarchy! do
    project = create_project!("Hierarchy")
    {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Test Epic"})

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, epic_id: epic.id, title: "Test Task"})

    {project, epic, task}
  end

  # ── CRUD ─────────────────────────────────────────────────────────────────

  describe "CRUD" do
    test "create_skill/1 inserts a skill with auto-generated slug" do
      {:ok, skill} = Skills.create_skill(%{name: "Suite Coding Agent", content: "# Content"})
      assert skill.name == "Suite Coding Agent"
      assert skill.slug == "suite-coding-agent"
      assert skill.content == "# Content"
    end

    test "create_skill/1 with description" do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "With Desc",
          content: "body",
          description: "A short summary"
        })

      assert skill.description == "A short summary"
    end

    test "create_skill/1 rejects duplicate name" do
      {:ok, _} = Skills.create_skill(%{name: "Unique Skill", content: "c"})
      {:error, changeset} = Skills.create_skill(%{name: "Unique Skill", content: "c2"})
      assert %{name: _} = errors_on(changeset)
    end

    test "update_skill/2 updates fields and regenerates slug on name change" do
      skill = create_skill!(%{name: "Original Name", content: "old"})
      {:ok, updated} = Skills.update_skill(skill, %{name: "New Name", content: "new"})
      assert updated.name == "New Name"
      assert updated.slug == "new-name"
      assert updated.content == "new"
    end

    test "delete_skill/1 removes the skill" do
      skill = create_skill!()
      {:ok, _} = Skills.delete_skill(skill)
      assert Skills.get_skill(skill.id) == nil
    end

    test "list_skills/0 returns skills ordered by name" do
      s2 = create_skill!(%{name: "Zulu Skill", content: "c"})
      s1 = create_skill!(%{name: "Alpha Skill", content: "c"})
      skills = Skills.list_skills()
      names = Enum.map(skills, & &1.name)
      assert Enum.find_index(names, &(&1 == s1.name)) < Enum.find_index(names, &(&1 == s2.name))
    end

    test "get_skill/1 and get_skill_by_slug/1" do
      skill = create_skill!(%{name: "Findable", content: "c"})
      assert Skills.get_skill(skill.id).id == skill.id
      assert Skills.get_skill_by_slug("findable").id == skill.id
    end
  end

  # ── Attachments ──────────────────────────────────────────────────────────

  describe "attach/detach" do
    test "attach_skill/3 creates an attachment" do
      skill = create_skill!()
      project = create_project!()
      {:ok, attachment} = Skills.attach_skill(skill.id, "project", project.id)
      assert attachment.skill_id == skill.id
      assert attachment.entity_type == "project"
      assert attachment.entity_id == project.id
    end

    test "attach_skill/3 rejects duplicate attachment" do
      skill = create_skill!()
      project = create_project!()
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)
      {:error, changeset} = Skills.attach_skill(skill.id, "project", project.id)
      assert %{skill_id: ["skill already attached to this entity"]} = errors_on(changeset)
    end

    test "detach_skill/3 removes an attachment" do
      skill = create_skill!()
      project = create_project!()
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)
      assert :ok = Skills.detach_skill(skill.id, "project", project.id)
      assert Skills.skills_for_entity("project", project.id) == []
    end

    test "detach_skill/3 returns error when not found" do
      assert {:error, :not_found} =
               Skills.detach_skill(Ecto.UUID.generate(), "project", Ecto.UUID.generate())
    end
  end

  # ── skills_for_entity ───────────────────────────────────────────────────

  describe "skills_for_entity/2" do
    test "returns skills attached to the entity" do
      skill1 = create_skill!(%{name: "Alpha", content: "c"})
      skill2 = create_skill!(%{name: "Beta", content: "c"})
      project = create_project!()

      {:ok, _} = Skills.attach_skill(skill1.id, "project", project.id)
      {:ok, _} = Skills.attach_skill(skill2.id, "project", project.id)

      skills = Skills.skills_for_entity("project", project.id)
      ids = Enum.map(skills, & &1.id)
      assert skill1.id in ids
      assert skill2.id in ids
    end

    test "returns empty list when no attachments" do
      assert Skills.skills_for_entity("project", Ecto.UUID.generate()) == []
    end
  end

  # ── resolve_skills ──────────────────────────────────────────────────────

  describe "resolve_skills/1" do
    test "returns empty list for non-existent task" do
      assert Skills.resolve_skills(Ecto.UUID.generate()) == []
    end

    test "returns task-level skills" do
      {_project, _epic, task} = create_hierarchy!()
      skill = create_skill!(%{name: "Task Skill", content: "c"})
      {:ok, _} = Skills.attach_skill(skill.id, "task", task.id)

      resolved = Skills.resolve_skills(task.id)
      assert [{%Skill{}, "task"}] = resolved
      assert elem(hd(resolved), 0).id == skill.id
    end

    test "returns project-level skills inherited by task" do
      {project, _epic, task} = create_hierarchy!()
      skill = create_skill!(%{name: "Project Skill", content: "c"})
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)

      resolved = Skills.resolve_skills(task.id)
      assert [{%Skill{}, "project"}] = resolved
      assert elem(hd(resolved), 0).id == skill.id
    end

    test "returns epic-level skills inherited by task" do
      {_project, epic, task} = create_hierarchy!()
      skill = create_skill!(%{name: "Epic Skill", content: "c"})
      {:ok, _} = Skills.attach_skill(skill.id, "epic", epic.id)

      resolved = Skills.resolve_skills(task.id)
      assert [{%Skill{}, "epic"}] = resolved
    end

    test "deduplicates: same skill at project + task returns once (task wins)" do
      {project, _epic, task} = create_hierarchy!()
      skill = create_skill!(%{name: "Shared Skill", content: "c"})
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)
      {:ok, _} = Skills.attach_skill(skill.id, "task", task.id)

      resolved = Skills.resolve_skills(task.id)
      assert length(resolved) == 1
      assert [{_, "task"}] = resolved
    end

    test "deduplicates: same skill at project + epic returns once (epic wins)" do
      {project, epic, task} = create_hierarchy!()
      skill = create_skill!(%{name: "Shared Skill", content: "c"})
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)
      {:ok, _} = Skills.attach_skill(skill.id, "epic", epic.id)

      resolved = Skills.resolve_skills(task.id)
      assert length(resolved) == 1
      assert [{_, "epic"}] = resolved
    end

    test "multi-level: different skills at each level all included" do
      {project, epic, task} = create_hierarchy!()
      s1 = create_skill!(%{name: "Proj Skill", content: "c"})
      s2 = create_skill!(%{name: "Epic Skill", content: "c"})
      s3 = create_skill!(%{name: "Task Skill", content: "c"})
      {:ok, _} = Skills.attach_skill(s1.id, "project", project.id)
      {:ok, _} = Skills.attach_skill(s2.id, "epic", epic.id)
      {:ok, _} = Skills.attach_skill(s3.id, "task", task.id)

      resolved = Skills.resolve_skills(task.id)
      assert length(resolved) == 3

      sources = Enum.map(resolved, fn {_skill, source} -> source end) |> Enum.sort()
      assert sources == ["epic", "project", "task"]
    end

    test "task without epic still resolves project skills" do
      project = create_project!()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No Epic"})
      skill = create_skill!(%{name: "Project Only", content: "c"})
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)

      resolved = Skills.resolve_skills(task.id)
      assert [{_, "project"}] = resolved
    end
  end

  # ── entities_for_skill ──────────────────────────────────────────────────

  describe "entities_for_skill/1" do
    test "returns grouped entity names" do
      {project, epic, task} = create_hierarchy!()
      skill = create_skill!()
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)
      {:ok, _} = Skills.attach_skill(skill.id, "epic", epic.id)
      {:ok, _} = Skills.attach_skill(skill.id, "task", task.id)

      grouped = Skills.entities_for_skill(skill.id)
      assert length(grouped["project"]) == 1
      assert length(grouped["epic"]) == 1
      assert length(grouped["task"]) == 1
    end

    test "returns empty lists when no attachments" do
      skill = create_skill!()
      grouped = Skills.entities_for_skill(skill.id)
      assert grouped == %{"project" => [], "epic" => [], "task" => []}
    end
  end

  # ── Cascade delete ──────────────────────────────────────────────────────

  describe "cascade" do
    test "deleting a skill cascades to attachments" do
      skill = create_skill!()
      project = create_project!()
      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)
      {:ok, _} = Skills.delete_skill(skill)
      assert Skills.skills_for_entity("project", project.id) == []
    end
  end

  describe "seed_defaults/0" do
    # Task 019f5e2b (meeting-to-tasks pipeline stack member M4) Stage 3
    # introduces the `Platform.Skills.seed_defaults/0` context helper —
    # mirrors `PromptTemplates.seed_defaults/0` at
    # `apps/platform/lib/platform/orchestration/prompt_templates.ex`
    # lines 100–113. Stage 4 owns these assertions; Stage 3 shipped the
    # code + the meeting-triage-officer descriptor.
    #
    # Note: the seeding migration
    # (`20260717000200_seed_meeting_triage_officer_skill.exs`) already
    # runs against the sandbox during test-DB setup, so the skill row
    # is present before these tests begin. The `seed_defaults/0`
    # invocations below therefore exercise the "already-present
    # slug → :skip" branch, which is exactly the branch the
    # idempotency contract cares about.

    test "seeds the meeting-triage-officer skill" do
      :ok = Skills.seed_defaults()

      skill = Skills.get_skill_by_slug("meeting-triage-officer")

      assert skill,
             "seed_defaults/0 must insert the meeting-triage-officer skill (or leave it in place)"

      assert skill.name == "Meeting Triage Officer",
             "seeded name must match the descriptor"
    end

    test "seeded content covers the parse/matching/priority/dedup contract" do
      :ok = Skills.seed_defaults()

      skill = Skills.get_skill_by_slug("meeting-triage-officer")
      assert skill, "meeting-triage-officer must be seeded before this assertion"

      # Locked against the plan's declared surface — every one of these
      # tokens is load-bearing for the runtime's convention layer. A
      # future edit that drops one silently loses that convention.
      for token <- [
            "jaro_distance",
            "principal_search",
            "project_hint",
            "meeting_triage_file",
            "snapshot_hash",
            "item_id",
            "source_segment_ids",
            "dedup and caps",
            "checklist_item",
            "high|medium|low"
          ] do
        assert skill.content =~ token,
               "meeting-triage-officer content must reference #{token}"
      end
    end

    test "double-call is a no-op (idempotency)" do
      # First call — the row may already exist from the migration, or
      # from the first test in this describe. Either way, capture the
      # baseline count.
      :ok = Skills.seed_defaults()
      baseline = length(Skills.list_skills())

      # Second call — must NOT insert a duplicate row and must NOT
      # raise a changeset error. This is exactly the idempotency the
      # docstring promises.
      :ok = Skills.seed_defaults()

      assert length(Skills.list_skills()) == baseline,
             "seed_defaults/0 must be idempotent — a second call must not add rows"

      # Sanity: the seed target is still present after two calls.
      assert Skills.get_skill_by_slug("meeting-triage-officer"),
             "meeting-triage-officer must still be present after a second seed_defaults/0 call"
    end
  end

  # ── Helper ──────────────────────────────────────────────────────────────

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  # The 16-character case is the load-bearing one: `Ecto.UUID.cast/1` accepts
  # any 16-byte binary, so a test built from "higgins" alone is green against
  # the bug these guards fix.
  describe "UUID boundary: get_skill/1" do
    test "returns nil for a slug — which is DESIGNED traffic, not a malformed id" do
      # skill_get accepts a slug OR an id and tool_handlers.ex routes any
      # non-empty binary through both branches, so nil here is what sends a
      # slug to `get_skill_by_slug/1` instead of raising inside Repo.
      skill = create_skill!(%{name: "Boundary Playbook"})

      assert Skills.get_skill(skill.slug) == nil
      assert Skills.get_skill("higginshigginsxx") == nil
      assert %Skill{id: id} = Skills.get_skill(skill.id)
      assert id == skill.id
    end

    test "resolve_skills/1 returns [] for a malformed task id" do
      assert Skills.resolve_skills("higginshigginsxx") == []
      assert Skills.resolve_skills("higgins") == []
    end
  end

  test "persisted officer skill forwards every priority and note fallback" do
    Skills.seed_defaults()
    content = Skills.get_skill_by_slug("meeting-triage-officer").content
    for value <- ["low", "medium", "high", "critical"], do: assert(content =~ "`#{value}` → `#{value}`")
    assert content =~ "Copy the parsed note priority into `priority`"
    assert content =~ "note priorities default to `medium`"
    assert content =~ "invalid explicit API priority is refused"
    assert content =~ "server owns the single batch junk control"
  end

end
