defmodule Mix.Tasks.Platform.PromptTemplate.Show do
  @moduledoc """
  Print the LIVE `prompt_templates` row for a slug, with a sha256 of its body.

      mix platform.prompt_template.show --slug meetings.intent_classify.v1
      mix platform.prompt_template.show --slug meetings.intent_classify.v1 --sha-only

  ## Why a task and not an IEx snippet

  Editing `PromptTemplates.do_default_templates/0` is a RUNTIME NO-OP:
  `seed_defaults/0` is INSERT-only and `render_template/2` prefers the row
  that already exists, so a source diff can look shipped while every
  environment keeps serving the old body. The recorded cost of not being
  able to check cheaply is six wrong diagnoses and one source-only-fix
  false-done.

  A snippet in a runbook is re-derived (and mistyped) each time. This task is
  one reproducible invocation that can be pasted into a deploy log and diffed
  across environments, and it yields a sha the reviewer can quote — the same
  property `Platform.Meetings.IntentEval.Harness` already relies on when it
  records `sha256(rendered_prompt)` into a run manifest.

  ## A missing row must not read as an empty template

  When the slug has no row the task raises `Mix.Error` (exit status 1) with
  the slug named in the message. Printing an empty body would be
  indistinguishable from a row whose content is empty, and that ambiguity is
  precisely the failure mode this exists to prevent.

  ## Read-only, on purpose

  Nothing here writes. Force-updating a row stays the migration's job, and
  operator iteration stays the `prompt_template_update` MCP tool's job.
  """

  use Mix.Task

  alias Platform.Orchestration.PromptTemplates

  @shortdoc "Print the live prompt_templates row for a slug, with its sha256"

  @switches [
    slug: :string,
    sha_only: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    slug = parsed[:slug] || Mix.raise("--slug <slug> is required")
    sha_only? = parsed[:sha_only] || false

    slug
    |> fetch!()
    |> report(sha_only?)
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  @doc """
  Fetch the live row, raising a named `Mix.Error` when it is absent.

  Separated from `run/1` so a test can exercise the absent-row branch without
  driving `OptionParser` and the shell.
  """
  @spec fetch!(String.t()) :: Platform.Orchestration.PromptTemplate.t()
  def fetch!(slug) do
    case PromptTemplates.get_template_by_slug(slug) do
      nil ->
        Mix.raise(
          "no prompt_templates row for slug #{inspect(slug)} in this environment — " <>
            "the template is ABSENT, not empty. Run the seed or the force-update " <>
            "migration against this database before reading it."
        )

      template ->
        template
    end
  end

  @doc """
  Render the report lines for a template.

  Returns the header lines always; the body only when `sha_only?` is false.

  ## Examples

      iex> t = %Platform.Orchestration.PromptTemplate{slug: "a", content: "hi", variables: []}
      iex> Mix.Tasks.Platform.PromptTemplate.Show.report(t, true) |> Enum.any?(&(&1 == "hi"))
      false
  """
  @spec report(Platform.Orchestration.PromptTemplate.t(), boolean()) :: [String.t()]
  def report(template, sha_only?) do
    header = [
      "slug:       #{template.slug}",
      "updated_at: #{inspect(template.updated_at)}",
      "updated_by: #{inspect(template.updated_by)}",
      "variables:  #{inspect(template.variables)}",
      "bytes:      #{byte_size(template.content || "")}",
      "sha256:     #{sha256(template.content || "")}"
    ]

    if sha_only? do
      header
    else
      header ++ ["", "--- content ---", template.content || ""]
    end
  end

  @doc "Lowercase hex sha256 of a binary, in the form `Harness` records."
  @spec sha256(binary()) :: String.t()
  def sha256(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end
end
