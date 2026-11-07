defmodule PlatformWeb.FeedbackInboxLiveTest do
  @moduledoc """
  Task 01a1b678 stage 4: the broker host's feedback inbox, end to end.

    * installs: two installs sending the same report count 2; the same
      install twice counts 1 (`Platform.Feedback.Inbox`, fed by
      `BrokerServer.create/2` from the wire's `sharing_install_id`);
    * the page: 404 on a normal install, rows sorted by install count,
      mono count, Open / "Shipped · notice sent";
    * shipped: a signed `issues` `closed` as `completed` marks the request
      shipped and `GET /issues/:fingerprint` says so; not-planned does not;
      `reopened` clears it.

  async: false: broker mode, policy and publisher config live in app env.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.FeedbackBrokerFixtures
  import Platform.InsightFixtures, only: [person!: 1]
  import Platform.TenancyFixtures, only: [root_admin!: 0]

  alias Platform.Feedback.BrokerServer
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Feedback.Inbox
  alias Platform.Feedback.Inbox.InstallReport
  alias Platform.Feedback.SubmissionRecord
  alias PlatformWeb.FeedbackInboxLive.NotFoundError

  @ip {203, 0, 113, 7}
  @other_ip {198, 51, 100, 9}
  @install_a "6f1c3b0e-6a43-4b5e-9a3f-2b7f2f0d1a01"
  @install_b "9a2d4c1f-7b54-4c6f-8b40-3c8f3a1e2b02"

  setup do
    broker_node!(self())
    Req.Test.stub(Broker, fn conn -> Req.Test.json(conn, %{}) end)
    :ok
  end

  defp send_report(install_id, ip, overrides \\ %{}) do
    BrokerServer.create(
      wire(submission(overrides), %{"sharing_install_id" => install_id}),
      ip
    )
  end

  defp conn_for(conn, user), do: init_test_session(conn, %{"current_user_id" => user.id})

  describe "distinct installs" do
    test "two installs sending the same report count 2" do
      assert {:ok, "created", identity} = send_report(@install_a, @ip)
      assert {:ok, "duplicate", ^identity} = send_report(@install_b, @other_ip)

      assert [%{installs: 2, title: "Calendar drops the reminder", shipped: false}] = Inbox.list()
      assert [_] = github_issues()
    end

    test "the same install twice counts 1" do
      assert {:ok, "created", _} = send_report(@install_a, @ip)
      assert {:ok, "duplicate", _} = send_report(@install_a, @other_ip)

      assert [%{installs: 1}] = Inbox.list()
      assert Platform.Repo.aggregate(InstallReport, :count) == 1
    end

    test "a missing or malformed install id records the request but counts no install" do
      assert {:ok, "created", _} = send_report(nil, @ip)
      assert {:ok, "duplicate", _} = send_report("not-a-uuid", @ip)
      assert {:ok, "duplicate", _} = send_report(%{"evil" => 1}, @ip)

      assert [%{installs: 0}] = Inbox.list()
    end

    test "the install's adapter puts its own sharing id on the wire" do
      Application.put_env(
        :platform,
        Platform.Feedback.GithubPublisher,
        Keyword.merge(Application.get_env(:platform, Platform.Feedback.GithubPublisher),
          adapter: Broker
        )
      )

      test_pid = self()

      Req.Test.stub(Broker, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:wire, Jason.decode!(raw)})

        Req.Test.json(Plug.Conn.put_status(conn, 201), %{
          "repository" => "x/y",
          "issue_number" => 9
        })
      end)

      assert {:ok, _} =
               Broker.create_issue(%{},
                 fingerprint: String.duplicate("a", 64),
                 repository: "GetBurrowing/core",
                 submission: submission()
               )

      assert_received {:wire, body}
      assert body["sharing_install_id"] == to_string(Platform.Sharing.get().sharing_install_id)
    end
  end

  describe "the page" do
    test "404s on a normal install, even for an org admin", %{conn: conn} do
      Application.put_env(:platform, :feedback_broker_server, enabled: false)

      assert_raise NotFoundError, fn ->
        conn |> conn_for(root_admin!()) |> live(~p"/admin/feedback-inbox")
      end

      assert {404, _, _} =
               assert_error_sent(404, fn ->
                 conn |> conn_for(root_admin!()) |> get(~p"/admin/feedback-inbox")
               end)
    end

    test "is refused for a member on the broker host", %{conn: conn} do
      result = conn |> conn_for(person!("member")) |> live(~p"/admin/feedback-inbox")
      assert {:error, {:redirect, %{to: "/access-denied?module=admin"}}} = result
      refute PlatformWeb.FeedbackInboxLive.visible?(person!("member"))
    end

    test "an admin on the broker host sees requests sorted by installs, with status",
         %{conn: conn} do
      {:ok, "created", _} = send_report(@install_a, @ip, %{"title" => "Voice tab stays silent"})

      for install <- [@install_a, @install_b, Ecto.UUID.generate()] do
        {:ok, _, _} = send_report(install, @other_ip, %{"title" => "Let agents join late"})
      end

      %{repository: repo, issue_number: number} =
        Inbox.list() |> Enum.find(&(&1.title == "Voice tab stays silent"))

      assert 1 = Inbox.mark_shipped(repo, number, true)

      {:ok, view, _html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/feedback-inbox")

      titles =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role=feedback-inbox-title]")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.trim/1)

      assert titles == ["[Bug] Let agents join late", "[Bug] Voice tab stays silent"] or
               titles == ["Let agents join late", "Voice tab stays silent"]

      assert has_element?(view, "[data-role=feedback-inbox-head]", "Installs")

      assert has_element?(
               view,
               "[data-role=feedback-inbox-installs].font-mono.text-right.shrink-0",
               "3"
             )

      assert has_element?(view, "[data-role=feedback-inbox-title].min-w-0.truncate")

      assert has_element?(
               view,
               "[data-role=feedback-inbox-status] .text-info",
               "Shipped · notice sent"
             )

      assert has_element?(view, "[data-role=feedback-inbox-status]", "Open")
    end
  end

  describe "shipped" do
    defp issue_event(conn, action, number, reason) do
      conn
      |> Plug.Conn.put_req_header("x-github-event", "issues")
      |> signed_github_post("/api/webhooks/github", %{
        "action" => action,
        "issue" => %{"number" => number, "state_reason" => reason, "title" => "t", "body" => "b"},
        "repository" => %{"full_name" => "GetBurrowing/core"}
      })
    end

    test "closed as completed marks it shipped, and GET /issues/:fingerprint says so",
         %{conn: conn} do
      {:ok, "created", %{issue_number: number}} = send_report(@install_a, @ip)
      [%SubmissionRecord{fingerprint: fp}] = Platform.Repo.all(SubmissionRecord)

      assert %{"shipped" => false} =
               conn |> get("/api/feedback-broker/v1/issues/#{fp}") |> json_response(200)

      not_planned = issue_event(build_conn(), "closed", number, "not_planned")
      assert %{"status" => "ignored"} = json_response(not_planned, 200)
      refute Inbox.shipped?(fp)

      done = issue_event(build_conn(), "closed", number, "completed")
      assert %{"status" => "processed", "shipped" => 1} = json_response(done, 200)
      assert Inbox.shipped?(fp)

      assert %{"shipped" => true, "issue_number" => ^number} =
               build_conn() |> get("/api/feedback-broker/v1/issues/#{fp}") |> json_response(200)

      _ = issue_event(build_conn(), "reopened", number, nil)
      refute Inbox.shipped?(fp)
    end

    test "an unsigned close, or one on a node that is not the broker host, ships nothing",
         %{conn: conn} do
      {:ok, "created", %{issue_number: number}} = send_report(@install_a, @ip)
      [%SubmissionRecord{fingerprint: fp}] = Platform.Repo.all(SubmissionRecord)

      _ =
        conn
        |> Plug.Conn.put_req_header("x-github-event", "issues")
        |> unsigned_github_post("/api/webhooks/github", %{
          "action" => "closed",
          "issue" => %{"number" => number, "state_reason" => "completed"},
          "repository" => %{"full_name" => "GetBurrowing/core"}
        })

      refute Inbox.shipped?(fp)

      Application.put_env(:platform, :feedback_broker_server, enabled: false)
      _ = issue_event(build_conn(), "closed", number, "completed")
      refute Inbox.shipped?(fp)
    end
  end
end
