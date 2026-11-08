defmodule Platform.Feedback.SubmissionTest do
  @moduledoc """
  Task 01a11ec3 stage 2: the `feedback_submit` boundary against a fake
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
        "repository" => "GetBurrowing/core",
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
               repository: "GetBurrowing/core",
               issue_number: 1001,
               url: "https://github.com/GetBurrowing/core/issues/1001"
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
            Req.Test.json(conn, %{"repository" => "GetBurrowing/core", "issue_number" => 77})

          "POST" ->
            Req.Test.json(Plug.Conn.put_status(conn, 201), %{
              "repository" => "GetBurrowing/core",
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

      assert Map.keys(body) |> Enum.sort() ==
               ~w(fingerprint installation repository sharing_install_id submission)

      assert Map.keys(body["submission"]) |> Enum.sort() ==
               ~w(category expected_behavior observed_behavior reproduction_steps source title version_environment)
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

      for body <- broker_bodies() do
        refute Jason.encode!(body) =~ "DIAG-SENTINEL"
        refute Map.has_key?(body["submission"], "diagnostics")
      end
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

      assert body["submission"]["diagnostics"] == %{
               "include" => true,
               "scope" => "error_message",
               "content" => "SCOPED-DIAG ** (ArgumentError) bad argument"
             }
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

      assert body["submission"]["observed_behavior"] =~ "[REDACTED]"
      assert body["submission"]["version_environment"] =~ "[REDACTED]"
    end

    test "the result carries no broker-supplied text", %{agent: agent} do
      assert {:ok, result} = Submission.submit(valid(), actor(agent))
      encoded = inspect(result)
      refute encoded =~ "evil.example"
      refute encoded =~ "ghs_leakedTokenFromBroker"
    end
  end

  describe "broker wire (task 01a1a6a5 stage 1)" do
    # `ghp_` + 36 alphanumerics: a GitHub personal-token shape.
    @canary "ghp_" <> "Zq7Lm2Xc9Vb4Nn1Kk8Jj3Hh6Gg5Ff0Dd2Ss4Aa"

    test "sends only repository, fingerprint, installation and the sanitized submission",
         %{agent: agent} do
      args = valid(%{"observed_behavior" => "Push failed with #{@canary} in the output."})

      assert {:ok, %{status: "created", fingerprint: fingerprint}} =
               Submission.submit(args, actor(agent))

      assert_received {:broker, "POST", "/issues", headers, raw}
      body = Jason.decode!(raw)

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(fingerprint installation repository sharing_install_id submission)

      refute Map.has_key?(body, "body")
      refute Map.has_key?(body, "title")
      refute Map.has_key?(body, "labels")
      assert body["repository"] == "GetBurrowing/core"
      assert body["fingerprint"] == fingerprint
      assert body["installation"] == nil
      assert {"idempotency-key", fingerprint} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)

      refute raw =~ @canary
      assert body["submission"]["observed_behavior"] =~ Platform.Feedback.Redaction.marker()

      {:ok, sanitized, _report} = Submission.normalize(args)
      assert body["submission"] == Submission.wire_fields(sanitized)
    end

    test "carries the configured installation label", %{agent: agent} do
      publisher = Platform.Feedback.GithubPublisher
      saved = Application.get_env(:platform, publisher, [])
      on_exit(fn -> Application.put_env(:platform, publisher, saved) end)

      Application.put_env(
        :platform,
        publisher,
        Keyword.put(saved, :installation_label, "burrow-7")
      )

      assert {:ok, _} = Submission.submit(valid(), actor(agent))
      assert [%{"installation" => "burrow-7"}] = broker_bodies()
    end

    test "wire_fields/1 round-trips through normalize/1 to the same map and fingerprint" do
      args =
        valid(%{
          "observed_behavior" => "  Token #{@canary} leaked;\nsee ```fence```  ",
          "diagnostics" => %{
            "include" => true,
            "scope" => "Stack_Trace",
            "content" => "** (RuntimeError) password=hunter2-sentinel"
          },
          "unknown" => "dropped"
        })

      {:ok, sanitized, _} = Submission.normalize(args)
      assert %{scope: "stack_trace"} = sanitized.diagnostics

      wire = Submission.wire_fields(sanitized)

      assert wire["diagnostics"] == %{
               "include" => true,
               "scope" => "stack_trace",
               "content" => sanitized.diagnostics.content
             }

      refute Map.has_key?(wire, "unknown")

      assert {:ok, ^sanitized, report} = Submission.normalize(wire)
      assert report.ignored_fields == []
      assert report.diagnostics_included

      {:ok, again, _} = Submission.normalize(wire)
      assert Submission.fingerprint(again) == Submission.fingerprint(sanitized)
    end

    test "wire_fields/1 omits absent optional fields" do
      {:ok, sanitized, _} =
        Submission.normalize(Map.drop(valid(), ["reproduction_steps", "version_environment"]))

      assert sanitized |> Submission.wire_fields() |> Map.keys() |> Enum.sort() ==
               ~w(category expected_behavior observed_behavior source title)
    end
  end

  describe "person actors, area and source (task 01a1a6a5 stage 2)" do
    # sha256 of main 056de28f8's fingerprint/1 over `valid/0` (no area):
    # "bug" and the five canonical text fields joined by NUL.
    @main_era_fingerprint "6709c2fc69d3098514b19a954b6a26dd292ae8b279bd92a40cac54841ce6a944"

    defp person!(label) do
      n = System.unique_integer([:positive])

      Repo.insert!(%Platform.Accounts.User{
        email: "#{label}-#{n}@example.com",
        name: "Person #{label}",
        oidc_sub: "oidc-#{label}-#{n}"
      })
    end

    defp person(user), do: %{user_id: user.id}

    defp rows, do: Repo.all(Platform.Feedback.SubmissionRecord)

    test "an area-less fingerprint is byte-identical to main's" do
      {:ok, sanitized, _} = Submission.normalize(valid())
      refute Map.has_key?(sanitized, :area)
      assert Submission.fingerprint(sanitized) == @main_era_fingerprint
    end

    test "area joins the fingerprint only when present, and is an enum" do
      {:ok, with_area, _} = Submission.normalize(valid(%{"area" => " Meetings "}))
      assert with_area.area == "meetings"
      refute Submission.fingerprint(with_area) == @main_era_fingerprint

      {:ok, blank_area, _} = Submission.normalize(valid(%{"area" => "  "}))
      assert Submission.fingerprint(blank_area) == @main_era_fingerprint

      assert {:error, %{code: :invalid_area, field: "area"}} =
               Submission.normalize(valid(%{"area" => "billing"}))

      assert "meetings" in Submission.areas()
      refute "source" in Submission.allowed_keys()
      assert "area" in Submission.allowed_keys()
    end

    test "a person submit with the policy disabled is refused before any call" do
      Application.put_env(:platform, :feedback_policy, "disabled")
      user = person!("disabled")

      assert {:error, %{code: :feedback_disabled}} = Submission.submit(valid(), person(user))
      refute_received {:broker, _, _, _, _}
      assert submission_count() == 0
    end

    test "a person submit records actor_user_id only and sends source person", ctx do
      user = person!("recorded")

      assert {:ok, %{status: "created"}} =
               Submission.submit(Map.delete(valid(), "expected_behavior"), person(user))

      assert [%{actor_user_id: user_id, actor_agent_id: nil}] = rows()
      assert user_id == user.id

      assert [%{"submission" => submission} = body] = broker_bodies()
      assert submission["source"] == "person"
      raw = Jason.encode!(body)
      refute raw =~ user.id
      refute raw =~ user.email
      refute raw =~ user.name

      assert {:ok, _} =
               Submission.submit(valid(%{"title" => "agent row"}), actor(ctx.agent))

      assert Enum.any?(rows(), &(&1.actor_agent_id == ctx.agent.id and is_nil(&1.actor_user_id)))
    end

    test "a person needs a title and at least one of expected or observed" do
      user = person!("fields")
      bare = Map.drop(valid(), ["expected_behavior", "observed_behavior"])

      assert {:error, %{code: :missing_field}} = Submission.submit(bare, person(user))

      assert {:error, %{code: :missing_field, field: "title"}} =
               Submission.submit(Map.delete(valid(), "title"), person(user))

      assert {:ok, _} =
               Submission.submit(Map.delete(valid(), "observed_behavior"), person(user))
    end

    test "an agent still needs title, expected and observed", %{agent: agent} do
      for field <- ~w(expected_behavior observed_behavior) do
        assert {:error, %{code: :missing_field, field: ^field}} =
                 Submission.submit(Map.delete(valid(), field), actor(agent))
      end
    end

    test "a caller-supplied source is overwritten from the actor kind", %{agent: agent} do
      assert {:ok, _} = Submission.submit(valid(%{"source" => "person"}), actor(agent))
      assert [%{"submission" => %{"source" => "agent"}}] = broker_bodies()

      user = person!("source")

      assert {:ok, _} =
               Submission.submit(valid(%{"title" => "x2", "source" => "agent"}), person(user))

      assert [%{"submission" => %{"source" => "person"}}] = broker_bodies()
    end

    test "identical text from a person and from an agent is one report", %{agent: agent} do
      user = person!("dedupe")

      assert {:ok, %{status: "created", issue: issue}} = Submission.submit(valid(), actor(agent))

      assert {:ok, %{status: "duplicate", issue: ^issue}} =
               Submission.submit(valid(), person(user))

      assert submission_count() == 1
    end

    test "the per-person cap allows N, refuses N+1, and ignores agent rows", ctx do
      user = person!("capped")
      Application.put_env(:platform, :feedback_rate_limits, per_actor: 2, per_installation: 50)

      # Agent rows in the window must not count against the person.
      for n <- 1..2 do
        assert {:ok, _} = Submission.submit(valid(%{"title" => "agent #{n}"}), actor(ctx.agent))
      end

      for n <- 1..2 do
        assert {:ok, %{status: "created"}} =
                 Submission.submit(valid(%{"title" => "person #{n}"}), person(user))
      end

      assert {:error, %{code: :rate_limited}} =
               Submission.submit(valid(%{"title" => "person 3"}), person(user))

      other = person!("uncapped")

      assert {:ok, %{status: "created"}} =
               Submission.submit(valid(%{"title" => "other person"}), person(other))
    end

    test "a row with both actor columns is refused by the database", %{agent: agent} do
      user = person!("both")

      assert_raise Postgrex.Error, ~r/feedback_submissions_one_actor_check/, fn ->
        Repo.insert_all("feedback_submissions", [
          %{
            id: Ecto.UUID.bingenerate(),
            fingerprint: String.duplicate("c", 64),
            category: "bug",
            status: "pending",
            actor_agent_id: Ecto.UUID.dump!(agent.id),
            actor_user_id: Ecto.UUID.dump!(user.id),
            attempted_at: DateTime.utc_now(),
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
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
          "repository" => "GetBurrowing/core",
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
