defmodule Platform.GameStream.BuildIdentityTest do
  use ExUnit.Case, async: true
  alias Platform.GameStream.{BuildIdentity, NativeBuild}

  defp fixtures do
    workflow =
      "GetBurrowing/core/.github/workflows/game-native-build.yml@" <> String.duplicate("a", 40)

    policy = %{
      "repository" => "owner/game",
      "repository_id" => "123",
      "workflow_ref" => "owner/game/.github/workflows/native-builds.yml@refs/heads/main",
      "job_workflow_ref" => workflow
    }

    manifest = %{
      "schema_version" => 1,
      "repository" => "owner/game",
      "source_sha" => String.duplicate("b", 40),
      "build_number" => 42,
      "publisher_workflow" => workflow
    }

    claims = %{
      "iss" => "https://token.actions.githubusercontent.com",
      "aud" => "burrow-native-builds",
      "exp" => 1300,
      "nbf" => 999,
      "repository" => "owner/game",
      "repository_id" => "123",
      "ref" => "refs/heads/main",
      "event_name" => "push",
      "workflow_ref" => policy["workflow_ref"],
      "job_workflow_ref" => workflow,
      "sha" => manifest["source_sha"],
      "run_number" => "42"
    }

    {policy, manifest, claims}
  end

  test "signed GitHub identity is scoped to repository id, main workflow, reusable commit, source and sequence" do
    {policy, manifest, claims} = fixtures()
    assert BuildIdentity.claims_match?(claims, policy, manifest, 1000)

    for key <-
          ~w(iss aud repository repository_id ref event_name workflow_ref job_workflow_ref sha run_number) do
      refute BuildIdentity.claims_match?(Map.put(claims, key, "forged"), policy, manifest, 1000)
    end

    refute BuildIdentity.claims_match?(Map.put(claims, "exp", 999), policy, manifest, 1000)
    refute BuildIdentity.claims_match?(Map.put(claims, "nbf", 1040), policy, manifest, 1000)

    refute BuildIdentity.claims_match?(
             claims,
             Map.put(policy, "job_workflow_ref", "owner/workflow@main"),
             manifest,
             1000
           )

    refute BuildIdentity.claims_match?(
             claims,
             policy,
             Map.delete(manifest, "schema_version"),
             1000
           )
  end

  test "signature, not a caller repo string or decoded JWT, establishes identity" do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(key)

    {_, token} =
      JOSE.JWT.sign(key, %{"alg" => "RS256"}, %{"repository" => "owner/game"})
      |> JOSE.JWS.compact()

    assert {:ok, %{"repository" => "owner/game"}} = BuildIdentity.verify_keys(token, [public])
    other = JOSE.JWK.generate_key({:rsa, 2048})
    {_, wrong} = JOSE.JWK.to_public_map(other)
    assert {:error, :unauthorized} = BuildIdentity.verify_keys(token, [wrong])
    assert {:error, :unauthorized} = BuildIdentity.verify_keys("not-a-jwt", [public])
  end

  test "complete platform matrix is required; metadata remains engine neutral" do
    artifacts =
      for {os, arch, role} <- [
            {"windows", "x86_64", "client"},
            {"linux", "x86_64", "client"},
            {"macos", "universal", "client"},
            {"linux", "x86_64", "server"}
          ] do
        %{
          "os" => os,
          "arch" => arch,
          "role" => role,
          "size" => 1,
          "asset_id" => 1,
          "sha256" => String.duplicate("c", 64),
          "executable" => "game",
          "filename" => os <> role <> ".zip"
        }
      end

    manifest = %{
      "schema_version" => 1,
      "source_sha" => String.duplicate("b", 40),
      "build_number" => 42,
      "artifacts" => artifacts,
      "engine" => "future-engine",
      "protocol_version" => 1,
      "capacity" => 4,
      "server_image" => "registry/game@sha256:" <> String.duplicate("d", 64)
    }

    assert NativeBuild.valid?(manifest)
    refute NativeBuild.valid?(Map.put(manifest, "artifacts", tl(artifacts)))
    refute NativeBuild.valid?(Map.put(manifest, "artifacts", artifacts ++ artifacts))
    refute NativeBuild.valid?(Map.put(manifest, "build_number", "42"))
  end

  test "asset handoff only accepts GitHub's signed HTTPS asset origins" do
    alias Platform.GameStream.NativeAssets

    assert NativeAssets.signed_asset_url?(
             "https://release-assets.githubusercontent.com/a?signature=opaque"
           )

    refute NativeAssets.signed_asset_url?("https://github.com.evil.example/a")
    refute NativeAssets.signed_asset_url?("http://objects.githubusercontent.com/a")
    refute NativeAssets.signed_asset_url?("https://credential@objects.githubusercontent.com/a")
  end
end
