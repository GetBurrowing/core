defmodule PlatformWeb.SocialZeroDataRemoveAcceptanceTest do
  @moduledoc """
  Remove then reconnect from zero social data, driven through the LiveView
  alone (task 01a14ac6, stage 4).

  Same discipline as `social_zero_data_connect_acceptance_test.exs`: setup
  creates ONLY a live human user who is an internal member of one live org,
  using core's own schemas and fixtures, and asserts there are no social
  profiles, no social accounts and no Zernio key. Everything after that is a
  LiveView event or a `live/2` mount of a URL:

    1. the empty-state create_profile form;
    2. Settings: save_zernio_key with an obvious fake key;
    3. Connections: "+ Add account", linkedin, and the external redirect;
    4. the vendor's return URL with the stub listing ref "zacc_same_1";
    5. open_remove on that row, then remove_account;
    6. "+ Add account", linkedin again, and a return with the SAME ref.

  This is the proof that the same Zernio account can be reconnected after a
  removal: the live-ref unique index ignores archived rows, and the archived
  row keeps its ref for history.

  The `Req.Test` stub records every request (method, path, query and the
  Authorization header) and answers `GET /api/v1/accounts` from a list the
  test controls through an Agent; `DELETE /api/v1/accounts/:id` answers 200
  or 503 as the test asks. A source guard below reads this file's own setup
  block and refutes any Social or Vault write.

  No request leaves the BEAM (`config :social, :zernio_req_options`).
  `async: false`: the publisher config and the install-level Vault row are
  global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Repo
  alias Platform.Social.{Account, Profile, Secrets}
  alias Platform.Social.Publisher.Zernio

  @auth_url "https://vendor.example.test/oauth"
  @vendor_profile_id "zprof_same_1"
  @ref "zacc_same_1"
  @username "@zerosame"
  @fake_key "sk_test_obviously_fake_key"

  setup do
    assert Repo.aggregate(from(p in "social_profiles"), :count) == 0
    assert Repo.aggregate(from(a in "social_accounts"), :count) == 0
    assert Secrets.zernio_key_status() == :not_set

    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.tenant_org_id("zero-remove-org-#{n}")

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "zero-remove-#{n}@example.com",
        name: "Zero Remove #{n}",
        oidc_sub: "zero-remove-#{n}"
      })
      |> Repo.insert!()

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })
    |> Repo.insert!()

    %{user: user, org_id: org_id}
  end

  # Logs every Zernio request to the test process. `delete_status` is what
  # DELETE /v1/accounts/:id answers. The account list comes from an Agent
  # the test edits between steps. The test, not the stub, asserts.
  defp stub_zernio(delete_status) do
    test = self()
    listed = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(Zernio, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      auth = Plug.Conn.get_req_header(conn, "authorization")
      send(test, {:zernio_request, conn.method, conn.request_path, conn.query_params, auth})

      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/profiles"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"message" => "created", "profile" => %{"_id" => @vendor_profile_id}})

        {"GET", "/api/v1/connect/" <> _} ->
          Req.Test.json(conn, %{"authUrl" => @auth_url})

        {"GET", "/api/v1/accounts"} ->
          entries =
            listed
            |> Agent.get(& &1)
            |> Enum.filter(&(get_in(&1, ["profileId", "_id"]) == conn.query_params["profileId"]))

          Req.Test.json(conn, %{"accounts" => entries, "hasAnalyticsAccess" => false})

        {"DELETE", "/api/v1/accounts/" <> _} ->
          conn
          |> Plug.Conn.put_status(delete_status)
          |> Req.Test.json(%{"message" => if(delete_status == 200, do: "deleted", else: "down")})

        _ ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)

    listed
  end

  defp list!(listed, entry), do: Agent.update(listed, &(&1 ++ [entry]))

  defp drain_requests(acc \\ []) do
    receive do
      {:zernio_request, method, path, params, auth} ->
        drain_requests([{method, path, params, auth} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp land(user, url) do
    conn = Plug.Test.init_test_session(build_conn(), current_user_id: user.id)
    {:ok, view, _html} = live(conn, url)
    child = find_live_child(view, "ext-page-social")
    Req.Test.allow(Zernio, self(), child.pid)
    child
  end

  defp goto(child, tab) do
    child |> element("[data-role='social-tab-button'][data-tab='#{tab}']") |> render_click()
    child
  end

  defp row(%Account{id: id}), do: "#accounts-#{id}"
  defp notice?(child, text), do: has_element?(child, "[data-role='social-notice']", text)

  @return_url "/m/social?connected=linkedin&profileId=#{@vendor_profile_id}" <>
                "&accountId=#{@ref}&username=zerosame"

  # "+ Add account", linkedin, up to the external redirect. Returns the
  # requests that made, in order.
  defp add_linkedin(child) do
    child = goto(child, "connections")
    refute has_element?(child, "[data-role='social-zernio-required']")
    child |> element("[data-role='social-add-account']") |> render_click()

    child
    |> form("#social-add-account-form", platform: "linkedin")
    |> render_submit()

    requests = drain_requests()
    assert_redirect(child, @auth_url)
    requests
  end

  # Steps 1-4 then the removal (step 5) up to the click on "Remove account".
  # Returns {child, connected_account, requests_so_far}.
  defp connect_then_open_remove(user, listed) do
    # (1) The empty state's create form. No key yet: nothing asked of Zernio.
    child = land(user, "/m/social")
    assert has_element?(child, "form#social-create-form[phx-submit='create_profile']")

    child
    |> form("#social-create-form", profile: %{name: "Zero Remove Brand", home_url: ""})
    |> render_submit()

    assert [%Profile{} = created] = Repo.all(Profile)
    assert drain_requests() == []

    # (2) Settings: save the fake key through the form.
    child = goto(child, "settings")

    child
    |> form("[data-role='social-zernio-key-form']", zernio_key: %{api_key: @fake_key})
    |> render_submit()

    assert has_element?(child, "[data-role='social-zernio-key'][data-state='set']")
    assert drain_requests() == []

    # (3) Connections: "+ Add account", linkedin.
    first_connect = add_linkedin(child)

    assert [
             {"POST", "/api/v1/profiles", _, _},
             {"GET", "/api/v1/connect/linkedin", %{"profileId" => @vendor_profile_id}, _}
           ] = first_connect

    # (4) Zernio lists the account; the browser comes back.
    list!(listed, %{
      "_id" => @ref,
      "platform" => "linkedin",
      "profileId" => %{"_id" => @vendor_profile_id},
      "username" => @username,
      "isActive" => true
    })

    child = land(user, @return_url)
    first_return = drain_requests()
    assert [{"GET", "/api/v1/accounts", _, _}] = first_return

    assert [%Account{provider_account_ref: @ref, status: "connected"} = account] =
             Repo.all(Account)

    assert account.profile_id == created.id
    assert has_element?(child, row(account) <> " [data-state='connected']")

    # (5) Remove: the inline panel names the account and its consequence.
    child = goto(child, "connections")
    drain_requests()

    child
    |> element(row(account) <> " [data-role='social-account-remove']")
    |> render_click()

    sentence = row(account) <> " [data-role='social-remove-sentence']"
    assert has_element?(child, sentence, "LINKEDIN")
    assert has_element?(child, sentence, @username)
    assert has_element?(child, sentence, "No scheduled posts are affected.")
    assert drain_requests() == []

    child
    |> element(row(account) <> " [data-role='social-remove-confirm']")
    |> render_click()

    {child, account, first_connect ++ first_return}
  end

  # Step 6: "+ Add account", linkedin again, and a return with the SAME ref.
  defp reconnect_same_ref(user, child, removed) do
    assert [{"GET", "/api/v1/connect/linkedin", %{"profileId" => @vendor_profile_id}, _}] =
             add_linkedin(child)

    child = land(user, @return_url)
    assert [{"GET", "/api/v1/accounts", _, _}] = drain_requests()

    [live] = Repo.all(from(a in Account, where: is_nil(a.archived_at)))
    assert live.id != removed.id
    assert live.provider_account_ref == @ref
    assert live.status == "connected"
    assert has_element?(child, row(live) <> " [data-state='connected']")
    refute has_element?(child, row(removed))
    assert notice?(child, "connected")

    rows = Repo.all(from(a in Account, where: a.provider_account_ref == ^@ref))
    assert length(rows) == 2
    assert [_one_live] = Enum.filter(rows, &is_nil(&1.archived_at))
    assert Repo.get!(Account, removed.id).archived_at
  end

  test "a human removes a connected LinkedIn account and reconnects the same Zernio account",
       %{user: user} do
    listed = stub_zernio(200)
    {child, account, before} = connect_then_open_remove(user, listed)

    # Nothing before the key was saved: the first request is the profile POST.
    assert [{"POST", "/api/v1/profiles", _, _} | _] = before
    assert Enum.all?(before, fn {_, _, _, auth} -> auth == ["Bearer #{@fake_key}"] end)

    # The removal told Zernio exactly once, with the Vault key.
    assert [{"DELETE", "/api/v1/accounts/" <> @ref, _, ["Bearer #{@fake_key}"]}] =
             drain_requests()

    refute has_element?(child, row(account))
    assert notice?(child, "Removed LINKEDIN #{@username}.")
    refute has_element?(child, "[data-role='social-notice'].alert-warning")
    assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, account.id)

    # (6) Same ref again: a new row connects.
    reconnect_same_ref(user, child, account)
    assert drain_requests() == []
  end

  test "Zernio answering 503 to the disconnect: the row is still removed, with a warning",
       %{user: user} do
    listed = stub_zernio(503)
    {child, account, _before} = connect_then_open_remove(user, listed)

    assert [{"DELETE", "/api/v1/accounts/" <> @ref, _, ["Bearer #{@fake_key}"]} | _] =
             drain_requests()

    refute has_element?(child, row(account))

    assert has_element?(
             child,
             "[data-role='social-notice'].alert-warning",
             "Removed here. Zernio didn't confirm the disconnect, so check the account in Zernio."
           )

    assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, account.id)
    assert Repo.all(from(a in Account, where: is_nil(a.archived_at))) == []

    reconnect_same_ref(user, child, account)
  end

  describe "source guard" do
    # Reads THIS file's setup block. A setup that writes social rows or the
    # key directly would make the tests above prove nothing about the UI.
    test "setup creates no social rows and writes no secrets" do
      source = File.read!(__ENV__.file)

      [setup_block] =
        Regex.run(~r/^  setup do\n(.*?)^  end\n/ms, source, capture: :all_but_first)

      # Non-vacuity: this really is the setup block above.
      assert setup_block =~ "Secrets.zernio_key_status() == :not_set"
      assert setup_block =~ "OrgMembership"

      for forbidden <- [
            "Social.",
            "update_profile",
            "put_zernio_api_key",
            "Vault.put",
            "provider_account_ref",
            "provider_profile_ref",
            "SocialFixtures"
          ] do
        refute setup_block =~ forbidden,
               "setup must not use #{forbidden}: drive the LiveView instead"
      end

      refute setup_block =~ ~r/insert(_all)?!?\(\s*"social_/
      refute setup_block =~ ~r/%(Profile|Account|Post)\{/
    end
  end
end
