defmodule Platform.PrototypeFixtures do
  @moduledoc """
  Fixtures for prototype tests (task 01a1316b-4e46 stage 1).

  `zip/1` hand-builds a zip archive so a test can state exactly what the
  archive DECLARES (names, sizes, Unix mode) independently of what it
  contains, which `:zip.create/3` will not do: it refuses or rewrites the
  hostile shapes these tests exist to send.
  """

  import Bitwise

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Prototypes.Settings
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @doc """
  Build a zip from entries. Each entry is a map with `:name` and `:data`, and
  optionally `:method` (0 stored, 8 deflate; default 8), `:declared` (the
  uncompressed size written to the headers; default the real size),
  `:mode` (a Unix st_mode, written with version-made-by UNIX) and `:crc`.
  """
  def zip(entries) do
    {locals, centrals, _offset} =
      Enum.reduce(entries, {[], [], 0}, fn entry, {locals, centrals, offset} ->
        name = entry.name
        data = Map.get(entry, :data, "")
        method = Map.get(entry, :method, 8)
        payload = if method == 8, do: :zlib.zip(data), else: data
        declared = Map.get(entry, :declared, byte_size(data))
        crc = Map.get(entry, :crc, :erlang.crc32(data))
        {made_by, ext_attr} = made_by(entry)

        local =
          <<0x04034B50::little-32, 20::little-16, 0::little-16, method::little-16, 0::little-16,
            0::little-16, crc::little-32, byte_size(payload)::little-32, declared::little-32,
            byte_size(name)::little-16, 0::little-16, name::binary, payload::binary>>

        central =
          <<0x02014B50::little-32, made_by::little-16, 20::little-16, 0::little-16,
            method::little-16, 0::little-16, 0::little-16, crc::little-32,
            byte_size(payload)::little-32, declared::little-32, byte_size(name)::little-16,
            0::little-16, 0::little-16, 0::little-16, 0::little-16, ext_attr::little-32,
            offset::little-32, name::binary>>

        {[local | locals], [central | centrals], offset + byte_size(local)}
      end)

    body = locals |> Enum.reverse() |> IO.iodata_to_binary()
    cd = centrals |> Enum.reverse() |> IO.iodata_to_binary()
    n = length(entries)

    body <>
      cd <>
      <<0x06054B50::little-32, 0::little-16, 0::little-16, n::little-16, n::little-16,
        byte_size(cd)::little-32, byte_size(body)::little-32, 0::little-16>>
  end

  defp made_by(%{mode: mode}), do: {3 <<< 8 ||| 20, mode <<< 16}
  defp made_by(_), do: {20, 0}

  @doc "Point the attachment store at a scratch dir for this test; returns it."
  def scratch_storage!(label) do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!(label)
    Application.put_env(:platform, :chat_attachments_root, scratch)

    ExUnit.Callbacks.on_exit(fn ->
      if prev,
        do: Application.put_env(:platform, :chat_attachments_root, prev),
        else: Application.delete_env(:platform, :chat_attachments_root)

      File.rm_rf!(scratch)
    end)

    scratch
  end

  @doc "Every regular file under the scratch store's `prototypes/` namespace."
  def stored_prototype_files(scratch) do
    scratch |> Path.join("prototypes/**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
  end

  @doc "Update the settings singleton directly (no admin actor needed)."
  def set_settings!(attrs) do
    Settings.get() |> Settings.changeset(attrs) |> Repo.update!()
  end

  def user!(name \\ "Proto User") do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "proto-user-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-proto-#{n}"
    })
  end

  def member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()
  end

  def agent!(metadata \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "proto-agent-#{System.unique_integer([:positive, :monotonic])}",
        name: "Proto Agent",
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  @doc """
  A runtime for `agent` owned by `owner`, holding `profile` (default: the
  DEFAULT tool profile) with the restriction `Platform.Federation.register_runtime/2`
  writes for an explicit profile (task 01a18da0 stage 1). Returns the
  MCP-shaped context `%{runtime_id, agent_id}` the transports build.
  """
  def reader_context!(
        agent,
        owner,
        profile \\ Platform.Agents.AgentRuntime.default_tool_profile()
      ) do
    n = System.unique_integer([:positive])

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "proto-reader-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        profile,
        Platform.Access.RuntimeProfiles.translated_permissions(profile)
      )

    %{runtime_id: runtime.runtime_id, agent_id: agent.id}
  end

  @doc "An agent publisher with no runtime owner."
  def agent_publisher(agent, owner \\ nil),
    do: %{kind: :agent, agent_id: agent.id, owner_user: owner}

  @doc "A small three-file bundle with a relative script, stylesheet and link."
  def bundle_files(marker \\ "v1") do
    %{
      "index.html" => %{
        "content" =>
          ~s(<!doctype html><link rel="stylesheet" href="./app.css"><a href="./b.html?screen=2">b</a><script src="./app.js"></script><!-- #{marker} -->)
      },
      "app.js" => %{"content" => "document.title = '#{marker}';"},
      "app.css" => %{"content" => "body { color: red; }"},
      "b.html" => %{"content" => "<p>b #{marker}</p>"}
    }
  end
end
