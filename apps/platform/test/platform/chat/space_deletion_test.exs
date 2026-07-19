defmodule Platform.Chat.SpaceDeletionTest do
  @moduledoc """
  Task 019e95ea stage 3: scheduled channel deletion + retention purge.

  Invariants under test:

    1. `schedule_space_deletion/2` is Fabrikam-admin ONLY (creator does not
       qualify) and only for `kind: "channel"` spaces.
    2. Scheduling sets BOTH `archived_at` and `deletion_scheduled_at` in one
       update, so the stage-1 write freeze applies immediately and the space
       vanishes from every listing/search surface at once.
    3. `cancel_space_deletion/2` clears the deletion flag only — the space
       returns to plain archived state.
    4. `SpacePurger.sweep/0` hard-deletes only channels past the retention
       window, cascades children, is idempotent, and never touches
       non-channel spaces even when their flags are corrupted.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Space
  alias Platform.Chat.SpacePurger
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "deletion-test-#{n}@example.com",
          name: "Deletion Test #{n}",
          oidc_sub: "oidc-deletion-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp membership!(user, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: role
    })
    |> Repo.insert!()
  end

  defp admin_user! do
    user = create_user!()
    membership!(user, "admin")
    user
  end

  defp member_user! do
    user = create_user!()
    membership!(user, "member")
    user
  end

  defp channel!(attrs \\ %{}) do
    default = %{
      name: "Deletion",
      slug: "deletion-#{System.unique_integer([:positive, :monotonic])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp space_of_kind!(kind) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Deletion #{kind}",
        slug: "deletion-#{kind}-#{System.unique_integer([:positive, :monotonic])}",
        kind: kind
      })

    space
  end

  defp participant!(space_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp message!(space_id, participant_id) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: "pre-deletion message"
      })

    msg
  end

  # Channel with a participant + message, flagged for deletion by an admin.
  defp scheduled_with_content!(admin) do
    space = channel!()
    participant = participant!(space.id)
    message = message!(space.id, participant.id)
    {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)
    {scheduled, participant, message}
  end

  # Backdates deletion_scheduled_at (and archived_at, so both flags stay
  # consistent) directly via Repo — the sweep-window tests need history the
  # public API refuses to fabricate.
  defp backdate_flags!(space, days_ago) do
    past = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    space
    |> Ecto.Changeset.change(archived_at: past, deletion_scheduled_at: past)
    |> Repo.update!()
  end

  # ── schedule_space_deletion/2 ──────────────────────────────────────────

  describe "schedule_space_deletion/2 authorization" do
    test "fabrikam admin can schedule a channel for deletion" do
      admin = admin_user!()
      space = channel!()

      assert {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)
      assert %DateTime{} = scheduled.deletion_scheduled_at
    end

    test "creator who is not an admin is rejected — deletion is admin-only" do
      creator = member_user!()
      space = channel!(%{created_by: creator.id})

      assert {:error, :unauthorized} = Chat.schedule_space_deletion(creator, space)
      assert Repo.reload!(space).deletion_scheduled_at == nil
    end

    test "plain member is rejected" do
      member = member_user!()
      space = channel!()

      assert {:error, :unauthorized} = Chat.schedule_space_deletion(member, space)
      assert Repo.reload!(space).deletion_scheduled_at == nil
    end
  end

  describe "schedule_space_deletion/2 kind guard" do
    test "dm, group, and execution spaces are not deletable" do
      admin = admin_user!()

      for kind <- ~w(dm group execution) do
        space = space_of_kind!(kind)

        assert {:error, :not_deletable} = Chat.schedule_space_deletion(admin, space),
               "expected #{kind} space to be rejected"

        assert Repo.reload!(space).deletion_scheduled_at == nil
      end
    end
  end

  describe "schedule_space_deletion/2 effects" do
    test "sets both archived_at and deletion_scheduled_at in one update" do
      admin = admin_user!()
      space = channel!()

      assert {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)
      assert %DateTime{} = scheduled.archived_at
      assert %DateTime{} = scheduled.deletion_scheduled_at
    end

    test "preserves an existing archived_at on an already-archived channel" do
      admin = admin_user!()
      space = channel!()
      {:ok, archived} = Chat.archive_space(space)

      assert {:ok, scheduled} = Chat.schedule_space_deletion(admin, archived)
      assert scheduled.archived_at == archived.archived_at
      assert %DateTime{} = scheduled.deletion_scheduled_at
    end

    test "the stage-1 write freeze applies immediately" do
      admin = admin_user!()
      {space, participant, _msg} = scheduled_with_content!(admin)

      assert {:error, :space_archived} =
               Chat.post_message(%{
                 space_id: space.id,
                 participant_id: participant.id,
                 content_type: "text",
                 content: "should not land"
               })
    end

    test "the space vanishes from list_spaces(archived: true)" do
      admin = admin_user!()

      plain_archived = channel!()
      {:ok, plain_archived} = Chat.archive_space(plain_archived)

      {scheduled, _participant, _msg} = scheduled_with_content!(admin)

      ids =
        [kind: "channel", archived: true]
        |> Chat.list_spaces()
        |> Enum.map(& &1.id)

      assert plain_archived.id in ids
      refute scheduled.id in ids
    end

    test "its messages vanish from list_messages_since(include_archived: true)" do
      admin = admin_user!()
      window_start = DateTime.add(DateTime.utc_now(), -60, :second)

      {_scheduled, _participant, flagged_msg} = scheduled_with_content!(admin)

      archived_space = channel!()
      archived_participant = participant!(archived_space.id)
      archived_msg = message!(archived_space.id, archived_participant.id)
      {:ok, _} = Chat.archive_space(archived_space)

      ids =
        window_start
        |> Chat.list_messages_since(include_archived: true)
        |> Enum.map(& &1.id)

      assert archived_msg.id in ids
      refute flagged_msg.id in ids
    end
  end

  # ── cancel_space_deletion/2 ────────────────────────────────────────────

  describe "cancel_space_deletion/2" do
    test "admin cancels — deletion flag cleared, archived_at retained" do
      admin = admin_user!()
      space = channel!()
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)

      assert {:ok, cancelled} = Chat.cancel_space_deletion(admin, scheduled)
      assert cancelled.deletion_scheduled_at == nil
      assert %DateTime{} = cancelled.archived_at
    end

    test "returns {:error, :not_scheduled} when no deletion is pending" do
      admin = admin_user!()
      space = channel!()
      {:ok, archived} = Chat.archive_space(space)

      assert {:error, :not_scheduled} = Chat.cancel_space_deletion(admin, archived)
    end

    test "non-admin is rejected" do
      admin = admin_user!()
      member = member_user!()
      space = channel!()
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)

      assert {:error, :unauthorized} = Chat.cancel_space_deletion(member, scheduled)
      assert %DateTime{} = Repo.reload!(scheduled).deletion_scheduled_at
    end

    test "clears a cascade child's provenance marker too" do
      admin = admin_user!()
      space = channel!()
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)

      # Stamp the cascade provenance marker as an org cascade would, on top of
      # this channel's own deletion clock.
      scheduled =
        scheduled
        |> Ecto.Changeset.change(archived_cascade_org_id: Tenancy.get_org_by_slug!("fabrikam").id)
        |> Repo.update!()

      refute is_nil(scheduled.archived_cascade_org_id)

      # Cancelling via the single-child path must clear the stale marker —
      # otherwise cascade_children_query would wrongly re-match this live
      # channel on a later org restore.
      assert {:ok, cancelled} = Chat.cancel_space_deletion(admin, scheduled)
      assert is_nil(cancelled.deletion_scheduled_at)
      assert is_nil(cancelled.archived_cascade_org_id)
    end
  end

  # ── SpacePurger.sweep/0 ────────────────────────────────────────────────

  describe "SpacePurger.sweep/0 retention window" do
    test "purges a channel flagged past the retention window, cascading messages" do
      admin = admin_user!()
      {scheduled, _participant, message} = scheduled_with_content!(admin)
      backdate_flags!(scheduled, Chat.space_retention_days() + 1)

      assert {:ok, 1} = SpacePurger.sweep()
      assert Repo.get(Space, scheduled.id) == nil
      assert Repo.get(Message, message.id) == nil
    end

    test "does not purge a channel flagged only 1 day ago" do
      admin = admin_user!()
      space = channel!()
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)
      backdate_flags!(scheduled, 1)

      assert {:ok, 0} = SpacePurger.sweep()
      assert %Space{} = Repo.get(Space, scheduled.id)
    end

    test "is idempotent — a second sweep purges nothing" do
      admin = admin_user!()
      space = channel!()
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)
      backdate_flags!(scheduled, Chat.space_retention_days() + 1)

      assert {:ok, 1} = SpacePurger.sweep()
      assert {:ok, 0} = SpacePurger.sweep()
    end

    test "never touches dm/group/execution spaces even with corrupted flags" do
      spaces =
        for kind <- ~w(dm group execution) do
          space = space_of_kind!(kind)
          backdate_flags!(space, Chat.space_retention_days() + 10)
        end

      log =
        capture_log(fn ->
          assert {:ok, 0} = SpacePurger.sweep()
        end)

      for space <- spaces do
        assert %Space{} = Repo.get(Space, space.id),
               "expected #{space.kind} space to survive the sweep"
      end

      assert log =~ "refusing to purge non-channel space"
    end
  end

  # ── Telemetry / audit bridge ───────────────────────────────────────────

  describe "telemetry" do
    test "schedule emits :space_deletion_scheduled with actor + retention deadline" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :chat, :space_deletion_scheduled]
        ])

      admin = admin_user!()
      space = channel!()
      {:ok, _} = Chat.schedule_space_deletion(admin, space)

      assert_receive {[:platform, :chat, :space_deletion_scheduled], ^ref, _m, meta}
      assert meta.actor_id == admin.id
      assert meta.actor_type == "user"
      assert meta.resource_id == space.id
      assert meta.resource_type == "chat_space"
      assert is_binary(meta.retention_deadline)
    end

    test "sweep emits :space_purged per purged space with actor_type system" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :chat, :space_purged]
        ])

      admin = admin_user!()
      space = channel!()
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)
      backdate_flags!(scheduled, Chat.space_retention_days() + 1)

      assert {:ok, 1} = SpacePurger.sweep()

      assert_receive {[:platform, :chat, :space_purged], ^ref, _m, meta}
      assert meta.actor_id == nil
      assert meta.actor_type == "system"
      assert meta.resource_id == space.id
      assert meta.space_kind == "channel"
      assert is_binary(meta.deletion_scheduled_at)
    end

    test "all three stage-3 events are registered with the audit bridge" do
      events = Platform.Audit.TelemetryHandler.events()

      assert [:platform, :chat, :space_deletion_scheduled] in events
      assert [:platform, :chat, :space_deletion_cancelled] in events
      assert [:platform, :chat, :space_purged] in events
    end
  end
end
