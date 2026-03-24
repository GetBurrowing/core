defmodule Platform.Skills.SkillSchemaTest do
  @moduledoc "Schema-level tests for Skill and SkillAttachment."
  use Platform.DataCase, async: true

  alias Platform.Skills.{Skill, SkillAttachment}

  describe "Skill.changeset/2" do
    test "valid changeset with name and content" do
      cs = Skill.changeset(%Skill{}, %{name: "Suite Coding Agent", content: "# Guide\nDo stuff."})
      assert cs.valid?
      assert get_change(cs, :slug) == "suite-coding-agent"
    end

    test "auto-generates slug from name" do
      cs = Skill.changeset(%Skill{}, %{name: "My Cool Skill!!", content: "content"})
      assert get_change(cs, :slug) == "my-cool-skill"
    end

    test "strips special characters from slug" do
      cs = Skill.changeset(%Skill{}, %{name: "Test (v2) — final", content: "c"})
      # em-dash and parens stripped, double hyphen collapsed
      slug = get_change(cs, :slug)
      assert slug =~ ~r/^test-v2/
    end

    test "requires name" do
      cs = Skill.changeset(%Skill{}, %{content: "content"})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "requires content" do
      cs = Skill.changeset(%Skill{}, %{name: "Test"})
      refute cs.valid?
      assert %{content: ["can't be blank"]} = errors_on(cs)
    end

    test "description is optional" do
      cs = Skill.changeset(%Skill{}, %{name: "Test", content: "c"})
      assert cs.valid?
    end
  end

  describe "SkillAttachment.changeset/2" do
    test "valid changeset" do
      cs =
        SkillAttachment.changeset(%SkillAttachment{}, %{
          skill_id: Ecto.UUID.generate(),
          entity_type: "project",
          entity_id: Ecto.UUID.generate()
        })

      assert cs.valid?
    end

    test "requires all fields" do
      cs = SkillAttachment.changeset(%SkillAttachment{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:skill_id]
      assert errors[:entity_type]
      assert errors[:entity_id]
    end

    test "rejects invalid entity_type" do
      cs =
        SkillAttachment.changeset(%SkillAttachment{}, %{
          skill_id: Ecto.UUID.generate(),
          entity_type: "invalid",
          entity_id: Ecto.UUID.generate()
        })

      refute cs.valid?
      assert errors_on(cs)[:entity_type]
    end

    test "accepts all valid entity types" do
      for type <- ~w(project epic task) do
        cs =
          SkillAttachment.changeset(%SkillAttachment{}, %{
            skill_id: Ecto.UUID.generate(),
            entity_type: type,
            entity_id: Ecto.UUID.generate()
          })

        assert cs.valid?, "expected #{type} to be valid"
      end
    end
  end

  # ── Helper ───────────────────────────────────────────────────────────────

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
