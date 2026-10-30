defmodule Platform.Meetings.GuestShortCodeTest do
  @moduledoc """
  Short guest links (task 01a18d0a-ec37-7000-8a47-108834f2efe2, stage 1).

  What each group defends:

    * **No token stored.** The architecture constraint for this stage: only an
      opaque code goes on the invite row; the signed token is a live bearer
      credential and is re-minted from the row on every hit. Asserted three
      ways, because each alone has a hole: the schema has no token-shaped
      field, the TABLE has no token-shaped column (a column the schema does
      not map would pass the first check), and no VALUE in the raw row equals
      or contains the returned token or its signature segment (a token
      written into an innocently named column would pass both).
    * **Same subject as the long link.** The short code must resolve to the
      same meeting and the same `invite_id` as the token `invite_guest/2`
      returned, and two meetings sharing a slug in different projects must
      not cross.
    * **The row stays authoritative.** Expiry is not extended by repeated
      resolves; expired, revoked and deleted-meeting rows are refused.
    * **Backfill.** The migration's `backfill/1` gives a pre-existing guest
      row a code and leaves account-holder rows alone.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.GuestShortCode
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Repo.Migrations.AddShortCodeToMeetingInvites
  alias Platform.Tasks

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261030160000_add_short_code_to_meeting_invites.exs"
                  ])

  setup_all do
    unless Code.ensure_loaded?(AddShortCodeToMeetingInvites),
      do: Code.require_file(@migration_path)

    :ok
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp project! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Short Code Project #{n}"})
    project
  end

  defp meeting!(project \\ project!(), slug \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Short Code Space #{n}",
        slug: "short-code-space-#{n}",
        kind: "meeting"
      })

    %Meeting{}
    |> Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: slug || "short-code-meeting-#{n}",
      name: "Short Code Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "short-code-#{n}@example.com",
      name: "Short Code User #{n}",
      oidc_sub: "oidc-short-code-#{n}"
    })
    |> Repo.insert!()
  end

  defp code_of(url) do
    %URI{path: "/g/" <> code} = URI.parse(url)
    code
  end

  defp raw_row(invite_id) do
    {:ok, uuid} = Ecto.UUID.dump(invite_id)

    %Postgrex.Result{columns: cols, rows: [row]} =
      Repo.query!("SELECT * FROM meeting_invites WHERE id = $1", [uuid])

    Enum.zip(cols, row)
  end

  # ── GuestShortCode ──────────────────────────────────────────────────────────

  describe "generate/0 and valid_format?/1" do
    test "codes are 22 url-safe characters and pass the format check" do
      for _ <- 1..50 do
        code = GuestShortCode.generate()
        assert String.length(code) == 22
        assert code =~ ~r/\A[A-Za-z0-9_-]{22}\z/
        assert GuestShortCode.valid_format?(code)
      end
    end

    test "codes carry 128 bits: they decode to 16 bytes" do
      assert {:ok, bytes} = Base.url_decode64(GuestShortCode.generate(), padding: false)
      assert byte_size(bytes) == 16
    end

    test "codes do not repeat" do
      codes = for _ <- 1..500, do: GuestShortCode.generate()
      assert length(Enum.uniq(codes)) == 500
    end

    test "wrong length, wrong alphabet and non-binaries are refused" do
      refute GuestShortCode.valid_format?(String.duplicate("A", 21))
      refute GuestShortCode.valid_format?(String.duplicate("A", 23))
      refute GuestShortCode.valid_format?(String.duplicate("A", 21) <> "+")
      refute GuestShortCode.valid_format?(String.duplicate("A", 21) <> ".")
      refute GuestShortCode.valid_format?(String.duplicate("A", 22) <> "\n")
      refute GuestShortCode.valid_format?("")
      refute GuestShortCode.valid_format?(nil)
      refute GuestShortCode.valid_format?(42)
    end
  end

  # ── NO TOKEN STORED ─────────────────────────────────────────────────────────

  describe "no token is stored" do
    test "the Invite schema has no token-shaped field" do
      assert :short_code in Invite.__schema__(:fields)
      assert Enum.filter(Invite.__schema__(:fields), &(Atom.to_string(&1) =~ ~r/token/)) == []
    end

    test "meeting_invites has no token-shaped column" do
      %Postgrex.Result{rows: rows} =
        Repo.query!("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'meeting_invites' AND column_name LIKE '%token%'
        """)

      assert rows == []

      # Positive control: the same query does see the column this stage added.
      %Postgrex.Result{rows: [["short_code"]]} =
        Repo.query!("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'meeting_invites' AND column_name = 'short_code'
        """)
    end

    test "after invite_guest/2 no value in the raw row equals or contains the token" do
      meeting = meeting!()

      assert {:ok, %{invite: invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      [_header, _body, signature] = String.split(token, ".", parts: 3)
      assert byte_size(signature) > 16

      row = raw_row(invite.id)
      assert {"short_code", invite.short_code} in row

      for {column, value} <- row, is_binary(value) do
        refute value == token, "column #{column} holds the token"
        refute String.contains?(value, token), "column #{column} contains the token"
        refute String.contains?(value, signature), "column #{column} contains its signature"
      end

      # And a re-mint through the short link writes nothing either.
      assert {:ok, %{token: reminted}} = Meetings.resolve_guest_short_code(invite.short_code)
      [_h, _b, reminted_sig] = String.split(reminted, ".", parts: 3)

      for {column, value} <- raw_row(invite.id), is_binary(value) do
        refute String.contains?(value, reminted_sig), "column #{column} contains a re-mint"
      end
    end
  end

  # ── invite_guest/2 ─────────────────────────────────────────────────────────

  describe "invite_guest/2 mints a short code on the same insert" do
    test "name-only invite (email nil) succeeds and :url is the short link" do
      meeting = meeting!()

      assert {:ok, %{invite: invite, url: url}} =
               Meetings.invite_guest(meeting, %{display_name: "Sam Ortiz"})

      assert is_nil(invite.email)
      assert is_nil(invite.user_id)
      assert invite.display_name == "Sam Ortiz"
      assert GuestShortCode.valid_format?(invite.short_code)
      assert url == "https://#{GuestInvite.guest_host()}/g/#{invite.short_code}"
      assert Repo.get!(Invite, invite.id).short_code == invite.short_code

      # The detail panel's re-derived link is the same short link.
      assert Meetings.guest_invite_link(meeting, invite) == url
    end

    test "two guests get two distinct codes" do
      meeting = meeting!()
      {:ok, %{invite: a}} = Meetings.invite_guest(meeting, %{display_name: "A"})
      {:ok, %{invite: b}} = Meetings.invite_guest(meeting, %{display_name: "B"})
      refute a.short_code == b.short_code
    end

    test "the short_code index refuses a duplicate code" do
      meeting = meeting!()
      {:ok, %{invite: a}} = Meetings.invite_guest(meeting, %{display_name: "A"})

      assert {:error, changeset} =
               %Invite{}
               |> Invite.changeset(%{
                 meeting_id: meeting.id,
                 display_name: "B",
                 expires_at: a.expires_at
               })
               |> Ecto.Changeset.put_change(:short_code, a.short_code)
               |> Repo.insert()

      assert Keyword.has_key?(changeset.errors, :short_code)
    end

    test "short_code cannot be set through the changeset's params" do
      changeset = Invite.changeset(%Invite{}, %{short_code: String.duplicate("A", 22)})
      refute Map.has_key?(changeset.changes, :short_code)
    end

    test "account-holder invites carry no code" do
      meeting = meeting!()
      user = user!()
      {:ok, invite} = Meetings.invite_user(meeting, user.id)
      assert is_nil(Repo.get!(Invite, invite.id).short_code)
    end

    test "a guest row with no code still gets the long link, and nothing is written" do
      meeting = meeting!()

      invite =
        %Invite{}
        |> Invite.changeset(%{
          meeting_id: meeting.id,
          display_name: "Legacy Guest",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Repo.insert!()

      url = Meetings.guest_invite_link(meeting, invite)
      assert String.starts_with?(url, "https://#{GuestInvite.guest_host()}/#{meeting.slug}/")
      assert is_nil(Repo.get!(Invite, invite.id).short_code)
    end
  end

  # ── resolve_guest_short_code/1 ──────────────────────────────────────────────

  describe "resolve_guest_short_code/1" do
    test "resolves to the same meeting and invite_id as the long token" do
      meeting = meeting!()

      {:ok, %{invite: invite, token: long_token}} =
        Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      assert {:ok, %{meeting: resolved, token: token}} =
               Meetings.resolve_guest_short_code(invite.short_code)

      assert resolved.id == meeting.id

      {:ok, long_payload} = GuestInvite.verify(long_token)
      {:ok, payload} = GuestInvite.verify(token)
      assert payload.invite_id == long_payload.invite_id
      assert payload.invite_id == invite.id
      assert payload.meeting_id == meeting.id
      assert payload.display_name == "Jane Doe"

      # The re-minted token is accepted by the existing guest ingress check.
      assert {:ok, %{state: :in_meeting, display_name: "Jane Doe"}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      # And the old long link still admits.
      assert {:ok, %{state: :in_meeting}} =
               Meetings.resolve_guest_invite(meeting.slug, long_token)
    end

    test "expiry is not extended by repeated resolves" do
      meeting = meeting!()
      {:ok, %{invite: invite}} = Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})
      before = Repo.get!(Invite, invite.id).expires_at

      for _ <- 1..5 do
        assert {:ok, %{token: token}} = Meetings.resolve_guest_short_code(invite.short_code)
        {:ok, payload} = GuestInvite.verify(token)
        assert payload.expires_at == DateTime.to_unix(before)
      end

      assert Repo.get!(Invite, invite.id).expires_at == before
    end

    test "an expired row is refused" do
      meeting = meeting!()
      {:ok, %{invite: invite}} = Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      invite
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      assert Meetings.resolve_guest_short_code(invite.short_code) == {:error, :expired}
    end

    test "a revoked row is refused, and so is its long link" do
      meeting = meeting!()

      {:ok, %{invite: invite, token: long_token}} =
        Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      assert {:ok, _} = Meetings.resolve_guest_short_code(invite.short_code)
      {:ok, _} = Meetings.revoke_invite(invite)

      assert Meetings.resolve_guest_short_code(invite.short_code) == {:error, :revoked}
      assert Meetings.resolve_guest_invite(meeting.slug, long_token) == {:error, :revoked}
    end

    test "a deleted meeting's code is refused" do
      meeting = meeting!()
      {:ok, %{invite: invite}} = Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})
      Repo.delete!(meeting)

      assert Meetings.resolve_guest_short_code(invite.short_code) == {:error, :invalid}
    end

    test "unknown, malformed and wrong-length codes are refused" do
      assert Meetings.resolve_guest_short_code(GuestShortCode.generate()) == {:error, :invalid}
      assert Meetings.resolve_guest_short_code("not a code") == {:error, :invalid}
      assert Meetings.resolve_guest_short_code(String.duplicate("A", 21)) == {:error, :invalid}
      assert Meetings.resolve_guest_short_code(String.duplicate("A", 23)) == {:error, :invalid}
      assert Meetings.resolve_guest_short_code("'; DROP TABLE x; --aaaa") == {:error, :invalid}
      assert Meetings.resolve_guest_short_code(nil) == {:error, :invalid}
    end

    test "two meetings with the same slug in different projects stay isolated" do
      slug = "same-slug-#{System.unique_integer([:positive])}"
      meeting_a = meeting!(project!(), slug)
      meeting_b = meeting!(project!(), slug)
      refute meeting_a.id == meeting_b.id

      {:ok, %{invite: a}} = Meetings.invite_guest(meeting_a, %{display_name: "Guest A"})
      {:ok, %{invite: b}} = Meetings.invite_guest(meeting_b, %{display_name: "Guest B"})

      assert {:ok, %{meeting: %{id: id_a}, token: token_a}} =
               Meetings.resolve_guest_short_code(a.short_code)

      assert {:ok, %{meeting: %{id: id_b}, token: token_b}} =
               Meetings.resolve_guest_short_code(b.short_code)

      assert id_a == meeting_a.id
      assert id_b == meeting_b.id
      assert {:ok, %{invite_id: invite_a}} = GuestInvite.verify(token_a)
      assert {:ok, %{invite_id: invite_b}} = GuestInvite.verify(token_b)
      assert invite_a == a.id
      assert invite_b == b.id
    end

    test "an account-holder row is never resolved, even if it carried a code" do
      meeting = meeting!()
      user = user!()
      {:ok, invite} = Meetings.invite_user(meeting, user.id)
      code = GuestShortCode.generate()
      invite |> Ecto.Changeset.change(short_code: code) |> Repo.update!()

      assert Meetings.resolve_guest_short_code(code) == {:error, :invalid}
    end
  end

  # ── Meeting slug reservation ───────────────────────────────────────────────

  describe "slug \"g\"" do
    test "is refused by Meeting.changeset/2" do
      changeset =
        Meeting.changeset(%Meeting{}, %{
          project_id: Ecto.UUID.generate(),
          chat_space_id: Ecto.UUID.generate(),
          slug: "g",
          name: "G",
          livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
        })

      assert {"is reserved", _} = changeset.errors[:slug]
    end

    test "a meeting named \"G\" is given another slug instead of failing" do
      project = project!()
      assert {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "G"})
      refute meeting.slug == "g"
    end
  end

  # ── Backfill ────────────────────────────────────────────────────────────────

  describe "the migration's backfill/1" do
    test "gives a code to a guest row inserted without one, and only to guest rows" do
      meeting = meeting!()
      user = user!()

      guest =
        %Invite{}
        |> Invite.changeset(%{
          meeting_id: meeting.id,
          display_name: "Pre-existing Guest",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Repo.insert!()

      {:ok, member} = Meetings.invite_user(meeting, user.id)

      assert is_nil(guest.short_code)

      assert AddShortCodeToMeetingInvites.backfill(Repo) >= 1

      code = Repo.get!(Invite, guest.id).short_code
      assert GuestShortCode.valid_format?(code)
      assert is_nil(Repo.get!(Invite, member.id).short_code)

      # The backfilled code resolves like any other.
      assert {:ok, %{meeting: %{id: meeting_id}}} = Meetings.resolve_guest_short_code(code)
      assert meeting_id == meeting.id

      # Re-running leaves an existing code alone.
      AddShortCodeToMeetingInvites.backfill(Repo)
      assert Repo.get!(Invite, guest.id).short_code == code
    end
  end
end
