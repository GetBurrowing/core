defmodule PlatformWeb.FeedbackBrokerControllerTest do
  @moduledoc """
  Task 01a1a6a5 stage 3: the feedback broker's HTTP surface,
  `POST /api/feedback-broker/v1/issues` and
  `GET /api/feedback-broker/v1/issues/:fingerprint`, through the real
  endpoint (so `PlatformWeb.Plugs.RewriteRemoteIp` runs) against the
  `Req.Test` GitHub stub. No request leaves the test.

  async: false — flips broker mode, the policy, proxy trust, publisher config
  and process env, and raises the global Logger level for the log checks.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Platform.FeedbackBrokerFixtures

  alias PlatformWeb.Plugs.FeedbackBrokerGate

  @path "/api/feedback-broker/v1/issues"
  @ghp "ghp_" <> "Mn3Bv5Cx7Zl9Kj1Hg3Fd5Sa7Po9Iu1Yt3Re5Wq"

  setup do
    broker_node!(self())
    :ok
  end

  defp post_json(conn, body, path \\ @path) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp capture_debug(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  describe "mode off" do
    setup do
      Application.put_env(:platform, :feedback_broker_server, enabled: false)
      :ok
    end

    test "both routes are 404 and nothing is published", %{conn: conn} do
      conn1 = post_json(conn, wire(submission()))
      assert json_response(conn1, 404) == %{"error" => "not_found"}

      conn2 = get(build_conn(), @path <> "/" <> String.duplicate("a", 64))
      assert json_response(conn2, 404) == %{"error" => "not_found"}

      assert github_issues() == []
    end

    test "the gate itself halts with 404" do
      conn =
        Phoenix.ConnTest.build_conn(:post, @path, "")
        |> FeedbackBrokerGate.call(FeedbackBrokerGate.init([]))

      assert conn.halted
      assert conn.status == 404
    end
  end

  test "the gate passes a request through when broker mode is on" do
    conn =
      Phoenix.ConnTest.build_conn(:post, @path, "")
      |> FeedbackBrokerGate.call(FeedbackBrokerGate.init([]))

    refute conn.halted
  end

  test "creates one fenced, redacted issue; the response is exactly the identity", %{conn: conn} do
    sub = submission(%{"observed_behavior" => "Token #{@ghp} @octocat"})

    conn = post_json(conn, wire(sub))
    body = json_response(conn, 201)

    assert body == %{"repository" => "GetBurrowing/core", "issue_number" => 701}
    assert [issue] = github_issues()
    refute Jason.encode!(issue) =~ @ghp
    assert issue["body"] =~ "```text\nToken [REDACTED] @octocat\n```"
    refute conn.resp_body =~ "GITHUB-RESPONSE-SENTINEL"
    refute conn.resp_body =~ "evil.example"
  end

  test "a duplicate answers 200 with the same identity and no second POST" do
    first = build_conn() |> post_json(wire(submission())) |> json_response(201)

    second =
      build_conn()
      |> put_req_header("x-forwarded-for", "198.51.100.4")
      |> post_json(wire(submission()))
      |> json_response(200)

    assert first == second
    assert [_] = github_issues()
  end

  test "a hostile top-level body, title and unknown keys are ignored", %{conn: conn} do
    body =
      wire(submission(), %{
        "body" => "TOP-BODY-SENTINEL",
        "title" => "TOP-TITLE-SENTINEL",
        "extra" => %{"nested" => "EXTRA-SENTINEL"}
      })

    conn = post_json(conn, body)
    assert json_response(conn, 201)
    assert [issue] = github_issues()
    blob = Jason.encode!(issue)
    refute blob =~ "TOP-BODY-SENTINEL"
    refute blob =~ "TOP-TITLE-SENTINEL"
    refute blob =~ "EXTRA-SENTINEL"
  end

  test "a repository mismatch is a 422 with the code only and no call", %{conn: conn} do
    conn = post_json(conn, wire(submission(), %{"repository" => "attacker/repo"}))
    assert json_response(conn, 422) == %{"error" => "repository_mismatch"}
    assert github_issues() == []
  end

  test "a validation error is a 422 with the code only, never the input", %{conn: conn} do
    conn =
      post_json(conn, wire(submission(%{"category" => "ECHO-SENTINEL-#{@ghp}"})))

    assert json_response(conn, 422) == %{"error" => "invalid_category"}
    refute conn.resp_body =~ "ECHO-SENTINEL"
    assert github_issues() == []
  end

  test "a body that is not an object is a 422", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@path, Jason.encode!([1, 2, 3]))

    assert json_response(conn, 422) == %{"error" => "invalid_arguments"}
  end

  test "a broker without a GitHub App answers 502 with the bounded code", %{conn: conn} do
    System.delete_env("FEEDBACK_GITHUB_APP_PRIVATE_KEY")

    conn = post_json(conn, wire(submission()))
    assert json_response(conn, 502) == %{"error" => "publisher_not_configured"}
  end

  describe "per-IP rate limit" do
    setup do
      Application.put_env(:platform, :feedback_broker_server, enabled: true, rate_per_hour: 2)
      :ok
    end

    test "N+1 requests from one IP get 429 with retry-after" do
      for n <- 1..2 do
        build_conn() |> post_json(wire(submission(%{"title" => "r#{n}"}))) |> json_response(201)
      end

      conn = build_conn() |> post_json(wire(submission(%{"title" => "r3"})))
      assert json_response(conn, 429) == %{"error" => "rate_limited"}
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) > 0
      assert length(github_issues()) == 2
    end

    test "under TRUST_PROXY_HEADERS two forwarded IPs get separate buckets" do
      Application.put_env(:platform, :trust_proxy_headers, true)

      send_from = fn ip, title ->
        build_conn()
        |> put_req_header("x-forwarded-for", ip)
        |> post_json(wire(submission(%{"title" => title})))
      end

      for n <- 1..2, do: assert(send_from.("203.0.113.10", "a#{n}").status == 201)
      assert send_from.("203.0.113.10", "a3").status == 429

      for n <- 1..2, do: assert(send_from.("203.0.113.20", "b#{n}").status == 201)
      assert send_from.("203.0.113.20", "b3").status == 429
    end
  end

  test "GET by fingerprint answers the identity or 404" do
    build_conn() |> post_json(wire(submission())) |> json_response(201)
    [record] = Platform.Repo.all(Platform.Feedback.SubmissionRecord)

    assert build_conn()
           |> get(@path <> "/" <> record.fingerprint)
           |> json_response(200) == %{"repository" => "GetBurrowing/core", "issue_number" => 701}

    assert build_conn()
           |> get(@path <> "/" <> String.duplicate("e", 64))
           |> json_response(404) == %{"error" => "not_found"}
  end

  test "nothing a caller sends reaches the log, even at debug", %{conn: conn} do
    log =
      capture_debug(fn ->
        conn
        |> put_req_header("x-canary-header", "HEADER-SENTINEL")
        |> post_json(wire(submission(%{"observed_behavior" => "LOG-SENTINEL #{@ghp}"})))
        |> json_response(201)
      end)

    # Positive control: the request did log, at the publisher's one line.
    assert log =~ "feedback.publisher"
    refute log =~ @ghp
    refute log =~ "LOG-SENTINEL"
    refute log =~ "HEADER-SENTINEL"
    refute log =~ "acme-install"
  end
end
