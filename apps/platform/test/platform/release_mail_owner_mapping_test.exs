defmodule Platform.ReleaseMailOwnerMappingTest do
  @moduledoc """
  `Platform.Release.apply_mail_owner_mapping/2` (task 01a1ea5b stage 5):
  dry-run by default, idempotent, never deletes or reassigns, refuses
  unknown addresses and users, and changes NOTHING on any refusal.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures

  alias Platform.Audit.Event
  alias Platform.Mail.{Account, AccountGrant, Ownership}
  alias Platform.Release

  setup do
    org_id = acme_org_id()
    admin = user!("admin") |> member!(org_id, "admin")
    owner = user!("owner") |> member!(org_id)
    mate = user!("mate") |> member!(org_id)
    n = unique()

    personal = account!(admin, org_id, %{"username" => "own#{n}@mapping.test"})
    shared = account!(admin, org_id, %{"username" => "team#{n}@mapping.test"})
    dir = Path.join(System.tmp_dir!(), "mail-owner-mapping-#{n}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{
      org_id: org_id,
      admin: admin,
      owner: owner,
      mate: mate,
      n: n,
      personal: personal,
      shared: shared,
      dir: dir
    }
  end

  defp write!(ctx, mapping) do
    path = Path.join(ctx.dir, "mapping-#{unique()}.json")
    File.write!(path, Jason.encode!(mapping))
    path
  end

  defp good(ctx) do
    %{
      ctx.personal.username => %{"kind" => "personal", "owner_email" => ctx.owner.email},
      ctx.shared.username => %{
        "kind" => "shared",
        "member_emails" => [ctx.owner.email, ctx.mate.email]
      }
    }
  end

  defp run(path, opts) do
    {result, output} = with_io(fn -> Release.apply_mail_owner_mapping(path, opts) end)
    {result, output}
  end

  defp kind(account), do: Repo.one!(from(a in Account, where: a.id == ^account.id))

  defp audit_count,
    do: Repo.aggregate(from(e in Event, where: e.event_type == "platform.mail.ownership"), :count)

  defp grant_count,
    do: Repo.aggregate(AccountGrant, :count)

  test "a dry run writes nothing and says what it would do", ctx do
    path = write!(ctx, good(ctx))
    before = {audit_count(), grant_count()}

    {{:ok, %{dry_run: true, outcomes: outcomes}}, output} =
      run(path, actor_email: ctx.admin.email)

    assert {audit_count(), grant_count()} == before
    assert kind(ctx.personal).owner_kind == "unassigned"
    assert kind(ctx.shared).owner_kind == "unassigned"
    assert output =~ "DRY RUN"
    assert output =~ "would set personal, owner #{ctx.owner.email}"
    assert Enum.any?(outcomes, fn {_label, text} -> text =~ "would set shared" end)
  end

  test "apply assigns owners and members, one audit row per write, and is idempotent", ctx do
    path = write!(ctx, good(ctx))
    audits = audit_count()

    {{:ok, %{dry_run: false}}, output} = run(path, actor_email: ctx.admin.email, apply: true)
    assert output =~ "APPLY"

    assert %{owner_kind: "personal", owner_user_id: owner_id} = kind(ctx.personal)
    assert owner_id == ctx.owner.id
    assert kind(ctx.shared).owner_kind == "shared"
    assert Ownership.can_read_account?(ctx.mate, ctx.shared)
    assert Ownership.can_read_account?(ctx.owner, ctx.shared)
    # set_owner x2 + grant x2.
    assert audit_count() == audits + 4

    {{:ok, %{outcomes: outcomes}}, _} = run(path, actor_email: ctx.admin.email, apply: true)
    assert Enum.all?(outcomes, fn {_label, text} -> text == "unchanged" end)
    assert audit_count() == audits + 4
  end

  test "any refusal rolls back the whole run: nothing changes", ctx do
    mapping =
      good(ctx)
      |> Map.put("nobody#{ctx.n}@mapping.test", %{"kind" => "shared"})

    path = write!(ctx, mapping)
    before = {audit_count(), grant_count()}

    {{:error, %{refusals: refusals}}, output} =
      run(path, actor_email: ctx.admin.email, apply: true)

    assert [{label, text}] = refusals
    assert label == "nobody#{ctx.n}@mapping.test"
    assert text =~ "no mail account"
    assert output =~ "REFUSED, nothing was changed"
    assert {audit_count(), grant_count()} == before
    assert kind(ctx.personal).owner_kind == "unassigned"
    assert kind(ctx.shared).owner_kind == "unassigned"
  end

  test "an unknown user, a non-member and a non-admin actor are refused", ctx do
    outsider = user!("outsider")

    for {entry, expected} <- [
          {%{"kind" => "personal", "owner_email" => "ghost#{ctx.n}@mapping.test"},
           "is not a user"},
          {%{"kind" => "personal", "owner_email" => outsider.email}, "not an internal member"},
          {%{"kind" => "personal"}, "owner_email is required"},
          {%{"kind" => "team"}, "kind must be"},
          {%{"kind" => "shared", "owner_email" => ctx.owner.email}, "has no owner"}
        ] do
      path = write!(ctx, Map.put(good(ctx), ctx.personal.username, entry))

      assert {{:error, %{refusals: refusals}}, _} =
               run(path, actor_email: ctx.admin.email, apply: true)

      assert Enum.any?(refusals, fn {_l, text} -> text =~ expected end), inspect(refusals)
      assert kind(ctx.shared).owner_kind == "unassigned"
    end

    path = write!(ctx, good(ctx))

    assert {{:error, %{refusals: refusals}}, _} =
             run(path, actor_email: ctx.mate.email, apply: true)

    assert Enum.all?(refusals, fn {_l, text} -> text =~ "not an admin" end)
    assert {{:error, _}, _} = run(path, apply: true)
    assert kind(ctx.personal).owner_kind == "unassigned"
  end

  test "it never reassigns or deletes: an account owned differently is refused, grants kept",
       ctx do
    {:ok, _} =
      Ownership.set_owner(ctx.admin, ctx.personal, %{kind: "personal", owner_user_id: ctx.mate.id})

    agent = agent!()
    {:ok, _} = Ownership.grant(ctx.mate, ctx.personal, {:agent, agent.id})
    grants = grant_count()

    path = write!(ctx, good(ctx))

    assert {{:error, %{refusals: refusals}}, _} =
             run(path, actor_email: ctx.admin.email, apply: true)

    assert Enum.any?(refusals, fn {_l, text} -> text =~ "already assigned" end)
    assert kind(ctx.personal).owner_user_id == ctx.mate.id
    assert grant_count() == grants
  end

  test "an address several accounts log in with needs account_name per entry", ctx do
    twin =
      account!(ctx.admin, ctx.org_id, %{
        "username" => ctx.personal.username,
        "name" => "Meetings #{ctx.n}"
      })

    path =
      write!(ctx, %{
        ctx.personal.username => %{"kind" => "personal", "owner_email" => ctx.owner.email}
      })

    assert {{:error, %{refusals: [{_, text}]}}, _} =
             run(path, actor_email: ctx.admin.email, apply: true)

    assert text =~ "must name its account_name"

    path =
      write!(ctx, %{
        String.upcase(ctx.personal.username) => [
          %{
            "account_name" => ctx.personal.name,
            "kind" => "personal",
            "owner_email" => ctx.owner.email
          },
          %{"account_name" => twin.name, "kind" => "shared", "member_emails" => []}
        ]
      })

    assert {{:ok, _}, _} = run(path, actor_email: ctx.admin.email, apply: true)
    assert kind(ctx.personal).owner_kind == "personal"
    assert kind(twin).owner_kind == "shared"
  end

  test "one account mapped twice is refused, so a run never reassigns its own write", ctx do
    path =
      write!(ctx, %{
        ctx.personal.username => %{"kind" => "personal", "owner_email" => ctx.owner.email},
        String.upcase(ctx.personal.username) => %{"kind" => "shared"}
      })

    assert {{:error, %{refusals: refusals}}, _} =
             run(path, actor_email: ctx.admin.email, apply: true)

    assert length(refusals) == 2
    assert Enum.all?(refusals, fn {_l, text} -> text =~ "mapped more than once" end)
    assert kind(ctx.personal).owner_kind == "unassigned"
  end

  test "a missing or malformed file is refused", ctx do
    assert {{:error, _}, _} = run(Path.join(ctx.dir, "absent.json"), actor_email: ctx.admin.email)
    bad = Path.join(ctx.dir, "bad.json")
    File.write!(bad, "[1, 2]")
    assert {{:error, %{refusals: [{_, text}]}}, _} = run(bad, actor_email: ctx.admin.email)
    assert text =~ "JSON object"
  end

  test "the shipped example mapping parses, and on an install without those accounts is refused",
       ctx do
    path = Application.app_dir(:platform, "priv/mail_owner_mappings/example.json")
    assert {:ok, %{} = mapping} = path |> File.read!() |> Jason.decode()
    assert map_size(mapping) >= 1

    assert {{:error, %{refusals: refusals}}, _} = run(path, actor_email: ctx.admin.email)
    assert Enum.all?(refusals, fn {_l, text} -> text =~ "no mail account" end)
  end
end
