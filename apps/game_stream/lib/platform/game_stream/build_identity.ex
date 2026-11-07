defmodule Platform.GameStream.BuildIdentity do
  @moduledoc "GitHub Actions workload identity. The issuer and JWKS origin are fixed, never supplied by a caller."
  @issuer "https://token.actions.githubusercontent.com"
  @audience "burrow-native-builds"

  def verify(token, policy, manifest) when is_binary(token) and is_map(policy) do
    with {:ok, %{status: 200, body: %{"keys" => keys}}} <-
           Req.get(@issuer <> "/.well-known/jwks", retry: false, receive_timeout: 5_000),
         {:ok, claims} <- verify_keys(token, keys),
         true <- claims_match?(claims, policy, manifest, System.system_time(:second)) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def verify(_, _, _), do: {:error, :unauthorized}

  def verify_keys(token, keys) do
    Enum.find_value(keys, {:error, :unauthorized}, fn key ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token) do
        {true, %{fields: claims}, _} -> {:ok, claims}
        _ -> nil
      end
    end)
  rescue
    _ -> {:error, :unauthorized}
  end

  def claims_match?(c, p, m, now) do
    m["schema_version"] == 1 and c["iss"] == @issuer and c["aud"] == @audience and
      is_integer(c["exp"]) and c["exp"] > now and c["exp"] <= now + 600 and
      is_integer(c["nbf"]) and c["nbf"] <= now + 30 and
      c["repository"] == p["repository"] and
      c["repository_id"] == p["repository_id"] and
      c["ref"] == "refs/heads/main" and c["event_name"] == "push" and
      c["workflow_ref"] == p["workflow_ref"] and
      c["job_workflow_ref"] == p["job_workflow_ref"] and
      is_binary(p["job_workflow_ref"]) and
      Regex.match?(~r/@[0-9a-f]{40}\z/, p["job_workflow_ref"]) and
      c["sha"] == m["source_sha"] and c["repository"] == m["repository"] and
      c["run_number"] == to_string(m["build_number"]) and
      m["publisher_workflow"] == p["job_workflow_ref"]
  end
end
