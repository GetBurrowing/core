defmodule Platform.Repo.Migrations.NeutraliseScribeCompletionExamplesTest do
  @moduledoc """
  Coverage for `20261018223000_neutralise_scribe_completion_examples`
  (task 01a14dd9-7172-7000-874c-b9ae3d4c1c83, stage 3).

  The migration rewrites lines of the `dispatch.scribe_completion` row whose
  sha256 is a key of a frozen map, and the description when its sha256 is a
  frozen digest. The old text is deliberately absent from the tree, so no
  test here can build a row that carries it. `rewrite/2` and `run/2` are
  driven instead with SYNTHETIC digests of invented placeholder lines. The
  digests the migration ships are pinned separately, as recorded constants,
  so an edit to one of them fails here too.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.NeutraliseScribeCompletionExamples

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261018223000_neutralise_scribe_completion_examples.exs"
                  ])

  @slug "dispatch.scribe_completion"

  # Recorded, not derived from the migration: the sha256 of each old line
  # (leading whitespace included, newline excluded) and of the old
  # description, measured from the descriptor at 87100c4c and from the rows
  # installs held on 2026-10-18.
  @recorded_line_digests [
    "bb575f433e237331d04917ba4112095c8a0c545a79ab6cbebf1c7a85ac387ce9",
    "c98b64449fe4420c8de677e49aa6cfda7f53fe53cfdbcc52baa8c8b3fe81bdbf",
    "5f7edf242f5159facc089574bfd6402556d082b2511681aef2808f805763dc1e",
    "facfd446445d5ac6f1b2228a9c99e8b2b2dbc4732048cf2ed0f59f2dc75349f4"
  ]
  @recorded_description_digest "6a920b44de116b82efae130ffb72a96fadcb51762db96aeca84b97e8ad6a32d9"

  # Invented stand-ins of the same shape. They are not the old lines.
  @stand_in_a ~S|  Example: `"Pat: draft the Initech launch memo by Monday"`.|
  @stand_in_b ~S|  "project_hint": "initech-atlas",|
  @stand_in_description "Sent to the scribe agent. Codifies the Initech scribe canvas."

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  defp migration(fun, args \\ []), do: apply(@migration_module, fun, args)
  defp rewrite(content, map), do: migration(:rewrite, [content, map])
  defp row, do: PromptTemplates.get_template_by_slug(@slug)

  defp descriptor do
    Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
  end

  defp write_row!(attrs) do
    {:ok, written} = PromptTemplates.update_template(row(), attrs)
    written
  end

  describe "rewrite/2 (pure)" do
    test "replaces exactly the lines whose sha256 is a key, and nothing else" do
      content = "first\n" <> @stand_in_a <> "\nmiddle\n" <> @stand_in_b <> "\nlast\n"
      map = %{sha256(@stand_in_a) => "  A", sha256(@stand_in_b) => "  B"}

      assert rewrite(content, map) == "first\n  A\nmiddle\n  B\nlast\n"
    end

    test "replaces every occurrence of a matching line" do
      content = Enum.join([@stand_in_a, "x", @stand_in_a], "\n")

      assert rewrite(content, %{sha256(@stand_in_a) => "y"}) == "y\nx\ny"
    end

    test "matches on the whole line, leading whitespace included" do
      content = String.trim_leading(@stand_in_a) <> "\n" <> @stand_in_a <> " "

      assert rewrite(content, %{sha256(@stand_in_a) => "y"}) == content
    end

    test "is the identity under an empty map or a map no line matches" do
      content = @stand_in_a <> "\n" <> @stand_in_b

      assert rewrite(content, %{}) == content
      assert rewrite(content, %{sha256("not a line here") => "y"}) == content
    end
  end

  describe "the shipped map" do
    test "is keyed by the recorded digests, and the description digest is the recorded one" do
      assert Enum.sort(Map.keys(migration(:line_map))) == Enum.sort(@recorded_line_digests)
      assert migration(:old_description_sha256) == @recorded_description_digest
    end

    test "writes neutral example lines and preserves its historical description contract" do
      lines = String.split(descriptor().content, "\n")

      for new_line <- Map.values(migration(:line_map)) do
        assert new_line in lines, "not a descriptor line: #{inspect(new_line)}"
      end

      # The callable completion boundary changed the current description later.
      # Pin this historical migration's original description independently.
      assert migration(:new_description) ==
               "Sent to the scribe agent on `meeting_scribe_completion` attention signals. Instructs the scribe to produce a 5-card meeting summary canvas (Summary / Decisions / Action items / Open questions / Provenance) in the meeting's chat space and hand structured action items off to the triage agent via `dispatch_triage_attention/2`. Codifies the Globex scribe canvas structure proven on the 2026-07-13 meeting."
    end

    test "matches nothing in the current descriptor, so a fresh database is untouched" do
      digests = descriptor().content |> String.split("\n") |> MapSet.new(&sha256/1)

      for key <- Map.keys(migration(:line_map)) do
        refute MapSet.member?(digests, key)
      end

      refute sha256(descriptor().description) == migration(:old_description_sha256)
      assert rewrite(descriptor().content, migration(:line_map)) == descriptor().content
    end
  end

  describe "run/2" do
    test "the migrated row is a no-op for the shipped map" do
      before = row()
      assert before.content == descriptor().content

      assert migration(:run, [migration(:line_map), migration(:old_description_sha256)]) ==
               :no_match

      assert row().content == before.content
      assert row().description == before.description
    end

    test "rewrites matching lines and the description, and keeps every other byte" do
      original = row()
      new_line = Map.values(migration(:line_map)) |> hd()
      [head | tail] = String.split(original.content, "\n")
      content = Enum.join([head, @stand_in_a | tail], "\n") <> "\nan operator note\n"
      write_row!(%{content: content, description: @stand_in_description})

      result =
        migration(:run, [
          %{sha256(@stand_in_a) => new_line},
          sha256(@stand_in_description)
        ])

      assert result == :rewritten
      after_ = row()

      assert after_.content ==
               Enum.join([head, new_line | tail], "\n") <> "\nan operator note\n"

      assert after_.description == migration(:new_description)
      assert after_.variables == original.variables
    end

    test "replaces the description only when its digest matches" do
      write_row!(%{description: @stand_in_description})

      assert migration(:run, [%{}, sha256("some other description")]) == :no_match
      assert row().description == @stand_in_description

      assert migration(:run, [%{}, sha256(@stand_in_description)]) == :rewritten
      assert row().description == migration(:new_description)
    end

    test "is idempotent: a second run matches nothing" do
      write_row!(%{content: @stand_in_a <> "\n" <> row().content})
      map = %{sha256(@stand_in_a) => "  replaced"}

      assert migration(:run, [map, sha256(@stand_in_description)]) == :rewritten
      once = row()

      assert migration(:run, [map, sha256(@stand_in_description)]) == :no_match
      assert row().content == once.content
    end

    test "is a no-op when the row is missing" do
      Repo.delete!(row())

      assert migration(:run, [migration(:line_map), migration(:old_description_sha256)]) ==
               :no_row

      assert Repo.get_by(PromptTemplate, slug: @slug) == nil
    end
  end

  test "down/0 is a no-op" do
    assert migration(:down) == :ok
  end
end
