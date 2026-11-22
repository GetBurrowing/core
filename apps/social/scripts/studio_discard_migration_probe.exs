# Run only with MIX_ENV=test and a dedicated freshly migrated database named
# studio_discard_probe_*. This probe runs the migration down and back up.
db = System.get_env("PLATFORM_TEST_DATABASE", "")

unless Mix.env() == :test and String.starts_with?(db, "studio_discard_probe_") and
         System.get_env("STUDIO_DISCARD_DISPOSABLE_DB") == db do
  raise "a dedicated studio_discard_probe_* database must be explicitly selected"
end

Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :auto)
Code.require_file("priv/repo/migrations/20261122120000_add_studio_draft_discard.exs")
alias Platform.Repo
alias Platform.Social.{PostEvent, Studio}
import Ecto.Query
import Platform.SocialStudioFixtures

w = studio_world!()
post = studio_post!(w, w.x, "draft")
{:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
version = 20_261_122_120_000
migration = Platform.Repo.Migrations.AddStudioDraftDiscard

refuse = fn label ->
  try do
    Ecto.Migrator.down(Repo, version, migration, log: false)
    raise "#{label} unexpectedly allowed migration down"
  rescue
    e in Postgrex.Error ->
      unless Exception.message(e) =~ "cannot roll back Studio draft discard",
        do: reraise(e, __STACKTRACE__)

      IO.puts("#{label}: refused")
  end
end

refuse.("marked row")
{:ok, _} = Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))
refuse.("restored event history")
# This probe uses its own disposable database; remove only its synthetic events.
Repo.delete_all(
  from(e in PostEvent, where: e.post_id == ^post.id and e.action in ["discarded", "restored"])
)

:ok = Ecto.Migrator.down(Repo, version, migration, log: false)
IO.puts("empty discard state: down succeeds")
:ok = Ecto.Migrator.up(Repo, version, migration, log: false)
IO.puts("migration restored")
