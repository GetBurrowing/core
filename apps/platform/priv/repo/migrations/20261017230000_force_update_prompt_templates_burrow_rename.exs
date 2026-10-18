defmodule Platform.Repo.Migrations.ForceUpdatePromptTemplatesBurrowRename do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task `01a14b9e-50a4-7000-996c-429bca872907` (Burrow rename A2), stage 3:
  force-update the stored prompt template rows whose descriptors name the
  product, so agents read "Burrow" instead of "Suite" / "Startup Suite".

  Copy-only change to four descriptors in
  `Platform.Orchestration.PromptTemplates`:

  - `federation.preamble`: "the Suite core test suite" and "The Suite MCP
    HTTP endpoint" now say Burrow;
  - `dispatch.review_e2e`: "via Suite MCP tools" now says Burrow;
  - `feedback.intake.v1`: "filed against Startup Suite", "a concrete defect
    in Suite", "improvement to Suite", "not about Suite" now say Burrow;
  - `janitor.cron_drain.v1`: "the Janitor for Startup Suite" now says Burrow.

  `{{feedback_guidance}}` is filled at render time from code
  (`PromptTemplates.feedback_guidance/1`), so its copy change needs no row.
  `Startup-Suite/core`, skill slugs and agent type names are identifiers and
  were not changed.

  `seed_defaults/0` is INSERT-only and a served row wins over its descriptor,
  so the descriptor edit alone reaches no existing deployment. This writes
  `default_content_for_slug/1` for each slug, guarded three ways by the md5 of
  the live row:

  - row equals the new descriptor: skip (idempotent, and a fresh install's
    row is seeded from current code);
  - md5 of the row is the measured pre-change md5: write the descriptor;
  - anything else: `Logger.warning` naming the slug and md5, then SKIP. An
    operator edit is never silently deleted; fold it into the descriptor and
    add its md5 here instead.

  Slugs with no row are skipped: `seed_defaults/0` owns first boot.

  Measured read-only (SELECT under `default_transaction_read_only`) on
  2026-10-17 22:30Z on all four installs on moon. Production installs run
  image revision 95040921; each pre-change md5 below equals md5 of the
  descriptor on origin/main 95040921, computed from the source:

  | slug                    | pre-change md5                     | core-platform (core_platform) | core-platform-milv (milv_platform) | core-platform-milvlife (milvlife_platform) | core-platform-exp (core_platform_exp) |
  | ----------------------- | ---------------------------------- | ----------------------------- | ---------------------------------- | ------------------------------------------ | ------------------------------------- |
  | `federation.preamble`   | `cd5c8e47b27fc6419cad360e956056b2` | match                         | match                              | match                                      | match                                 |
  | `dispatch.review_e2e`   | `0ec878e34edf00088bac0d4594ca45af` | match                         | match                              | match                                      | `e75607564b0fcfbb16a925d210a8002a`    |
  | `feedback.intake.v1`    | `6e1913735fb549661be6224de70009d8` | match                         | match                              | match                                      | match                                 |
  | `janitor.cron_drain.v1` | `10680d2c9880882f884b2bc675ff6760` | match                         | match                              | match                                      | match                                 |

  The exp install's `dispatch.review_e2e` row is not an operator edit: it is
  the pre-change md5 of `20261014180000_force_update_dispatch_templates_design_fidelity`,
  and exp's schema is at 20261013180000, so that earlier migration runs first
  and writes the current descriptor (which already says Burrow); this one then
  takes the descriptor-equality skip. No experiment targets any of the four
  slugs on any install.

  `down/0` is a no-op, as in
  `20261014180000_force_update_dispatch_templates_design_fidelity.exs`.
  """

  @pre_change_md5 %{
    "federation.preamble" => "cd5c8e47b27fc6419cad360e956056b2",
    "dispatch.review_e2e" => "0ec878e34edf00088bac0d4594ca45af",
    "feedback.intake.v1" => "6e1913735fb549661be6224de70009d8",
    "janitor.cron_drain.v1" => "10680d2c9880882f884b2bc675ff6760"
  }

  def pre_change_md5, do: @pre_change_md5

  def up, do: run(@pre_change_md5)

  def down, do: :ok

  @doc """
  Applies the three-way guard for every `slug => md5` in `pre_change`.
  Public so tests can model a deployed row with a stale body of their own.
  """
  def run(pre_change) when is_map(pre_change) do
    alias Platform.Orchestration.PromptTemplates

    for {slug, expected_md5} <- pre_change do
      with %{} = template <- PromptTemplates.get_template_by_slug(slug),
           content when is_binary(content) <- PromptTemplates.default_content_for_slug(slug) do
        live_md5 = md5(template.content)

        cond do
          template.content == content ->
            :skip

          live_md5 == expected_md5 ->
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})

          true ->
            Logger.warning(
              "force_update_prompt_templates_burrow_rename: skipping #{slug}: " <>
                "live md5 #{live_md5} is neither the pre-change md5 #{expected_md5} " <>
                "nor the new descriptor; an operator edit is preserved, fold it into the descriptor"
            )

            :skip
        end
      else
        _ -> :skip
      end
    end

    :ok
  end

  defp md5(content) when is_binary(content),
    do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

  defp md5(_), do: nil
end
