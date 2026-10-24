defmodule PlatformWeb.SocialZeroDataQueueAcceptanceTest do
  @moduledoc """
  The Queue from zero social data (Social authoring 5/11, task 01a16c50):
  create a profile, connect a stubbed LinkedIn, an agent draft arrives, a
  human approves it from the Queue, and it is published to the stub.

  Same discipline as `social_zero_data_return_acceptance_test.exs`: setup
  creates ONLY core rows (a live human member of one live org, a chat
  channel in that org with the human in it, and an agent pinned to the org)
  and asserts there are no social profiles, accounts or Zernio key.
  Everything social after that is a LiveView event, a `live/2` mount of a
  URL, or the agent's own tool call through `ToolArguments.dispatch/3`.
  A source guard reads this file's setup block and refutes any Social write.

  No request leaves the BEAM (`config :social, :zernio_req_options`).
  `async: false`: the publisher config and the install-level Vault row are
  global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social.{Account, Post, PostEvent, Profile, Secrets}
  alias Platform.Social.Publisher.Zernio

  @auth_url "https://vendor.example.test/oauth"
  @vendor_profile_id "zprof_queue_1"
  @fake_key "zk_test_queue_1"

  setup do
    assert Repo.aggregate(from(p in "social_profiles"), :count) == 0
    assert Repo.aggregate(from(a in "social_accounts"), :count) == 0
    assert Secrets.zernio_key_status() == :not_set

    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.tenant_org_id("zero-queue-org-#{n}")

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "zero-queue-#{n}@example.com",
        name: "Zero Queue #{n}",
        oidc_sub: "zero-queue-#{n}"
      })
      |> Repo.insert!()

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })
    |> Repo.insert!()

    {:ok, channel} =
      Platform.Chat.create_space(%{
        name: "Approvals #{n}",
        slug: "approvals-#{n}",
        kind: "channel",
        org_id: org_id
      })

    {:ok, _} =
      Platform.Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "zero-queue-agent-#{n}",
        name: "Drafter #{n}",
        metadata: %{"org_id" => org_id}
      })

    %{user: user, org_id: org_id, channel: channel, agent: agent}
  end

  # Logs every Zernio request to the test process and answers the calls this
  # flow makes: profile create, connect, the account list, and the post.
  defp stub_zernio do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:zernio_request, conn.method, conn.request_path, conn.query_params, raw})

      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/profiles"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"message" => "created", "profile" => %{"_id" => @vendor_profile_id}})

        {"GET", "/api/v1/connect/" <> _} ->
          Req.Test.json(conn, %{"authUrl" => @auth_url})

        {"GET", "/api/v1/accounts"} ->
          Req.Test.json(conn, %{
            "accounts" => [
              %{
                "_id" => "zacc_li_q",
                "platform" => "linkedin",
                "profileId" => %{"_id" => @vendor_profile_id},
                "username" => "zeroqueue",
                "isActive" => true
              }
            ],
            "hasAnalyticsAccess" => false
          })

        {"POST", "/api/v1/posts"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"post" => %{"_id" => "zp_q1"}})

        _ ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:zernio_request, method, path, params, body} ->
        drain_requests([{method, path, params, body} | acc])
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

  test "zero data: profile, stubbed LinkedIn, an agent draft, approve from Queue, published to the stub",
       %{user: user, channel: channel, agent: agent} do
    stub_zernio()

    # (1) The empty state's create form.
    child = land(user, "/m/social")

    child
    |> form("#social-create-form", profile: %{name: "Zero Queue Show", home_url: ""})
    |> render_submit()

    assert [%Profile{} = profile] = Repo.all(Profile)
    assert has_element?(child, "[data-role='social-empty']", "Connect an account to start.")

    # (2) Settings: the key, and the approval channel.
    child = goto(child, "settings")

    child
    |> form("[data-role='social-zernio-key-form']", zernio_key: %{api_key: @fake_key})
    |> render_submit()

    child
    |> form("#social-settings-form", profile: %{space_id: channel.id})
    |> render_submit()

    assert Repo.get!(Profile, profile.id).space_id == channel.id

    # (3) Connections: + Add account, LinkedIn, out to the vendor and back.
    child = goto(child, "connections")
    child |> element("[data-role='social-add-account']") |> render_click()
    child |> form("#social-add-account-form", platform: "linkedin") |> render_submit()
    assert_redirect(child, @auth_url)

    child =
      land(
        user,
        "/m/social?connected=linkedin&profileId=#{@vendor_profile_id}" <>
          "&accountId=zacc_li_q&username=zeroqueue"
      )

    assert [%Account{status: "connected", provider_account_ref: "zacc_li_q"} = account] =
             Repo.all(Account)

    _ = drain_requests()

    # (4) The agent drafts through its own tool.
    assert {:ok, %{posts: [%{id: post_id}]}} =
             ToolArguments.dispatch(
               "social_draft_create",
               %{
                 "profile_id" => profile.id,
                 "account_ids" => [account.id],
                 "body" => "Episode one is live.",
                 "schedule_reason" => "Posted while the episode is fresh."
               },
               %{agent_id: agent.id}
             )

    assert Repo.get!(Post, post_id).status == "needs_approval"

    # (5) The Queue shows it on one card; the human approves.
    child = goto(child, "queue")

    assert has_element?(
             child,
             "#queue-#{post_id} [data-role='social-preview'][data-platform='linkedin']"
           )

    assert has_element?(
             child,
             "#queue-#{post_id} [data-role='queue-reason']",
             "Posted while the episode is fresh."
           )

    assert has_element?(
             child,
             "#queue-card-idea-#{post_id} [data-role='queue-agent']",
             agent.name
           )

    child |> element("#queue-#{post_id} [data-role='queue-approve']") |> render_click()

    # (6) Published to the stub, once, for the connected account.
    assert [{"POST", "/api/v1/posts", _, body}] =
             Enum.filter(drain_requests(), &match?({"POST", "/api/v1/posts", _, _}, &1))

    body = Jason.decode!(body)
    assert body["content"] =~ "Episode one is live."
    assert [%{"platform" => "linkedin", "accountId" => "zacc_li_q"}] = body["platforms"]

    post = Repo.get!(Post, post_id)
    assert post.status in Post.approved_statuses()
    assert post.external_id == "zp_q1"
    assert post.approved_by_user_id == user.id

    assert Repo.exists?(
             from(e in PostEvent,
               where: e.post_id == ^post_id and e.action == "approved" and e.actor_kind == "human"
             )
           )

    assert has_element?(child, "#queue-#{post_id} [data-role='queue-status']", "Approved by")
  end

  describe "source guard" do
    test "setup creates no social rows and writes no secrets" do
      source = File.read!(__ENV__.file)

      [setup_block] =
        Regex.run(~r/^  setup do\n(.*?)^  end\n/ms, source, capture: :all_but_first)

      assert setup_block =~ "Secrets.zernio_key_status() == :not_set"
      assert setup_block =~ "OrgMembership"

      for forbidden <- [
            "Social.",
            "update_profile",
            "put_zernio_api_key",
            "Vault.put",
            "provider_account_ref",
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
