defmodule Platform.Social.SchemaTest do
  @moduledoc """
  Social's tables refuse bad rows AT THE DATABASE, not only in a changeset:
  every write here is a raw `Repo.insert_all/3` on the
  table name, so no `Platform.Social` schema or changeset is in the path.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Social.{Account, Clip, Post}

  defp now, do: DateTime.utc_now()

  # Each raw write runs in its own savepoint, so a refused one rolls back
  # cleanly and the sandbox transaction stays usable for the next.
  defp tx_insert_all(table, rows) do
    {:ok, result} = Repo.transaction(fn -> Repo.insert_all(table, rows) end)
    result
  end

  defp uuid, do: Ecto.UUID.generate()
  defp dump(id), do: Ecto.UUID.dump!(id)

  defp raw_profile!(org_id) do
    id = uuid()

    tx_insert_all("social_profiles", [
      %{
        id: dump(id),
        org_id: dump(org_id),
        name: "raw #{unique()}",
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp raw_account!(profile_id, overrides \\ %{}) do
    id = uuid()

    row =
      Map.merge(
        %{
          id: dump(id),
          profile_id: dump(profile_id),
          platform: "linkedin",
          inserted_at: now(),
          updated_at: now()
        },
        overrides
      )

    tx_insert_all("social_accounts", [row])
    id
  end

  defp raw_post(account_id, overrides) do
    row =
      Map.merge(
        %{
          id: dump(uuid()),
          account_id: dump(account_id),
          body: "hello",
          inserted_at: now(),
          updated_at: now()
        },
        overrides
      )

    tx_insert_all("social_posts", [row])
  end

  defp clip_row(profile_id) do
    %{
      id: dump(uuid()),
      profile_id: dump(profile_id),
      source_url: "https://www.youtube.com/watch?v=abc",
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp raw_clip(profile_id, overrides) do
    row =
      Map.merge(
        %{
          id: dump(uuid()),
          profile_id: dump(profile_id),
          source_url: "https://www.youtube.com/watch?v=abc",
          inserted_at: now(),
          updated_at: now()
        },
        overrides
      )

    tx_insert_all("social_clips", [row])
  end

  setup do
    org_id = org_id!()
    profile_id = raw_profile!(org_id)
    account_id = raw_account!(profile_id)
    %{org_id: org_id, profile_id: profile_id, account_id: account_id}
  end

  describe "social_accounts" do
    test "a bad platform, approval_mode or status is refused by a CHECK", %{profile_id: pid} do
      for {field, bad, constraint} <- [
            {:platform, "facebook", "social_accounts_platform_check"},
            {:approval_mode, "auto", "social_accounts_approval_mode_check"},
            {:status, "pending", "social_accounts_status_check"}
          ] do
        error = assert_raise Postgrex.Error, fn -> raw_account!(pid, %{field => bad}) end
        assert error.postgres.code == :check_violation
        assert error.postgres.constraint == constraint
      end
    end

    test "approval_mode omitted reads back approve_first (column default)", %{account_id: id} do
      assert %Account{approval_mode: "approve_first"} = Repo.get!(Account, id)
    end

    test "has secret_slug and no token, password, secret or key column" do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'social_accounts'"
        )

      columns = List.flatten(rows)
      assert "secret_slug" in columns

      secretish =
        Enum.filter(columns, &Regex.match?(~r/token|password|secret|key/i, &1)) -- ["secret_slug"]

      assert secretish == []
    end

    test "the changeset rejects the same bad values on the field" do
      changeset =
        Account.changeset(%Account{}, %{
          platform: "facebook",
          approval_mode: "auto",
          status: "pending"
        })

      errors = errors_on(changeset)
      assert errors[:platform]
      assert errors[:approval_mode]
      assert errors[:status]
      assert Account.platforms() == ~w(linkedin x tiktok instagram youtube)
      assert Account.approval_modes() == ~w(draft_only approve_first)
    end
  end

  describe "social_posts" do
    test "a bad status is refused by a CHECK", %{account_id: aid} do
      error = assert_raise Postgrex.Error, fn -> raw_post(aid, %{status: "live"}) end
      assert error.postgres.constraint == "social_posts_status_check"
    end

    test "status approved with no approver is refused by a CHECK", %{account_id: aid} do
      for status <- Post.approved_statuses() do
        error = assert_raise Postgrex.Error, fn -> raw_post(aid, %{status: status}) end
        assert error.postgres.constraint == "social_posts_approved_needs_approver_check"
      end

      # approved_at without an approver is not enough either
      error =
        assert_raise Postgrex.Error, fn ->
          raw_post(aid, %{status: "approved", approved_at: now()})
        end

      assert error.postgres.constraint == "social_posts_approved_needs_approver_check"
    end

    test "an AGENT id as approver is refused by the FK to users", %{account_id: aid} do
      agent = agent!()

      error =
        assert_raise Postgrex.Error, fn ->
          raw_post(aid, %{
            status: "approved",
            approved_by_user_id: dump(agent.id),
            approved_at: now()
          })
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == "social_posts_approved_by_user_id_fkey"
    end

    test "a real user as approver is accepted", %{account_id: aid} do
      user = user!()

      assert {1, _} =
               raw_post(aid, %{
                 status: "approved",
                 approved_by_user_id: dump(user.id),
                 approved_at: now()
               })
    end

    test "the general changeset casts neither approver field and refuses approved status" do
      changeset =
        Post.changeset(%Post{}, %{
          status: "approved",
          approved_by_user_id: Ecto.UUID.generate(),
          approved_at: DateTime.utc_now()
        })

      assert Ecto.Changeset.get_change(changeset, :approved_by_user_id) == nil
      assert Ecto.Changeset.get_change(changeset, :approved_at) == nil
      assert errors_on(changeset)[:status]
      assert errors_on(Post.changeset(%Post{}, %{status: "live"}))[:status]
    end
  end

  describe "social_clips" do
    test "a bad status is refused by a CHECK", %{profile_id: pid} do
      error = assert_raise Postgrex.Error, fn -> raw_clip(pid, %{status: "done"}) end
      assert error.postgres.constraint == "social_clips_status_check"
    end

    test "end_s not after start_s is refused by a CHECK", %{profile_id: pid} do
      for {s, e} <- [{10.0, 5.0}, {5.0, 5.0}] do
        error = assert_raise Postgrex.Error, fn -> raw_clip(pid, %{start_s: s, end_s: e}) end
        assert error.postgres.constraint == "social_clips_span_check"
      end

      assert {1, _} = raw_clip(pid, %{start_s: 1.0, end_s: 2.0})
      assert {1, _} = raw_clip(pid, %{start_s: 1.0})
    end

    test "the changeset rejects a bad status and a backwards span" do
      errors = errors_on(Clip.changeset(%Clip{}, %{status: "done", start_s: 10, end_s: 5}))
      assert errors[:status]
      assert errors[:end_s]
    end

    # Social 5/7: exactly one footage source, and a crop centre in 0..1.
    test "both sources set, or neither, is refused by a CHECK", %{org_id: org_id, profile_id: pid} do
      file = file!(org_id)

      for overrides <- [
            %{source_file_id: dump(file.id)},
            %{source_url: nil}
          ] do
        error = assert_raise Postgrex.Error, fn -> raw_clip(pid, overrides) end
        assert error.postgres.constraint == "social_clips_one_source_check"
      end

      assert {1, _} = raw_clip(pid, %{source_url: nil, source_file_id: dump(file.id)})
    end

    test "crop_x outside 0..1 is refused by a CHECK; it defaults to 0.5", %{profile_id: pid} do
      for bad <- [1.5, -0.1] do
        error = assert_raise Postgrex.Error, fn -> raw_clip(pid, %{crop_x: bad}) end
        assert error.postgres.constraint == "social_clips_crop_x_check"
      end

      {1, [%{id: id}]} =
        Repo.transaction(fn ->
          Repo.insert_all("social_clips", [clip_row(pid)], returning: [:id])
        end)
        |> elem(1)

      assert %Clip{crop_x: 0.5, attempts: 0, platforms: []} = Repo.get!(Clip, Ecto.UUID.load!(id))
    end

    test "the changeset names the source and crop errors" do
      errors = errors_on(Clip.changeset(%Clip{}, %{crop_x: 1.5}))
      assert errors[:source_url] == ["exactly one of source_url or source_file_id must be set"]
      assert errors[:crop_x]

      both = %{source_url: "https://x.test/v", source_file_id: Ecto.UUID.generate()}
      assert errors_on(Clip.changeset(%Clip{}, both))[:source_url]
    end
  end

  describe "social_profiles" do
    test "name is unique per org", %{org_id: org_id} do
      tx_insert_all("social_profiles", [
        %{
          id: dump(uuid()),
          org_id: dump(org_id),
          name: "dup",
          inserted_at: now(),
          updated_at: now()
        }
      ])

      error =
        assert_raise Postgrex.Error, fn ->
          tx_insert_all("social_profiles", [
            %{
              id: dump(uuid()),
              org_id: dump(org_id),
              name: "dup",
              inserted_at: now(),
              updated_at: now()
            }
          ])
        end

      assert error.postgres.code == :unique_violation
    end

    test "org_id is required and must be an org" do
      error =
        assert_raise Postgrex.Error, fn ->
          tx_insert_all("social_profiles", [
            %{id: dump(uuid()), name: "x", inserted_at: now(), updated_at: now()}
          ])
        end

      assert error.postgres.code == :not_null_violation

      error =
        assert_raise Postgrex.Error, fn ->
          tx_insert_all("social_profiles", [
            %{
              id: dump(uuid()),
              org_id: dump(uuid()),
              name: "x",
              inserted_at: now(),
              updated_at: now()
            }
          ])
        end

      assert error.postgres.code == :foreign_key_violation
    end
  end
end
