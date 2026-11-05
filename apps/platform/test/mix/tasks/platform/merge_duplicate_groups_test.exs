defmodule Mix.Tasks.Platform.MergeDuplicateGroupsTest do
  @moduledoc """
  `mix platform.merge_duplicate_groups` (task 01a1acea stage 2): report by
  default, `--apply` merges, a second `--apply` changes nothing. Also pins
  that the task is never wired into deploy.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.MergeDuplicateGroups
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Attachment, Message, Participant, Pin, Reaction, Space}
  alias Platform.Repo

  @t0 ~U[2026-01-01 10:00:00.000000Z]

  defp user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "merge-dup-#{n}@example.com",
      name: "Dev #{label} #{n}",
      oidc_sub: "oidc-merge-dup-#{n}"
    })
    |> Repo.insert!()
  end

  defp seed_group!(users) do
    [creator | _] = users

    space =
      %Space{}
      |> Space.changeset(%{kind: "group", is_direct: false, created_by: creator.id})
      |> Repo.insert!()

    for user <- users do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })
    end

    space
  end

  defp pid_of(space, user) do
    [id] =
      Repo.all(
        from(p in Participant,
          where:
            p.space_id == ^space.id and p.participant_type == "user" and
              p.participant_id == ^user.id,
          select: p.id
        )
      )

    id
  end

  defp message!(space, user, seconds) do
    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: pid_of(space, user),
      content_type: "text",
      content: "m#{seconds}",
      inserted_at: DateTime.add(@t0, seconds, :second)
    })
  end

  defp run_task(args), do: capture_io(fn -> MergeDuplicateGroups.run(args) end)

  defp state(ids) do
    %{
      spaces:
        Repo.all(
          from(s in Space,
            where: s.id in ^ids,
            order_by: s.id,
            select: {s.id, s.archived_at, s.updated_at}
          )
        ),
      messages:
        Repo.all(
          from(m in Message,
            where: m.space_id in ^ids,
            order_by: m.id,
            select: {m.id, m.space_id, m.participant_id}
          )
        ),
      pins: Repo.all(from(p in Pin, order_by: p.id, select: {p.id, p.space_id, p.pinned_by})),
      attachments: Repo.all(from(a in Attachment, order_by: a.id, select: {a.id, a.space_id})),
      reactions:
        Repo.all(
          from(r in Reaction, order_by: r.id, select: {r.id, r.message_id, r.participant_id})
        ),
      counts:
        for(s <- [Space, Participant, Message], into: %{}, do: {s, Repo.aggregate(s, :count)})
    }
  end

  test "report, then --apply, then --apply again" do
    [a, b, c] = users = for l <- ~w(Alice Bob Carol), do: user!(l)

    older = seed_group!(users)
    group_b = seed_group!(users)

    o1 = message!(older, a, 0)
    message!(group_b, b, 10)
    o2 = message!(older, c, 20)
    message!(group_b, a, 30)

    reaction =
      Repo.insert!(%Reaction{message_id: o1.id, participant_id: pid_of(older, b), emoji: "+1"})

    pin = Repo.insert!(%Pin{space_id: older.id, message_id: o2.id, pinned_by: pid_of(older, a)})

    attachment =
      Repo.insert!(%Attachment{
        space_id: older.id,
        message_id: o1.id,
        filename: "notes.txt",
        content_type: "text/plain",
        byte_size: 5,
        storage_key: "merge-dup/#{System.unique_integer([:positive])}"
      })

    ids = [older.id, group_b.id]
    before = state(ids)

    # 1. Report only.
    out = run_task([])
    assert out =~ "keeper #{group_b.id}, losers #{older.id}"
    assert out =~ "Report only: nothing written."
    assert out =~ "Duplicate sets: 1"
    assert state(ids) == before

    # 2. --apply merges into group B.
    out = run_task(["--apply"])
    assert out =~ "keeper #{group_b.id}"
    assert out =~ "Merged duplicate sets: 1"
    assert out =~ "messages=2"

    assert [{_, nil, _}] = Enum.filter(state(ids).spaces, fn {id, _, _} -> id == group_b.id end)

    assert [%Space{archived_at: %DateTime{}}] =
             Repo.all(from(s in Space, where: s.id == ^older.id))

    keeper_messages =
      Repo.all(from(m in Message, where: m.space_id == ^group_b.id, order_by: m.inserted_at))

    assert Enum.map(keeper_messages, & &1.content) == ~w(m0 m10 m20 m30)

    keeper_pids =
      Repo.all(from(p in Participant, where: p.space_id == ^group_b.id, select: p.id))

    assert Enum.all?(keeper_messages, &(&1.participant_id in keeper_pids))

    [r] = Repo.all(from(r in Reaction, where: r.id == ^reaction.id))
    assert r.participant_id in keeper_pids
    assert [%Pin{space_id: pin_space}] = Repo.all(from(p in Pin, where: p.id == ^pin.id))
    assert pin_space == group_b.id

    assert [%Attachment{space_id: att_space}] =
             Repo.all(from(x in Attachment, where: x.id == ^attachment.id))

    assert att_space == group_b.id

    # 3. A second --apply reports zero sets and changes no row.
    after_first = state(ids)
    out = run_task(["--apply"])
    assert out =~ "Merged duplicate sets: 0"
    assert state(ids) == after_first
    assert run_task([]) =~ "Duplicate sets: 0"
  end

  describe "never part of deploy" do
    @root Path.expand("../../../../../..", __DIR__)
    @needles ["DuplicateGroups", "merge_duplicate_groups", "MergeDuplicateGroups"]

    # Read from disk, not git: CI job containers cannot run git.
    @globs [
      "apps/platform/lib/platform/release.ex",
      "apps/platform/priv/repo/migrations/**/*.exs",
      "apps/*/Dockerfile",
      "services/*/Dockerfile",
      "deployment/**/*Dockerfile*",
      "apps/*/rel/overlays/bin/*",
      ".github/workflows/*.yml"
    ]

    test "no deploy path names the merge" do
      files =
        for glob <- @globs do
          matched = @root |> Path.join(glob) |> Path.wildcard() |> Enum.filter(&File.regular?/1)

          assert matched != [],
                 "glob #{glob} matched nothing under #{@root}; the guard would be vacuous"

          matched
        end
        |> List.flatten()

      # The scan reads real deploy files: release.ex runs migrations and the
      # platform Dockerfile starts the release.
      assert File.read!(Path.join(@root, "apps/platform/lib/platform/release.ex")) =~ "migrate"

      assert File.read!(Path.join(@root, "apps/platform/Dockerfile")) =~
               "Platform.Release.migrate"

      offenders =
        for file <- files,
            content = File.read!(file),
            needle <- @needles,
            String.contains?(content, needle),
            do: {Path.relative_to(file, @root), needle}

      assert offenders == []
    end
  end
end
