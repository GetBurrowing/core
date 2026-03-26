defmodule Mix.Tasks.Platform.BackfillChangelogTest do
  @moduledoc "Tests for the backfill changelog mix task."
  use Platform.DataCase, async: false

  alias Platform.Changelog

  describe "backfill_changelog" do
    test "task module is defined" do
      # Verify the mix task module exists and compiles
      assert Code.ensure_loaded?(Mix.Tasks.Platform.BackfillChangelog)
    end

    test "parse_title reuse — conventional commits produce correct tags" do
      # The backfill task uses the same Changelog.parse_title as the webhook.
      # Test that the shared logic works for patterns we'd see in real PRs.
      assert {"add feature X", ["feature"]} = Changelog.parse_title("feat: add feature X")
      assert {"fix crash on nil", ["fix"]} = Changelog.parse_title("fix: fix crash on nil")
      assert {"update deps", ["chore"]} = Changelog.parse_title("chore: update deps")
      assert {"Merge branch main", []} = Changelog.parse_title("Merge branch main")
    end

    test "idempotency — inserting same PR number twice is rejected" do
      attrs = %{
        title: "Test PR",
        pr_number: 999_999,
        pr_url: "https://github.com/test/repo/pull/999999",
        commit_sha: "abc123",
        author: "backfill-test",
        tags: ["feature"],
        merged_at: DateTime.utc_now()
      }

      assert {:ok, _} = Changelog.create_entry(attrs)
      assert {:error, changeset} = Changelog.create_entry(attrs)
      assert changeset.errors[:pr_number]
    end
  end
end
