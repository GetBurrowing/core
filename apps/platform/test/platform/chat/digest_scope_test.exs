defmodule Platform.Chat.DigestScopeTest do
  @moduledoc """
  Stack member 12 (rbac-external-users) — the external-space digest
  partition primitives on `Platform.Chat`:

    * `external_space_ids/0` — spaces carrying any external-visible content
      (fully-external AND mixed Acme+external spaces), `[]` when no external
      users exist.
    * `participant_space_ids_for_user/1` — the external user's allowlisted
      spaces.
    * `list_messages_since/2` `:scope` — `:internal` (default) omits external
      + mixed spaces; `{:external_spaces, ids}` restricts to them.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "u-#{n}@example.com", name: "User #{n}", oidc_sub: "oidc-#{n}"})
    |> Repo.insert!()
  end

  defp external_user! do
    user = create_user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: TenancyFixtures.tenant_org_id("globex")
      })

    user
  end

  defp create_space!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "sp-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp add_user!(space_id, user_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space_id, participant_id, content) do
    %Message{}
    |> Message.changeset(%{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      author_display_name: "T"
    })
    |> Repo.insert!()
  end

  defp window do
    now = DateTime.utc_now()
    {DateTime.add(now, -3600, :second), DateTime.add(now, 3600, :second)}
  end

  # ── external_space_ids/0 ───────────────────────────────────────────────

  describe "external_space_ids/0" do
    test "returns the fully-external and mixed spaces but not internal-only" do
      acme = create_user!()
      ext = external_user!()

      internal = create_space!("acme-eng")
      add_user!(internal.id, acme.id)

      external = create_space!("globex-support")
      add_user!(external.id, ext.id)

      mixed = create_space!("globex-shared")
      add_user!(mixed.id, acme.id)
      add_user!(mixed.id, ext.id)

      ids = Chat.external_space_ids()

      assert external.id in ids
      assert mixed.id in ids
      refute internal.id in ids
    end

    test "returns [] when there are no external memberships" do
      acme = create_user!()
      internal = create_space!("acme-eng")
      add_user!(internal.id, acme.id)

      assert Chat.external_space_ids() == []
    end
  end

  # ── participant_space_ids_for_user/1 ───────────────────────────────────

  describe "participant_space_ids_for_user/1" do
    test "returns exactly the spaces the given external user participates in" do
      ext = external_user!()
      other = create_user!()

      a = create_space!("globex-support")
      add_user!(a.id, ext.id)

      b = create_space!("globex-shared")
      add_user!(b.id, ext.id)

      # A space the external user is NOT in.
      c = create_space!("acme-eng")
      add_user!(c.id, other.id)

      ids = Chat.participant_space_ids_for_user(ext.id)

      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      refute c.id in ids
    end
  end

  # ── list_messages_since/2 :scope ───────────────────────────────────────

  describe "list_messages_since/2 :scope" do
    test "default :internal omits external + mixed space rows, keeps internal" do
      acme = create_user!()
      ext = external_user!()

      internal = create_space!("acme-eng")
      kp = add_user!(internal.id, acme.id)
      post!(internal.id, kp.id, "internal msg")

      external = create_space!("globex-support")
      ep = add_user!(external.id, ext.id)
      post!(external.id, ep.id, "external msg")

      mixed = create_space!("globex-shared")
      mk = add_user!(mixed.id, acme.id)
      _me = add_user!(mixed.id, ext.id)
      post!(mixed.id, mk.id, "mixed msg")

      {ws, we} = window()
      rows = Chat.list_messages_since(ws, window_end: we)
      contents = Enum.map(rows, & &1.content)

      assert "internal msg" in contents
      refute "external msg" in contents
      refute "mixed msg" in contents
    end

    test "{:external_spaces, ids} returns only those spaces' rows" do
      acme = create_user!()
      ext = external_user!()

      internal = create_space!("acme-eng")
      kp = add_user!(internal.id, acme.id)
      post!(internal.id, kp.id, "internal msg")

      external = create_space!("globex-support")
      ep = add_user!(external.id, ext.id)
      post!(external.id, ep.id, "external msg")

      {ws, we} = window()

      rows =
        Chat.list_messages_since(ws, window_end: we, scope: {:external_spaces, [external.id]})

      contents = Enum.map(rows, & &1.content)

      assert "external msg" in contents
      refute "internal msg" in contents
    end

    test "with zero external users the default filter is a no-op (regression guard)" do
      acme = create_user!()

      internal = create_space!("acme-eng")
      kp = add_user!(internal.id, acme.id)
      post!(internal.id, kp.id, "internal msg")

      {ws, we} = window()

      # No external memberships exist → NOT IN ^[] must leave every internal row.
      assert Chat.external_space_ids() == []

      default = Chat.list_messages_since(ws, window_end: we)
      assert "internal msg" in Enum.map(default, & &1.content)
    end
  end
end
