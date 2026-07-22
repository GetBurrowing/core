defmodule Platform.ExternalUserFixtures do
  @moduledoc """
  The ONE canonical adversarial external-user world reused by every
  `test/security/*_test.exs` file (rbac-external-users M15).

  `external_world/0` seeds the fixtures the whole security suite binds to and
  returns a map of the created structs/ids. `login/2` is the session shim used
  by the ConnCase-based stages to authenticate an HTTP/LiveView session.

  Mirrors the private helpers each enforcement member (M6-M13) grew in its own
  test file (`external_reads_test.exs`, `chat_dm_allowlist_test.exs`,
  `external_attachment_scope_test.exs`, `router_external_scope_test.exs`, …) —
  consolidating them here so the adversarial matrix is seeded once and every
  surface is proved against the SAME world.

  ## The world (`external_world/0`)

    * `orgA` — the SXI org EXT belongs to, DM-allowlisted for EXT (seeded
      tenant `"sxi"`, so its slug atom exists for TasksLive's scope-rail on the
      internal-user regression path — a raw-inserted novel slug would crash it).
    * `orgB` — a second SXI org NOT allowlisted for EXT (seeded tenant
      `"soylent"`, same scope-rail safety).
    * `ext` — the EXTERNAL user (org_memberships row marked external via
      `Tenancy.mark_membership_external/1`), `allow_dm`'d to `orgA`. Member of
      channel `A` only.
    * `ext2` — a second external user in `orgA` (the SXI↔SXI DM case).
    * `int` — an INTERNAL user (plain member of `orgA`, `external` false).
      Member of channel `A` (so `/chat/<A.slug>` dead-renders for the
      internal-user regression).
    * `m` — an allowlisted member in `orgA` (a permitted DM target for EXT).
    * `n` — a non-allowlisted user in `orgB` (a denied DM target for EXT).
    * `a` — a channel EXT (and INT) participate in.
    * `b` — a channel EXT is NOT a participant of (out-of-scope space).

  Stage-specific extras (a third channel, "quarterly" messages, attachments,
  canvases, transcripts, agent runtimes) are layered on top in each test's own
  `setup` via the public builders below.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── The canonical world ────────────────────────────────────────────────

  @doc "Seed and return the canonical adversarial external-user world."
  def external_world do
    org_a = Tenancy.get_org_by_slug!("sxi")
    org_b = Tenancy.get_org_by_slug!("soylent")

    ext = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org_a.id})
    {:ok, _} = Tenancy.allow_dm(ext, org_a)

    ext2 = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext2.id, org_id: org_a.id})

    int = create_user!()
    plain_member!(int, org_a)

    m = create_user!()
    plain_member!(m, org_a)

    n = create_user!()
    plain_member!(n, org_b)

    other = create_user!()

    a = channel!(%{org_id: org_a.id})
    b = channel!(%{org_id: org_a.id})

    p_a_ext = add_user!(a.id, ext.id)
    p_a_int = add_user!(a.id, int.id)
    p_b = add_user!(b.id, other.id)

    %{
      org_a: org_a,
      org_b: org_b,
      ext: ext,
      ext2: ext2,
      int: int,
      m: m,
      n: n,
      other: other,
      a: a,
      b: b,
      p_a_ext: p_a_ext,
      p_a_int: p_a_int,
      p_b: p_b
    }
  end

  @doc """
  Authenticate a Plug/LiveView session as `user_id`.

  Mirrors `test/platform_web/plugs/require_auth_test.exs` — RequireAuth reads
  `get_session(conn, :current_user_id)` and loads the user + membership assigns.
  """
  def login(conn, user_id) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user_id})
  end

  # ── Reusable builders (mirroring the per-member test helpers) ───────────

  def create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{email: "ext-world-#{n}@example.com", name: "World #{n}", oidc_sub: "oidc-world-#{n}"},
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  @doc "A plain (non-external) org membership."
  def plain_member!(user, org, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  @doc "An external user whose (external) membership lives in `org`, allowlisted to DM `org` unless allowlist: false."
  def external_user!(org, opts \\ []) do
    user = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    if Keyword.get(opts, :allowlist, true), do: Tenancy.allow_dm(user, org)
    user
  end

  def channel!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "Chan #{n}", slug: "sec-chan-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  def add_user!(space_id, user_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  def add_agent!(space_id, agent_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  def post!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  def attachment!(space_id, message_id) do
    {:ok, att} =
      Chat.create_attachment(%{
        space_id: space_id,
        message_id: message_id,
        filename: "f.bin",
        content_type: "application/octet-stream",
        byte_size: 3,
        storage_key: "sec-k-#{System.unique_integer([:positive])}"
      })

    att
  end

  @doc "A pre-backfill / canvas-orphan attachment: no space_id anchor."
  def legacy_attachment! do
    {:ok, att} =
      Chat.create_attachment(%{
        filename: "legacy.bin",
        content_type: "application/octet-stream",
        byte_size: 3,
        storage_key: "sec-legacy-#{System.unique_integer([:positive])}"
      })

    att
  end

  def canvas!(space_id, created_by) do
    {:ok, c} =
      Chat.create_canvas(%{
        "space_id" => space_id,
        "created_by" => created_by,
        "title" => "Doc"
      })

    c
  end

  @doc "The chat_participants row PK for a user in a space (what post_message wants as :participant_id)."
  def participant_pk!(space_id, user_id) do
    Repo.get_by!(Participant,
      space_id: space_id,
      participant_type: "user",
      participant_id: user_id
    ).id
  end

  @doc "Count `chat_participants` rows (for no-row-materialized assertions)."
  def participant_count, do: Repo.aggregate(Participant, :count, :id)

  @doc "Count `chat_messages` rows in a space."
  def message_count(space_id),
    do: Repo.aggregate(from(m in Chat.Message, where: m.space_id == ^space_id), :count)

  @doc "Count `chat_attachments` rows in a space."
  def attachment_count(space_id),
    do: Repo.aggregate(from(a in Chat.Attachment, where: a.space_id == ^space_id), :count)
end
