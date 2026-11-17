defmodule Platform.FeedbackBrokerFixtures do
  @moduledoc """
  Test helpers for the feedback broker (task 01a1a6a5 stage 3).

  `broker_node!/1` turns the test node into a broker: broker mode on, policy
  quarantined, the GithubApp adapter on `GetBurrowing/core`, a THROWAWAY RSA
  key generated here in the process environment, and the `Req.Test` GitHub
  stub. Every GitHub call is sent to the test process as
  `{:github_issue, decoded_json}` (issue creates) so "exactly one POST" is an
  assertion about messages. Nothing reaches a network. Everything it changes
  is restored on exit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.GithubApp

  @app_env ~w(FEEDBACK_GITHUB_APP_ID FEEDBACK_GITHUB_APP_INSTALLATION_ID FEEDBACK_GITHUB_APP_PRIVATE_KEY)
  @app_keys [
    :feedback_policy,
    :feedback_broker_server,
    :feedback_rate_limits,
    :trust_proxy_headers,
    :trusted_proxies,
    GithubPublisher
  ]

  @doc "Save and restore the app env and process env the broker tests touch."
  def isolate_broker_env! do
    saved = Enum.map(@app_keys, &{&1, Application.fetch_env(:platform, &1)})
    saved_env = Enum.map(@app_env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:platform, key, value)
        {key, :error} -> Application.delete_env(:platform, key)
      end)

      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Platform.Feedback.BrokerRateLimit.reset()
    end)

    Platform.Feedback.BrokerRateLimit.reset()
    :ok
  end

  @doc "Put the publisher into the broker-side GithubApp configuration."
  def github_app_publisher! do
    current = Application.get_env(:platform, GithubPublisher, [])

    Application.put_env(
      :platform,
      GithubPublisher,
      Keyword.merge(current,
        adapter: GithubApp,
        repository: "GetBurrowing/core",
        installation_label: "hosted-broker"
      )
    )
  end

  @doc "Turn this node into a broker and stub GitHub; see the moduledoc."
  def broker_node!(test_pid, opts \\ []) do
    isolate_broker_env!()
    Application.put_env(:platform, :feedback_policy, "quarantined")

    Application.put_env(:platform, :feedback_broker_server,
      enabled: true,
      rate_per_hour: Keyword.get(opts, :rate_per_hour, 100)
    )

    Application.put_env(:platform, :feedback_rate_limits, per_actor: 20, per_installation: 100)
    github_app_publisher!()

    {_, pem} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_pem()
    System.put_env("FEEDBACK_GITHUB_APP_ID", "424242")
    System.put_env("FEEDBACK_GITHUB_APP_INSTALLATION_ID", "9001")
    System.put_env("FEEDBACK_GITHUB_APP_PRIVATE_KEY", pem)

    stub_github!(test_pid)
    :ok
  end

  @doc "Stub GitHub: a dummy token, and issues numbered from 701."
  def stub_github!(test_pid) do
    counter = :counters.new(1, [])

    Req.Test.stub(GithubApp, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/9001/access_tokens"} ->
          Req.Test.json(Plug.Conn.put_status(conn, 201), %{"token" => "ghs_dummyBrokerToken0"})

        {"POST", "/repos/GetBurrowing/core/issues"} ->
          send(test_pid, {:github_issue, Jason.decode!(raw)})
          :counters.add(counter, 1, 1)

          Req.Test.json(Plug.Conn.put_status(conn, 201), %{
            "number" => 700 + :counters.get(counter, 1),
            "html_url" => "https://evil.example/not-used",
            "body" => "GITHUB-RESPONSE-SENTINEL"
          })

        {method, path} ->
          send(test_pid, {:github_other, method, path})
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  @doc "Drain the `{:github_issue, json}` messages."
  def github_issues(acc \\ []) do
    receive do
      {:github_issue, issue} -> github_issues([issue | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "An install's broker request body for `submission`."
  def wire(submission, overrides \\ %{}) do
    Map.merge(
      %{
        "repository" => "GetBurrowing/core",
        "fingerprint" => String.duplicate("0", 64),
        "installation" => "acme-install",
        "submission" => submission
      },
      overrides
    )
  end

  @doc "A valid agent submission in wire shape."
  def submission(overrides \\ %{}) do
    Map.merge(
      %{
        "category" => "bug",
        "source" => "agent",
        "title" => "Calendar drops the reminder",
        "expected_behavior" => "The reminder fires.",
        "observed_behavior" => "Nothing happens."
      },
      overrides
    )
  end
end
