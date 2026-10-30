defmodule Platform.Repo.Migrations.AddRunIdentityToMeetingCompletionTemplatesTest do
  # Task 01a18ab4-badb-7000-a966-44ca701a276a stage 1.
  use Platform.DataCase, async: false

  @migration Path.expand(
               "../../../../priv/repo/migrations/20261030140000_add_run_identity_to_meeting_completion_templates.exs",
               __DIR__
             )
  Code.require_file(@migration)
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo.Migrations.AddRunIdentityToMeetingCompletionTemplates, as: Migration

  @tools %{
    "dispatch.scribe_completion" => "meeting_scribe_complete",
    "dispatch.triage_dispatch" => "meeting_triage_file"
  }
  @slugs Map.keys(@tools)

  # Every placeholder the block must carry, per slug (stage spec).
  @required %{
    "dispatch.scribe_completion" =>
      ~w(meeting_id run_id transcript_id snapshot_hash canvas_id source_transcript_ids accepted_action_candidates completion_transcript),
    "dispatch.triage_dispatch" =>
      ~w(meeting_id run_id transcript_id snapshot_hash canvas_id source_transcript_ids candidate_provenance_instructions accepted_action_candidates completion_transcript)
  }

  defp human_body(slug) do
    """
    HUMAN PREFIX for #{slug}: preserve this install's corrections ("Cozoa" -> "Legacy").
    {{federation_preamble}}

    HUMAN MIDDLE: an operator rewrote this section; keep every byte.
    Second {{federation_preamble}} must not get a second block.

    HUMAN SUFFIX: escalate to the on-call channel.
    """
  end

  defp placeholders(content) do
    ~r/\{\{(\w+)\}\}/ |> Regex.scan(content, capture: :all_but_first) |> List.flatten()
  end

  describe "rewrite/2" do
    test "(a) keeps a human-edited body byte-for-byte and adds run_id plus the tool name" do
      for slug <- @slugs do
        original = human_body(slug)
        updated = Migration.rewrite(slug, original)

        assert updated =~ "{{run_id}}"
        assert updated =~ "`#{@tools[slug]}`"
        assert updated =~ "run_id={{run_id}}"

        for var <- @required[slug],
            do: assert(updated =~ "{{#{var}}}", "#{slug} block lacks {{#{var}}}")

        # Removing exactly the inserted block gives the original back.
        assert String.replace(updated, "\n\n" <> Migration.block(slug), "", global: false) ==
                 original

        # Inserted after the FIRST preamble, once.
        [before_first, after_first] = String.split(updated, "{{federation_preamble}}", parts: 2)
        refute before_first =~ "{{run_id}}"
        assert String.starts_with?(after_first, "\n\n## This run — every identifier")
        assert length(String.split(updated, "## This run —")) == 2
      end
    end

    test "(b) is idempotent" do
      for slug <- @slugs do
        once = Migration.rewrite(slug, human_body(slug))
        assert Migration.rewrite(slug, once) == once
      end
    end

    test "(c) a body without a preamble still gets the block, prepended" do
      for slug <- @slugs do
        original = "No preamble here.\nHUMAN TEXT stays.\n"
        updated = Migration.rewrite(slug, original)

        assert updated == Migration.block(slug) <> "\n\n" <> original
        assert updated =~ "{{run_id}}"
        assert updated =~ "`#{@tools[slug]}`"
      end
    end

    test "retargets the 'from the signal' sentence when present, whitespace-tolerant" do
      scribe =
        "{{federation_preamble}}\n\nRead `meeting_id`, `run_id` and\n`source_transcript_ids` from the attention signal. Rest.\n"

      triage =
        "{{federation_preamble}}\n\n   `snapshot_hash` and `source_transcript_ids`  from the signal.\n"

      assert Migration.rewrite("dispatch.scribe_completion", scribe) =~
               "Read `meeting_id`, `run_id` and\n`source_transcript_ids` from the `This run` block above. Rest."

      assert Migration.rewrite("dispatch.triage_dispatch", triage) =~
               "`source_transcript_ids`  from the `This run` block above."
    end
  end

  describe "up/0" do
    test "(d) live rows carry run_id and the tool name, including after up on stale edited rows" do
      # Migrations ran before ExUnit: the rows as migrated must already carry the block.
      :ok = PromptTemplates.seed_defaults()

      for slug <- @slugs do
        live = PromptTemplates.get_template_by_slug(slug)
        assert live.content =~ "{{run_id}}", "#{slug} live row lacks {{run_id}}"
        assert live.content =~ "`#{@tools[slug]}`"
      end

      # Drive each row stale (a human-edited body without the block), then run up.
      for slug <- @slugs do
        template = PromptTemplates.get_template_by_slug(slug)

        assert {:ok, _} =
                 PromptTemplates.update_template(template, %{
                   content: human_body(slug),
                   variables: ["federation_preamble"]
                 })
      end

      assert :ok = Migration.up()

      updated =
        for slug <- @slugs, into: %{} do
          row = PromptTemplates.get_template_by_slug(slug)
          assert row.content =~ "{{run_id}}"
          assert row.content =~ "`#{@tools[slug]}`"
          assert row.content =~ "HUMAN PREFIX for #{slug}"
          assert row.content =~ "HUMAN SUFFIX: escalate to the on-call channel."
          assert hd(row.variables) == "federation_preamble"

          for var <- @required[slug], do: assert(var in row.variables)

          {slug, row.content}
        end

      assert :ok = Migration.up()

      for slug <- @slugs,
          do: assert(PromptTemplates.get_template_by_slug(slug).content == updated[slug])
    end

    test "touches no meeting_completion_runs row" do
      before = Repo.aggregate("meeting_completion_runs", :count)
      assert :ok = Migration.up()
      assert Repo.aggregate("meeting_completion_runs", :count) == before
    end
  end

  describe "descriptor parity" do
    test "(e) both descriptors carry the identical block and declare its placeholders" do
      for slug <- @slugs do
        content = PromptTemplates.default_content_for_slug(slug)
        descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

        assert content =~ "{{federation_preamble}}\n\n" <> Migration.block(slug) <> "\n\n"
        assert Migration.rewrite(slug, content) == content

        for var <- @required[slug] do
          assert content =~ "{{#{var}}}"
          assert var in descriptor.variables, "#{slug} descriptor does not declare #{var}"
        end

        for var <- placeholders(content),
            do: assert(var in descriptor.variables, "#{slug} uses undeclared {{#{var}}}")

        refute content =~ "from the attention signal."
      end
    end

    test "render_default/2 fills the identifiers from string assigns" do
      assigns = %{
        meeting_id: "m-1",
        run_id: "r-1",
        transcript_id: "t-1",
        snapshot_hash: "h-1",
        canvas_id: "c-1",
        source_transcript_ids: "t-0, t-1",
        accepted_action_candidates: "- cand-1: Draft the memo",
        candidate_provenance_instructions: "Preserve candidate ids.",
        completion_transcript: "seg-1 | 00:00:01 | Alex: hello"
      }

      for slug <- @slugs do
        assert {:ok, body} = PromptTemplates.render_default(slug, assigns)
        assert body =~ "run_id=r-1"
        assert body =~ "snapshot_hash=h-1"
        assert body =~ "`#{@tools[slug]}` with meeting_id=m-1, run_id=r-1"
        assert body =~ "seg-1 | 00:00:01 | Alex: hello"
        assert body =~ "- cand-1: Draft the memo"
      end
    end
  end
end
