defmodule Platform.Repo.Migrations.ForceUpdateIntentClassifyPromptAgentRosterDriftTest do
  @moduledoc """
  Byte-identity drift guard for the roster-aware revision of
  `meetings.intent_classify.v1` (task 01a08f9f stage 2; recovers the guard from task 01a05997 stage 3).

  The prompt body exists in TWO places and they must not diverge:

    * the `@new_content` heredoc in
      `priv/repo/migrations/20260911030000_force_update_intent_classify_prompt_agent_roster_on_unmerged.exs`,
      which is what every environment's `prompt_templates` row holds; and
    * `priv/intent_eval/prompts/agent_roster.txt`, the inline body the
      `agent_roster` eval arm scores.

  If those two differ, the eval harness reports a number for a prompt
  nothing is running — the exact unattributable run the harness exists
  to end (see the `prompt_provenance` note in
  `priv/intent_eval/configs/off_topic_default.json`).

  ## Why the comparison is row-vs-file, not source-vs-source

  Migrations under `priv/repo/migrations` are not compiled into the
  app, so `@new_content` is not readable as a module attribute from
  here. It IS readable from the row the migration wrote: migrations run
  to `:up` before ExUnit boots, so `get_template_by_slug/1` returns
  exactly the literal the migration shipped. Editing EITHER copy alone
  fails this test — the file side directly, the migration side through
  the row.

  This also makes the check strictly stronger than a source diff would
  be: it fails if the migration never reached the DB at all.

  Note that this slug has NO `do_default_templates/0` entry. The row is
  created by `20260707120000_seed_prompt_template_intent_classify.exs`
  and refreshed by force-update migrations, so a fresh environment
  arrives at the shipped body through the migration chain, not through
  `seed_defaults/0`. `default_content_for_slug/1` returns `nil` here,
  which is why this guard pins the eval prompt file rather than a
  hardcoded default.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @slug "meetings.intent_classify.v1"
  @prompt_file "priv/intent_eval/prompts/agent_roster.txt"
  @config_file "priv/intent_eval/configs/agent_roster.json"

  # Paths above are written source-relative (the same way they appear in
  # the eval config), so resolve them from the project root rather than
  # from the build's priv.
  defp source_path(relative) do
    root = Path.expand("../../../..", __DIR__)
    Path.join(root, relative)
  end

  defp read_prompt_file do
    path = source_path(@prompt_file)
    assert File.exists?(path), "eval prompt arm missing at #{path}"
    File.read!(path)
  end

  describe "shipped body drift guard" do
    test "the migrated row and the eval prompt arm are byte-identical" do
      %{content: row_content} = PromptTemplates.get_template_by_slug(@slug)
      file_content = read_prompt_file()

      assert row_content == file_content,
             """
             `meetings.intent_classify.v1` has drifted from its eval arm.

             row bytes:  #{byte_size(row_content)} sha256 #{sha(row_content)}
             file bytes: #{byte_size(file_content)} sha256 #{sha(file_content)}

             Both copies must be edited together: the @new_content heredoc in
             priv/repo/migrations/20260911030000_force_update_intent_classify_prompt_agent_roster_on_unmerged.exs
             AND #{@prompt_file}. Editing one alone means the eval harness
             scores a prompt nothing is running.
             """
    end

    test "the eval config resolves its inline_file to the arm this guard pins" do
      config = source_path(@config_file) |> File.read!() |> Jason.decode!()

      assert get_in(config, ["prompt_source", "inline_file"]) == @prompt_file,
             "agent_roster.json must score the same file the drift guard pins"

      assert File.exists?(source_path(@prompt_file))
    end
  end

  defp sha(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
