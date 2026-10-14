defmodule PlatformWeb.AuthErrorEnvelopeTest do
  @moduledoc """
  Cross-plug pin for the unauthenticated-JSON error envelope (task
  01a0ac9c stage 2).

  Two plugs answer an unauthenticated JSON caller with a 401:
  `PlatformWeb.Plugs.RequireAuthAPI` (the `:require_auth_api` pipeline) and
  `PlatformWeb.Plugs.RequireAuth`'s API-client arm (reached on
  `:blob_browser` via `Accept: application/json`, and on any RequireAuth
  pipeline via an `authorization` header). Both must emit the envelope
  `docs/contracts/editable-messages-contract.md` section B.4 specifies:

      {"error": {"code": "unauthorized", "message": "...", ...}}

  Every request here goes through `PlatformWeb.Router` with
  `Phoenix.ConnTest` (not `Plug.call`), so pipeline ordering is part of
  what is tested: a 406 from content negotiation or a redirect from a
  plug placed earlier would fail these tests rather than bypass them.

  One client handler, `error_code/1`, is applied UNCHANGED to all three
  doors. That is the property the task exists for: a client written
  against one door works against the other.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Tenancy.OrgMembership
  alias Platform.{Files, Repo, Tasks}

  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("auth_error_envelope_test")
    Application.put_env(:platform, :chat_attachments_root, scratch)

    on_exit(fn ->
      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end

      File.rm_rf!(scratch)
    end)

    :ok
  end

  # ── The shared client handler ─────────────────────────────────────────

  # What a client would write once and point at every auth surface.
  defp error_code(conn),
    do: conn.resp_body |> Jason.decode!() |> get_in(["error", "code"])

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp insert_member do
    uniq = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "auth_envelope_#{uniq}@example.com",
        name: "Auth Envelope User",
        oidc_sub: "oidc-auth-envelope-#{uniq}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp seed_blob(body) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Envelope Project #{System.unique_integer([:positive])}",
        slug: "envelope-project-#{System.unique_integer([:positive])}",
        org_id: acme_org_id()
      })

    storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/preview.bin"
    path = Platform.Chat.AttachmentStorage.path_for(storage_key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: "preview.bin",
        original_filename: "preview-original.bin",
        content_type: "text/plain",
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
        ingest_status: "ingested"
      })

    file
  end

  # ── The three doors ───────────────────────────────────────────────────

  defp require_auth_api_door(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> patch("/api/messages/#{Ecto.UUID.generate()}", Jason.encode!(%{content: "x"}))
  end

  defp require_auth_accept_door(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> get("/files/blob/#{Ecto.UUID.generate()}")
  end

  defp require_auth_bearer_door(conn) do
    conn
    |> put_req_header("authorization", "Bearer junk")
    |> get("/agents/#{Ecto.UUID.generate()}/avatar")
  end

  # ── Positive controls ─────────────────────────────────────────────────

  describe "positive controls (the doors are reachable and the non-JSON paths are untouched)" do
    test "an authenticated session still gets the exact bytes from /files/blob/:id",
         %{conn: conn} do
      user = insert_member()
      file = seed_blob("ENVELOPE-POSITIVE-CONTROL")

      conn =
        conn
        |> init_test_session(current_user_id: user.id)
        |> get("/files/blob/#{file.id}")

      assert conn.status == 200
      assert conn.resp_body == "ENVELOPE-POSITIVE-CONTROL"
    end

    test "a browser navigation without a session is still redirected to /auth/login",
         %{conn: conn} do
      file = seed_blob("ENVELOPE-BROWSER-CONTROL")

      conn = get(conn, "/files/blob/#{file.id}")

      assert conn.status == 302
      assert redirected_to(conn) == "/auth/login"
    end
  end

  # ── The shared envelope ───────────────────────────────────────────────

  describe "unauthenticated JSON callers get one envelope from every door" do
    setup %{conn: conn} do
      %{
        api: require_auth_api_door(conn),
        accept: require_auth_accept_door(build_conn()),
        bearer: require_auth_bearer_door(build_conn())
      }
    end

    test "RequireAuthAPI door (PATCH /api/messages/:id) -> 401 with error.code", %{api: conn} do
      assert conn.status == 401
      assert error_code(conn) == "unauthorized"
      assert is_binary(get_in(body(conn), ["error", "message"]))
    end

    test "RequireAuth Accept door (GET /files/blob/:id) -> 401 with error.code",
         %{accept: conn} do
      assert conn.status == 401
      assert error_code(conn) == "unauthorized"
      assert is_binary(get_in(body(conn), ["error", "message"]))
    end

    test "RequireAuth bearer door (GET /agents/:id/avatar) -> 401 with error.code",
         %{bearer: conn} do
      assert conn.status == 401
      assert error_code(conn) == "unauthorized"
      assert is_binary(get_in(body(conn), ["error", "message"]))
    end

    test "the same handler reads the same code from all three doors", ctx do
      codes = Enum.map([ctx.api, ctx.accept, ctx.bearer], &error_code/1)
      assert codes == ["unauthorized", "unauthorized", "unauthorized"]
    end

    test "drift guard: every key RequireAuthAPI puts in error, RequireAuth puts there too",
         ctx do
      api_keys = ctx.api |> body() |> Map.fetch!("error") |> Map.keys() |> MapSet.new()

      for conn <- [ctx.accept, ctx.bearer] do
        require_auth_keys = conn |> body() |> Map.fetch!("error") |> Map.keys() |> MapSet.new()
        assert MapSet.subset?(api_keys, require_auth_keys)
      end
    end

    test "no flat top-level string survives on any door", ctx do
      for conn <- [ctx.api, ctx.accept, ctx.bearer] do
        body = body(conn)
        refute is_binary(body["error"])
        refute Map.has_key?(body, "reason")
      end
    end
  end
end
