defmodule Platform.Chat.GroupMentionToken do
  @moduledoc "Stable group identities with message-time display labels."
  @namespace ~r/@\[group:[^\]]*\]/u
  @token ~r/@\[group:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\|([^\[\]\r\n]+)\]/u

  def encode(id, name) do
    if Regex.match?(~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, id) and
         is_binary(name) and String.trim(name) != "" and not Regex.match?(~r/[\[\]\r\n]/, name) do
      "@[group:#{String.downcase(id)}|#{name}]"
    else
      raise ArgumentError, "invalid group token"
    end
  end

  def parse(content) when is_binary(content) do
    Regex.scan(@token, content, capture: :all_but_first)
    |> Enum.map(fn [id, name] -> %{id: String.downcase(id), name: name} end)
    |> Enum.reject(&(String.trim(&1.name) == ""))
    |> Enum.uniq_by(& &1.id)
  end

  def parse(_), do: []
  def strip(content) when is_binary(content), do: Regex.replace(@namespace, content, "")
  def strip(other), do: other
end
