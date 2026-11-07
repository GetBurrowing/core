defmodule Platform.Agents.RoleTemplates do
  @moduledoc """
  The Control Center role templates an agent can be seeded from.

  Moved out of `PlatformWeb.ControlCenter.OnboardingEvents` (task 01a1b6ad
  stage 1), which still exposes them as `role_templates/0` for its chooser,
  so `Platform.Agents.Character` can read a class's tool profile and model
  from the context layer. The list itself is unchanged.
  """

  @templates [
    %{
      id: "designer",
      name: "Designer",
      icon: "hero-paint-brush",
      description: "Visual design, UI/UX, branding",
      default_name: "Designer",
      system_prompt: "You are a skilled visual designer...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["canvas", "image", "web_search"]
    },
    %{
      id: "researcher",
      name: "Researcher",
      icon: "hero-magnifying-glass",
      description: "Deep research, analysis, synthesis",
      default_name: "Researcher",
      system_prompt: "You are a thorough researcher...",
      model_tier: "high",
      suggested_model: "anthropic/claude-opus-4-6",
      tool_profile: "minimal",
      tools_allow: ["web_search", "web_fetch", "pdf", "group:fs"]
    },
    %{
      id: "architect",
      name: "Architect",
      icon: "hero-cube-transparent",
      description: "System design, ADRs, code review",
      default_name: "Architect",
      system_prompt: "You are a senior software architect...",
      model_tier: "high",
      suggested_model: "anthropic/claude-opus-4-6",
      tool_profile: "full",
      tools_allow: ["group:fs", "exec", "web_search"]
    },
    %{
      id: "writer",
      name: "Writer",
      icon: "hero-pencil-square",
      description: "Content, docs, copywriting",
      default_name: "Writer",
      system_prompt: "You are a skilled writer...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["group:fs", "web_search"]
    },
    %{
      id: "analyst",
      name: "Analyst",
      icon: "hero-chart-bar",
      description: "Data analysis, reporting, dashboards",
      default_name: "Analyst",
      system_prompt: "You are a data analyst...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["canvas", "web_fetch", "exec"]
    },
    %{
      id: "devops",
      name: "DevOps",
      icon: "hero-server-stack",
      description: "Infrastructure, CI/CD, monitoring",
      default_name: "DevOps",
      system_prompt: "You are a DevOps engineer...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "full",
      tools_allow: ["exec", "group:fs", "web_search"]
    },
    %{
      id: "pm",
      name: "Project Manager",
      icon: "hero-clipboard-document-list",
      description: "Planning, tracking, coordination",
      default_name: "PM",
      system_prompt: "You are a project manager...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["canvas", "web_search"]
    },
    %{
      id: "sales",
      name: "Sales",
      icon: "hero-currency-dollar",
      description: "Outreach, proposals, CRM",
      default_name: "Sales",
      system_prompt: "You are a sales professional...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["web_search", "web_fetch", "canvas"]
    }
  ]

  @doc "Every role template, in chooser order."
  @spec all() :: [map()]
  def all, do: @templates

  @doc "The template with `id`, or nil."
  @spec get(String.t() | nil) :: map() | nil
  def get(id) when is_binary(id), do: Enum.find(@templates, &(&1.id == id))
  def get(_), do: nil
end
