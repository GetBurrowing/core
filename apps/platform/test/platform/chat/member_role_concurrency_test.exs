defmodule Platform.Chat.MemberRoleConcurrencyTest do
  @moduledoc """
  Task 01a19355-9f4d-7000-befc-284f2df2318d stage 1: the last-human-admin
  floor of `Chat.set_member_role/4` holds under a real race.

  Two human admins A and B demote each other on independent database
  connections (sandbox `:auto`), released together by a `:go` barrier, 25
  times. Without the space-row lock both reads see the other admin, both
  writes land, and the channel is left with zero admins. With it, exactly one
  call succeeds and the admin count is 1 after every iteration.

  Positive control (run by hand, not committed): with the `lock:` removed from
  `do_set_member_role/4` and a `Process.sleep(50)` between the floor check and
  the write, this test goes red with an admin count of 0.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo

  @iterations 25

  defp user!(n, tag) do
    Repo.insert!(%Platform.Accounts.User{
      name: "Race #{tag} #{n}",
      email: "role-race-#{tag}-#{n}@example.com",
      oidc_sub: "role-race-#{tag}-#{n}"
    })
  end

  defp seat!(space_id, user) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: "admin",
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp admin_count(space_id) do
    Repo.aggregate(
      from(p in Participant,
        where: p.space_id == ^space_id and p.participant_type == "user" and p.role == "admin"
      ),
      :count
    )
  end

  test "mutual demotion of the only two human admins leaves exactly one admin" do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Role race #{n}", slug: "role-race-#{n}", kind: "channel"})

    a = user!(n, "a")
    b = user!(n, "b")

    try do
      a_p = seat!(space.id, a)
      b_p = seat!(space.id, b)
      parent = self()

      for i <- 1..@iterations do
        Repo.update_all(
          from(p in Participant, where: p.id in ^[a_p.id, b_p.id]),
          set: [role: "admin"]
        )

        assert admin_count(space.id) == 2

        tasks =
          for {actor, target} <- [{a, b_p}, {b, a_p}] do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> Chat.set_member_role(space, actor.id, target.id, "member")
              end
            end)
          end

        for _ <- tasks, do: assert_receive({:ready, _}, 2000)
        Enum.each(tasks, &send(&1.pid, :go))
        results = Enum.map(tasks, &Task.await(&1, 15_000))

        count = admin_count(space.id)

        assert count == 1,
               "iteration #{i}: user-admin count #{count} after #{inspect(results)}"

        assert Enum.count(results, &match?({:ok, %Participant{role: "member"}}, &1)) == 1,
               "iteration #{i}: #{inspect(results)}"

        assert Enum.count(results, fn r ->
                 r in [{:error, :unauthorized}, {:error, :last_admin}]
               end) == 1,
               "iteration #{i}: #{inspect(results)}"
      end
    after
      Repo.delete_all(from(p in Participant, where: p.space_id == ^space.id))
      Repo.delete_all(from(s in Space, where: s.id == ^space.id))
      Repo.delete!(a)
      Repo.delete!(b)
      Sandbox.mode(Repo, :manual)
    end
  end
end
