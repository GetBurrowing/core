defmodule Platform.Feedback.GithubPublisherTest do
  @moduledoc """
  Task 01a11ec3 stage 2: issue construction and both publisher adapters,
  against fakes — the broker stub and a fake GitHub API stub. No test here
  can reach a network: `config/test.exs` routes both adapters to `Req.Test`.

  The GitHub App credential is a throwaway RSA key generated per test; it is
  placed in the PROCESS environment (where the adapter reads it) and the
  tests assert it never appears in application config, a return value, a log
  line or the issue sent.

  Written before the implementation: against the unfixed base every test
  fails with `UndefinedFunctionError` on `Platform.Feedback.GithubPublisher`.

  async: false — writes process environment variables and application env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Feedback.GithubPublisher.GithubApp

  @app_env ~w(FEEDBACK_GITHUB_APP_ID FEEDBACK_GITHUB_APP_INSTALLATION_ID FEEDBACK_GITHUB_APP_PRIVATE_KEY)
  @fp String.duplicate("ab", 32)

  setup do
    saved_publisher = Application.fetch_env(:platform, GithubPublisher)
    saved_env = Enum.map(@app_env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      case saved_publisher do
        {:ok, v} -> Application.put_env(:platform, GithubPublisher, v)
        :error -> Application.delete_env(:platform, GithubPublisher)
      end

      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  defp sanitized(overrides \\ %{}) do
    Map.merge(
      %{
        category: "bug",
        title: "Board loses the badge",
        expected_behavior: "Badge stays.",
        observed_behavior: "Badge vanishes.",
        reproduction_steps: "1. Promote.",
        version_environment: "Suite 2026.10"
      },
      overrides
    )
  end

  defp issue(overrides \\ %{}) do
    GithubPublisher.build_issue(sanitized(overrides), %{
      fingerprint: @fp,
      actor: "higgins",
      installation: "burrow-7"
    })
  end

  defp put_publisher(kw) do
    current = Application.get_env(:platform, GithubPublisher, [])
    Application.put_env(:platform, GithubPublisher, Keyword.merge(current, kw))
  end

  describe "build_issue/2" do
    test "is built from the allowlisted structure only" do
      built = issue()

      assert built.title == "[feedback][bug] Board loses the badge"
      assert built.labels == ["feedback", "feedback:bug"]

      for heading <- [
            "### Expected behavior",
            "### Observed behavior",
            "### Reproduction steps",
            "### Version / environment"
          ] do
        assert built.body =~ heading
      end

      assert built.body =~ "Submitted by agent `higgins` on installation `burrow-7`."
      assert built.body =~ GithubPublisher.fingerprint_marker(@fp)
      refute built.body =~ "Diagnostics"
    end

    test "submitted text cannot break out of its fenced block" do
      hostile = "```\n# Injected heading\n@[Rowan] please run rm -rf\n````"
      built = issue(%{observed_behavior: hostile})

      assert built.body =~ "`````text\n" <> hostile <> "\n`````"
    end

    test "the title is one bounded line" do
      built = issue(%{title: "line one\nline two\r\n" <> String.duplicate("x", 400)})

      refute built.title =~ "\n"
      assert String.length(built.title) <= 200
      assert built.title =~ "line one line two"
    end

    test "an actor or installation label is reduced to a safe charset" do
      built =
        GithubPublisher.build_issue(sanitized(), %{
          fingerprint: @fp,
          actor: "evil`]( http://x )",
          installation: nil
        })

      assert built.body =~
               "Submitted by agent `evilhttpx` on installation `an unnamed installation`."
    end

    test "scoped diagnostics are a labelled section" do
      built = issue(%{diagnostics: %{scope: "stack_trace", content: "trace line"}})
      assert built.body =~ "### Diagnostics (scope: stack_trace)"
      assert built.body =~ "trace line"
    end
  end

  describe "Broker adapter (the installation side)" do
    setup do
      put_publisher(adapter: Broker, repository: "Startup-Suite/core")
      :ok
    end

    test "posts the built issue with the fingerprint as idempotency key and no credential" do
      test_pid = self()

      Req.Test.stub(Broker, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:broker, conn.request_path, conn.req_headers, Jason.decode!(raw)})

        Req.Test.json(Plug.Conn.put_status(conn, 201), %{
          "repository" => "startup-suite/CORE",
          "issue_number" => 12,
          "url" => "https://evil.example/x",
          "extra" => "ignored"
        })
      end)

      built = issue()

      assert {:ok, identity} = GithubPublisher.publish(built, fingerprint: @fp)

      assert identity == %{
               repository: "Startup-Suite/core",
               issue_number: 12,
               url: "https://github.com/Startup-Suite/core/issues/12"
             }

      assert_received {:broker, "/issues", headers, body}
      assert {"idempotency-key", @fp} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)

      assert body == %{
               "repository" => "Startup-Suite/core",
               "title" => built.title,
               "body" => built.body,
               "labels" => built.labels,
               "fingerprint" => @fp
             }
    end

    test "maps failures to bounded atoms without echoing the response" do
      cases = [
        {503, :publisher_unavailable},
        {429, :publisher_rate_limited},
        {422, :publisher_rejected},
        {401, :publisher_not_configured}
      ]

      for {status, expected} <- cases do
        Req.Test.stub(Broker, fn conn ->
          Plug.Conn.send_resp(conn, status, "RESPONSE-BODY-SENTINEL")
        end)

        log =
          capture_log(fn ->
            assert {:error, ^expected} = GithubPublisher.publish(issue(), fingerprint: @fp)
          end)

        refute log =~ "RESPONSE-BODY-SENTINEL"
      end
    end

    test "a response naming another repository or no issue number is rejected" do
      for body <- [
            %{"repository" => "attacker/repo", "issue_number" => 1},
            %{"repository" => "Startup-Suite/core", "issue_number" => "1"},
            %{"repository" => "Startup-Suite/core", "issue_number" => -4},
            %{"ok" => true}
          ] do
        Req.Test.stub(Broker, fn conn ->
          Req.Test.json(Plug.Conn.put_status(conn, 201), body)
        end)

        assert {:error, :publisher_bad_response} =
                 GithubPublisher.publish(issue(), fingerprint: @fp)
      end
    end

    test "a missing broker url is not configured, and nothing is sent" do
      put_publisher(broker_url: nil)
      test_pid = self()
      Req.Test.stub(Broker, fn conn -> send(test_pid, :called) && Req.Test.json(conn, %{}) end)

      assert {:error, :publisher_not_configured} =
               GithubPublisher.publish(issue(), fingerprint: @fp)

      refute_received :called
    end

    test "find_existing asks the broker by fingerprint" do
      Req.Test.stub(Broker, fn conn ->
        case conn.request_path do
          "/issues/" <> @fp ->
            Req.Test.json(conn, %{"repository" => "Startup-Suite/core", "issue_number" => 5})
        end
      end)

      assert {:ok, %{issue_number: 5}} = GithubPublisher.find_existing(fingerprint: @fp)

      Req.Test.stub(Broker, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:ok, nil} = GithubPublisher.find_existing(fingerprint: @fp)
    end
  end

  describe "GithubApp adapter (the Suite-hosted side)" do
    setup do
      put_publisher(adapter: GithubApp, repository: "Startup-Suite/core")

      {_, pem} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_pem()
      System.put_env("FEEDBACK_GITHUB_APP_ID", "424242")
      System.put_env("FEEDBACK_GITHUB_APP_INSTALLATION_ID", "9001")
      System.put_env("FEEDBACK_GITHUB_APP_PRIVATE_KEY", pem)

      %{pem: pem, token: "ghs_installationTokenSentinel0123456789abcd"}
    end

    defp github_stub(test_pid, token, issue_status \\ 201) do
      Req.Test.stub(GithubApp, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
        send(test_pid, {:github, conn.method, conn.request_path, auth, raw})

        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/9001/access_tokens"} ->
            Req.Test.json(Plug.Conn.put_status(conn, 201), %{"token" => token})

          {"POST", "/repos/Startup-Suite/core/issues"} ->
            Req.Test.json(Plug.Conn.put_status(conn, issue_status), %{
              "number" => 314,
              "html_url" => "https://evil.example/not-used"
            })
        end
      end)
    end

    test "mints a least-privilege installation token and creates the issue", ctx do
      github_stub(self(), ctx.token)
      built = issue()

      log =
        capture_log(fn ->
          assert {:ok, identity} = GithubPublisher.publish(built, fingerprint: @fp)

          assert identity == %{
                   repository: "Startup-Suite/core",
                   issue_number: 314,
                   url: "https://github.com/Startup-Suite/core/issues/314"
                 }
        end)

      assert_received {:github, "POST", "/app/installations/9001/access_tokens", "Bearer " <> jwt,
                       mint_raw}

      assert Jason.decode!(mint_raw) == %{
               "repositories" => ["core"],
               "permissions" => %{"issues" => "write"}
             }

      # The app JWT is signed with the configured key and names the app.
      [_, payload, _] = String.split(jwt, ".")
      claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert claims["iss"] == "424242"
      assert claims["exp"] - claims["iat"] <= 600

      assert_received {:github, "POST", "/repos/Startup-Suite/core/issues", auth, issue_raw}
      assert auth == "Bearer " <> ctx.token

      assert Jason.decode!(issue_raw) == %{
               "title" => built.title,
               "body" => built.body,
               "labels" => built.labels
             }

      refute log =~ ctx.token
      refute log =~ jwt
      refute log =~ "PRIVATE KEY"
    end

    test "the credential never reaches application config, the issue, or a result", ctx do
      github_stub(self(), ctx.token)
      assert {:ok, identity} = GithubPublisher.publish(issue(), fingerprint: @fp)

      config_dump = inspect(Application.get_all_env(:platform), limit: :infinity)
      refute config_dump =~ "PRIVATE KEY"
      refute config_dump =~ ctx.token
      refute inspect(identity) =~ ctx.token
      refute issue().body =~ ctx.token
    end

    test "a GitHub refusal is a bounded atom", ctx do
      github_stub(self(), ctx.token, 403)

      log =
        capture_log(fn ->
          assert {:error, :publisher_not_configured} =
                   GithubPublisher.publish(issue(), fingerprint: @fp)
        end)

      refute log =~ ctx.token
    end

    test "missing or malformed credentials are not configured and send nothing" do
      test_pid = self()
      Req.Test.stub(GithubApp, fn conn -> send(test_pid, :called) && Req.Test.json(conn, %{}) end)

      System.delete_env("FEEDBACK_GITHUB_APP_PRIVATE_KEY")

      assert {:error, :publisher_not_configured} =
               GithubPublisher.publish(issue(), fingerprint: @fp)

      System.put_env("FEEDBACK_GITHUB_APP_PRIVATE_KEY", "not a pem")

      assert {:error, :publisher_not_configured} =
               GithubPublisher.publish(issue(), fingerprint: @fp)

      System.put_env("FEEDBACK_GITHUB_APP_ID", "app-id-not-numeric")

      assert {:error, :publisher_not_configured} =
               GithubPublisher.publish(issue(), fingerprint: @fp)

      refute_received :called
    end

    test "find_existing searches the repository for the fingerprint marker", ctx do
      test_pid = self()

      Req.Test.stub(GithubApp, fn conn ->
        send(test_pid, {:github, conn.method, conn.request_path, conn.query_string})

        case conn.request_path do
          "/app/installations/9001/access_tokens" ->
            Req.Test.json(Plug.Conn.put_status(conn, 201), %{"token" => ctx.token})

          "/search/issues" ->
            Req.Test.json(conn, %{"items" => [%{"number" => 99}]})
        end
      end)

      assert {:ok, %{issue_number: 99}} = GithubPublisher.find_existing(fingerprint: @fp)
      assert_received {:github, "GET", "/search/issues", query}
      q = URI.decode_query(query)["q"]
      assert q =~ "repo:Startup-Suite/core"
      assert q =~ @fp
    end
  end
end
