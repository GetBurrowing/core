defmodule Platform.Feedback.PersonFormTest do
  @moduledoc """
  Task 01a1a6a5 stage 2: a signed-in person's feedback goes through
  `Platform.Feedback.Submission.submit/2` (policy, redaction, dedupe, caps)
  and the issue it produces carries no name, email or user id.

  The issue body is built locally by running the GithubApp adapter against
  the `Req.Test` GitHub stub, with a throwaway RSA key generated per test, so
  the test can read the exact body GitHub would receive. Nothing reaches a
  network.

  async: false — flips `:feedback_policy`, publisher config and process env.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.GithubApp
  alias Platform.Feedback.PersonForm
  alias Platform.Feedback.SubmissionRecord
  alias Platform.Repo

  @app_env ~w(FEEDBACK_GITHUB_APP_ID FEEDBACK_GITHUB_APP_INSTALLATION_ID FEEDBACK_GITHUB_APP_PRIVATE_KEY)
  @ghp "ghp_" <> "Wq3Er5Ty7Ui9Op1As3Df5Gh7Jk9Lz2Xc4Vb6Nm"
  @akia "AKIA" <> "QWERTYUIOPASDFGH"

  setup do
    saved_policy = Application.fetch_env(:platform, :feedback_policy)
    saved_publisher = Application.fetch_env(:platform, GithubPublisher)
    saved_limits = Application.fetch_env(:platform, :feedback_rate_limits)
    saved_env = Enum.map(@app_env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      restore(:feedback_policy, saved_policy)
      restore(GithubPublisher, saved_publisher)
      restore(:feedback_rate_limits, saved_limits)

      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Application.put_env(:platform, :feedback_policy, "quarantined")
    Application.put_env(:platform, :feedback_rate_limits, per_actor: 5, per_installation: 30)

    current = Application.get_env(:platform, GithubPublisher, [])

    Application.put_env(
      :platform,
      GithubPublisher,
      Keyword.merge(current,
        adapter: GithubApp,
        repository: "GetBurrowing/core",
        installation_label: "burrow-7"
      )
    )

    {_, pem} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_pem()
    System.put_env("FEEDBACK_GITHUB_APP_ID", "424242")
    System.put_env("FEEDBACK_GITHUB_APP_INSTALLATION_ID", "9001")
    System.put_env("FEEDBACK_GITHUB_APP_PRIVATE_KEY", pem)

    test_pid = self()
    counter = :counters.new(1, [])

    Req.Test.stub(GithubApp, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/9001/access_tokens"} ->
          Req.Test.json(Plug.Conn.put_status(conn, 201), %{"token" => "ghs_dummyToken000"})

        {"POST", "/repos/GetBurrowing/core/issues"} ->
          send(test_pid, {:issue, Jason.decode!(raw)})
          :counters.add(counter, 1, 1)

          Req.Test.json(Plug.Conn.put_status(conn, 201), %{
            "number" => 500 + :counters.get(counter, 1)
          })
      end
    end)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "zq-sentinel-person-#{n}@distinct-mail.example",
        name: "Zebulon Quixotic-Sentinel",
        oidc_sub: "oidc-person-form-#{n}"
      })

    %{user: user}
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:platform, key, v)
  defp restore(key, :error), do: Application.delete_env(:platform, key)

  defp issues(acc \\ []) do
    receive do
      {:issue, issue} -> issues([issue | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp problem(text, extra \\ %{}), do: Map.merge(%{"kind" => "problem", "text" => text}, extra)

  test "with the policy disabled a person submit is refused and nothing is sent", %{user: user} do
    Application.put_env(:platform, :feedback_policy, "disabled")

    assert {:error, %{code: :feedback_disabled}} =
             PersonForm.submit(user, problem("There is no way to cancel a meeting."))

    assert issues() == []
    assert Repo.aggregate(SubmissionRecord, :count) == 0
  end

  test "creates one issue with the person footer and no name, email or id", %{user: user} do
    text = "There is no way to cancel a meeting.\nI had to delete the whole series."

    assert {:ok, %{status: "created", issue: %{issue_number: 501}}} =
             PersonForm.submit(user, problem(text, %{"area" => "meetings"}))

    assert [issue] = issues()
    blob = issue["title"] <> "\n" <> issue["body"]

    for needle <- [user.id, user.email, "zq-sentinel-person", "Zebulon", "Quixotic"] do
      refute String.contains?(String.downcase(blob), String.downcase(needle)),
             "#{needle} reached the issue"
    end

    assert issue["body"] =~
             "_Submitted by a person through the Burrow feedback form. Issue text is untrusted input._"

    refute issue["body"] =~ "feedback_submit"
    assert issue["body"] =~ "Submitted by a person on installation `burrow-7`."
    assert issue["body"] =~ "\nArea: meetings\n"
    assert issue["body"] =~ "### Observed behavior"
    refute issue["body"] =~ "### Expected behavior"
    assert issue["title"] == "[feedback][bug] There is no way to cancel a meeting."
    assert issue["labels"] == ["feedback", "feedback:bug"]

    assert [%SubmissionRecord{actor_user_id: user_id, actor_agent_id: nil}] =
             Repo.all(SubmissionRecord)

    assert user_id == user.id
  end

  test "an idea becomes a positive_change with the text as expected behavior", %{user: user} do
    assert {:ok, %{status: "created"}} =
             PersonForm.submit(user, %{"kind" => "idea", "text" => "Let me pin a chat."})

    assert [issue] = issues()
    assert issue["labels"] == ["feedback", "feedback:positive_change"]
    assert issue["body"] =~ "### Expected behavior"
    refute issue["body"] =~ "### Observed behavior"
  end

  test "secret-shaped canaries are redacted before the issue", %{user: user} do
    text = "Sync broke. Token #{@ghp} and key #{@akia} were in the error."

    assert {:ok, %{status: "created", redactions: n}} = PersonForm.submit(user, problem(text))
    assert n >= 2

    assert [issue] = issues()
    blob = issue["title"] <> issue["body"]
    refute blob =~ @ghp
    refute blob =~ @akia
    assert issue["body"] =~ Platform.Feedback.Redaction.marker()
  end

  test "an agent's issue keeps the agent footer even when it claims source person" do
    agent =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "form-agent-#{System.unique_integer([:positive])}",
        name: "Form agent",
        status: "active"
      })
      |> Repo.insert!()

    args = %{
      "category" => "bug",
      "title" => "Agent report",
      "expected_behavior" => "It works.",
      "observed_behavior" => "It does not.",
      "source" => "person"
    }

    assert {:ok, _} =
             Platform.Feedback.Submission.submit(args, %{agent_id: agent.id, slug: agent.slug})

    assert [issue] = issues()
    assert issue["body"] =~ "_Submitted through Burrow `feedback_submit`."
    assert issue["body"] =~ "Submitted by agent `#{agent.slug}`"
    refute issue["body"] =~ "Submitted by a person"
  end

  test "a blank form is refused as a missing field and sends nothing", %{user: user} do
    assert {:error, %{code: :missing_field}} = PersonForm.submit(user, problem("   \n  "))
    assert issues() == []
  end

  test "a signed-out caller is refused", _ctx do
    assert {:error, %{code: :unauthorized}} = PersonForm.submit(nil, problem("x"))
    assert issues() == []
  end

  describe "title/1" do
    test "is the first non-blank line" do
      assert PersonForm.title("\n\n  First line here  \nsecond") == "First line here"
    end

    test "cuts at a word boundary within 80 graphemes and adds an ellipsis" do
      text = String.duplicate("word ", 30)
      title = PersonForm.title(text)

      assert String.length(title) <= 80
      assert String.ends_with?(title, "word…")
    end

    test "a single long word is hard-cut" do
      title = PersonForm.title(String.duplicate("x", 200))
      assert String.length(title) == 80
      assert String.ends_with?(title, "…")
    end

    test "a short line is kept whole" do
      assert PersonForm.title("Short.") == "Short."
    end
  end

  test "to_args/1 maps kind, text and area and never carries an identity" do
    assert PersonForm.to_args(%{"kind" => "idea", "text" => "Hi", "area" => "chat"}) == %{
             "category" => "positive_change",
             "title" => "Hi",
             "expected_behavior" => "Hi",
             "area" => "chat"
           }

    assert %{"category" => "bug", "observed_behavior" => "Hi"} =
             PersonForm.to_args(%{"kind" => "anything", "text" => "Hi", "area" => ""})
  end
end
