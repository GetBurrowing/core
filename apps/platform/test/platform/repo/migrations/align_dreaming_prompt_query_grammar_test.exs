defmodule Platform.Repo.Migrations.AlignDreamingPromptQueryGrammarTest do
  @moduledoc """
  Coverage for `20261018000400_align_dreaming_prompt_query_grammar` (task
  01a13867 stage 4).

  The stage-1 body is rebuilt from the current descriptor by putting the old
  grammar sentence back, and its md5 is checked against the md5 the
  migration pins. That check is what proves the rebuilt body is the text the
  stage-1 migration wrote, rather than a body this test made up.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.AlignDreamingPromptQueryGrammar

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261018000400_align_dreaming_prompt_query_grammar.exs"
                  ])

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp md5(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
  defp m(fun), do: apply(@migration_module, fun, [])

  defp write_row!(slug, content) do
    template = PromptTemplates.get_template_by_slug(slug)
    {:ok, written} = PromptTemplates.update_template(template, %{content: content})
    assert written.content == content
  end

  defp row(slug), do: PromptTemplates.get_template_by_slug(slug).content

  defp stage_one(slug) do
    descriptor = PromptTemplates.default_content_for_slug(slug)
    assert length(String.split(descriptor, m(:new_span))) == 2
    String.replace(descriptor, m(:new_span), m(:old_span))
  end

  defp snapshot do
    Repo.all(
      from(t in PromptTemplate, order_by: t.slug, select: {t.slug, t.content, t.updated_at})
    )
  end

  test "the descriptor carries the new grammar sentence and not the stage-1 one" do
    for slug <- m(:slugs) do
      descriptor = PromptTemplates.default_content_for_slug(slug)
      assert descriptor =~ m(:new_span)
      refute descriptor =~ m(:old_span)
    end
  end

  test "a stage-1 row has only its grammar sentence replaced" do
    for slug <- m(:slugs) do
      stage_one = stage_one(slug)
      # The rebuilt body IS the stage-1 text: its md5 is the one pinned.
      assert md5(stage_one) == m(:stage_one_md5)
      write_row!(slug, stage_one)
    end

    others_before = Enum.reject(snapshot(), fn {slug, _, _} -> slug in m(:slugs) end)

    assert :ok = m(:up)

    for slug <- m(:slugs) do
      assert row(slug) == PromptTemplates.default_content_for_slug(slug)
    end

    assert Enum.reject(snapshot(), fn {slug, _, _} -> slug in m(:slugs) end) == others_before
  end

  test "a hand-edited row is left untouched and its content is not logged" do
    hand = stage_one("historian.dreaming") <> "\n\nHAND-EDIT-MARKER keep this line."
    write_row!("historian.dreaming", hand)

    log = capture_log(fn -> assert :ok = m(:up) end)

    assert row("historian.dreaming") == hand
    assert log =~ "skipping historian.dreaming"
    refute log =~ "HAND-EDIT-MARKER"
    refute log =~ "memory_search query"
  end

  test "rows already at the descriptor are a no-op: no template row changes" do
    for slug <- m(:slugs),
        do: assert(row(slug) == PromptTemplates.default_content_for_slug(slug))

    before = snapshot()
    log = capture_log(fn -> assert :ok = m(:up) end)
    assert snapshot() == before
    refute log =~ "skipping"
  end
end
