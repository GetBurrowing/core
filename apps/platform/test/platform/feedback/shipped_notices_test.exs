defmodule Platform.Feedback.ShippedNoticesTest do
  @moduledoc """
  Task 01a1b678 stage 4: the reporting install's "Shipped" notice.

  The broker's truth is the real `Platform.Feedback.Inbox` (the `Req.Test`
  stub for `GET /issues/:fingerprint` answers `Inbox.shipped?/1`), so the
  test is "the broker marked ONE fingerprint shipped; which installs hear
  about it". Each install's own rows are the ones it filed, so install Y
  (filed B) runs first with only B in its table, then install X (filed A).

    * Y asks only about B, gets "not shipped", and posts nothing;
    * X asks only about A and posts one info notice to the person who filed
      it, in their conversation with Burrow, exactly once;
    * an agent filer's notice lands in the space it filed from.

  async: false: flips the publisher adapter and feedback policy.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Burrow
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Feedback.Inbox
  alias Platform.Feedback.ShippedNotices
  alias Platform.Feedback.SubmissionRecord

  @fp_a String.duplicate("a", 64)
  @fp_b String.duplicate("b", 64)

  setup do
    saved =
      for key <- [:feedback_policy, GithubPublisher],
          do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    Application.put_env(:platform, :feedback_policy, "quarantined")

    Application.put_env(
      :platform,
      GithubPublisher,
      Keyword.merge(Application.get_env(:platform, GithubPublisher, []),
        adapter: Broker,
        repository: "GetBurrowing/core"
      )
    )

    _ = Platform.TenancyFixtures.acme_org_id()
    test_pid = self()

    # The broker: answers from the real inbox, and reports every fingerprint
    # it was asked about.
    Req.Test.stub(Broker, fn conn ->
      fp = Path.basename(conn.request_path)
      send(test_pid, {:asked, fp})

      Req.Test.json(conn, %{
        "repository" => "GetBurrowing/core",
        "issue_number" => 1,
        "shipped" => Inbox.shipped?(fp)
      })
    end)

    # The broker marked A shipped (issue 41). B (issue 42) is still open.
    :ok =
      Inbox.record(@fp_a, Ecto.UUID.generate(), %{
        repository: "GetBurrowing/core",
        issue_number: 41
      })

    :ok =
      Inbox.record(@fp_b, Ecto.UUID.generate(), %{
        repository: "GetBurrowing/core",
        issue_number: 42
      })

    Repo.update_all(from(r in Inbox.Request, where: r.fingerprint == ^@fp_a),
      set: [shipped_at: DateTime.utc_now()]
    )

    owner = user!("owner")
    {:ok, burrow} = Burrow.ensure(owner.id, "claude_code")
    %{burrow: burrow}
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "shipped-#{label}-#{n}@example.com",
        name: "Shipped #{label} #{n}",
        oidc_sub: "oidc-shipped-#{label}-#{n}"
      })

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.Tenancy.get_root_org().id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp filed!(fingerprint, number, attrs) do
    Repo.insert!(
      struct(
        SubmissionRecord,
        Map.merge(
          %{
            fingerprint: fingerprint,
            category: "bug",
            status: "published",
            external_repository: "GetBurrowing/core",
            external_issue_number: number,
            published_at: DateTime.utc_now(),
            attempted_at: DateTime.utc_now()
          },
          attrs
        )
      )
    )
  end

  defp asked(acc \\ []) do
    receive do
      {:asked, fp} -> asked([fp | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  defp notices do
    Repo.all(
      from(m in Message,
        where:
          m.content_type == "system" and fragment("?->>'kind'", m.metadata) == "feedback_shipped"
      )
    )
  end

  test "the shipped flag reaches only the install that filed it", %{burrow: burrow} do
    filer_b = user!("b")
    filer_a = user!("a")

    # Install Y filed only B.
    row_b = filed!(@fp_b, 42, %{actor_user_id: filer_b.id})
    assert %{checked: 1, notified: 0} = ShippedNotices.run()
    assert asked() == [@fp_b]
    assert notices() == []
    assert Repo.reload!(row_b).shipped_notified_at == nil

    # Install X filed only A.
    Repo.delete!(row_b)
    row_a = filed!(@fp_a, 41, %{actor_user_id: filer_a.id})
    assert %{checked: 1, notified: 1} = ShippedNotices.run()
    assert asked() == [@fp_a]

    assert [%Message{} = notice] = notices()
    assert notice.content == ShippedNotices.text("GetBurrowing/core", 41)
    assert notice.metadata["issue_number"] == 41
    {:ok, dm} = Chat.find_or_create_agent_dm(burrow.id, filer_a.id)
    assert notice.space_id == dm.id
    refute Repo.reload!(row_a).shipped_notified_at == nil

    # Once only: the next cycle asks nothing and posts nothing.
    assert %{checked: 0, notified: 0} = ShippedNotices.run()
    assert asked() == []
    assert [_] = notices()
  end

  test "an agent filer's notice lands in the space it filed from", %{burrow: burrow} do
    {:ok, space} =
      Chat.create_space(%{
        name: "Ops",
        slug: "ops-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: Platform.Tenancy.get_root_org().id
      })

    {:ok, _} = Chat.add_agent_participant(space.id, burrow)
    filed!(@fp_a, 41, %{actor_agent_id: burrow.id, notice_space_id: space.id})

    assert %{notified: 1} = ShippedNotices.run()
    assert [%Message{space_id: space_id}] = notices()
    assert space_id == space.id
  end

  test "rows another install sent through this broker are never asked about" do
    # On the broker host the shared ledger holds other installs' rows; their
    # actor is a per-IP id that is no agent here.
    filed!(@fp_a, 41, %{actor_agent_id: Ecto.UUID.generate()})

    assert %{checked: 0, notified: 0} = ShippedNotices.run()
    assert asked() == []
  end

  test "off while the owner's feedback switch is off" do
    filed!(@fp_a, 41, %{actor_user_id: user!("off").id})
    {:ok, _} = Platform.Sharing.set(:feedback, false, :system)

    assert ShippedNotices.run() == :off
    assert asked() == []
  end
end
