defmodule Platform.Social.StudioNeverSendTest do
  @moduledoc """
  Social Studio slice B, never sending: a full run of every Studio transition, with
  the Fake publisher AND with the real (Zernio) publisher configured, makes no
  call into `Platform.Social.Publisher*`, `Platform.Social.Publishing` or
  `ZernioHTTP`, and leaves no Studio post outside draft, needs_approval,
  approved, planned.

  The proof is a BEAM call trace on the test process (every Studio function
  runs in it), not a mock: a new path that reaches a publisher cannot hide in
  a stub the test forgot to configure. `Publisher.Fake.calls/0` is asserted
  empty as well.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Post, Studio}
  alias Platform.Social.Publisher.Fake

  @traced [
    Platform.Social.Publisher,
    Platform.Social.Publisher.Fake,
    Platform.Social.Publisher.Zernio,
    Platform.Social.Publishing,
    Platform.Social.ZernioHTTP
  ]

  setup do
    Fake.reset()
    original = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, original) end)
    %{w: studio_world!(), original: original}
  end

  defp future(secs \\ 3_600), do: DateTime.add(DateTime.utc_now(), secs, :second)

  # Every transition, each as a fresh view of the post.
  defp lifecycle(w) do
    org = w.org_id
    me = w.approver.id
    clip = w |> pending_clip!() |> make_studio_clip!()

    {:ok, third} =
      Social.create_account(org, w.profile, %{platform: "linkedin", handle: "@third"})

    {:ok, %{posts: [post, _]}} =
      Studio.accept_render(org, clip.id, me, %{
        render_id: render_id!(clip),
        account_ids: [w.x.id, w.tiktok.id]
      })

    ok = fn
      {:ok, %{post: p}} -> p
      {:ok, %Post{} = p} -> p
    end

    step = fn p, f -> p |> then(f) |> ok.() end

    p = step.(post, &Studio.approve_version(org, &1.id, me, expect(&1)))
    p = step.(p, &Studio.plan_post(org, &1.id, me, expect(&1), future()))
    p = step.(p, &Studio.plan_post(org, &1.id, me, expect(&1), future(7_200)))
    p = step.(p, &Studio.cancel_plan(org, &1.id, me, expect(&1)))
    p = step.(p, &Studio.plan_post(org, &1.id, me, expect(&1), future()))

    p =
      step.(
        p,
        &Studio.revoke_approval(
          org,
          &1.id,
          me,
          expect(&1, %{approval_id: hd(receipts(&1)).id}),
          "no"
        )
      )

    p = step.(p, &Studio.approve_version(org, &1.id, me, expect(&1)))
    p = step.(p, &Studio.plan_post(org, &1.id, me, expect(&1), future()))

    p =
      step.(
        p,
        &(Studio.save_version(
            org,
            &1.id,
            {:human, me},
            %{body: "edited after planning"},
            expect(&1)
          )
          |> then(fn {:ok, r} -> {:ok, r} end))
      )

    p =
      step.(
        p,
        &Studio.save_version(org, &1.id, {:human, me}, %{account_id: third.id}, expect(&1))
      )

    p =
      step.(
        p,
        &AgentDrafts.update_agent_draft(w.scope, &1.id, %{"body" => "agent pass"},
          agent_id: w.agent.id
        )
      )

    p = step.(p, &Studio.request_changes(org, &1.id, me, expect(&1), "tighten"))
    p = step.(p, &Studio.resubmit(org, &1.id, me, expect(&1), "done"))
    p = step.(p, &Studio.approve_version(org, &1.id, me, expect(&1)))
    _ = step.(p, &Studio.plan_post(org, &1.id, me, expect(&1), future()))
    {:ok, _} = Studio.list_approvals(org, post.id)
    :ok
  end

  defp trace_on do
    for module <- @traced do
      {:module, _} = Code.ensure_loaded(module)
      :erlang.trace_pattern({module, :_, :_}, true, [:local])
    end

    # A process cannot be traced by itself: a relay process is the tracer.
    parent = self()

    relay =
      spawn_link(fn ->
        loop = fn loop ->
          receive do
            {:trace, _pid, :call, mfa} ->
              send(parent, {:trace, :call, mfa})
              loop.(loop)

            :stop ->
              :ok
          end
        end

        loop.(loop)
      end)

    1 = :erlang.trace(self(), true, [:call, {:tracer, relay}])
    Process.put(:trace_relay, relay)
  end

  defp trace_off do
    :erlang.trace(self(), false, [:call])
    # Let the relay deliver everything it already received, then stop it.
    relay = Process.get(:trace_relay)
    send(relay, :stop)
    ref = Process.monitor(relay)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    for module <- @traced, do: :erlang.trace_pattern({module, :_, :_}, false, [:local])
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:trace, :call, mfa} -> collect_calls([mfa | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  for impl <- [:fake, :zernio] do
    test "a full lifecycle with the #{impl} publisher configured sends nothing", %{w: w} do
      Application.put_env(
        :social,
        :publisher,
        if(unquote(impl) == :fake, do: Fake, else: Platform.Social.Publisher.Zernio)
      )

      trace_on()

      try do
        assert :ok = lifecycle(w)
      after
        trace_off()
      end

      assert collect_calls() == []
      assert Fake.calls() == []

      statuses =
        Repo.all(from(p in Post, where: p.flow == "studio", select: p.status)) |> Enum.uniq()

      assert Enum.all?(statuses, &(&1 in ~w(draft needs_approval approved planned)))
      assert Repo.aggregate(from(p in Post, where: not is_nil(p.external_id)), :count) == 0
      _ = Social
    end
  end

  test "the trace is live: a call into the publisher facade IS seen (the probe is not vacuous)",
       %{w: _w} do
    trace_on()
    Application.put_env(:social, :publisher, Fake)
    _ = Platform.Social.Publisher.impl()
    trace_off()
    assert [{Platform.Social.Publisher, :impl, _} | _] = collect_calls()
  end
end
