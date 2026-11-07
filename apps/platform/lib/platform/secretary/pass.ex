defmodule Platform.Secretary.Pass do
  @moduledoc """
  One batch for one person, start to finish (task 01a1b721 stage 3). The
  `Platform.Secretary.Scheduler` runs it in a supervised task; tests call
  `run/2` directly.

    1. gather the person's readable inputs (`Platform.Secretary.Inputs`),
       leaving out refs at the retry cap with no new activity;
    2. no subscription AI (`Platform.Secretary.Model.Host.eligible_agent/0`)
       -> batch `no_ai`, fallback, no host call;
    3. build the prompt (`Platform.Secretary.Prompt`) and reserve its tokens;
       over either ceiling (`Platform.Secretary.Budget`) -> batch
       `budget_exhausted`, fallback, no host call. The check and the batch
       insert run under one advisory lock, so two passes cannot both squeeze
       under the install ceiling;
    4. ask the host; record real usage as `actual_tokens`;
    5. hand the answer to `Platform.Secretary.Submit.apply/3`. A timeout,
       failure or refusal keeps the reservation and gives the batch's refs
       the fallback with `failed_attempts + 1`.

  Every pass that makes a batch emits `[:platform, :secretary, :batch]` with
  measurements `%{reserved_tokens, actual_tokens}` and metadata `%{user_id,
  date, outcome}`, `outcome` one of `:submitted | :failed |
  :budget_exhausted | :no_ai | :rejected`.

  The prompt and the answer are never logged and never posted anywhere.
  """

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Secretary

  alias Platform.Secretary.{
    Budget,
    Context,
    Fallback,
    Feedback,
    Input,
    Inputs,
    Policy,
    Prompt,
    Settings,
    Store,
    Submit
  }

  alias Platform.Secretary.Model.Host

  @event [:platform, :secretary, :batch]
  @lookback_seconds 24 * 3600
  @max_output_tokens 4_000
  @retry_cap 2
  # pg_advisory_xact_lock key: the budget check and the batch insert.
  @budget_lock 7_210_031_721

  @type outcome :: :submitted | :failed | :budget_exhausted | :no_ai | :rejected | :noop

  @doc "The telemetry event every batch emits."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "The retry cap: a ref at this many failed attempts is not re-sent."
  @spec retry_cap() :: pos_integer()
  def retry_cap, do: @retry_cap

  @doc """
  Runs one pass for `user` (a `%User{}` or an id).

  Options: `:now`; `:payload` (default `Platform.Secretary.Policy.for_user/1`);
  `:install_payload` (default `Policy.install/0`); `:eligible` (0-arity,
  default `Host.eligible_agent/0`); `:request` (3-arity `(user, prompt,
  opts)`, default `Host.request/3`); `:max_output_tokens`; `:timeout`.

  `{:ok, outcome}`; `:noop` when there is nothing to read.
  """
  @spec run(User.t() | Ecto.UUID.t(), keyword()) :: {:ok, outcome()}
  def run(user, opts \\ [])

  def run(user_id, opts) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %User{} = user -> run(user, opts)
      nil -> {:ok, :noop}
    end
  end

  def run(%User{} = user, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    policy = Keyword.get_lazy(opts, :payload, fn -> Policy.for_user(user.id).payload end)
    install = Keyword.get_lazy(opts, :install_payload, &Policy.install/0)
    settings = Settings.get(user)

    inputs =
      user
      |> Inputs.gather(DateTime.add(now, -@lookback_seconds, :second),
        now: now,
        max_batch_items: policy["max_batch_items"]
      )
      |> drop_capped(user.id)

    ctx = %{
      user: user,
      now: now,
      policy: policy,
      install: install,
      settings: settings,
      refs: Enum.map(inputs, &ref/1),
      date: Prompt.today(now, settings["time_zone"]),
      opts: opts
    }

    if inputs == [], do: {:ok, :noop}, else: dispatch(ctx, inputs)
  end

  defp dispatch(ctx, inputs) do
    eligible = Keyword.get(ctx.opts, :eligible, &Host.eligible_agent/0)

    case eligible.() do
      {:ok, agent} ->
        prompt =
          Prompt.build(ctx.user, inputs, Context.for_user(ctx.user), ctx.policy, now: ctx.now)

        max_output = Keyword.get(ctx.opts, :max_output_tokens, @max_output_tokens)
        reserve = Budget.reserve(prompt, max_output)

        case reserve_batch(ctx, agent, reserve) do
          {:ok, batch} -> ask(ctx, batch, prompt, max_output)
          {:error, :budget} -> refuse(ctx, "budget_exhausted", :budget_exhausted, agent)
        end

      _no_ai ->
        refuse(ctx, "no_ai", :no_ai, nil)
    end
  end

  defp reserve_batch(ctx, agent, reserve) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@budget_lock])

      case Budget.check(ctx.user.id, reserve, ctx.policy,
             now: ctx.now,
             settings: ctx.settings,
             install_payload: ctx.install
           ) do
        :ok ->
          {:ok, batch} =
            Store.create_batch(ctx.user.id, %{
              agent_id: agent.id,
              item_refs: ctx.refs,
              status: "dispatched",
              reserved_tokens: reserve,
              dispatched_at: ctx.now
            })

          batch

        {:error, _ceiling} ->
          Repo.rollback(:budget)
      end
    end)
  end

  defp ask(ctx, batch, prompt, max_output) do
    request = Keyword.get(ctx.opts, :request, &Host.request/3)
    host_opts = [max_output_tokens: max_output] ++ Keyword.take(ctx.opts, [:timeout])

    case request.(ctx.user, prompt, host_opts) do
      {:ok, %{text: text} = answer} ->
        actual = Budget.actual(answer[:usage])

        outcome =
          case Submit.apply(batch, decode(text),
                 model_version: answer[:model_version] || "host:#{batch.agent_id}:unknown",
                 brief_max_lines: ctx.policy["brief_max_lines"],
                 settings: ctx.settings,
                 actual_tokens: actual,
                 now: ctx.now
               ) do
            {:ok, _} -> :submitted
            {:error, {:rejected, _}} -> :rejected
          end

        emit(ctx, batch.reserved_tokens, actual, outcome)

      {:error, :no_subscription_ai} ->
        fail(ctx, batch, "no_ai", :no_ai)

      {:error, :timeout} ->
        fail(ctx, batch, "expired", :failed)

      _other ->
        fail(ctx, batch, "failed", :failed)
    end
  end

  # A batch that reached the host keeps its reservation whatever happened.
  defp fail(ctx, batch, status, outcome) do
    Store.finish_batch(ctx.user.id, batch.id, %{status: status, finished_at: ctx.now})
    failed? = outcome == :failed
    Fallback.apply(ctx.user.id, ctx.refs, batch_id: batch.id, failed?: failed?, now: ctx.now)
    Secretary.broadcast_updated(ctx.user.id)
    emit(ctx, batch.reserved_tokens, 0, outcome)
  end

  # No host call: nothing is reserved.
  defp refuse(ctx, status, outcome, agent) do
    {:ok, batch} =
      Store.create_batch(ctx.user.id, %{
        agent_id: agent && agent.id,
        item_refs: ctx.refs,
        status: status,
        reserved_tokens: 0,
        dispatched_at: ctx.now,
        finished_at: ctx.now
      })

    Fallback.apply(ctx.user.id, ctx.refs, batch_id: batch.id, now: ctx.now)
    Secretary.broadcast_updated(ctx.user.id)
    emit(ctx, 0, 0, outcome)
  end

  defp emit(ctx, reserved, actual, outcome) do
    :telemetry.execute(
      @event,
      %{reserved_tokens: reserved, actual_tokens: actual},
      %{user_id: ctx.user.id, date: ctx.date, outcome: outcome}
    )

    {:ok, outcome}
  end

  defp drop_capped(inputs, user_id) do
    capped = Store.capped_refs(user_id, @retry_cap)

    Enum.reject(inputs, fn %Input{} = input ->
      case Map.get(capped, {input.ref_type, input.ref_id}) do
        nil -> false
        %DateTime{} = evaluated_at -> not newer?(input.at, evaluated_at)
        _ -> true
      end
    end)
  end

  defp newer?(%DateTime{} = at, evaluated_at), do: DateTime.compare(at, evaluated_at) == :gt
  defp newer?(_at, _evaluated_at), do: false

  defp ref(%Input{} = input) do
    %{
      "ref_type" => input.ref_type,
      "ref_id" => input.ref_id,
      "kind" => input.kind,
      "kind_key" => Feedback.kind_key(input.kind, input.author_id),
      "space_id" => input.space_id,
      "mentioned" => input.mentioned?
    }
  end

  # The host returns text; a model may wrap its JSON in a code fence.
  defp decode(text) when is_binary(text) do
    trimmed =
      text
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```\z/, "")

    case Jason.decode(trimmed) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp decode(_text), do: nil
end
