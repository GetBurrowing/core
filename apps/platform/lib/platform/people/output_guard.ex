defmodule Platform.People.OutputGuard do
  @moduledoc """
  Renders the external dispatch path's structured people-profile output into
  the two page tiers and runs both through `Platform.People.PageGuard`.

  Input shape (string keys, as the structured-output schema delivers it):

      %{
        "slug" => "...", "name" => "...", "aliases" => [...], "user_id" => "...",
        "relation" => "...", "organisation" => "...", "role" => "...",
        "current_projects" => [...],
        "interactions" => [%{"date", "kind", "title", "citation"}],
        "perspectives" => [%{"statement", "said_by_subject", "citation"}],
        "agents" => [...]
      }

  A perspective whose `said_by_subject` is not exactly `true` is dropped
  BEFORE rendering — it never reaches either tier — and the drop is counted
  under `counts.dropped_others_said`.
  """

  alias Platform.People.PageGuard

  @frontmatter_keys ~w(name aliases user_id relation organisation role last_seen)

  @type rendered :: %{
          card: String.t(),
          private: String.t(),
          counts: %{
            dropped_others_said: non_neg_integer(),
            card: PageGuard.counts(),
            private: PageGuard.counts()
          }
        }

  @doc "Renders `profile` into guarded `:card` and `:private` markdown."
  @spec render(map()) :: rendered()
  def render(profile) when is_map(profile) do
    perspectives = list(profile, "perspectives")
    own = Enum.filter(perspectives, &(Map.get(&1, "said_by_subject") == true))
    dropped_others_said = length(perspectives) - length(own)

    body = body(Map.put(profile, "perspectives", own))

    {card, card_counts} = PageGuard.enforce(:card, page(:card, profile, body))
    {private, private_counts} = PageGuard.enforce(:private, page(:private, profile, body))

    %{
      card: card,
      private: private,
      counts: %{
        dropped_others_said: dropped_others_said,
        card: card_counts,
        private: private_counts
      }
    }
  end

  # -- rendering ----------------------------------------------------------------

  defp page(tier, profile, body) do
    frontmatter =
      @frontmatter_keys
      |> Enum.map(fn key -> {key, frontmatter_value(Map.get(profile, key))} end)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)

    Enum.join(["---", "tier: #{tier}"] ++ frontmatter ++ ["---", "", body], "\n")
  end

  defp frontmatter_value(nil), do: ""
  defp frontmatter_value(list) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)
  defp frontmatter_value(value), do: value |> to_string() |> String.trim()

  defp body(profile) do
    [
      section("Role", [text(profile, "role")]),
      section("Current projects", bullets(list(profile, "current_projects"))),
      section("Interactions", Enum.map(list(profile, "interactions"), &interaction/1)),
      section("Perspectives", Enum.map(list(profile, "perspectives"), &perspective/1)),
      section("Agents", bullets(list(profile, "agents")))
    ]
    |> Enum.join("\n")
  end

  defp section(name, lines) do
    lines = lines |> Enum.map(&to_string/1) |> Enum.reject(&(String.trim(&1) == ""))
    Enum.join(["## #{name}" | lines] ++ [""], "\n")
  end

  defp bullets(items), do: Enum.map(items, &"- #{&1}")

  defp interaction(%{} = item) do
    "- #{text(item, "date")} #{text(item, "kind")}: #{text(item, "title")}#{cite(item)}"
  end

  defp interaction(_), do: ""

  defp perspective(%{} = item), do: "- #{text(item, "statement")} — own words#{cite(item)}"
  defp perspective(_), do: ""

  defp cite(item) do
    case text(item, "citation") do
      "" -> ""
      ref -> " [cite: #{ref}]"
    end
  end

  defp text(map, key), do: map |> Map.get(key) |> frontmatter_value()

  defp list(map, key) do
    case Map.get(map, key) do
      items when is_list(items) -> items
      _ -> []
    end
  end
end
