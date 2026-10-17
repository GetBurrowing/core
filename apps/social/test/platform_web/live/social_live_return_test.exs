defmodule PlatformWeb.SocialLiveReturnTest do
  @moduledoc """
  The OAuth return leg in the Social tab (task 01a14807, stage 3): the vendor
  sends the browser back to `/m/social?...`, core's `/m/<prefix>` host forwards
  the query to the nested SocialLive as untrusted strings, and SocialLive
  completes the connection through `Platform.Social.complete_connect/4`.

  Driven through `live(conn, "/m/social?...")` and
  `find_live_child(view, "ext-page-social")`. Zernio traffic goes to a
  `Req.Test` stub ONLY, which reports every request to the test process.
  `async: false`: the publisher config and the install-level key are global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Profile, Secrets}
  alias Platform.Social.Publisher.Zernio

  @key "zernio-live-return-test-key-not-real"
  @profile_ref "zprof_live_return_1"
  @other_ref "zprof_other_org_1"
  @account_ref "zacct_li_1"

  setup do
    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Return Brand #{unique()}"})
    approver = make_approver!(org_id, profile, user!())
    bystander = member!(user!(), org_id)
    profile = link!(profile, @profile_ref)
    {:ok, pending} = Social.create_account(org_id, profile, %{platform: "linkedin"})

    other_org = org_id!()
    {:ok, other} = Social.create_profile(other_org, %{name: "Other Org Brand #{unique()}"})
    other = link!(other, @other_ref)
    {:ok, other_pending} = Social.create_account(other_org, other, %{platform: "linkedin"})

    {:ok, _} = Secrets.put_zernio_api_key(@key, approver)

    %{
      org_id: org_id,
      profile: profile,
      approver: approver,
      bystander: bystander,
      pending: pending,
      other_pending: other_pending
    }
  end

  defp link!(profile, ref) do
    profile
    |> Ecto.Changeset.change(provider_profile_ref: ref)
    |> Repo.update!()
  end

  defp stub_accounts(entries) do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      send(test, {:zernio_request, conn.method, conn.request_path})

      conn
      |> Plug.Conn.put_status(200)
      |> Req.Test.json(%{"accounts" => entries, "hasAnalyticsAccess" => false})
    end)
  end

  defp entry(ref, platform, profile_ref \\ @profile_ref) do
    %{
      "_id" => ref,
      "platform" => platform,
      "profileId" => %{"_id" => profile_ref, "name" => "Brand"},
      "username" => "brand-#{ref}",
      "isActive" => true
    }
  end

  defp requests(acc \\ []) do
    receive do
      {:zernio_request, method, path} -> requests([{method, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp success_url(account_ref \\ @account_ref, profile_ref \\ @profile_ref) do
    "/m/social?connected=linkedin&profileId=#{profile_ref}&accountId=#{account_ref}" <>
      "&username=spoofed-handle"
  end

  defp land(conn, user, url) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, url)
    find_live_child(view, "ext-page-social")
  end

  defp row(account), do: "#accounts-#{account.id}"
  defp notice?(child, text), do: has_element?(child, "[data-role='social-notice']", text)

  defp reload(%Account{id: id}), do: Repo.get!(Account, id)

  defp accounts(profile),
    do: Repo.all(from(a in Account, where: a.profile_id == ^profile.id))

  test "a success return for a listed account connects the row with exactly one GET",
       %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin")])

    child = land(conn, ctx.approver, success_url())

    # Checked FIRST: the static render must send nothing, so the vendor is
    # asked exactly once (by the connected mount).
    assert requests() == [{"GET", "/api/v1/accounts"}]
    assert has_element?(child, row(ctx.pending) <> " [data-state='connected']", "Connected")
    assert notice?(child, "LinkedIn connected as brand-#{@account_ref}.")
    # The handle came from the vendor list, never from the URL.
    refute render(child) =~ "spoofed-handle"

    row = reload(ctx.pending)
    assert row.provider_account_ref == @account_ref
    assert row.status == "connected"
  end

  test "a repeat of the same URL is already connected: one row, no write",
       %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin")])
    _ = land(conn, ctx.approver, success_url())
    before = reload(ctx.pending)
    assert before.status == "connected"
    _ = requests()

    child = land(build_conn(), ctx.approver, success_url())

    assert notice?(child, "LinkedIn is already connected.")
    assert [%Account{} = only] = accounts(ctx.profile)
    assert only.id == ctx.pending.id
    assert reload(ctx.pending).updated_at == before.updated_at
    assert requests() == [{"GET", "/api/v1/accounts"}]
  end

  test "an unlisted accountId writes nothing and says Zernio didn't confirm it",
       %{conn: conn} = ctx do
    stub_accounts([entry("zacct_someone_else", "linkedin")])

    child = land(conn, ctx.approver, success_url("zacct_not_listed"))

    assert notice?(
             child,
             "Zernio didn't confirm that account for #{ctx.profile.name}. Nothing changed."
           )

    assert %Account{status: nil, provider_account_ref: nil} = reload(ctx.pending)
    assert has_element?(child, row(ctx.pending) <> " [data-role='social-account-connect']")
    assert requests() == [{"GET", "/api/v1/accounts"}]
  end

  test "another org's profileId sends no request and matches no profile",
       %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin", @other_ref)])

    child = land(conn, ctx.approver, success_url(@account_ref, @other_ref))

    assert notice?(child, "That connection doesn't match a profile you can manage.")
    assert requests() == []
    assert %Account{status: nil, provider_account_ref: nil} = reload(ctx.other_pending)
    assert %Account{status: nil} = reload(ctx.pending)
  end

  test "a malformed accountId sends no request and writes nothing", %{conn: conn} = ctx do
    stub_accounts([entry("bad id!", "linkedin")])

    child =
      land(
        conn,
        ctx.approver,
        "/m/social?connected=linkedin&profileId=#{@profile_ref}&accountId=bad%20id!"
      )

    assert notice?(child, "That connection couldn't be read. Nothing changed.")
    assert requests() == []
    assert %Account{status: nil, provider_account_ref: nil} = reload(ctx.pending)
  end

  test "an error return shows the code, sends no request and leaves Connect",
       %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin")])

    child =
      land(
        conn,
        ctx.approver,
        "/m/social?error=oauth_denied&platform=linkedin&profileId=#{@profile_ref}" <>
          "&error_message=%3Cscript%3E"
      )

    assert notice?(child, "The account wasn't connected (oauth_denied). Try Connect again.")

    assert has_element?(
             child,
             row(ctx.pending) <> " [data-role='social-account-connect']",
             "Connect"
           )

    assert requests() == []
    assert %Account{status: nil} = reload(ctx.pending)
  end

  test "an error code that fails the shape check is left out of the copy", %{conn: conn} = ctx do
    stub_accounts([])
    child = land(conn, ctx.approver, "/m/social?error=Bad%20Code!&platform=linkedin")

    assert notice?(child, "The account wasn't connected. Try Connect again.")
    refute render(child) =~ "Bad Code"
    assert requests() == []
  end

  test "a non-approver human of the same org is refused with no request",
       %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin")])

    child = land(conn, ctx.bystander, success_url())

    assert notice?(child, "Only an approver of this profile can change it.")
    assert requests() == []
    assert %Account{status: nil, provider_account_ref: nil} = reload(ctx.pending)
  end

  test "an agent session is a no-op: no request, no notice", %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin")])
    agent = agent!()

    {:ok, child, _html} =
      live_isolated(conn, PlatformWeb.SocialLive,
        session: %{
          "user_id" => agent.id,
          "query" => %{
            "connected" => "linkedin",
            "profileId" => @profile_ref,
            "accountId" => @account_ref
          }
        }
      )

    refute has_element?(child, "[data-role='social-notice']")
    assert requests() == []
    assert %Account{status: nil, provider_account_ref: nil} = reload(ctx.pending)
  end

  test "an archived approver is a no-op: no request, no notice", %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin")])
    archived = make_approver!(ctx.org_id, Repo.get!(Profile, ctx.profile.id), user!())

    archived
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, child, _html} =
      live_isolated(conn, PlatformWeb.SocialLive,
        session: %{
          "user_id" => archived.id,
          "query" => %{
            "connected" => "linkedin",
            "profileId" => @profile_ref,
            "accountId" => @account_ref
          }
        }
      )

    refute has_element?(child, "[data-role='social-notice']")
    assert requests() == []
    assert %Account{status: nil, provider_account_ref: nil} = reload(ctx.pending)
  end

  test "POSITIVE CONTROL: the approver on the identical URL connects", %{conn: conn} = ctx do
    stub_accounts([entry(@account_ref, "linkedin")])

    child = land(conn, ctx.approver, success_url())

    assert has_element?(child, row(ctx.pending) <> " [data-state='connected']")
    assert %Account{status: "connected", provider_account_ref: @account_ref} = reload(ctx.pending)
    assert requests() == [{"GET", "/api/v1/accounts"}]
    assert %Profile{provider_profile_ref: @profile_ref} = Repo.get!(Profile, ctx.profile.id)
  end
end
