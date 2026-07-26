defmodule Platform.Webhooks.GithubSignatureTest do
  @moduledoc """
  Tests for `Platform.Webhooks.GithubSignature`.

  Covers both secret candidates (per-project `deploy_config["webhook_secret"]`
  and the app-level `:github_webhook_secret` fallback), the dual-accept
  behaviour that makes rotation possible, and every fail-closed reason.

  `async: false`: several cases mutate `Application.put_env/delete_env` for
  `:github_webhook_secret`, which is global VM state — the plan's
  "async: false for that block" isn't expressible per-block in ExUnit, and an
  async file would let a `delete_env` race the signed webhook POSTs in the
  controller suites.

  Task 019f9b11 stage 1 — GitHub webhook auth-bypass fix.
  """

  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Webhooks.GithubSignature

  @body ~s({"action":"completed","repository":{"html_url":"https://github.com/test/sig-repo"}})
  @project_secret "project-level-secret"

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  defp env_secret, do: Application.get_env(:platform, :github_webhook_secret)

  defp create_project!(attrs) do
    {:ok, project} =
      Tasks.create_project(
        Map.merge(
          %{name: "Sig Test #{System.unique_integer([:positive])}"},
          attrs
        )
      )

    project
  end

  defp with_env_secret(value, fun) do
    prev = Application.get_env(:platform, :github_webhook_secret)

    if is_nil(value) do
      Application.delete_env(:platform, :github_webhook_secret)
    else
      Application.put_env(:platform, :github_webhook_secret, value)
    end

    try do
      fun.()
    after
      if is_nil(prev) do
        Application.delete_env(:platform, :github_webhook_secret)
      else
        Application.put_env(:platform, :github_webhook_secret, prev)
      end
    end
  end

  describe "verify/3 — happy paths" do
    test "accepts a signature made with the project's webhook_secret" do
      repo_url = "https://github.com/test/sig-repo-#{System.unique_integer([:positive])}"

      create_project!(%{
        repo_url: repo_url,
        deploy_config: %{"webhook_secret" => @project_secret}
      })

      assert :ok == GithubSignature.verify(@body, sign(@body, @project_secret), repo_url)
    end

    test "accepts the env fallback when the project has no webhook_secret" do
      repo_url = "https://github.com/test/no-secret-#{System.unique_integer([:positive])}"
      create_project!(%{repo_url: repo_url, deploy_config: %{}})

      assert :ok == GithubSignature.verify(@body, sign(@body, env_secret()), repo_url)
    end

    test "accepts the env fallback for an unknown repo_url" do
      assert :ok ==
               GithubSignature.verify(
                 @body,
                 sign(@body, env_secret()),
                 "https://github.com/nobody/never-seen"
               )
    end

    test "accepts the env fallback when repo_url is nil" do
      assert :ok == GithubSignature.verify(@body, sign(@body, env_secret()), nil)
    end

    test "dual-accept: project secret is preferred but the env secret still verifies" do
      repo_url = "https://github.com/test/dual-#{System.unique_integer([:positive])}"

      create_project!(%{
        repo_url: repo_url,
        deploy_config: %{"webhook_secret" => @project_secret}
      })

      # Rotation headroom: both candidates are honoured for the same delivery.
      assert :ok == GithubSignature.verify(@body, sign(@body, @project_secret), repo_url)
      assert :ok == GithubSignature.verify(@body, sign(@body, env_secret()), repo_url)
    end

    test "uppercase hex digests verify" do
      repo_url = "https://github.com/test/upper-#{System.unique_integer([:positive])}"

      create_project!(%{
        repo_url: repo_url,
        deploy_config: %{"webhook_secret" => @project_secret}
      })

      header =
        @body |> sign(@project_secret) |> String.upcase() |> String.replace("SHA256", "sha256")

      assert :ok == GithubSignature.verify(@body, header, repo_url)
    end
  end

  describe "verify/3 — fail closed" do
    test "signature made with the wrong secret is a mismatch" do
      repo_url = "https://github.com/test/wrong-#{System.unique_integer([:positive])}"

      create_project!(%{
        repo_url: repo_url,
        deploy_config: %{"webhook_secret" => @project_secret}
      })

      assert {:error, :signature_mismatch} ==
               GithubSignature.verify(@body, sign(@body, "not-the-secret"), repo_url)
    end

    test "a signature over different bytes is a mismatch" do
      repo_url = "https://github.com/test/tamper-#{System.unique_integer([:positive])}"

      create_project!(%{
        repo_url: repo_url,
        deploy_config: %{"webhook_secret" => @project_secret}
      })

      signature = sign(@body, @project_secret)

      assert {:error, :signature_mismatch} ==
               GithubSignature.verify(@body <> " ", signature, repo_url)
    end

    test "nil signature header is missing_signature" do
      assert {:error, :missing_signature} == GithubSignature.verify(@body, nil, nil)
    end

    test "blank signature header is missing_signature" do
      assert {:error, :missing_signature} == GithubSignature.verify(@body, "", nil)
      assert {:error, :missing_signature} == GithubSignature.verify(@body, "   ", nil)
    end

    test "a header without the sha256= prefix is malformed" do
      assert {:error, :malformed_signature} ==
               GithubSignature.verify(@body, "not-sha256", nil)

      assert {:error, :malformed_signature} ==
               GithubSignature.verify(@body, "sha1=deadbeef", nil)
    end

    test "an empty or non-hex digest is malformed" do
      assert {:error, :malformed_signature} == GithubSignature.verify(@body, "sha256=", nil)

      assert {:error, :malformed_signature} ==
               GithubSignature.verify(@body, "sha256=not-hex-at-all", nil)
    end

    test "no project secret and no env secret is no_secret_configured" do
      repo_url = "https://github.com/test/unconfigured-#{System.unique_integer([:positive])}"
      create_project!(%{repo_url: repo_url, deploy_config: %{}})

      with_env_secret(nil, fn ->
        assert {:error, :no_secret_configured} ==
                 GithubSignature.verify(@body, sign(@body, "anything"), repo_url)
      end)
    end

    test "unknown repo and no env secret is no_secret_configured" do
      with_env_secret(nil, fn ->
        assert {:error, :no_secret_configured} ==
                 GithubSignature.verify(@body, sign(@body, "anything"), nil)
      end)
    end

    test "malformed header is reported before secret resolution" do
      with_env_secret(nil, fn ->
        assert {:error, :malformed_signature} == GithubSignature.verify(@body, "garbage", nil)
      end)
    end
  end

  describe "secrets_for_repo/1" do
    test "returns the project secret first, then the env fallback" do
      repo_url = "https://github.com/test/order-#{System.unique_integer([:positive])}"

      create_project!(%{
        repo_url: repo_url,
        deploy_config: %{"webhook_secret" => @project_secret}
      })

      assert [@project_secret, env_secret()] == GithubSignature.secrets_for_repo(repo_url)
    end

    test "drops blank project secrets" do
      repo_url = "https://github.com/test/blank-#{System.unique_integer([:positive])}"
      create_project!(%{repo_url: repo_url, deploy_config: %{"webhook_secret" => ""}})

      assert [env_secret()] == GithubSignature.secrets_for_repo(repo_url)
    end

    test "de-duplicates when project and env secrets are identical" do
      repo_url = "https://github.com/test/dupe-#{System.unique_integer([:positive])}"

      create_project!(%{
        repo_url: repo_url,
        deploy_config: %{"webhook_secret" => env_secret()}
      })

      assert [env_secret()] == GithubSignature.secrets_for_repo(repo_url)
    end

    test "returns an empty list when nothing is configured" do
      repo_url = "https://github.com/test/empty-#{System.unique_integer([:positive])}"
      create_project!(%{repo_url: repo_url, deploy_config: %{}})

      with_env_secret(nil, fn ->
        assert [] == GithubSignature.secrets_for_repo(repo_url)
        assert [] == GithubSignature.secrets_for_repo(nil)
      end)
    end
  end

  describe "verify_hmac/3" do
    test "true for a matching digest" do
      assert GithubSignature.verify_hmac(@body, sign(@body, @project_secret), @project_secret)
    end

    test "false for a mismatched digest" do
      refute GithubSignature.verify_hmac(@body, sign(@body, "other"), @project_secret)
    end

    test "false for a header that isn't sha256=<hex>" do
      refute GithubSignature.verify_hmac(@body, "deadbeef", @project_secret)
    end
  end
end
