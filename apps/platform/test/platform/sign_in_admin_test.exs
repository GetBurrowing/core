defmodule Platform.SignInAdminTest do
  @moduledoc """
  Task 01a113ea stage 2: the `Platform.SignInAdmin` context over
  `Platform.Accounts`.

  pocket-id is a small stateful fake behind the `Req.Test` stub named
  `Platform.SignInAdmin.PocketId` (`config/test.exs`), so a create is visible
  to a later list, a delete to a later get. Response shapes follow what
  pocket-id v2.18.0 returned live on moon in stage 1 (create 201, duplicate
  email 409 with `details.property`, token 201 `{"token": ...}`, delete 204,
  missing user 404). Every request is recorded to the test process, so
  "zero requests" is an assertion and not an assumption.
  """
  # async: false: flips :platform app env (the gate, the URL and key, the
  # email-domain rule) and, in one describe, the global Logger level.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo
  alias Platform.SignInAdmin
  alias Platform.SignInAdmin.{Link, PocketId}
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @key "pid-ctx-key-0123456789-SECRET"
  @token "TOKENa1b2c3Z"
  @static "00000000-0000-0000-0000-000000000000"
  @env_keys [
    :sign_in_admin_enabled,
    :sign_in_admin_url,
    :sign_in_admin_api_key,
    :root_org_admin_email_domain
  ]

  setup do
    saved = for key <- @env_keys, do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
    Application.put_env(:platform, :sign_in_admin_api_key, @key)
    Application.put_env(:platform, :sign_in_admin_enabled, true)

    admin = suite_user!("admin")
    {:ok, _} = Tenancy.promote_to_admin(admin)
    assert Tenancy.root_admin?(admin)

    %{admin: admin}
  end

  # -- fixtures -------------------------------------------------------------

  defp suite_user!(label, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{sub: "sub-#{label}-#{n}", email: "#{label}-#{n}@example.test", name: "#{label} #{n}"},
        overrides
      )

    {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
    user
  end

  defp pid_user(id, email, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "username" => "u-#{id}",
        "email" => email,
        "emailVerified" => true,
        "firstName" => "First",
        "lastName" => "Last",
        "displayName" => "First Last",
        "isAdmin" => false,
        "locale" => "en",
        "disabled" => false
      },
      overrides
    )
  end

  defp authored_message!(user) do
    {:ok, space} =
      Chat.create_space(%{
        name: "SignInAdmin",
        slug: "sign-in-admin-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: "authored before removal",
      author_user_id: user.id
    })
    |> Repo.insert!()
  end

  defp root_membership(user) do
    org = Tenancy.get_root_org()
    Repo.get_by!(OrgMembership, user_id: user.id, org_id: org.id)
  end

  defp user_count, do: Repo.aggregate(Accounts.User, :count)

  # A recorded link expiry 1 second in the past: no live link.
  defp expire_link!(user) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

    {1, _} =
      Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id),
        set: [sign_in_link_expires_at: past]
      )

    past
  end

  defp backdate_archive!(user, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, _} =
      Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id), set: [archived_at: at])
  end

  # -- fake pocket-id -------------------------------------------------------

  # opts: :users (list of pocket-id user maps), :passkeys (%{id => n}),
  # :ids (ids handed to successive creates), :fail (%{kind => status}).
  defp fake!(opts \\ []) do
    test = self()

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             users: Map.new(Keyword.get(opts, :users, []), &{&1["id"], &1}),
             passkeys: Keyword.get(opts, :passkeys, %{}),
             ids: Keyword.get(opts, :ids, []),
             fail: Keyword.get(opts, :fail, %{})
           }
         end}
      )

    Req.Test.stub(PocketId, fn conn -> handle(conn, agent, test) end)
    agent
  end

  defp fail!(agent, kind, status),
    do: Agent.update(agent, &put_in(&1, [:fail, kind], status))

  defp handle(conn, agent, test) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    conn = Plug.Conn.fetch_query_params(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)
    kind = kind(conn.method, conn.path_info)

    send(test, {
      :pocket_id_req,
      %{
        method: conn.method,
        path: conn.request_path,
        kind: kind,
        body: body,
        key: Plug.Conn.get_req_header(conn, "x-api-key")
      }
    })

    case Agent.get(agent, &get_in(&1, [:fail, kind])) do
      nil -> route(kind, conn, body, agent)
      status -> json(conn, status, %{"error" => "stub failure"})
    end
  end

  defp kind("GET", ["api", "users"]), do: :list
  defp kind("POST", ["api", "users"]), do: :create
  defp kind("GET", ["api", "users", _]), do: :get
  defp kind("PUT", ["api", "users", _]), do: :put
  defp kind("DELETE", ["api", "users", _]), do: :delete
  defp kind("GET", ["api", "users", _, "webauthn-credentials"]), do: :passkeys
  defp kind("POST", ["api", "users", _, "one-time-access-token"]), do: :token

  defp route(:list, conn, _body, agent) do
    search = conn.query_params["search"]

    users =
      agent
      |> Agent.get(& &1.users)
      |> Map.values()
      |> Enum.filter(&(is_nil(search) or String.contains?(String.downcase(&1["email"]), search)))

    data = [pid_user(@static, "static-api-user@pocket-id.invalid") | users]

    json(conn, 200, %{
      "data" => data,
      "pagination" => %{"totalPages" => 1, "currentPage" => 1, "itemsPerPage" => 100}
    })
  end

  defp route(:create, conn, body, agent) do
    result =
      Agent.get_and_update(agent, fn state ->
        if Enum.any?(Map.values(state.users), &(&1["email"] == body["email"])) do
          {:email_taken, state}
        else
          {id, ids} =
            case state.ids do
              [id | rest] -> {id, rest}
              [] -> {"pid-#{System.unique_integer([:positive])}", []}
            end

          user = Map.merge(body, %{"id" => id, "disabled" => false, "locale" => nil})
          {{:ok, user}, %{state | ids: ids, users: Map.put(state.users, id, user)}}
        end
      end)

    case result do
      {:ok, user} ->
        json(conn, 201, user)

      :email_taken ->
        json(conn, 409, %{"error" => "taken", "details" => %{"property" => "email"}})
    end
  end

  defp route(:get, conn, _body, agent) do
    case Agent.get(agent, &Map.get(&1.users, id_of(conn))) do
      nil -> json(conn, 404, %{"error" => "not found"})
      user -> json(conn, 200, user)
    end
  end

  defp route(:put, conn, body, agent) do
    id = id_of(conn)

    updated =
      Agent.get_and_update(agent, fn state ->
        case Map.get(state.users, id) do
          nil ->
            {nil, state}

          user ->
            merged = Map.merge(user, body)
            {merged, put_in(state, [:users, id], merged)}
        end
      end)

    if updated, do: json(conn, 200, updated), else: json(conn, 404, %{"error" => "not found"})
  end

  defp route(:delete, conn, _body, agent) do
    id = id_of(conn)

    existed =
      Agent.get_and_update(agent, fn state ->
        {Map.has_key?(state.users, id), %{state | users: Map.delete(state.users, id)}}
      end)

    if existed,
      do: Plug.Conn.send_resp(conn, 204, ""),
      else: json(conn, 404, %{"error" => "not found"})
  end

  defp route(:passkeys, conn, _body, agent) do
    n = Agent.get(agent, &Map.get(&1.passkeys, Enum.at(conn.path_info, 2), 0))
    json(conn, 200, for(i <- 1..n//1, do: %{"id" => "cred-#{i}"}))
  end

  defp route(:token, conn, _body, agent) do
    with f when is_function(f, 0) <- Agent.get(agent, &Map.get(&1, :on_token)), do: f.()

    if Agent.get(agent, &Map.has_key?(&1.users, Enum.at(conn.path_info, 2))),
      do: json(conn, 201, %{"token" => @token}),
      else: json(conn, 404, %{"error" => "not found"})
  end

  defp id_of(conn), do: Enum.at(conn.path_info, 2)

  defp json(conn, status, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp requests(acc \\ []) do
    receive do
      {:pocket_id_req, req} -> requests([req | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # What `Accounts.note_sign_in_link_expiry/2` stores for a link expiring at
  # `at`: rounded UP to the whole second, plus 5 s (task 01a11503).
  defp recorded_expiry(%DateTime{microsecond: {0, _}} = at),
    do: at |> DateTime.truncate(:second) |> DateTime.add(5, :second)

  defp recorded_expiry(%DateTime{} = at),
    do: at |> DateTime.truncate(:second) |> DateTime.add(6, :second)

  defp refute_secret(text, what) do
    refute text =~ @token, "token leaked in #{what}"
    refute text =~ @key, "API key leaked in #{what}"
    refute text =~ "/lc/", "sign-in link leaked in #{what}"
  end

  # Every public function, called once each against `target`.
  defp call_all(actor, target) do
    [
      list_users: SignInAdmin.list_users(actor),
      invite: SignInAdmin.invite(actor, %{email: "gated@example.test", name: "G", role: :member}),
      resend_link: SignInAdmin.resend_link(actor, target.id),
      disable: SignInAdmin.disable(actor, target.id),
      enable: SignInAdmin.enable(actor, target.id),
      remove: SignInAdmin.remove(actor, target.id)
    ]
  end

  # -- gate -----------------------------------------------------------------

  describe "gate" do
    test "with the switch off every function is :not_found, sends nothing and writes nothing",
         %{admin: admin} do
      target = suite_user!("target")
      fake!(users: [pid_user(target.oidc_sub, target.email)])
      Application.put_env(:platform, :sign_in_admin_enabled, false)
      count = user_count()

      results = call_all(admin, target)

      for {fun, result} <- results do
        assert result == {:error, :not_found}, "#{fun} returned #{inspect(result)}"
      end

      assert requests() == []
      assert user_count() == count
      assert is_nil(Repo.get!(Accounts.User, target.id).archived_at)
    end

    test "positive control: the same calls with the switch on do reach pocket-id",
         %{admin: admin} do
      target = suite_user!("target")
      fake!(users: [pid_user(target.oidc_sub, target.email)])

      assert {:ok, _rows} = SignInAdmin.list_users(admin)
      assert requests() != []
    end
  end

  # -- authz ----------------------------------------------------------------

  describe "admin authorization in the context" do
    test "a non-admin actor is :unauthorized everywhere, with zero pocket-id requests" do
      member = suite_user!("member")
      refute Tenancy.root_admin?(member)
      target = suite_user!("target")
      fake!(users: [pid_user(target.oidc_sub, target.email)])
      count = user_count()

      for {fun, result} <- call_all(member, target) do
        assert result == {:error, :unauthorized}, "#{fun} returned #{inspect(result)}"
      end

      assert requests() == []
      assert user_count() == count
    end

    test "an admin demoted after a successful call is refused on the next one",
         %{admin: admin} do
      fake!()
      assert {:ok, _} = SignInAdmin.list_users(admin)
      assert requests() != []

      {:ok, _} = Tenancy.revoke_admin(admin)

      assert {:error, :unauthorized} = SignInAdmin.list_users(admin)
      assert requests() == []
    end
  end

  # -- boundary, behavioural -------------------------------------------------

  describe "boundary: an invited user is the row a first real login makes" do
    test "user I (invite) and user L (first login) match on every schema field but identity",
         %{admin: admin} do
      Application.put_env(:platform, :root_org_admin_email_domain, nil)
      fake!(ids: ["S1"])
      i_email = "invited-#{System.unique_integer([:positive])}@example.test"
      l_email = "loggedin-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %{user: invited}} =
               SignInAdmin.invite(admin, %{email: i_email, name: "N", role: :member})

      {:ok, logged_in} =
        Accounts.find_or_create_from_oidc(%{sub: "S2", email: l_email, name: "N"})

      i_row = Repo.get!(Accounts.User, invited.id)
      l_row = Repo.get!(Accounts.User, logged_in.id)
      assert i_row.oidc_sub == "S1"

      # `sign_in_link_expires_at` is excluded and asserted below: the invite
      # minted a link, the first login did not (task 01a114c1).
      compared =
        Accounts.User.__schema__(:fields) --
          [:id, :email, :oidc_sub, :inserted_at, :updated_at, :sign_in_link_expires_at]

      # Not vacuous: name, avatar, preferences and the archive columns.
      assert length(compared) >= 5

      for field <- compared do
        assert Map.fetch!(i_row, field) == Map.fetch!(l_row, field),
               "users.#{field}: invited #{inspect(Map.fetch!(i_row, field))} " <>
                 "vs first login #{inspect(Map.fetch!(l_row, field))}"
      end

      assert %DateTime{} = i_row.sign_in_link_expires_at
      assert is_nil(l_row.sign_in_link_expires_at)

      i_m = root_membership(invited)
      l_m = root_membership(logged_in)
      assert i_m.org_id == l_m.org_id
      assert i_m.role == l_m.role
      assert i_m.role == "member"

      # The one expected difference: the invite's role step locks the role so
      # the email-domain rule cannot override the admin's choice later.
      assert %DateTime{} = i_m.roles_locked_at
      assert is_nil(l_m.roles_locked_at)

      # The membership existed BEFORE the role step, so the Accounts call made
      # it. Without this, a hand-built users row would still end up with a
      # matching membership: the role step inserts one when none exists, and
      # its audit event then records `from_role: nil`.
      assert [%{"from_role" => "member", "to_role" => "member"}] =
               Repo.all(
                 from(e in Platform.Audit.Event,
                   where:
                     e.action == "revoke_admin" and
                       fragment("?->>'target_user_id'", e.metadata) == ^invited.id,
                   select: e.metadata
                 )
               )

      # The invitee's later real login lands on the same row.
      count = user_count()

      assert {:ok, again} =
               Accounts.find_or_create_from_oidc(%{sub: "S1", email: i_email, name: "N"})

      assert again.id == invited.id
      assert user_count() == count
    end
  end

  # -- list -----------------------------------------------------------------

  describe "list_users/1" do
    test "joins Suite users to pocket-id users and derives every status", %{admin: admin} do
      active = suite_user!("active")
      pending = suite_user!("pending")
      disabled = suite_user!("disabled")
      orphan_suite = suite_user!("noident")

      fake!(
        users: [
          pid_user(active.oidc_sub, active.email),
          pid_user(pending.oidc_sub, pending.email),
          pid_user(disabled.oidc_sub, disabled.email, %{"disabled" => true}),
          pid_user("pid-only", "pid-only@example.test")
        ],
        passkeys: %{active.oidc_sub => 2}
      )

      assert {:ok, rows} = SignInAdmin.list_users(admin)

      status_of = fn id -> Enum.find(rows, &(&1.user && &1.user.id == id)).status end
      assert status_of.(active.id) == :active
      assert status_of.(pending.id) == :pending
      assert status_of.(disabled.id) == :disabled
      assert status_of.(orphan_suite.id) == :no_identity

      assert [%{status: :not_in_suite, user: nil, pocket_id: %{id: "pid-only"}}] =
               Enum.filter(rows, &is_nil(&1.user))

      refute Enum.any?(rows, &(&1.pocket_id && &1.pocket_id.id == @static))
      assert Enum.find(rows, &(&1.user && &1.user.id == active.id)).passkeys == 2
    end

    test "pocket-id down, or a failed passkey count, is :unreachable", %{admin: admin} do
      user = suite_user!("u")
      agent = fake!(users: [pid_user(user.oidc_sub, user.email)])

      fail!(agent, :passkeys, 500)
      assert {:error, :unreachable} = SignInAdmin.list_users(admin)

      fail!(agent, :list, 503)
      assert {:error, :unreachable} = SignInAdmin.list_users(admin)
    end
  end

  # -- invite ---------------------------------------------------------------

  describe "invite/2" do
    test "creates the pocket-id user and the Suite user, and mints a 30m link", %{admin: admin} do
      fake!(ids: ["pid-new"])
      before = DateTime.utc_now()

      assert {:ok, %{user: user, link: %Link{} = link}} =
               SignInAdmin.invite(admin, %{
                 email: "  New.Person@Example.TEST ",
                 name: "New Person",
                 role: :member
               })

      assert user.email == "new.person@example.test"
      assert user.name == "New Person"
      assert user.oidc_sub == "pid-new"
      assert is_nil(user.archived_at)
      refute Tenancy.root_admin?(user)

      assert link.code == @token
      assert link.url == "https://issuer.example.com/lc/#{@token}?redirect=%2Fsettings%2Faccount"
      diff = DateTime.diff(link.expires_at, before, :second)
      assert diff >= 29 * 60 and diff <= 31 * 60

      reqs = requests()
      assert Enum.all?(reqs, &(&1.key == [@key]))
      assert [create] = Enum.filter(reqs, &(&1.kind == :create))
      assert create.body["isAdmin"] == false
      assert create.body["emailVerified"] == true
      assert [token] = Enum.filter(reqs, &(&1.kind == :token))
      assert token.body == %{"ttl" => "30m"}
      assert token.path == "/api/users/pid-new/one-time-access-token"
    end

    test "sends the invite name to pocket-id as display, first and last name (01a114c1)",
         %{admin: admin} do
      fake!(ids: ["pid-carol"])

      assert {:ok, %{user: user}} =
               SignInAdmin.invite(admin, %{
                 email: "carol.case@example.com",
                 name: "Carol Case",
                 role: :member
               })

      assert user.name == "Carol Case"
      assert [create] = Enum.filter(requests(), &(&1.kind == :create))
      assert create.body["displayName"] == "Carol Case"
      assert create.body["firstName"] == "Carol"
      assert create.body["lastName"] == "Case"
    end

    test "role :admin promotes and locks the root membership", %{admin: admin} do
      fake!()

      assert {:ok, %{user: user}} =
               SignInAdmin.invite(admin, %{email: "boss@example.test", name: "B", role: "admin"})

      assert Tenancy.root_admin?(user)
      assert %DateTime{} = root_membership(user).roles_locked_at
    end

    test "the name falls back to the email's local part", %{admin: admin} do
      fake!()

      assert {:ok, %{user: user}} =
               SignInAdmin.invite(admin, %{email: "jo.smith@example.test", role: :member})

      assert user.name == "jo.smith"
    end

    test "an active Suite user with that email is :already_exists, before any request",
         %{admin: admin} do
      existing = suite_user!("dup")
      fake!()

      assert {:error, :already_exists} =
               SignInAdmin.invite(admin, %{
                 email: " " <> String.upcase(existing.email),
                 name: "X",
                 role: :member
               })

      assert requests() == []
    end

    test "bad email or role is refused before any request", %{admin: admin} do
      fake!()
      assert {:error, :invalid_email} = SignInAdmin.invite(admin, %{email: "  ", role: :member})

      assert {:error, :invalid_role} =
               SignInAdmin.invite(admin, %{email: "a@b.test", role: :owner})

      assert requests() == []
    end

    test "adopts a pocket-id user that already has the email and no Suite row", %{admin: admin} do
      fake!(users: [pid_user("pid-existing", "adopt@example.test")])

      assert {:ok, %{user: user}} =
               SignInAdmin.invite(admin, %{email: "adopt@example.test", name: "A", role: :member})

      assert user.oidc_sub == "pid-existing"
      reqs = requests()
      assert Enum.filter(reqs, &(&1.kind == :create)) == []
      assert Enum.filter(reqs, &(&1.kind == :delete)) == []
    end
  end

  # -- compensation ---------------------------------------------------------

  describe "invite/2 compensation" do
    test "the Accounts call failing after a CREATE deletes the created pocket-id user",
         %{admin: admin} do
      agent = fake!(ids: ["S"])
      count = user_count()

      # Passes the context's light normalisation, fails `User.changeset`'s
      # email format inside `find_or_create_from_oidc/1`.
      assert {:error, %Ecto.Changeset{}} =
               SignInAdmin.invite(admin, %{email: "bad email@example.test", role: :member})

      assert Enum.map(Enum.filter(requests(), &(&1.kind == :delete)), & &1.path) ==
               ["/api/users/S"]

      assert Agent.get(agent, & &1.users) == %{}
      assert user_count() == count
    end

    test "a Suite row already holding the created sub is refused and the pocket-id user deleted",
         %{admin: admin} do
      holder = suite_user!("holder", %{sub: "S"})
      {:ok, _} = Accounts.archive_user(holder, reason: "earlier")
      fake!(ids: ["S"])

      assert {:error, :identity_in_use} =
               SignInAdmin.invite(admin, %{email: "fresh@example.test", role: :member})

      assert Enum.map(Enum.filter(requests(), &(&1.kind == :delete)), & &1.path) ==
               ["/api/users/S"]
    end

    test "an ACTIVE Suite row holding the sub keeps its email (no hijack)", %{admin: admin} do
      holder = suite_user!("holder", %{sub: "S"})
      fake!(ids: ["S"])

      assert {:error, :identity_in_use} =
               SignInAdmin.invite(admin, %{email: "hijack@example.test", role: :member})

      assert Repo.get!(Accounts.User, holder.id).email == holder.email
      assert [_] = Enum.filter(requests(), &(&1.kind == :delete))
    end

    test "on the ADOPT path a failure never deletes the pocket-id user", %{admin: admin} do
      agent = fake!(users: [pid_user("pid-adopted", "bad email@example.test")])

      assert {:error, %Ecto.Changeset{}} =
               SignInAdmin.invite(admin, %{email: "bad email@example.test", role: :member})

      assert Enum.filter(requests(), &(&1.kind == :delete)) == []
      assert Map.has_key?(Agent.get(agent, & &1.users), "pid-adopted")
    end
  end

  # -- restore / remove / disable / self ------------------------------------

  describe "remove/2 and the restore path" do
    test "remove is soft; a re-invite relinks a new identity onto the same Suite user",
         %{admin: admin} do
      person = suite_user!("person")
      message = authored_message!(person)
      agent = fake!(users: [pid_user(person.oidc_sub, person.email)], ids: ["pid-second"])

      assert {:ok, removed} = SignInAdmin.remove(admin, person.id)
      assert removed.id == person.id
      assert %DateTime{} = removed.archived_at
      assert removed.archived_reason == "sign-in removed"
      assert removed.archived_by_user_id == admin.id
      refute Map.has_key?(Agent.get(agent, & &1.users), person.oidc_sub)
      assert [%{path: path}] = Enum.filter(requests(), &(&1.kind == :delete))
      assert path == "/api/users/" <> person.oidc_sub

      kept = Repo.get!(Message, message.id)
      assert kept.author_user_id == person.id

      assert {:ok, %{user: restored, link: %Link{}}} =
               SignInAdmin.invite(admin, %{email: person.email, name: "Again", role: :member})

      assert restored.id == person.id
      assert restored.oidc_sub == "pid-second"
      assert is_nil(restored.archived_at)
      assert Repo.get!(Message, message.id).author_user_id == person.id

      assert {:ok, again} =
               Accounts.find_or_create_from_oidc(%{
                 sub: "pid-second",
                 email: person.email,
                 name: person.name
               })

      assert again.id == person.id
    end

    test "disable then enable round-trips, preserving every pocket-id field", %{admin: admin} do
      person = suite_user!("person")

      fake!(
        users: [
          pid_user(person.oidc_sub, person.email, %{
            "username" => "keepme",
            "firstName" => "Kee",
            "lastName" => "Pme",
            "displayName" => "Kee Pme"
          })
        ]
      )

      assert {:ok, disabled} = SignInAdmin.disable(admin, person.id)
      assert %DateTime{} = disabled.archived_at
      assert disabled.archived_reason == "sign-in disabled"

      assert [put] = Enum.filter(requests(), &(&1.kind == :put))
      assert put.body["disabled"] == true

      assert Map.take(put.body, ["username", "email", "firstName", "lastName", "displayName"]) ==
               %{
                 "username" => "keepme",
                 "email" => person.email,
                 "firstName" => "Kee",
                 "lastName" => "Pme",
                 "displayName" => "Kee Pme"
               }

      assert {:error, :disabled} = SignInAdmin.resend_link(admin, person.id)

      assert {:ok, enabled} = SignInAdmin.enable(admin, person.id)
      assert is_nil(enabled.archived_at)
      assert [put] = Enum.filter(requests(), &(&1.kind == :put))
      assert put.body["disabled"] == false
      assert put.body["username"] == "keepme"
    end

    test "disable and remove refuse the actor's own id, with zero requests", %{admin: admin} do
      fake!(users: [pid_user(admin.oidc_sub, admin.email)])

      assert {:error, :self} = SignInAdmin.disable(admin, admin.id)
      assert {:error, :self} = SignInAdmin.remove(admin, admin.id)
      assert requests() == []
      assert is_nil(Repo.get!(Accounts.User, admin.id).archived_at)
    end

    test "resend_link mints for a pending user and refuses a missing identity", %{admin: admin} do
      pending = suite_user!("pending")
      no_identity = suite_user!("noident")
      fake!(users: [pid_user(pending.oidc_sub, pending.email)])

      assert {:ok, %Link{code: @token}} = SignInAdmin.resend_link(admin, pending.id)
      assert {:error, :no_identity} = SignInAdmin.resend_link(admin, no_identity.id)
      assert {:error, :user_not_found} = SignInAdmin.resend_link(admin, "not-a-uuid")
    end
  end

  # -- enable while a Suite-minted link is live (task 01a114c1) -------------

  describe "enable/3 while a Suite-minted sign-in link is live" do
    test "an invitee disabled with a live link is refused, before any pocket-id request",
         %{admin: admin} do
      agent = fake!(ids: ["pid-live"])
      before = DateTime.utc_now()

      assert {:ok, %{user: user, link: link}} =
               SignInAdmin.invite(admin, %{
                 email: "live@example.test",
                 name: "Live Link",
                 role: :member
               })

      # Task 01a11503: mint_link/2 must hand the RAW clock value to the
      # recording point. A truncated `link.expires_at` would satisfy the
      # equality below too (it is computed from the same value), so pin the
      # precision: `utc_now/0` always carries 6 digits, truncation leaves 0.
      assert {_, 6} = link.expires_at.microsecond

      recorded = recorded_expiry(link.expires_at)
      assert Repo.get!(Accounts.User, user.id).sign_in_link_expires_at == recorded

      # Behavioural floor, in addition to the equality: the clock was sampled
      # after `before`, so the recorded value covers ceil(before + TTL) + 5 s.
      floor = recorded_expiry(DateTime.add(before, 30 * 60, :second))
      assert DateTime.compare(recorded, floor) in [:gt, :eq]
      assert {:ok, _} = SignInAdmin.disable(admin, user.id)
      _ = requests()

      assert {:error, {:sign_in_link_live, until}} = SignInAdmin.enable(admin, user.id)

      assert until == recorded
      refute_received {:pocket_id_req, %{kind: :put}}
      assert requests() == []
      assert %DateTime{} = Repo.get!(Accounts.User, user.id).archived_at
      assert get_in(Agent.get(agent, & &1.users), ["pid-live", "disabled"]) == true
    end

    test "positive control: the same flow with the link expired enables", %{admin: admin} do
      agent = fake!(ids: ["pid-expired"])

      assert {:ok, %{user: user}} =
               SignInAdmin.invite(admin, %{
                 email: "expired@example.test",
                 name: "Expired Link",
                 role: :member
               })

      assert {:ok, _} = SignInAdmin.disable(admin, user.id)
      expire_link!(user)
      _ = requests()

      assert {:ok, enabled} = SignInAdmin.enable(admin, user.id)

      assert enabled.id == user.id
      assert is_nil(enabled.archived_at)
      assert [put] = Enum.filter(requests(), &(&1.kind == :put))
      assert put.body["disabled"] == false
      assert get_in(Agent.get(agent, & &1.users), ["pid-expired", "disabled"]) == false
    end

    test "undo: true enables right after the Disable, and not 60 seconds later",
         %{admin: admin} do
      fake!(ids: ["pid-undo", "pid-late"])

      assert {:ok, %{user: undone}} =
               SignInAdmin.invite(admin, %{email: "undo@example.test", name: "U", role: :member})

      assert {:ok, _} = SignInAdmin.disable(admin, undone.id)
      # Without undo the live link refuses; with it, inside the window, it does not.
      assert {:error, {:sign_in_link_live, _}} = SignInAdmin.enable(admin, undone.id)
      assert {:ok, enabled} = SignInAdmin.enable(admin, undone.id, undo: true)
      assert is_nil(enabled.archived_at)

      assert {:ok, %{user: late}} =
               SignInAdmin.invite(admin, %{email: "late@example.test", name: "L", role: :member})

      assert {:ok, _} = SignInAdmin.disable(admin, late.id)
      backdate_archive!(late, 60)
      _ = requests()

      assert {:error, {:sign_in_link_live, _}} = SignInAdmin.enable(admin, late.id, undo: true)
      assert requests() == []
      assert %DateTime{} = Repo.get!(Accounts.User, late.id).archived_at
    end

    test "fail closed: a link whose expiry cannot be recorded is never returned",
         %{admin: admin} do
      gone = suite_user!("gone")
      agent = fake!(users: [pid_user(gone.oidc_sub, gone.email)])

      # The Suite row disappears while pocket-id mints, so the expiry write
      # finds nothing to update.
      Agent.update(agent, fn state ->
        Map.put(state, :on_token, fn ->
          Repo.delete_all(from(m in OrgMembership, where: m.user_id == ^gone.id))
          Repo.delete_all(from(u in Accounts.User, where: u.id == ^gone.id))
        end)
      end)

      {result, log} = with_log(fn -> SignInAdmin.resend_link(admin, gone.id) end)

      assert result == {:error, :link_failed}
      assert [_] = Enum.filter(requests(), &(&1.kind == :token))
      assert log =~ "sign_in_admin.link_expiry_not_recorded suite_user_id=#{gone.id}"
      refute_secret(log, "the log")
    end
  end

  # -- secrets --------------------------------------------------------------

  describe "the link and the key are never logged or persisted" do
    test "success and 5xx paths log ids only and inspect redacts", %{admin: admin} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      agent = fake!(ids: ["pid-log"])
      person = suite_user!("person")

      Agent.update(
        agent,
        &put_in(&1, [:users, person.oidc_sub], pid_user(person.oidc_sub, person.email))
      )

      {results, log} =
        with_log(fn ->
          invite = SignInAdmin.invite(admin, %{email: "logged@example.test", role: :member})
          resend = SignInAdmin.resend_link(admin, person.id)
          disable = SignInAdmin.disable(admin, person.id)
          # The resend above recorded a live link, which would refuse Enable
          # (task 01a114c1). Expire it so Enable still runs and logs here.
          expire_link!(person)
          enable = SignInAdmin.enable(admin, person.id)
          remove = SignInAdmin.remove(admin, person.id)
          [invite, resend, disable, enable, remove]
        end)

      [{:ok, %{user: invited, link: link}}, {:ok, %Link{}} | _] = results
      assert link.code == @token

      # Positive control: the line the context does emit is captured.
      assert log =~ "sign_in_admin.invite suite_user_id=#{invited.id}"
      assert log =~ "pocket_id.request method=POST path=/api/users status=201"
      refute_secret(log, "the log")

      for result <- results, do: refute_secret(inspect(result), "inspect/1 of #{elem(result, 0)}")
      assert inspect(link) =~ "redacted"

      # pocket-id 5xx on every step.
      other = suite_user!("other")

      Agent.update(
        agent,
        &put_in(&1, [:users, other.oidc_sub], pid_user(other.oidc_sub, other.email))
      )

      for kind <- [:token, :put, :delete], do: fail!(agent, kind, 502)

      {failures, log} =
        with_log(fn ->
          [
            SignInAdmin.invite(admin, %{email: "logged2@example.test", role: :member}),
            SignInAdmin.resend_link(admin, other.id),
            SignInAdmin.disable(admin, other.id),
            SignInAdmin.remove(admin, other.id)
          ]
        end)

      for failure <- failures do
        assert match?({:error, _}, failure)
        refute_secret(inspect(failure), "inspect/1 of a failure")
      end

      assert log =~ "status=502"
      refute_secret(log, "the 5xx log")
    end

    test "after an invite no users, messages or audit row contains the token", %{admin: admin} do
      fake!()

      assert {:ok, %{user: user, link: %Link{code: @token}}} =
               SignInAdmin.invite(admin, %{email: "persist@example.test", role: :admin})

      matching = fn table, needle ->
        %{rows: [[n]]} =
          Repo.query!("SELECT count(*) FROM #{table} t WHERE t::text LIKE $1", ["%#{needle}%"])

        n
      end

      # Positive control: the row-as-text probe can find a value that IS there.
      assert matching.("users", user.email) >= 1

      for table <- ["users", "chat_messages", "audit_events"] do
        assert matching.(table, @token) == 0, "token found in #{table}"
        assert matching.(table, @key) == 0, "API key found in #{table}"
      end
    end
  end
end
