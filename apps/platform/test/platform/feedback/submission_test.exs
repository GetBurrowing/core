defmodule Platform.Feedback.SubmissionTest do
  @moduledoc """
  Task 01a11ec3 stage 2: the `feedback.submit` boundary against a fake
  broker (`Req.Test` stub `Platform.Feedback.GithubPublisher.Broker`). Every
  broker call is sent to the test process as `{:broker, method, path, headers,
  body}`, so "no external call" is an assertion about messages, not a mock
  expectation.

  Written before the implementation: against the unfixed base every test here
  fails with `UndefinedFunctionError` on `Platform.Feedback.Submission` (or
  the policy module), which is the failure the stage records.

  async: false — flips `:feedback_policy` and `:feedback_rate_limits`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Feedback.Submission
  alias Platform.Repo

  @broker Platform.Feedback.GithubPublisher.Broker

  setup do
    restore = save_env([:feedback_policy, :feedback_rate_limits])
    on_exit(restore)

    Application.put_env(:platform, :feedback_policy, "quarantined")
    Application.put_env(:platform, :feedback_rate_limits, per_actor: 3, per_installation: 5)

    test_pid = self()
    counter = :counters.new(1, [])

    Req.Test.stub(@broker, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:broker, conn.method, conn.request_path, conn.req_headers, raw})
      :counters.add(counter, 1, 1)
      number = 1000 + :counters.get(counter, 1)

      Req.Test.json(Plug.Conn.put_status(conn, 201), %{
        "repository" => "Startup-Suite/core",
        "issue_number" => number,
        "url" => "https://evil.example/phish",
        "token" => "ghs_leakedTokenFromBrokerShouldNeverSurface0000"
      })
    end)

    %{agent: agent!("reporter"), other: agent!("other-reporter")}
  end

  defp save_env(keys) do
    saved = Enum.map(keys, &{&1, Application.fetch_env(:platform, &1)})

    fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:platform, key, value)
        {key, :error} -> Application.delete_env(:platform, key)
      end)
    end
  end

  defp agent!(label) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{label}-#{System.unique_integer([:positive, :monotonic])}",
      name: "Agent #{label}",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp actor(agent), do: %{agent_id: agent.id, slug: agent.slug}

  defp valid(overrides \\ %{}) do
    Map.merge(
      %{
        "category" => "bug",
        "title" => "Task board drops the stage badge after promotion",
        "expected_behavior" => "The stage badge stays visible after a task is promoted.",
        "observed_behavior" => "The badge disappears until the page is reloaded.",
        "reproduction_steps" => "1. Promote a task. 2. Look at the board.",
        "version_environment" => "Suite 2026.10 / Chrome 130"
      },
      overrides
    )
  end

  defp submission_count, do: Repo.aggregate(from(r in "feedback_submissions"), :count)

  defp broker_bodies do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:broker, "POST", _path, _headers, raw} -> receive_all([Jason.decode!(raw) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "capability" do
    test "a disabled installation refuses before any external call", %{agent: agent} do
      Application.put_env(:platform, :feedback_policy, "disabled")

      assert {:error, %{code: :feedback_disabled}} = Submission.submit(valid(), actor(agent))
      refute_received {:broker, _, _, _, _}
      assert submission_count() == 0
    end

    test "an unknown policy value fails closed", %{agent: agent} do
      Application.put_env(:platform, :feedback_policy, "enabled")

      assert {:error, %{code: :feedback_disabled}} = Submission.submit(valid(), actor(agent))
      refute_received {:broker, _, _, _, _}
    end

    test "an anonymous caller is refused", _ctx do
      assert {:error, %{code: :unauthorized}} = Submission.submit(valid(), nil)
      refute_received {:broker, _, _, _, _}
    end
  end

  describe "idempotency" do
    test "a retried valid submission creates exactly one issue", %{agent: agent} do
      assert {:ok, first} = Submission.submit(valid(), actor(agent))
      assert first.status == "created"

      assert first.issue == %{
               repository: "Startup-Suite/core",
               issue_number: 1001,
               url: "https://github.com/Startup-Suite/core/issues/1001"
             }

      assert {:ok, second} = Submission.submit(valid(), actor(agent))
      assert second.status == "duplicate"
      assert second.issue == first.issue
      assert second.fingerprint == first.fingerprint

      assert length(broker_bodies()) == 1
      assert submission_count() == 1
    end

    test "case and whitespace differences are the same report", %{agent: agent} do
      assert {:ok, %{status: "created"}} = Submission.submit(valid(), actor(agent))

      noisy =
        valid(%{
          "title" => "  TASK board   drops the stage badge\nafter promotion ",
          "category" => " BUG "
        })

      assert {:ok, %{status: "duplicate"}} = Submission.submit(noisy, actor(agent))
      assert length(broker_bodies()) == 1
    end

    test "a different agent submitting the same report gets the existing issue", ctx do
      assert {:ok, %{status: "created", issue: issue}} =
               Submission.submit(valid(), actor(ctx.agent))

      assert {:ok, %{status: "duplicate", issue: ^issue}} =
               Submission.submit(valid(), actor(ctx.other))

      assert length(broker_bodies()) == 1
    end

    test "the broker receives the fingerprint as its idempotency key", %{agent: agent} do
      assert {:ok, %{fingerprint: fp}} = Submission.submit(valid(), actor(agent))
      assert_received {:broker, "POST", "/issues", headers, _raw}
      assert {"idempotency-key", fp} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)
    end

    test "a stale pending reservation is reconciled before publishing again", %{agent: agent} do
      {:ok, sanitized, _} = Submission.normalize(valid())
      fp = Submission.fingerprint(sanitized)
      stale = DateTime.add(DateTime.utc_now(), -3_600, :second)

      Repo.insert_all("feedback_submissions", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          fingerprint: fp,
          category: "bug",
          status: "pending",
          attempted_at: stale,
          inserted_at: stale,
          updated_at: stale
        }
      ])

      # The earlier attempt DID create the issue; the broker knows it.
      Req.Test.stub(@broker, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{"repository" => "Startup-Suite/core", "issue_number" => 77})

          "POST" ->
            Req.Test.json(Plug.Conn.put_status(conn, 201), %{
              "repository" => "Startup-Suite/core",
              "issue_number" => 78
            })
        end
      end)

      assert {:ok, %{status: "duplicate", issue: %{issue_number: 77}}} =
               Submission.submit(valid(), actor(agent))

      assert submission_count() == 1
    end

    test "a fresh pending reservation is refused as in flight, not published twice",
         %{agent: agent} do
      {:ok, sanitized, _} = Submission.normalize(valid())
      now = DateTime.utc_now()

      Repo.insert_all("feedback_submissions", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          fingerprint: Submission.fingerprint(sanitized),
          category: "bug",
          status: "pending",
          attempted_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      assert {:error, %{code: :in_flight}} = Submission.submit(valid(), actor(agent))
      refute_received {:broker, _, _, _, _}
    end
  end

  describe "allowlist, diagnostics and redaction" do
    test "fields outside the allowlist never reach the broker", %{agent: agent} do
      args =
        valid(%{
          "logs" => "LOG-SENTINEL full application log",
          "session" => "SESSION-SENTINEL transcript",
          "environment" => "ENV-SENTINEL PATH=/usr/bin",
          "labels" => ["security", "p0"]
        })

      assert {:ok, result} = Submission.submit(args, actor(agent))
      assert result.ignored_fields == ["environment", "labels", "logs", "session"]

      [body] = broker_bodies()
      raw = Jason.encode!(body)
      refute raw =~ "LOG-SENTINEL"
      refute raw =~ "SESSION-SENTINEL"
      refute raw =~ "ENV-SENTINEL"
      assert body["labels"] == ["feedback", "feedback:bug"]
    end

    test "diagnostics are absent unless explicitly opted in and scoped", %{agent: agent} do
      unscoped = valid(%{"diagnostics" => "DIAG-SENTINEL stack trace pasted without scope"})
      assert {:ok, result} = Submission.submit(unscoped, actor(agent))
      assert result.diagnostics_included == false
      assert result.diagnostics_dropped == true

      not_opted =
        valid(%{
          "title" => "Second report",
          "diagnostics" => %{"scope" => "stack_trace", "content" => "DIAG-SENTINEL two"}
        })

      assert {:ok, %{diagnostics_included: false}} = Submission.submit(not_opted, actor(agent))

      bad_scope =
        valid(%{
          "title" => "Third report",
          "diagnostics" => %{
            "include" => true,
            "scope" => "everything",
            "content" => "DIAG-SENTINEL"
          }
        })

      assert {:ok, %{diagnostics_included: false}} = Submission.submit(bad_scope, actor(agent))

      for body <- broker_bodies(), do: refute(body["body"] =~ "DIAG-SENTINEL")
    end

    test "opted-in, scoped diagnostics are included and labelled with their scope",
         %{agent: agent} do
      args =
        valid(%{
          "diagnostics" => %{
            "include" => true,
            "scope" => "error_message",
            "content" => "SCOPED-DIAG ** (ArgumentError) bad argument"
          }
        })

      assert {:ok, %{diagnostics_included: true}} = Submission.submit(args, actor(agent))
      [body] = broker_bodies()
      assert body["body"] =~ "Diagnostics (scope: error_message)"
      assert body["body"] =~ "SCOPED-DIAG"
    end

    test "secrets and credentials are redacted before the external call", %{agent: agent} do
      args =
        valid(%{
          "observed_behavior" =>
            "Failed with token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123 and " <>
              "AKIAABCDEFGHIJKLMNOP, Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345, " <>
              "password=hunter2-sentinel, postgres://suite:dbpass-sentinel@db.internal/suite, " <>
              "mailto ops-sentinel@example.com",
          "version_environment" =>
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAsentinel\n-----END RSA PRIVATE KEY-----"
        })

      assert {:ok, result} = Submission.submit(args, actor(agent))
      assert result.redactions >= 7

      [body] = broker_bodies()
      raw = Jason.encode!(body)

      for secret <- [
            "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123",
            "AKIAABCDEFGHIJKLMNOP",
            "abcdefghijklmnopqrstuvwxyz012345",
            "hunter2-sentinel",
            "dbpass-sentinel",
            "ops-sentinel@example.com",
            "MIIEpAIBAAKCAQEAsentinel"
          ] do
        refute raw =~ secret, "#{secret} reached the broker"
      end

      assert body["body"] =~ "[REDACTED]"
    end

    test "the result carries no broker-supplied text", %{agent: agent} do
      assert {:ok, result} = Submission.submit(valid(), actor(agent))
      encoded = inspect(result)
      refute encoded =~ "evil.example"
      refute encoded =~ "ghs_leakedTokenFromBroker"
    end
  end

  describe "validation" do
    test "category is an enum", %{agent: agent} do
      assert {:error, %{code: :invalid_category}} =
               Submission.submit(valid(%{"category" => "feature"}), actor(agent))

      refute_received {:broker, _, _, _, _}
    end

    test "required fields are required", %{agent: agent} do
      for field <- ~w(title expected_behavior observed_behavior) do
        assert {:error, %{code: :missing_field, field: ^field}} =
                 Submission.submit(Map.delete(valid(), field), actor(agent))

        assert {:error, %{code: :missing_field}} =
                 Submission.submit(Map.put(valid(), field, "   "), actor(agent))
      end

      refute_received {:broker, _, _, _, _}
    end

    test "per-field length limits", %{agent: agent} do
      long = String.duplicate("a", Submission.limits().title + 1)

      assert {:error, %{code: :field_too_long, field: "title"}} =
               Submission.submit(valid(%{"title" => long}), actor(agent))

      assert {:error, %{code: :invalid_field}} =
               Submission.submit(valid(%{"title" => %{"nested" => "x"}}), actor(agent))

      refute_received {:broker, _, _, _, _}
    end

    test "the aggregate length limit", %{agent: agent} do
      args =
        valid(%{
          "expected_behavior" => String.duplicate("e", 2_000),
          "observed_behavior" => String.duplicate("o", 4_000),
          "reproduction_steps" => String.duplicate("r", 4_000),
          "version_environment" => String.duplicate("v", 1_000),
          "diagnostics" => %{
            "include" => true,
            "scope" => "stack_trace",
            "content" => String.duplicate("d", 1_500)
          }
        })

      assert {:error, %{code: :submission_too_long}} = Submission.submit(args, actor(agent))
      refute_received {:broker, _, _, _, _}
    end
  end

  describe "rate limits" do
    test "distinct submissions past the per-agent limit are refused; duplicates are not",
         %{agent: agent} do
      for n <- 1..3 do
        assert {:ok, %{status: "created"}} =
                 Submission.submit(valid(%{"title" => "Report #{n}"}), actor(agent))
      end

      assert {:error, %{code: :rate_limited, retry_after_seconds: secs}} =
               Submission.submit(valid(%{"title" => "Report 4"}), actor(agent))

      assert secs > 0

      # The duplicate of report 1 still answers with its issue.
      assert {:ok, %{status: "duplicate"}} =
               Submission.submit(valid(%{"title" => "Report 1"}), actor(agent))

      assert length(broker_bodies()) == 3
    end

    test "the installation-wide limit spans agents", ctx do
      for n <- 1..3,
          do: {:ok, _} = Submission.submit(valid(%{"title" => "A#{n}"}), actor(ctx.agent))

      for n <- 1..2,
          do: {:ok, _} = Submission.submit(valid(%{"title" => "B#{n}"}), actor(ctx.other))

      assert {:error, %{code: :rate_limited}} =
               Submission.submit(valid(%{"title" => "B3"}), actor(ctx.other))

      assert length(broker_bodies()) == 5
    end
  end

  describe "publisher failure" do
    test "a refused publication is recorded and an identical retry publishes once",
         %{agent: agent} do
      Req.Test.stub(@broker, fn conn ->
        Plug.Conn.send_resp(conn, 503, "BROKER-ERROR-BODY ghs_shouldNotSurface")
      end)

      assert {:error, %{code: :publisher_unavailable} = err} =
               Submission.submit(valid(), actor(agent))

      refute inspect(err) =~ "BROKER-ERROR-BODY"
      refute inspect(err) =~ "ghs_shouldNotSurface"

      test_pid = self()

      Req.Test.stub(@broker, fn conn ->
        send(test_pid, {:broker_retry, conn.method})

        Req.Test.json(Plug.Conn.put_status(conn, 201), %{
          "repository" => "Startup-Suite/core",
          "issue_number" => 42
        })
      end)

      assert {:ok, %{status: "created", issue: %{issue_number: 42}}} =
               Submission.submit(valid(), actor(agent))

      assert {:ok, %{status: "duplicate", issue: %{issue_number: 42}}} =
               Submission.submit(valid(), actor(agent))

      assert_received {:broker_retry, "POST"}
      refute_received {:broker_retry, _}
      assert submission_count() == 1
    end

    test "a broker naming a different repository is a bad response", %{agent: agent} do
      Req.Test.stub(@broker, fn conn ->
        Req.Test.json(Plug.Conn.put_status(conn, 201), %{
          "repository" => "attacker/elsewhere",
          "issue_number" => 1
        })
      end)

      assert {:error, %{code: :publisher_bad_response}} =
               Submission.submit(valid(), actor(agent))
    end
  end
end
