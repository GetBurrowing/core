defmodule PlatformWeb.ChatLiveSpaceAdmissionTest do
  @moduledoc """
  Internal admission to `/chat/<uuid>` (task 01a01d0e).

  `handle_params/3` resolves a space by UUID with no scope, and the only
  admission gate ahead of the success branch — `external_space_denied?/2` — is
  scoped to EXTERNAL sessions by construction. An internal session therefore
  passed the gate for every space row in the database, and
  `ensure_participant/2` (which carries no authorization check of its own) then
  minted a `chat_participants` row. A read bypass became permanent membership.

  ## What the fix draws the line on

  Implicit join survives only for spaces that are open to internal users BY
  POLICY. Three kinds qualify, each established elsewhere in the suite:

    * `channel` — `Chat.list_spaces(kind: "channel", scope: nil)` applies no
      membership filter, so the rail already lists every workspace channel to
      every internal user. Clicking one MUST still join. Task 01a0181f settled
      that this is deliberate.
    * `system` — the per-agent system-event spaces, which `handle_params/3`
      reaches through its own `system_prefix_fallback/1` branch. Navigable by
      slug on purpose.
    * `execution` — which the filing ticket got WRONG. It listed exec spaces
      as part of the exposure; the suite already pins the opposite, because a
      task pin propagates to every @-mentioned participant and those
      bystanders open the exec space with no participant row, cross-org
      included. See the dedicated describe block below.

  That leaves `dm`, `group`, `meeting` and `guest_meeting` requiring a
  participant row that already exists. Those kinds have an explicit join seam
  of their own — `Chat.find_or_create_dm/4`, `Meetings.Membership` — so
  closing the implicit one removes a bypass rather than a feature.

  EXTERNAL sessions are out of scope here and the gate declines to answer for
  them: `external_space_denied?/2` and its per-org DM allowlist already
  adjudicate those, and that allowlist admits a DM the external user has no
  row in yet. Stacking the internal rule on top vetoed it — caught by
  `ChatLiveExternalRailTest`, and the reason `implicit_join_denied?/2` tests
  `external_session?/1` first.

  ## Anti-vacuity notes

    * The load-bearing test is the NEGATIVE one, and its load-bearing
      assertion is the participant COUNT, not the redirect. A fix that hid the
      message pane but still wrote the row would satisfy a render-only or
      redirect-only check while leaving the permanent grant — which is the
      whole defect — completely intact. Every refusal below therefore asserts
      `Chat.list_participants(space.id)` is unchanged, and asserts it against
      a count captured BEFORE the navigation rather than a hardcoded literal.

    * Each refusal is paired with a positive control in the same file: a
      member opening the same KIND of space still works, and an internal user
      opening a workspace channel they have never opened still auto-joins.
      Without those, a fix that denied everything would pass every refute here
      and break chat for the entire team.

    * Test 1 was run against the unfixed tree and failed by minting the row
      (3 participants where 2 were seeded). That detonation is the evidence
      the defect is real rather than theoretical.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "admission-#{n}@example.com",
      name: "Admission #{n}",
      oidc_sub: "oidc-admission-#{n}",
      avatar_url: nil
    })
  end

  # A bare user with no `org_memberships` row is INTERNAL:
  # `Tenancy.external_user?/1` is an EXISTS over memberships with
  # `external == true`. So these sessions pass the external gate exactly as a
  # real internal employee's session does, which is the session the ticket is
  # about. Asserted explicitly in `setup` rather than assumed, because if these
  # users were external the whole file would pass for the wrong reason — the
  # external gate would be doing the denying.
  defp authed(conn) do
    user = insert_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp acme_org, do: Tenancy.get_org_by_slug!("acme")

  defp add_user(space, user_or_id, name) do
    id = if is_binary(user_or_id), do: user_or_id, else: user_or_id.id

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # A DM between two OTHER people. Neither participant is the viewer, which is
  # the arrangement the ticket describes and the only one where the leak is a
  # confidentiality breach rather than a no-op.
  defp dm_between_others(kind \\ "dm") do
    {:ok, space} = Chat.create_space(%{kind: kind, is_direct: kind == "dm"})
    add_user(space, insert_user(), "Other One")
    add_user(space, insert_user(), "Other Two")
    space
  end

  defp create_channel do
    n = System.unique_integer([:positive])

    {:ok, ch} =
      Chat.create_space(%{
        name: "Channel #{n}",
        slug: "admission-channel-#{n}",
        kind: "channel",
        org_id: acme_org().id
      })

    ch
  end

  defp create_execution_space do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "task-exec-#{n}",
        slug: "task-exec-#{n}",
        kind: "execution",
        metadata: %{"task_id" => Ecto.UUID.generate()}
      })

    space
  end

  defp user_participant_ids(space_id) do
    space_id
    |> Chat.list_participants()
    |> Enum.filter(&(&1.participant_type == "user"))
    |> Enum.map(& &1.participant_id)
    |> Enum.sort()
  end

  setup %{conn: conn} do
    {conn, user} = authed(conn)

    # The premise of every test here. If this flipped, the refusals below would
    # be produced by the EXTERNAL gate (task 01a011ed) and would prove nothing
    # about the internal path this ticket is about.
    refute Tenancy.external_user?(%{id: user.id}),
           "fixture user must be INTERNAL or this file tests the external gate by mistake"

    {:ok, conn: conn, user: user}
  end

  # ── 1. The defect: refusal, and NO row written ──────────────────────────

  describe "a space that is not open by policy" do
    test "refuses an internal non-member at a DM between two other people, and writes no participant row",
         %{conn: conn, user: user} do
      dm = dm_between_others()
      before_ids = user_participant_ids(dm.id)
      assert length(before_ids) == 2
      refute user.id in before_ids

      assert {:error, {:live_redirect, %{to: "/chat"}}} = live(conn, ~p"/chat/#{dm.id}")

      # THE assertion. A refusal that still called `ensure_participant/2` would
      # satisfy the redirect match above and still hand the viewer a permanent,
      # self-authorizing grant that every later membership check agrees with.
      assert user_participant_ids(dm.id) == before_ids,
             "navigating to another pair's DM must not mint a participant row"
    end

    test "refuses an internal non-member at a GROUP conversation, and writes no participant row",
         %{conn: conn, user: user} do
      group = dm_between_others("group")
      before_ids = user_participant_ids(group.id)

      assert {:error, {:live_redirect, %{to: "/chat"}}} = live(conn, ~p"/chat/#{group.id}")
      assert user_participant_ids(group.id) == before_ids
      refute user.id in user_participant_ids(group.id)
    end

    # The refusal must not be an existence oracle over space ids. A space that
    # does not exist and a space that exists but is not yours produce the same
    # tuple, so a caller cannot probe UUIDs for existence by diffing responses.
    test "a nonexistent space id is refused indistinguishably from a forbidden one", %{
      conn: conn
    } do
      dm = dm_between_others()
      missing = Ecto.UUID.generate()

      forbidden_result = live(conn, ~p"/chat/#{dm.id}")
      missing_result = live(conn, ~p"/chat/#{missing}")

      assert {:error, {:live_redirect, %{to: "/chat"}}} = forbidden_result
      assert forbidden_result == missing_result
    end
  end

  # ── 2. Positive control: membership still opens the same kinds ──────────

  describe "a member of a closed space" do
    test "still opens their own DM", %{conn: conn, user: user} do
      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})
      add_user(dm, user, user.name)
      add_user(dm, insert_user(), "The Other Person")

      before_ids = user_participant_ids(dm.id)
      assert user.id in before_ids

      assert {:ok, view, _html} = live(conn, ~p"/chat/#{dm.id}")
      assert has_element?(view, "#compose-form")

      # Opening a DM you are already in must not duplicate your row either.
      assert user_participant_ids(dm.id) == before_ids
    end

    test "still opens an execution space they were joined to", %{conn: conn, user: user} do
      space = create_execution_space()
      add_user(space, user, user.name)

      assert {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      assert has_element?(view, "#compose-form")
    end
  end

  # ── 2b. The category the ticket got WRONG ───────────────────────────────

  describe "an execution space (open by policy, contrary to the filing ticket)" do
    # The ticket listed execution spaces as part of the exposure. They are not,
    # and the suite says so in two places: `ChatLiveTest`'s "mentioned
    # bystander opens pinned exec space via rail row" and "resolves cross-org
    # exec-space slug for @-mentioned bystander" both open an exec space for a
    # user carrying a PIN row and NO participant row — the second across orgs,
    # deliberately (PR #548 stage 3 propagates a task pin to every @-mentioned
    # participant). A first draft of this fix closed execution spaces and
    # turned five such tests red. This test pins the corrected decision so the
    # next person does not repeat the mistake.
    test "still resolves AND still auto-joins an internal user with no participant row", %{
      conn: conn,
      user: user
    } do
      space = create_execution_space()
      refute user.id in user_participant_ids(space.id)

      assert {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      assert has_element?(view, "#compose-form")
      assert user.id in user_participant_ids(space.id)
    end
  end

  # ── 3. Open-by-policy control: channels must still implicitly join ──────

  describe "a workspace channel (open to internal users by policy)" do
    test "still resolves AND still auto-joins an internal user who has never opened it", %{
      conn: conn,
      user: user
    } do
      channel = create_channel()
      refute user.id in user_participant_ids(channel.id)

      assert {:ok, view, _html} = live(conn, ~p"/chat/#{channel.id}")
      assert has_element?(view, "#compose-form")

      # The implicit join is the FEATURE here, not the bug. A fix that denied
      # everything would pass every refute above and fail exactly this.
      assert user.id in user_participant_ids(channel.id),
             "internal navigation to a workspace channel must still create the participant row"
    end
  end
end
