defmodule Platform.Orchestration.PromptTemplatesFeedbackTest do
  @moduledoc """
  Task 01a11ec3 stage 2: task dispatch and nudge templates advertise
  `feedback_submit` exactly when the capability predicate is on, in BOTH the
  code defaults and the migrated live rows.

  The force-update guard, stated so it is checkable: a descriptor edit alone
  reaches no existing install (`seed_defaults/0` is insert-only and a served
  row wins). So the live-row half of this file first writes a PRE-MIGRATION
  row — the descriptor with the placeholder removed, i.e. what every existing
  install serves today — and proves that it does NOT advertise the tool even
  with the capability on, then runs the migration and proves that it does.
  Asserting `row == default_content_for_slug(slug)` in this database would be
  true by construction and prove nothing.

  Written before the implementation: against the unfixed base the
  placeholder assertions fail and `PromptTemplates.feedback_guidance/1`,
  `feedback_guidance_slugs/0` and the migration module do not exist.

  async: false — flips `:feedback_policy` and rewrites seeded template rows.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @placeholder "{{feedback_guidance}}"
  @heading "Reporting a defect in Suite itself"
  @migration Platform.Repo.Migrations.AddFeedbackGuidancePlaceholderToPromptTemplates
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261010140100_add_feedback_guidance_placeholder_to_prompt_templates.exs",
                    __DIR__
                  )

  # LITERAL slug list — never read back from the module under test, or a slug
  # silently dropped from `feedback_guidance_slugs/0` would also drop out of
  # the assertion.
  @slugs ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.review_e2e dispatch.deploying dispatch.fallback nudge)

  setup do
    saved = Application.fetch_env(:platform, :feedback_policy)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:platform, :feedback_policy, v)
        :error -> Application.delete_env(:platform, :feedback_policy)
      end
    end)

    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    :ok
  end

  defp set_policy(value), do: Application.put_env(:platform, :feedback_policy, value)

  defp descriptor(slug), do: Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

  defp legacy(content), do: String.replace(content, @placeholder, "")

  defp assigns(form \\ :dispatch) do
    %{
      task_id: "01a11ec3-6566-7001-8047-544e77a39d68",
      stage_id: "01a11f32-c312-7002-98f2-259a7211ab53",
      task_title: "Fixture task",
      federation_preamble: "PREAMBLE-SENTINEL",
      feedback_guidance: PromptTemplates.feedback_guidance(form)
    }
  end

  defp form(slug), do: if(slug == "nudge", do: :nudge, else: :dispatch)

  defp put_row(slug, content, variables) do
    case PromptTemplates.get_template_by_slug(slug) do
      nil ->
        {:ok, _} =
          PromptTemplates.create_template(%{
            descriptor(slug)
            | content: content,
              variables: variables
          })

      row ->
        {:ok, _} =
          PromptTemplates.update_template(row, %{content: content, variables: variables})
    end
  end

  describe "code defaults" do
    test "the module's slug list is exactly the task dispatches plus the nudge" do
      assert Enum.sort(PromptTemplates.feedback_guidance_slugs()) == Enum.sort(@slugs)
    end

    test "every descriptor carries the placeholder once and declares the variable" do
      for slug <- @slugs do
        d = descriptor(slug)
        assert d, "#{slug} descriptor missing"

        assert length(String.split(d.content, @placeholder)) == 2,
               "#{slug} must carry {{feedback_guidance}} exactly once"

        assert "feedback_guidance" in d.variables
      end
    end

    test "guidance is empty when disabled and names the tool when enabled" do
      set_policy("disabled")
      assert PromptTemplates.feedback_guidance() == ""
      assert PromptTemplates.feedback_guidance(:nudge) == ""

      for value <- ["quarantined", "trusted"] do
        set_policy(value)
        assert PromptTemplates.feedback_guidance() =~ "`feedback_submit`"
        assert PromptTemplates.feedback_guidance(:nudge) =~ "`feedback_submit`"
      end
    end

    test "render_default advertises the tool only while enabled" do
      for slug <- @slugs do
        set_policy("quarantined")
        assert {:ok, on} = PromptTemplates.render_default(slug, assigns(form(slug)))
        assert on =~ "feedback_submit", "#{slug} enabled render must advertise feedback_submit"

        set_policy("disabled")
        assert {:ok, off} = PromptTemplates.render_default(slug, assigns(form(slug)))
        refute off =~ "feedback_submit", "#{slug} disabled render must omit the tool"
        refute off =~ @heading, "#{slug} disabled render must omit all feedback guidance"
        refute off =~ @placeholder
      end
    end

    test "a disabled render is byte-identical to the placeholder-free body" do
      set_policy("disabled")

      for slug <- @slugs do
        legacy_slug = "legacy-#{slug}-#{System.unique_integer([:positive])}"

        {:ok, _} =
          PromptTemplates.create_template(%{
            slug: legacy_slug,
            name: "legacy",
            content: legacy(descriptor(slug).content),
            variables: []
          })

        {:ok, served} = PromptTemplates.render_default(slug, assigns(form(slug)))
        {:ok, legacy_render} = PromptTemplates.render_template(legacy_slug, assigns(form(slug)))
        assert served == legacy_render, "#{slug} disabled render changed"
      end
    end

    test "insert_feedback_placeholder/1 rebuilds each descriptor from its legacy body" do
      for slug <- @slugs do
        content = descriptor(slug).content
        assert PromptTemplates.insert_feedback_placeholder(legacy(content)) == content
        assert PromptTemplates.insert_feedback_placeholder(content) == content
      end
    end
  end

  describe "migrated live rows" do
    test "a pre-migration row does not advertise the tool, and the migrated row does" do
      set_policy("quarantined")

      for slug <- @slugs do
        d = descriptor(slug)
        put_row(slug, legacy(d.content), List.delete(d.variables, "feedback_guidance"))

        {:ok, before} = PromptTemplates.render_template(slug, assigns(form(slug)))

        refute before =~ "feedback_submit",
               "#{slug}: the stale row must NOT advertise the tool, or this test proves nothing"
      end

      assert :ok = apply(@migration, :up, [])

      for slug <- @slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        assert row.content == descriptor(slug).content
        assert "feedback_guidance" in row.variables

        {:ok, after_up} = PromptTemplates.render_template(slug, assigns(form(slug)))
        assert after_up =~ "feedback_submit", "#{slug}: migrated row must advertise the tool"
      end

      set_policy("disabled")

      for slug <- @slugs do
        {:ok, off} = PromptTemplates.render_template(slug, assigns(form(slug)))

        refute off =~ "feedback_submit",
               "#{slug}: disabled render of the migrated row must omit it"

        refute off =~ @heading
      end
    end

    test "an operator's edit to a live row survives the migration" do
      d = descriptor("dispatch.in_progress")
      edited = "OPERATOR-EDIT-SENTINEL\n" <> legacy(d.content)
      put_row("dispatch.in_progress", edited, d.variables -- ["feedback_guidance"])

      assert :ok = apply(@migration, :up, [])

      row = PromptTemplates.get_template_by_slug("dispatch.in_progress")
      assert row.content =~ "OPERATOR-EDIT-SENTINEL"
      assert row.content == "OPERATOR-EDIT-SENTINEL\n" <> d.content
    end

    test "the migration is idempotent and down removes only the placeholder" do
      for slug <- @slugs do
        d = descriptor(slug)
        put_row(slug, legacy(d.content), d.variables -- ["feedback_guidance"])
      end

      assert :ok = apply(@migration, :up, [])
      assert :ok = apply(@migration, :up, [])

      for slug <- @slugs do
        content = PromptTemplates.get_template_by_slug(slug).content
        assert length(String.split(content, @placeholder)) == 2, "#{slug} doubled"
      end

      assert :ok = apply(@migration, :down, [])

      for slug <- @slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        assert row.content == legacy(descriptor(slug).content)
        refute "feedback_guidance" in row.variables
      end
    end
  end
end
