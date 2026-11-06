defmodule Platform.Feedback.BrokerServerTest do
  @moduledoc """
  Task 01a1a6a5 stage 3: `Platform.Feedback.BrokerServer`, the hosted half of
  the feedback broker, against the `Req.Test` GitHub stub
  (`Platform.FeedbackBrokerFixtures`). No request leaves the test.

  async: false — flips broker mode, the policy, publisher config and process
  env.
  """
  use Platform.DataCase, async: false

  import Platform.FeedbackBrokerFixtures

  alias Platform.Feedback.BrokerServer
  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Feedback.SubmissionRecord

  @ip {203, 0, 113, 7}
  @other_ip {198, 51, 100, 9}
  @ghp "ghp_" <> "Hj4Kl6Zx8Cv0Bn2Mq4We6Rt8Yu0Io2Pa4Sd6Fg"

  setup do
    broker_node!(self())
    test_pid = self()

    Req.Test.stub(Broker, fn conn ->
      send(test_pid, :broker_called) && Req.Test.json(conn, %{})
    end)

    :ok
  end

  test "mode off refuses with not_found and makes no call" do
    Application.put_env(:platform, :feedback_broker_server, enabled: false)

    assert {:error, :not_found} = BrokerServer.create(wire(submission()), @ip)
    assert {:error, :not_found} = BrokerServer.find(String.duplicate("a", 64))
    assert github_issues() == []
    assert Repo.aggregate(SubmissionRecord, :count) == 0
  end

  test "a broker on the Broker adapter refuses instead of forwarding (no loop)" do
    current = Application.get_env(:platform, GithubPublisher)
    Application.put_env(:platform, GithubPublisher, Keyword.put(current, :adapter, Broker))

    assert {:error, :publisher_not_configured} = BrokerServer.create(wire(submission()), @ip)
    refute_received :broker_called
    assert github_issues() == []
    assert Repo.aggregate(SubmissionRecord, :count) == 0
  end

  test "a repository other than the configured one is refused before any call" do
    for repo <- ["attacker/repo", "GetBurrowing/core-archive", nil, 42] do
      assert {:error, :repository_mismatch} =
               BrokerServer.create(wire(submission(), %{"repository" => repo}), @ip)
    end

    assert {:ok, "created", _} =
             BrokerServer.create(wire(submission(), %{"repository" => "getburrowing/CORE"}), @ip)

    assert [_] = github_issues()
  end

  test "creates exactly one fenced, redacted issue and answers only the identity" do
    sub = submission(%{"observed_behavior" => "Leaked #{@ghp} in the log."})

    assert {:ok, "created", identity} = BrokerServer.create(wire(sub), @ip)
    assert identity == %{repository: "GetBurrowing/core", issue_number: 701}

    assert [issue] = github_issues()
    refute issue["body"] =~ @ghp
    assert issue["body"] =~ "[REDACTED]"
    assert issue["body"] =~ "```text\nLeaked [REDACTED] in the log.\n```"
    assert issue["body"] =~ "Submitted by agent `acme-install` on installation `acme-install`."
    assert issue["labels"] == ["feedback", "feedback:bug"]
  end

  test "a hostile request cannot inject its own markdown, body, title or keys" do
    hostile =
      submission(%{
        "title" => "Hostile #{@ghp}",
        "observed_behavior" =>
          "``````\n@octocat [click](https://evil.example) AKIA" <>
            "ABCDEFGHIJKLMNOP Bearer abcdefghijklmnopqrstuvwxyz0123456789",
        "labels" => ["security", "p0"],
        "evil_key" => "EVIL-KEY-SENTINEL"
      })

    body =
      wire(hostile, %{
        "body" => "TOP-LEVEL-BODY-SENTINEL #{@ghp}",
        "title" => "TOP-LEVEL-TITLE-SENTINEL",
        "labels" => ["pwned"]
      })

    assert {:ok, "created", _} = BrokerServer.create(body, @ip)
    assert [issue] = github_issues()
    blob = Jason.encode!(issue)

    for sentinel <- [
          @ghp,
          "AKIAABCDEFGHIJKLMNOP",
          "abcdefghijklmnopqrstuvwxyz0123456789",
          "TOP-LEVEL-BODY-SENTINEL",
          "TOP-LEVEL-TITLE-SENTINEL",
          "EVIL-KEY-SENTINEL",
          "pwned",
          "security"
        ] do
      refute blob =~ sentinel, "#{sentinel} reached GitHub"
    end

    # The six-backtick run is fenced by seven, so the mention and the link
    # sit inside a code block.
    assert issue["body"] =~ "```````text\n``````\n@octocat [click](https://evil.example)"
    assert issue["labels"] == ["feedback", "feedback:bug"]
  end

  test "the same submission from two IPs makes one GitHub POST and one number" do
    assert {:ok, "created", first} = BrokerServer.create(wire(submission()), @ip)
    assert {:ok, "duplicate", ^first} = BrokerServer.create(wire(submission()), @other_ip)
    assert [_] = github_issues()
  end

  test "a person source hint keeps the person footer and rule; anything else is agent" do
    person = submission(%{"source" => "person"}) |> Map.delete("expected_behavior")

    assert {:ok, "created", _} = BrokerServer.create(wire(person), @ip)
    assert [issue] = github_issues()
    assert issue["body"] =~ "Submitted by a person through the Burrow feedback form."
    assert issue["body"] =~ "Submitted by a person on installation `acme-install`."

    weird = submission(%{"source" => "admin", "title" => "weird source"})
    assert {:ok, "created", _} = BrokerServer.create(wire(weird), @ip)
    assert [issue] = github_issues()
    assert issue["body"] =~ "_Submitted through Burrow `feedback_submit`."
  end

  test "each IP is its own actor for the per-actor cap" do
    Application.put_env(:platform, :feedback_rate_limits, per_actor: 1, per_installation: 100)

    assert {:ok, "created", _} = BrokerServer.create(wire(submission()), @ip)

    assert {:error, :rate_limited} =
             BrokerServer.create(wire(submission(%{"title" => "second"})), @ip)

    assert {:ok, "created", _} =
             BrokerServer.create(wire(submission(%{"title" => "second"})), @other_ip)

    assert BrokerServer.ip_actor_id(@ip) == BrokerServer.ip_actor_id(@ip)
    refute BrokerServer.ip_actor_id(@ip) == BrokerServer.ip_actor_id(@other_ip)
    assert {:ok, _} = Ecto.UUID.cast(BrokerServer.ip_actor_id(@ip))
  end

  test "validation errors are bounded codes" do
    assert {:error, :invalid_arguments} =
             BrokerServer.create(wire(nil), @ip)

    assert {:error, :missing_field} =
             BrokerServer.create(wire(Map.delete(submission(), "title")), @ip)

    assert {:error, :invalid_category} =
             BrokerServer.create(wire(submission(%{"category" => "x"})), @ip)

    assert github_issues() == []
  end

  test "find/1 answers the published identity or nil" do
    assert {:ok, "created", identity} = BrokerServer.create(wire(submission()), @ip)
    [%SubmissionRecord{fingerprint: fingerprint}] = Repo.all(SubmissionRecord)

    assert {:ok, ^identity} = BrokerServer.find(fingerprint)
    assert {:ok, nil} = BrokerServer.find(String.duplicate("f", 64))
    assert {:ok, nil} = BrokerServer.find("not-a-fingerprint")
  end
end
