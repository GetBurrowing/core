defmodule Platform.SecretaryFixtures do
  @moduledoc """
  Fixtures for the secretary's evaluator pass (task 01a1b721 stage 3): a
  person with something to read, a stand-in host that records every call
  and answers like the dev fake host, and the stage-1 readability world.
  """

  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Restrictions}
  alias Platform.Accounts
  alias Platform.AgentHost.FakeHost
  alias Platform.Chat.{Message, Space}
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Tenancy

  @doc "A plain member of a fresh tenant org."
  def person!(label \\ "p") do
    org =
      Tenancy.get_org!(tenant_org_id("secretary_#{label}_#{System.unique_integer([:positive])}"))

    user = create_user!()
    plain_member!(user, org)
    Accounts.get_user(user.id)
  end

  @doc "An unread inbox row for `user`."
  def inbox_item!(user, kind \\ "task_sponsor_assigned", body \\ "a thing") do
    Repo.insert!(%Item{
      user_id: user.id,
      kind: kind,
      source_type: "task",
      source_id: Ecto.UUID.generate(),
      title: "#{kind} #{System.unique_integer([:positive])}",
      body: body,
      url: "/tasks"
    })
  end

  @doc "A stand-in agent that passes the gate."
  def eligible(agent_id \\ Ecto.UUID.generate()), do: fn -> {:ok, %{id: agent_id}} end

  @doc """
  A stand-in `request/3`: sends `{:oneshot_called, user_id, prompt}` to
  `pid`, then answers `reply` (a function of the prompt) or, by default, the
  dev fake host's deterministic answer with the given usage.
  """
  def request(pid, reply \\ :fake) do
    fn user, prompt, _opts ->
      send(pid, {:oneshot_called, user.id, prompt})

      case reply do
        :fake ->
          {:ok, text} = FakeHost.oneshot_answer(prompt)

          {:ok,
           %{
             text: text,
             usage: %{
               input_tokens: 11,
               output_tokens: 7,
               cache_read_tokens: 3,
               cache_creation_tokens: 2
             },
             model_version: "host:test:claude_code"
           }}

        fun when is_function(fun, 1) ->
          fun.(prompt)

        other ->
          other
      end
    end
  end

  @doc """
  The stage-1 readability world: A, B, C, D in one sub-org. Returns the
  users and the spaces; the secret strings are those of
  `Platform.Secretary.InputsTest`.
  """
  def readability_world! do
    s1 = Tenancy.get_org!(tenant_org_id("secretary_w1_#{System.unique_integer([:positive])}"))
    s2 = Tenancy.get_org!(tenant_org_id("secretary_w2_#{System.unique_integer([:positive])}"))
    [a, b, c, admin, d] = for _ <- 1..5, do: create_user!()
    for u <- [a, b, c, d], do: plain_member!(u, s1)
    plain_member!(admin, s1, "admin")
    s2_member = create_user!()
    plain_member!(s2_member, s2)

    dm = space!("dm", s1.id)
    add_user!(dm.id, a.id)
    say!(dm, b, "dm-secret-xyz")

    group = space!("group", s1.id)
    say!(group, b, "grp-secret-xyz")
    add_user!(group.id, a.id)

    open = channel!(%{org_id: s1.id})
    say!(open, a, "open-text")

    restricted = channel!(%{org_id: s1.id})
    say!(restricted, a, "restricted-xyz")
    {:ok, _} = Restrictions.restrict_space(restricted, ["admin"], admin.id)

    exec = space!("execution", s1.id)
    say!(exec, a, "exec-xyz")

    suborg = channel!(%{org_id: s2.id})
    say!(suborg, s2_member, "suborg-xyz")

    denied = channel!(%{org_id: s1.id})
    say!(denied, a, "denied-xyz")

    {:ok, _} =
      Grants.deny(%{
        principal: {:user, c.id},
        permission: "chat.read",
        resource: {:space, denied.id}
      })

    allowed = space!("dm", s1.id)
    say!(allowed, a, "allowed-xyz")
    add_user!(allowed.id, d.id)

    {:ok, _} =
      Grants.grant(%{
        principal: {:user, c.id},
        permission: "chat.read",
        resource: {:space, allowed.id}
      })

    %{
      a: Accounts.get_user(a.id),
      b: Accounts.get_user(b.id),
      c: Accounts.get_user(c.id),
      d: Accounts.get_user(d.id),
      dm: dm,
      open: open,
      exec: exec
    }
  end

  @doc "The world's secrets C must never see."
  def secrets, do: ~w(dm-secret-xyz grp-secret-xyz restricted-xyz exec-xyz suborg-xyz denied-xyz)

  @doc "A space of `kind`."
  def space!(kind, org_id) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Space{
      kind: kind,
      name: "#{kind} #{n}",
      slug: "sec3-#{kind}-#{n}",
      org_id: org_id
    })
  end

  @doc "`user` joins `space` and says `text`. Options: `:metadata`."
  def say!(space, user, text, opts \\ []) do
    p =
      Repo.get_by(Platform.Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) || add_user!(space.id, user.id)

    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: p.id,
      content_type: "text",
      content: text,
      metadata: Keyword.get(opts, :metadata, %{}),
      author_user_id: user.id,
      author_display_name: user.name,
      author_participant_type: "user"
    })
  end
end
