defmodule Platform.Social.Analytics.PersistenceTest do
  use Platform.DataCase, async: true
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social.Analytics.SyncState
  alias Platform.Social.Post

  test "post metrics and vendor sync timestamp round-trip without becoming editable" do
    {_, account} = social_account!(org_id!(), "instagram")
    post = Repo.insert!(%Post{account_id: account.id, body: "fixture"})
    assert post.metrics == %{}
    assert post.metrics_synced_at == nil

    metrics = %{
      "views" => 0,
      "likes" => 3,
      "comments" => 2,
      "shares" => 1,
      "saves" => 4,
      "reach" => 80
    }

    timestamp = ~U[2026-10-29 19:00:00.000000Z]

    Repo.update!(Ecto.Changeset.change(post, metrics: metrics, metrics_synced_at: timestamp))
    stored = Repo.get!(Post, post.id)
    assert stored.metrics == metrics
    assert stored.metrics_synced_at == timestamp

    edited =
      Post.changeset(stored, %{
        "metrics" => %{"views" => 9999},
        "analytics_external_id" => "agent-injected-analytics-ID",
        "metrics_synced_at" => "2099-01-01T00:00:00Z",
        "body" => "edited"
      })

    assert edited.changes == %{body: "edited"}
  end

  test "one durable state per org retains opaque cursor and baseline checkpoint" do
    org_id = org_id!()
    post_id = Ecto.UUID.generate()
    cursor = "opaque+/= ? C0"
    timestamp = ~U[2026-10-29 19:00:00.000000Z]

    Repo.insert!(%SyncState{
      org_id: org_id,
      cursor: cursor,
      cursor_captured_at: timestamp,
      bootstrap_after_post_id: post_id
    })

    loaded = Repo.get!(SyncState, org_id)
    assert loaded.cursor == cursor
    assert loaded.cursor_captured_at == timestamp
    assert loaded.bootstrap_after_post_id == post_id
    refute loaded.bootstrap_complete

    other = Repo.insert!(%SyncState{org_id: org_id!(), cursor: "other-cursor"})
    Repo.update!(Ecto.Changeset.change(loaded, cursor: "C1", bootstrap_complete: true))
    assert Repo.get!(SyncState, org_id).cursor == "C1"
    assert Repo.get!(SyncState, org_id).bootstrap_complete
    assert Repo.get!(SyncState, other.org_id).cursor == "other-cursor"

    duplicate =
      %SyncState{org_id: org_id}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:org_id, name: :social_analytics_sync_states_pkey)

    assert {:error, changeset} = Repo.insert(duplicate)
    assert Keyword.has_key?(changeset.errors, :org_id)
  end
end
