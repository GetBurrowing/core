defmodule Platform.Agents.ConfigFiles.Backend.Host do
  @moduledoc """
  Federated agents: file operations over `runtime_host:<runtime_id>`
  (`PlatformWeb.RuntimeHostChannel`), served by the burrow-cli on the agent's
  machine. The host redacts before it sends; core redacts again in
  `Platform.Agents.ConfigFiles`. The hash is over the full on-disk bytes.
  """
  @behaviour Platform.Agents.ConfigFiles.Backend

  alias Platform.Federation.RuntimeHosts

  @impl true
  def list(ctx) do
    with {:ok, %{"entries" => entries}} when is_list(entries) <- ask(ctx, "file.list", %{}) do
      {:ok,
       for(
         %{"path" => path, "sha256" => sha} <- entries,
         is_binary(path),
         is_binary(sha),
         do: %{path: path, sha256: sha, secret?: false}
       )}
    else
      {:ok, _} -> {:error, {:host_error, "malformed reply"}}
      error -> error
    end
  end

  @impl true
  def read(ctx, path) do
    case ask(ctx, "file.read", %{"path" => path}) do
      {:ok, %{"content" => content, "sha256" => sha}}
      when is_binary(content) and is_binary(sha) ->
        {:ok, %{content: content, sha256: sha}}

      {:ok, _} ->
        {:error, {:host_error, "malformed reply"}}

      error ->
        error
    end
  end

  @impl true
  def write(ctx, path, content, expected) do
    payload = %{"path" => path, "content" => content, "expected_sha256" => expected}

    case ask(ctx, "file.write", payload) do
      {:ok, %{"status" => "ok", "sha256" => sha}} when is_binary(sha) -> {:ok, sha}
      {:ok, %{"status" => "conflict"} = r} -> {:conflict, r["current_sha256"]}
      {:ok, _} -> {:error, {:host_error, "malformed reply"}}
      error -> error
    end
  end

  @impl true
  def set_secret(ctx, path, pointer, value) do
    case ask(ctx, "secret.set", %{"path" => path, "pointer" => pointer, "value" => value}) do
      {:ok, %{"status" => "ok", "sha256" => sha}} when is_binary(sha) -> {:ok, sha}
      {:ok, _} -> {:error, {:host_error, "malformed reply"}}
      error -> error
    end
  end

  # `file.delete` is sent only to a host whose hello advertised it
  # (`ConfigFiles.describe/2`); the host applies the same hash precondition
  # as a write.
  @impl true
  def delete(ctx, path, expected) do
    case ask(ctx, "file.delete", %{"path" => path, "expected_sha256" => expected}) do
      {:ok, %{"status" => "ok"}} -> {:ok, nil}
      {:ok, %{"status" => "conflict"} = r} -> {:conflict, r["current_sha256"]}
      {:ok, _} -> {:error, {:host_error, "malformed reply"}}
      error -> error
    end
  end

  # Every request names the actor's ROLE (never an id): the CLI checks it
  # against the opt-in chosen on the machine (`owner_only` refuses an admin).
  defp ask(ctx, event, payload) do
    payload = Map.put(payload, "actor_role", to_string(Map.get(ctx, :role) || :other))
    RuntimeHosts.request(ctx.runtime.runtime_id, event, payload)
  end
end
