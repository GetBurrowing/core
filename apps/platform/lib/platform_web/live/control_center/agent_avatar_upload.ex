defmodule PlatformWeb.ControlCenter.AgentAvatarUpload do
  @moduledoc """
  The consume side of the agent-avatar upload on the Control Center config
  form (task `01a00122` stage 2).

  Stage 1 built the storage namespace, the two columns and the serving
  route. This module is the piece that turns a file the operator picked on
  their own machine into `agents.avatar_storage_key` — deliberately NOT a
  text field holding an off-platform URL.

  ## Why a LiveView upload and not the presigned flow

  `Platform.Chat.AttachmentStorage.Adapter.LocalDisk.presign_upload/3` and
  `PlatformWeb.ChatAttachmentUploadController` exist because MCP tools have
  no LiveView socket and must POST bytes at a URL. The config form HAS a
  socket, so it uses `allow_upload/3` + `consume_uploaded_entry/3` — the
  same shape `PlatformWeb.FilesLive` uses, which is the only other place in
  this repo where a human picks a local file in a LiveView form and the
  bytes land at a stable authenticated URL.

  ## `max_file_size`: 5 MB

  The existing spread is 15 MB (chat attachments, task attachments) and
  50 MB (project files). An avatar sits far below both, and 5 MB is picked
  against three facts rather than by halving a neighbour:

    1. The likeliest "image from a local machine" is an unedited phone
       photo, which is 1.5–4 MB as HEIC or JPEG. A 2 MB ceiling would
       bounce a large share of those and reintroduce exactly the friction
       that got v1 rejected.
    2. An avatar renders as one 40–80 px chrome element, not as a document
       the viewer opened on purpose. It does not deserve a document's
       budget, so it gets 3x less than a chat attachment.
    3. Nothing in this repo downscales images server-side, so the accepted
       size IS the served size on every page that renders the agent. That
       argues for the smallest ceiling that does not reject ordinary
       input, and 5 MB is that ceiling rather than a round number.

  ## The type check is here, not in `accept`

  `accept/0` feeds the browser's file-picker filter, which is a
  convenience: the picker's "all files" escape hatch, a scripted client, or
  a renamed file all walk straight around it. `allowed_entry?/1` runs at
  consume time on the server, and `Platform.Agents.AvatarStorage.put/3`
  enforces the reported content type behind it.

  The two checks are not redundant. `put/3` trusts the client-reported
  type when that type is on the allowlist, and `Phoenix.LiveView`'s own
  `accept` validation short-circuits on the same reported type
  (`UploadConfig.accepted?/2` returns true as soon as `client_type` is
  acceptable and never looks at the filename). So an entry claiming
  `image/png` while named `payload.svg` satisfies BOTH of those and is
  caught only here, by looking at what the FILENAME resolves to.

  SVG is the reason this matters: it can embed `<script>`, which is why
  stage 1 left it off the allowlist.
  """

  use PlatformWeb, :verified_routes

  alias Platform.Agents.Agent
  alias Platform.Agents.AvatarStorage

  @upload_name :agent_avatar
  @max_file_size 5 * 1024 * 1024

  @doc "The `allow_upload/3` name this module consumes."
  @spec upload_name() :: atom()
  def upload_name, do: @upload_name

  @doc "See the moduledoc for why this is 5 MB and not 15 or 50."
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: @max_file_size

  @doc "Human-facing size ceiling, for helper text that cannot drift from it."
  @spec max_file_size_label() :: String.t()
  def max_file_size_label, do: "#{div(@max_file_size, 1024 * 1024)} MB"

  @doc """
  The `:accept` list for `allow_upload/3`.

  Built from `AvatarStorage.allowed_content_types/0` so the picker filter
  cannot drift from the list the server enforces. Both the MIME types and
  their extensions are included: LiveView matches an entry on either, and
  the extension arm is what keeps an iOS upload labelled
  `application/octet-stream` from being bounced before it reaches
  `put/3`'s filename fallback.
  """
  @spec accept() :: [String.t()]
  def accept do
    Enum.flat_map(AvatarStorage.allowed_content_types(), fn type ->
      [type | Enum.map(MIME.extensions(type), &("." <> &1))]
    end)
  end

  @doc "Human-facing list of accepted formats, derived from the same allowlist."
  @spec accept_label() :: String.t()
  def accept_label do
    AvatarStorage.allowed_content_types()
    |> Enum.map(&(&1 |> String.split("/") |> List.last() |> String.upcase()))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  @doc """
  Drains a completed avatar entry, if there is one, into attrs for
  `Agent.changeset/2`.

  Returns:

    * `{:ok, %{}}` — nothing was picked; the caller saves the rest of the
      form untouched.
    * `{:ok, %{avatar_url: url, avatar_storage_key: key}}` — bytes are
      stored. The caller writes these through the changeset and, only once
      the row is committed, deletes the PREVIOUS key.
    * `{:error, message}` — a user-facing string. The entry is consumed
      either way, so a rejected file does not linger and get re-tried on
      the next save.
  """
  @spec consume(Phoenix.LiveView.Socket.t(), Agent.t()) ::
          {:ok, map()} | {:error, String.t()}
  def consume(socket, %Agent{} = agent) do
    case Phoenix.LiveView.uploaded_entries(socket, @upload_name) do
      {[entry | _], _in_progress} -> consume_entry(socket, agent, entry)
      _ -> {:ok, %{}}
    end
  end

  @doc """
  Deletes a stored blob, tolerating a nil/blank key.

  This is how a superseded avatar stops existing. `agents.avatar_storage_key`
  exists for exactly this call: without it a replaced avatar's bytes stay in
  the bucket forever, because nothing else ever enumerates that namespace.
  """
  @spec delete_blob(String.t() | nil) :: :ok
  def delete_blob(key) when is_binary(key) and key != "", do: AvatarStorage.delete(key)
  def delete_blob(_key), do: :ok

  @doc """
  The server-side type check.

  Read the moduledoc before deleting this as redundant — it is the ONLY
  check that looks at the filename when the client-reported type is
  acceptable, and a `.svg` named file claiming `image/png` clears both
  LiveView's `accept` validation and `AvatarStorage.put/3`.

  An extension MIME cannot recognise resolves to `application/octet-stream`
  and is deferred rather than rejected: `put/3` then enforces the reported
  content type, which is the same fallback stage 1 built for iOS uploads.
  """
  @spec allowed_entry?(map()) :: boolean()
  def allowed_entry?(%{client_name: client_name}) do
    case MIME.from_path(to_string(client_name)) do
      "application/octet-stream" -> true
      inferred -> inferred in AvatarStorage.allowed_content_types()
    end
  end

  def allowed_entry?(_entry), do: false

  @doc "Maps an `upload_errors/1,2` reason to copy an operator can act on."
  @spec error_message(term()) :: String.t()
  def error_message(:too_large),
    do: "That image is over #{max_file_size_label()}. Pick a smaller one."

  def error_message(:not_accepted), do: unsupported_message()
  def error_message(:too_many_files), do: "One avatar at a time — the newest pick wins."
  def error_message(:external_client_failure), do: "The upload did not finish. Try again."
  def error_message(reason), do: "The upload failed (#{inspect(reason)})."

  @doc """
  The URL written to `agents.avatar_url`.

  Carries a `v` token derived from the storage key. The serving route is
  `/agents/:id/avatar` and does not change when the bytes do, so without
  the token a replaced avatar keeps rendering the old image out of the
  browser cache — the cache-poisoning stage 1's `AvatarStorage` moduledoc
  calls out. The key already contains a fresh UUID per upload, so hashing
  it gives a token that changes exactly when the bytes change.
  """
  @spec avatar_url(Agent.t(), String.t()) :: String.t()
  def avatar_url(%Agent{id: id}, storage_key) when is_binary(storage_key) do
    ~p"/agents/#{id}/avatar?#{[v: cache_token(storage_key)]}"
  end

  defp consume_entry(socket, %Agent{} = agent, entry) do
    outcome =
      Phoenix.LiveView.consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, store(path, entry, agent)}
      end)

    case outcome do
      {:ok, %{storage_key: key}} ->
        {:ok, %{avatar_url: avatar_url(agent, key), avatar_storage_key: key}}

      {:error, {:unsupported_content_type, _reported}} ->
        {:error, unsupported_message()}

      {:error, reason} ->
        {:error, "Could not store that image (#{inspect(reason)})."}
    end
  end

  defp store(path, entry, %Agent{} = agent) do
    if allowed_entry?(entry) do
      AvatarStorage.put({:path, path}, agent.id,
        content_type: entry.client_type,
        filename: entry.client_name || "avatar"
      )
    else
      {:error, {:unsupported_content_type, entry.client_type}}
    end
  end

  defp unsupported_message do
    "That file type is not supported for an avatar. Use #{accept_label()}."
  end

  defp cache_token(storage_key), do: storage_key |> :erlang.phash2() |> Integer.to_string(36)
end
