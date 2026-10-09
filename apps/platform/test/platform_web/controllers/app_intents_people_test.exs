defmodule PlatformWeb.AppIntentsPeopleTest do
  @moduledoc """
  Task 01a111bb stage 1: `GET /api/app/people` and
  `POST /api/app/people/:user_id/dm`.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Mobile
  alias Platform.Repo

  defp token!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    token
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp rename!(user, name), do: Repo.update!(Ecto.Changeset.change(user, name: name))

  describe "401" do
    test "both routes refuse a request with no bearer", %{conn: conn} do
      assert json_response(get(conn, "/api/app/people"), 401) == %{"error" => "unauthorized"}

      assert json_response(post(conn, "/api/app/people/#{Ecto.UUID.generate()}/dm"), 401) ==
               %{"error" => "unauthorized"}
    end
  end

  describe "GET /api/app/people" do
    test "a search returns rows with no email or phone", %{conn: conn} do
      t = "Pz#{System.unique_integer([:positive])}"
      me = create_user!()
      dana = create_user!(%{name: "#{t} Dana", email: "dana-#{t}@example.com"})

      body =
        conn |> bearer(token!(me)) |> get("/api/app/people", %{"q" => t}) |> json_response(200)

      assert [row] = body["people"]

      assert row == %{
               "id" => dana.id,
               "kind" => "user",
               "name" => dana.name,
               "org_names" => [],
               "dm_space_id" => nil
             }

      refute inspect(body) =~ "example.com"
    end

    test "an external user: the allow-listed person is found, the other is not", %{conn: conn} do
      world = external_world()
      t = "Pz#{System.unique_integer([:positive])}"
      m = rename!(world.m, "#{t} Allowed")
      n = rename!(world.n, "#{t} Denied")
      token = token!(world.ext)

      ids =
        conn
        |> bearer(token)
        |> get("/api/app/people", %{"q" => t})
        |> json_response(200)
        |> Map.fetch!("people")
        |> Enum.map(& &1["id"])

      assert m.id in ids
      refute n.id in ids
    end

    test "no q answers recent collaborators", %{conn: conn} do
      me = create_user!()
      other = create_user!()
      {:ok, dm} = Chat.find_or_create_dm(me.id, "user", other.id)
      post!(dm.id, participant_pk!(dm.id, me.id), "hello")

      body = conn |> bearer(token!(me)) |> get("/api/app/people") |> json_response(200)

      assert [%{"id" => id, "dm_space_id" => dm_id, "kind" => "user"}] = body["people"]
      assert {id, dm_id} == {other.id, dm.id}
    end
  end

  describe "GET /api/app/people?scope=directory" do
    test "lists an org mate who shares no space; Ext still cannot get Riley", %{conn: conn} do
      world = external_world()
      priya = create_user!()
      plain_member!(priya, world.org_a)
      # Riley (world.n, org B only) shares a channel with Ext.
      add_user!(world.a.id, world.n.id)

      ids_for = fn user ->
        conn
        |> bearer(token!(user))
        |> get("/api/app/people", %{"scope" => "directory"})
        |> json_response(200)
        |> Map.fetch!("people")
        |> Enum.map(& &1["id"])
      end

      # An internal org member sees Priya with no shared space.
      assert priya.id in ids_for.(world.int)

      ext_ids = ids_for.(world.ext)
      # Positive control, then the negative: Riley (org B) is never listed.
      assert world.m.id in ext_ids
      refute world.n.id in ext_ids
    end
  end

  describe "POST /api/app/people/:user_id/dm" do
    test "opens the DM and answers its id", %{conn: conn} do
      me = create_user!()
      other = create_user!()
      token = token!(me)

      body = conn |> bearer(token) |> post("/api/app/people/#{other.id}/dm") |> json_response(200)
      assert %{"space_id" => id, "path_segment" => id} = body
      assert Chat.participant?(id, me.id) and Chat.participant?(id, other.id)
    end

    test "external: 200 to the allow-listed person, 403 to the other", %{conn: conn} do
      world = external_world()
      token = token!(world.ext)

      assert %{"space_id" => _} =
               conn
               |> bearer(token)
               |> post("/api/app/people/#{world.m.id}/dm")
               |> json_response(200)

      assert conn
             |> bearer(token)
             |> post("/api/app/people/#{world.n.id}/dm")
             |> json_response(403) == %{"error" => "forbidden"}
    end

    test "404 for an unknown or malformed id", %{conn: conn} do
      token = token!(create_user!())

      for id <- [Ecto.UUID.generate(), "nope"] do
        assert conn |> bearer(token) |> post("/api/app/people/#{id}/dm") |> json_response(404) ==
                 %{"error" => "not_found"}
      end
    end
  end
end
