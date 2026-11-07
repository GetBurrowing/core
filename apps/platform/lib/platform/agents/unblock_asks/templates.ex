defmodule Platform.Agents.UnblockAsks.Templates do
  @moduledoc """
  The ask templates (task 01a1b6de stage 4): one per blocker class, plus one
  for a person stuck on setup steps. DATA with placeholders only, never a real
  name, account or host:

    * `{agent}` — the stuck agent's name;
    * `{owner}` — the person the ask is addressed to;
    * `{org}` / `{repo}` — the repository the agent was refused, read from the
      refusal text;
    * `{account}` — the account the agent pushes as, read from the refusal
      text;
    * `{setting}` — where a setting lives on this install.

  A template is `%{title, subtitle, steps, primary, secondary, success,
  still_missing}`. `steps` are `%{text, copy}` maps (`copy` is the literal the
  person types, shown with a Copy button, or nil). `primary` is the ONE
  primary button `%{label, url}`, or nil when the fix has no single place to
  go. `secondary` are the three secondary actions in order.

  `access` is the GitHub write template and needs `{org}` and `{repo}`; an
  access refusal whose repository cannot be read renders `access_other`.
  """

  @secondary ["I did it, check again", "Not now", "Why?"]

  @placeholders ~w(agent owner org repo account setting)

  @templates %{
    "access" => %{
      title: "Give {agent} write access so they can save code to your project",
      subtitle: "{agent} can read it but not save changes. Takes about 2 minutes.",
      steps: [
        %{text: "Open your project's access settings", copy: nil},
        %{text: "Click \"Add people\"", copy: nil},
        %{text: "Type {account}", copy: "{account}"},
        %{text: "Choose \"Write\", then \"Add\"", copy: nil}
      ],
      primary: %{
        label: "Open GitHub access",
        url: "https://github.com/{org}/{repo}/settings/access"
      },
      success: "Unblocked. {agent} can save changes to your project now.",
      still_missing: "{agent} still can't save changes to your project."
    },
    "access_other" => %{
      title: "Give {agent} the access it was refused",
      subtitle: "{agent} tried to do its work and was turned away.",
      steps: [
        %{text: "Open \"Why?\" to see what {agent} was refused", copy: nil},
        %{text: "Open that service's sharing or access settings", copy: nil},
        %{text: "Add {account} with the access it needs", copy: "{account}"}
      ],
      primary: nil,
      success: "Unblocked. {agent} has the access it needed.",
      still_missing: "{agent} is still being refused."
    },
    "credentials" => %{
      title: "Reconnect {agent}'s sign-in so they can keep working",
      subtitle: "The sign-in {agent} uses has expired or was turned down.",
      steps: [
        %{text: "Open {setting}", copy: nil},
        %{text: "Find {agent} and choose \"Reconnect\"", copy: nil},
        %{text: "Sign in again when asked", copy: nil}
      ],
      primary: %{label: "Open agent settings", url: "/control"},
      success: "Unblocked. {agent} is signed in again.",
      still_missing: "{agent}'s sign-in is still being turned down."
    },
    "toolchain" => %{
      title: "Install the tool {agent} is missing so they can finish",
      subtitle: "{agent} needs a program that isn't installed where it runs.",
      steps: [
        %{text: "Open \"Why?\" to see which program is missing", copy: nil},
        %{text: "Install it on the computer {agent} runs on", copy: nil},
        %{text: "Come back and choose \"I did it, check again\"", copy: nil}
      ],
      primary: nil,
      success: "Unblocked. {agent} has what it needs.",
      still_missing: "{agent} still can't find the program it needs."
    },
    "spend_consent" => %{
      title: "Approve spending so {agent} can keep working",
      subtitle: "{agent} ran out of credits or needs your OK to spend more.",
      steps: [
        %{text: "Open {setting}", copy: nil},
        %{text: "Top up credits or raise the limit", copy: nil}
      ],
      primary: %{label: "Open billing", url: "/control"},
      success: "Unblocked. {agent} can spend again.",
      still_missing: "{agent} still can't spend."
    },
    "offline" => %{
      title: "Bring {agent} back online so they can pick up work",
      subtitle: "{agent} hasn't connected for a while.",
      steps: [
        %{text: "Check the computer {agent} runs on is on and awake", copy: nil},
        %{text: "Restart {agent} there", copy: nil}
      ],
      primary: %{label: "Open agents", url: "/control"},
      success: "Unblocked. {agent} is back online.",
      still_missing: "{agent} still hasn't connected."
    },
    "person_setup" => %{
      title: "Finish setting up so your team can reach you",
      subtitle: "A few setup steps are still open.",
      steps: [],
      primary: %{label: "Open settings", url: "/settings"},
      success: "All set. Your setup is done.",
      still_missing: "Still to do:"
    }
  }

  # One step per person-setup step a person can be stuck on
  # (`Platform.Onboarding.PersonSetup.steps/0`).
  @person_steps %{
    "signed_in" => "Sign in once",
    "notifications" => "Turn on notifications in {setting}",
    "ai_login" => "Connect your AI login in {setting}",
    "channels" => "Join a channel",
    "who_to_ask" => "Read the welcome note that says who to ask"
  }

  @doc "The placeholders a template may use."
  @spec placeholders() :: [String.t()]
  def placeholders, do: @placeholders

  @doc "The secondary actions every ask offers, in order."
  @spec secondary() :: [String.t()]
  def secondary, do: @secondary

  @doc "Every template, keyed by template name."
  @spec all() :: %{String.t() => map()}
  def all, do: @templates

  @doc "The step text per person-setup step."
  @spec person_steps() :: %{String.t() => String.t()}
  def person_steps, do: @person_steps

  @doc """
  The template name for a class and its details: `access` needs a known
  `org` and `repo`, else `access_other`.
  """
  @spec template_name(String.t(), map()) :: String.t()
  def template_name("access", details) do
    if present?(details["org"]) and present?(details["repo"]), do: "access", else: "access_other"
  end

  def template_name(class, _details) when is_map_key(@templates, class), do: class
  def template_name(_class, _details), do: "access_other"

  @doc """
  Render the template for `class` with `values` (string keys from
  `placeholders/0`). Unknown values render a neutral phrase, never a raw
  `{placeholder}`. For `person_setup`, `values["steps"]` (a list of step
  names) becomes the numbered steps.
  """
  @spec render(String.t(), map()) :: map()
  def render(class, values) when is_map(values) do
    name = template_name(class, values)
    template = Map.fetch!(@templates, name)
    fill = &fill(&1, values)

    steps =
      if name == "person_setup" do
        values
        |> Map.get("steps", [])
        |> List.wrap()
        |> Enum.map(&Map.get(@person_steps, to_string(&1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&%{text: fill.(&1), copy: nil})
      else
        Enum.map(template.steps, fn step ->
          %{text: fill.(step.text), copy: step.copy && fill.(step.copy)}
        end)
      end

    %{
      template: name,
      title: fill.(template.title),
      subtitle: fill.(template.subtitle),
      steps: steps,
      primary:
        template.primary && %{label: template.primary.label, url: fill.(template.primary.url)},
      secondary: @secondary,
      success: fill.(template.success),
      still_missing: fill.(template.still_missing)
    }
  end

  @fallbacks %{
    "agent" => "your agent",
    "owner" => "you",
    "org" => "your-org",
    "repo" => "your-repo",
    "account" => "the account your agent uses",
    "setting" => "Settings"
  }

  defp fill(text, values) do
    Regex.replace(~r/\{([a-z_]+)\}/, text, fn whole, key ->
      cond do
        present?(values[key]) -> to_string(values[key])
        Map.has_key?(@fallbacks, key) -> Map.fetch!(@fallbacks, key)
        true -> whole
      end
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
