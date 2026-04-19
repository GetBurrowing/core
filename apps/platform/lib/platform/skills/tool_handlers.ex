defmodule Platform.Skills.ToolHandlers do
  @moduledoc """
  Agent tool handlers for the skill registry — `skill.list`, `skill.get`,
  `skill.upsert`.

  Skills are centrally-distributed markdown playbooks (see
  `Platform.Skills`). These tools let agents discover what skills exist
  and publish new ones without having to drop down to a direct DB edit.
  """

  alias Platform.Skills

  @doc """
  skill.list — return skill summaries (slug, name, description, size).

  Optional `query` arg does a case-insensitive substring match against
  name + description + slug. Content body is omitted from list results
  to keep payloads small; call `skill.get` to fetch content.
  """
  @spec list(map(), map()) :: {:ok, map()}
  def list(args, _context) do
    query = args |> Map.get("query") |> normalize_query()
    skills = Skills.list_skills()

    filtered =
      case query do
        nil -> skills
        q -> Enum.filter(skills, &matches?(&1, q))
      end

    {:ok,
     %{
       count: length(filtered),
       skills: Enum.map(filtered, &summary/1)
     }}
  end

  @doc """
  skill.get — fetch a full skill (including markdown content) by `slug` or `id`.
  """
  @spec get(map(), map()) :: {:ok, map()} | {:error, map()}
  def get(args, _context) do
    slug = Map.get(args, "slug")
    id = Map.get(args, "id")

    skill =
      cond do
        is_binary(slug) and slug != "" -> Skills.get_skill_by_slug(slug)
        is_binary(id) and id != "" -> Skills.get_skill(id)
        true -> nil
      end

    case {skill, slug, id} do
      {nil, nil, nil} ->
        {:error,
         %{
           error: "skill.get requires either `slug` or `id`",
           recoverable: true
         }}

      {nil, _, _} ->
        {:error,
         %{
           error: "skill not found",
           recoverable: false,
           slug: slug,
           id: id
         }}

      {%{} = s, _, _} ->
        {:ok, detail(s)}
    end
  end

  @doc """
  skill.upsert — create or update a skill by name.

  Required: `name`, `content` (full markdown body).
  Optional: `description`.

  Slug is auto-derived from the name (same logic as the Skills.Skill
  changeset). Calling with an existing name replaces content and
  description. Calling with a new name creates a new skill.
  """
  @spec upsert(map(), map()) :: {:ok, map()} | {:error, map()}
  def upsert(args, _context) do
    with {:ok, name} <- require_string(args, "name"),
         {:ok, content} <- require_string(args, "content") do
      description = Map.get(args, "description")

      attrs = %{
        name: name,
        content: content,
        description: description
      }

      expected_slug = slugify(name)

      result =
        case Skills.get_skill_by_slug(expected_slug) do
          nil ->
            case Skills.create_skill(attrs) do
              {:ok, s} -> {:ok, s, :created}
              other -> other
            end

          existing ->
            case Skills.update_skill(existing, attrs) do
              {:ok, s} -> {:ok, s, :updated}
              other -> other
            end
        end

      case result do
        {:ok, skill, action} ->
          {:ok, Map.put(detail(skill), :action, action)}

        {:error, %Ecto.Changeset{} = cs} ->
          {:error,
           %{
             error: "skill.upsert: #{format_changeset(cs)}",
             recoverable: true,
             field_errors: cs.errors |> Enum.map(fn {k, {m, _}} -> {k, m} end) |> Map.new()
           }}
      end
    end
  end

  # ── Shape helpers ──────────────────────────────────────────────────────

  defp summary(s) do
    %{
      id: s.id,
      slug: s.slug,
      name: s.name,
      description: s.description,
      content_size: (s.content || "") |> byte_size(),
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp detail(s) do
    %{
      id: s.id,
      slug: s.slug,
      name: s.name,
      description: s.description,
      content: s.content,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp normalize_query(nil), do: nil
  defp normalize_query(""), do: nil

  defp normalize_query(q) when is_binary(q) do
    q |> String.trim() |> String.downcase() |> nil_if_blank()
  end

  defp normalize_query(_), do: nil

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp matches?(s, q) do
    haystack =
      [s.name, s.description, s.slug]
      |> Enum.map(&(&1 || ""))
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, q)
  end

  defp require_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error, %{error: "missing or invalid \"#{key}\" (non-empty string)", recoverable: true}}
    end
  end

  defp slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp format_changeset(cs) do
    cs.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join("; ")
  end
end
