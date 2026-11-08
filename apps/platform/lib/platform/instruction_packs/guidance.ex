defmodule Platform.InstructionPacks.Guidance do
  @moduledoc """
  Consumed text targets for the existing install-managed setup guide.

  NativeAgents seeds its instructions file once. Updating a seed alone would
  not reach an existing agent. These PromptTemplates instead travel on each
  eligible attention through its existing prompt/context fields. No file,
  runtime lifecycle, identity, authority or tool configuration is changed.
  Local instructions retain precedence over this supplemental guidance.
  """
  alias Platform.Agents.{Agent, Burrow, NativeAgents, SlugLookup}
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  @role "agents.burrow.role.v1"
  @setup "agents.burrow.setup.v1"
  def slugs, do: [@role, @setup]
  def target("role_prompt", "burrow"), do: {:ok, @role}
  def target("setup_dialogue", "burrow"), do: {:ok, @setup}
  def target(_, _), do: {:error, :missing_target_mapping}

  # The source is the real setup-guide consumer extended by task 01a1b6de.
  # No independently maintained copy of that text.
  def defaults do
    shared = NativeAgents.identity_template("Burrow", "claude_code")
    text = String.replace_prefix(Burrow.identity_template("Burrow", "claude_code"), shared, "")
    [role, setup] = String.split(text, "## Helping your owner finish setup", parts: 2)
    [{@role, role}, {@setup, "## Helping your owner finish setup" <> setup}]
  end

  def seed do
    for {slug, content} <- defaults() do
      unless PromptTemplates.get_template_by_slug(slug) do
        {:ok, _} =
          PromptTemplates.create_template(%{
            slug: slug,
            name: slug,
            description: "Supplemental saved install-guide instructions",
            content: content
          })
      end
    end

    :ok
  end

  def enrich(payload, agent_ref) do
    case agent(agent_ref) do
      %Agent{slug: "burrow"} = agent ->
        if Burrow.burrow?(agent), do: enrich_guide(payload), else: payload

      _ ->
        payload
    end
  end

  defp enrich_guide(%{signal: %{prompt: prompt} = signal} = payload)
       when is_binary(prompt) and prompt != "" do
    Map.put(payload, :signal, Map.put(signal, :prompt, text() <> "\n\n" <> prompt))
  end

  defp enrich_guide(%{context: %{org: org} = context} = payload) when is_map(org) do
    # Reuse the context map every channel runtime already renders. The label
    # names the real data source rather than impersonating an org wiki page.
    pages = Map.put(org, "instruction-guidance/burrow", text())
    Map.put(payload, :context, Map.put(context, :org, pages))
  end

  # A deliberate no-work / absent-prompt event must stay absent. Never turn
  # supplemental guidance alone into a new model invocation.
  defp enrich_guide(payload), do: payload

  defp text do
    content =
      Enum.map_join(slugs(), "\n\n", fn slug ->
        case PromptTemplates.get_template_by_slug(slug) do
          nil -> ""
          row -> row.content
        end
      end)

    "Supplemental saved guidance (PromptTemplates; local instructions take precedence):\n" <>
      content
  end

  defp agent(%Agent{} = value), do: value

  defp agent(value) when is_binary(value) do
    if Platform.UUID.valid?(value) do
      Repo.get(Agent, value)
    else
      case SlugLookup.resolve(value) do
        {:ok, agent} -> agent
        _ -> nil
      end
    end
  end

  defp agent(_), do: nil
end
