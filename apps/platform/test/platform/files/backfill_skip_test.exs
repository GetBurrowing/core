defmodule Platform.Files.BackfillSkipTest do
  @moduledoc """
  Stage 6 of task `019ebd47` is a deliberate no-op. This test pins that
  intent so a future hand doesn't quietly turn the tombstone migration
  into a live backfill without the corresponding plan review.

  See `Platform.Repo.Migrations.SkipBackfillChatAttachmentsToFiles` for
  the design rationale (chat_attachments and platform_files stay
  distinct; promotion is a user-driven future surface).
  """
  use Platform.DataCase, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260619050000_skip_backfill_chat_attachments_to_files.exs",
                    __DIR__
                  )

  describe "stage 6 deliberate no-op tombstone" do
    test "migration file exists at the expected path" do
      assert File.exists?(@migration_path),
             "Stage 6 tombstone migration missing at #{@migration_path}"
    end

    test "migration source declares a no-op change/0 that returns :ok" do
      source = File.read!(@migration_path)

      assert source =~
               "defmodule Platform.Repo.Migrations.SkipBackfillChatAttachmentsToFiles do",
             "Tombstone module renamed; update this test alongside the migration."

      assert source =~ ~r/def change do\s+:ok\s+end/,
             """
             Stage 6 migration is no longer a no-op. If you're adding a real
             backfill of chat_attachments → platform_files, route it through
             a new plan stage with explicit review — Rowan rejected the v3
             auto-backfill on 2026-06-19 because project_id derivation is
             unsound for org-level chat spaces.
             """
    end

    test "loading the migration defines a change/0 that returns :ok and writes no platform_files rows" do
      # The migration file is not in the application load path, so we
      # eval it once and then exercise its change/0 to prove the
      # behaviour matches the source assertion above.
      Code.eval_file(@migration_path)

      pre = Repo.aggregate(Platform.Files.File, :count)
      assert :ok = Platform.Repo.Migrations.SkipBackfillChatAttachmentsToFiles.change()
      post = Repo.aggregate(Platform.Files.File, :count)
      assert pre == post
    end
  end
end
