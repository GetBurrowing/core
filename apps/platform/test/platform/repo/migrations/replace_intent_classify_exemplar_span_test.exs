defmodule Platform.Repo.Migrations.ReplaceIntentClassifyExemplarSpanTest do
  @moduledoc """
  Coverage for `20261018072000_replace_intent_classify_exemplar_span`
  (task 01a14dce-d2d8-7000-becf-79544fe7cf98, stage 1).

  The migration swaps ONE line of `meetings.intent_classify.v1`, found by its
  sha256. The real old line is deliberately absent from the tree, so no test
  here can build a row that carries it. Each `run/1` case instead writes a
  row of its own around an invented stand-in line, hands `run/1` that line's
  digest, and asserts the delta. The digest the migration actually ships is
  pinned separately, against the value measured from the row the migration
  chain wrote (`priv/imp_pilot/open_question/prompt_a.txt:30` before this
  task), so an edit to `@old_line_sha256` fails here too.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.ReplaceIntentClassifyExemplarSpan

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261018072000_replace_intent_classify_exemplar_span.exs"
                  ])

  @slug "meetings.intent_classify.v1"

  # Measured, not derived from the migration: sha256 of the old exemplar line
  # (leading whitespace included, newline excluded) as the migrated row held it.
  @recorded_old_line_sha256 "532cd085a06254f993d53c2cfb8562a798cda2fbbd5af9d7531d1d3462df0c22"

  # An invented stand-in for the old line, same shape. It is not the real one.
  @stand_in ~S|  - "Okay, I'll go and find Pat for this."                            -> `action_items`, `target_role: null` (a concrete commitment; the owner is a person)|

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp new_line, do: apply(@migration_module, :new_line, [])
  defp run(pin), do: apply(@migration_module, :run, [pin])

  defp write_row!(content) do
    template = PromptTemplates.get_template_by_slug(@slug)
    refute is_nil(template), "#{@slug} must be migrated before this test can rewrite it"
    {:ok, written} = PromptTemplates.update_template(template, %{content: content})
    assert written.content == content
    written
  end

  defp row, do: PromptTemplates.get_template_by_slug(@slug)

  # A row shaped like the shipped one: the migrated body with its neutral
  # exemplar put back to the stand-in, so the stand-in is the only line that
  # matches the stand-in's digest.
  defp untouched_content do
    content = row().content

    assert [_, _] = String.split(content, new_line()),
           "the migrated row must carry the new line once"

    String.replace(content, new_line(), @stand_in)
  end

  defp changed_lines(before, after_) do
    a = String.split(before, "\n")
    b = String.split(after_, "\n")
    assert length(a) == length(b)
    for {x, y} <- Enum.zip(a, b), x != y, do: {x, y}
  end

  test "the shipped pin is the measured digest of the old line" do
    assert apply(@migration_module, :old_line_sha256, []) == @recorded_old_line_sha256
    refute sha256(new_line()) == @recorded_old_line_sha256
  end

  test "the migrated row carries the new line once and no line at the old digest" do
    lines = String.split(row().content, "\n")
    assert Enum.count(lines, &(&1 == new_line())) == 1
    refute Enum.any?(lines, &(sha256(&1) == @recorded_old_line_sha256))
  end

  test "an untouched row gets exactly one changed line, the exemplar" do
    content = untouched_content()
    before = write_row!(content)

    assert run(sha256(@stand_in)) == :swapped

    after_ = row()
    assert changed_lines(content, after_.content) == [{@stand_in, new_line()}]

    assert byte_size(after_.content) - byte_size(content) ==
             byte_size(new_line()) - byte_size(@stand_in)

    assert after_.variables == before.variables
  end

  test "a row with an extra line appended at the end keeps it byte-for-byte" do
    extra = "\n  - an operator note appended by hand\n"
    content = untouched_content() <> extra
    write_row!(content)

    assert run(sha256(@stand_in)) == :swapped

    after_ = row().content
    assert String.ends_with?(after_, extra)
    assert changed_lines(content, after_) == [{@stand_in, new_line()}]
  end

  test "a row whose exemplar line was hand-edited is left unchanged" do
    edited = String.replace(@stand_in, "for this", "for this one")
    content = String.replace(untouched_content(), @stand_in, edited)
    write_row!(content)

    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :info], fn ->
        assert run(sha256(@stand_in)) == :no_match
      end)

    assert row().content == content
    assert log =~ @slug
    assert log =~ sha256(content)
    refute log =~ "for this one"
  end

  test "a second run is a no-op" do
    write_row!(untouched_content())
    assert run(sha256(@stand_in)) == :swapped
    once = row()

    assert run(sha256(@stand_in)) == :no_match

    twice = row()
    assert twice.content == once.content
    assert twice.updated_at == once.updated_at
  end

  test "two matching lines are ambiguous: skipped with a warning, row unchanged" do
    content = untouched_content() <> "\n" <> @stand_in
    write_row!(content)

    log =
      capture_log(fn ->
        assert run(sha256(@stand_in)) == :ambiguous
      end)

    assert row().content == content
    assert log =~ "2 lines"
    assert log =~ sha256(content)
    refute log =~ "find Pat"
  end

  test "no row: skipped" do
    PromptTemplates.delete_template(row())
    assert run(sha256(@stand_in)) == :no_row
  end
end
