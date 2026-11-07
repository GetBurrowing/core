defmodule Platform.Feedback.BrokerRoundTripTest do
  @moduledoc """
  Task 01a1a6a5 stage 3: install -> broker -> GitHub in one BEAM, no
  network.

  The install leg is a real `Platform.Feedback.Submission.submit/2` on the
  Broker adapter. Its `Req.Test` plug forwards the request into the REAL
  broker controller through `Phoenix.ConnTest.dispatch/5` with this node
  switched to broker mode (GithubApp adapter, GitHub stubbed), then switches
  back.

  Two nodes share one test database here, but in production each has its
  own `feedback_submissions` table. The stub therefore swaps the rows: while
  the broker leg runs only the broker's rows exist, and while the install
  leg runs only the install's. Without that the broker would see the
  install's own pending reservation and answer `in_flight`.

  async: false — swaps publisher config, broker mode and process env.
  """
  use Platform.DataCase, async: false

  import Platform.FeedbackBrokerFixtures

  alias Platform.Agents.Agent
  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Feedback.Submission
  alias Platform.Feedback.SubmissionRecord

  @fields ~w(id fingerprint category actor_agent_id actor_user_id status external_repository
             external_issue_number error_code published_at attempted_at inserted_at updated_at)a

  setup do
    test_pid = self()
    broker_node!(test_pid)

    broker_publisher = Application.get_env(:platform, GithubPublisher)

    install_publisher =
      broker_publisher
      |> Keyword.merge(
        adapter: Broker,
        broker_url: "https://broker.test/api/feedback-broker/v1",
        installation_label: "acme-install"
      )

    Application.put_env(:platform, GithubPublisher, install_publisher)
    broker_rows = :ets.new(:broker_rows, [:set, :public])
    :ets.insert(broker_rows, {:rows, []})

    Req.Test.stub(Broker, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:install_request, conn.method, conn.request_path, conn.req_headers, raw})

      # Swap to the broker node: its config, and its own rows only.
      install_rows = take_rows()
      [{:rows, saved}] = :ets.lookup(broker_rows, :rows)
      put_rows(saved)
      Application.put_env(:platform, GithubPublisher, broker_publisher)

      response =
        try do
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            PlatformWeb.Endpoint,
            String.downcase(conn.method) |> String.to_atom(),
            conn.request_path,
            raw
          )
        after
          :ets.insert(broker_rows, {:rows, take_rows()})
          put_rows(install_rows)
          Application.put_env(:platform, GithubPublisher, install_publisher)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(response.status, response.resp_body)
    end)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "round-trip-#{System.unique_integer([:positive])}",
        name: "Round trip agent",
        status: "active"
      })
      |> Repo.insert!()

    %{agent: agent, broker_rows: broker_rows}
  end

  defp take_rows do
    rows = Repo.all(SubmissionRecord)
    Repo.delete_all(SubmissionRecord)
    rows
  end

  defp put_rows(rows) do
    Repo.insert_all(SubmissionRecord, Enum.map(rows, &Map.take(&1, @fields)))
  end

  defp args do
    %{
      "category" => "bug",
      "title" => "Round trip: meeting cannot be cancelled",
      "expected_behavior" => "A cancel button.",
      "observed_behavior" => "No way to cancel; token ghp_" <> String.duplicate("Q", 36)
    }
  end

  test "an install submit creates one issue via the real broker; a repeat is a duplicate",
       %{agent: agent, broker_rows: broker_rows} do
    actor = %{agent_id: agent.id, slug: agent.slug}

    assert {:ok, %{status: "created", issue: issue}} = Submission.submit(args(), actor)

    assert issue == %{
             repository: "GetBurrowing/core",
             issue_number: 701,
             url: "https://github.com/GetBurrowing/core/issues/701"
           }

    assert_received {:install_request, "POST", "/api/feedback-broker/v1/issues", headers, raw}
    refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)

    assert raw |> Jason.decode!() |> Map.keys() |> Enum.sort() ==
             ~w(fingerprint installation repository sharing_install_id submission)

    assert [gh] = github_issues()
    refute gh["body"] =~ "ghp_QQQQ"
    assert gh["body"] =~ "Submitted by agent `acme-install` on installation `acme-install`."

    # Each node holds its own published row.
    assert [%SubmissionRecord{status: "published", actor_agent_id: install_actor}] =
             Repo.all(SubmissionRecord)

    assert install_actor == agent.id
    [{:rows, [broker_row]}] = :ets.lookup(broker_rows, :rows)
    assert broker_row.status == "published"
    assert broker_row.external_issue_number == 701
    refute broker_row.actor_agent_id == agent.id

    # A repeat is answered from the install's own row: no second request.
    assert {:ok, %{status: "duplicate", issue: ^issue}} = Submission.submit(args(), actor)
    refute_received {:install_request, _, _, _, _}
    assert github_issues() == []
  end

  test "a second install with the same text gets the broker's duplicate", %{agent: agent} do
    actor = %{agent_id: agent.id, slug: agent.slug}
    assert {:ok, %{status: "created", issue: issue}} = Submission.submit(args(), actor)

    # A fresh install: none of the first install's rows.
    Repo.delete_all(SubmissionRecord)

    assert {:ok, %{status: "created", issue: ^issue}} = Submission.submit(args(), actor)
    assert [_one_github_post] = github_issues()
  end
end
