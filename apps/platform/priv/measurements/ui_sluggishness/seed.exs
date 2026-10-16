# Dev-only perf seed for task 01a13884 ("UI sluggishness"), stage 1.
#
#     podman exec dev-platform-<wt> mix run priv/measurements/ui_sluggishness/seed.exs
#
# Builds, in the dev DB only:
#   * project `perf-ui-sluggishness` with 1,363 tasks (status mix below),
#     sponsors, user assignees, plans with stages, and 3 stacks x 4 members;
#   * channel `perf-heavy-channel`: 160 top-level messages, 18 of them canvas
#     messages (4 table, 4 markdown, 4 code, 4 embed, 2 prototype), long
#     markdown bodies and 6 threads;
#   * channel `perf-light-channel`: 6 short messages, the switch origin;
#   * channel `perf-canvas-heavy-channel` (stage 4): 60 top-level messages
#     whose newest-50 window holds 30 canvas messages: 10 static HTML
#     mockup embeds (~20 KB srcdoc each), 8 `scripts: true` embeds and 6
#     prototype frames whose inline JS builds its UI on load (a 2,000-cell
#     grid, a 5,000-point canvas chart, a 160-card board), plus 2 table,
#     2 markdown and 2 code canvases. Stage 1's heavy channel switched in
#     ~150 ms of long tasks on the rig, under the 300 ms target before any
#     fix, so it could not tell a fix from no fix; this one is the
#     discriminating seed. The mix is an ASSUMPTION modelled on a design
#     review channel (agents posting mockup iterations); the prod spaces'
#     content was not read.
#
# Nothing is read from prod. The status mix is an ASSUMPTION: the prod Done
# share was not measured, so it is printed with the result.
#
# Idempotent: each part is find-or-create. A part that already exists with
# the expected shape is left alone and reported as `existing`; a part that
# exists with a different shape raises instead of guessing.
#
# Side effect outside the seeded rows: install prototype settings are set to
# `enabled: true` so the two prototype canvases can publish (dev DB only).

{guard, _} = Code.eval_file("guard.exs", __DIR__)
:ok = guard.({Mix.env(), System.get_env("MIX_ENV")})

import Ecto.Query

# 1,363 task inserts at :debug would print every INSERT.
Logger.configure(level: :info)

alias Platform.Repo
alias Platform.Accounts
alias Platform.Chat
alias Platform.Tasks.{Plan, Project, Stack, Stage, Task}

:rand.seed(:exsss, {1363, 160, 18})

status_mix = [
  {"done", 1_040},
  {"cancelled", 110},
  {"backlog", 80},
  {"planning", 30},
  {"in_progress", 45},
  {"blocked", 10},
  {"in_review", 30},
  {"deploying", 18}
]

task_total = status_mix |> Enum.map(&elem(&1, 1)) |> Enum.sum()
1_363 = task_total

now = DateTime.utc_now()
ago = fn minutes -> DateTime.add(now, -minutes * 60, :second) end

# ── People ─────────────────────────────────────────────────────────────────

{:ok, dev_user} =
  Accounts.find_or_create_from_oidc(%{
    sub: "dev-local-user",
    email: "dev@localhost",
    name: "Dev User"
  })

others =
  for {slug, name} <- [
        {"perf-ada", "Ada Okafor"},
        {"perf-bo", "Bo Lindqvist"},
        {"perf-cy", "Cyra Patel"},
        {"perf-dm", "Dmitri Hale"},
        {"perf-eve", "Eve Moreau"}
      ] do
    {:ok, u} =
      Accounts.find_or_create_from_oidc(%{
        sub: "dev-#{slug}",
        email: "#{slug}@localhost",
        name: name
      })

    u
  end

people = [dev_user | others]
pick = fn list -> Enum.at(list, :rand.uniform(length(list)) - 1) end

root_org =
  Platform.Tenancy.get_root_org() || raise "no root org in the dev DB; boot the dev server once"

# ── Tasks ──────────────────────────────────────────────────────────────────

verbs = ~w(Add Fix Refactor Remove Migrate Document Harden Tune Split Instrument Retry Cache)

objects = [
  "the kanban drag handle on touch devices",
  "sponsor avatars in the review queue",
  "the plan engine stage cursor",
  "execution log pagination",
  "canvas patch rebase on stale revisions",
  "meeting transcript speaker labels",
  "the prototype publish flow",
  "deploy target resolution for rollups",
  "chat attachment presign expiry",
  "org memory journal digest",
  "task search ranking for short queries",
  "the inbox unread counter",
  "agent runtime heartbeat timeouts",
  "stack rollup branch provisioning",
  "review request superseding",
  "the mobile bottom nav safe area",
  "LiveKit token refresh",
  "skills resolution per task",
  "dark theme token contrast",
  "the files ingest retry queue"
]

description =
  "Context: this was reported from the board while triaging a busy week. " <>
    "The current behaviour is inconsistent between desktop and mobile, and the " <>
    "fix should keep the existing ids that tests and hooks resolve. Acceptance: " <>
    "the change is covered by a LiveView test and verified on the dev rig."

seed_task = fn status, i, extra ->
  sponsor = pick.(people)
  assignee = pick.(people)
  minutes = if status in ["done", "cancelled"], do: 600 + i * 97, else: 5 + i * 41

  %Task{
    project_id: extra.project_id,
    title: "#{pick.(verbs)} #{pick.(objects)} (#{i})",
    description: description,
    status: status,
    priority: pick.(~w(low medium medium high critical)),
    kind: pick.(~w(feature feature chore bug research ops)),
    sponsor_user_id: sponsor.id,
    assignee_type: "user",
    assignee_id: assignee.id,
    phase_assignees: %{
      "planning" => %{"assignee_id" => assignee.id, "assignee_type" => "user"},
      "execution" => %{"assignee_id" => assignee.id, "assignee_type" => "user"},
      "review" => %{"assignee_id" => sponsor.id, "assignee_type" => "user"}
    },
    reported_by: "ui_sluggishness seed",
    stack_id: Map.get(extra, :stack_id),
    stack_position: Map.get(extra, :stack_position),
    inserted_at: ago.(minutes + 2_000),
    updated_at: ago.(minutes)
  }
  |> Repo.insert!()
end

# Stage statuses per task status. nil means no plan at all.
plan_shape = fn
  "backlog" -> nil
  "planning" -> {"pending_review", fn _n, _i -> "pending" end}
  "cancelled" -> {"rejected", fn _n, _i -> "pending" end}
  "done" -> {"completed", fn _n, _i -> "passed" end}
  "deploying" -> {"approved", fn n, i -> if i < n, do: "passed", else: "running" end}
  "in_review" -> {"approved", fn n, i -> if i < n, do: "passed", else: "running" end}
  _ -> {"approved", fn n, i -> if i <= div(n, 2), do: "passed", else: "pending" end}
end

seed_plan = fn task ->
  case plan_shape.(task.status) do
    nil ->
      :ok

    {plan_status, stage_status} ->
      plan =
        Repo.insert!(%Plan{
          task_id: task.id,
          status: plan_status,
          version: 1,
          inserted_at: task.inserted_at,
          updated_at: task.updated_at
        })

      n = 2 + rem(:erlang.phash2(task.id), 4)

      for i <- 1..n do
        Repo.insert!(%Stage{
          plan_id: plan.id,
          position: i,
          name: "Stage #{i}: #{pick.(verbs)} #{pick.(objects)}",
          description: description,
          status: stage_status.(n, i),
          inserted_at: task.inserted_at,
          updated_at: task.updated_at
        })
      end

      :ok
  end
end

seed_tasks = fn ->
  project =
    Repo.insert!(%Project{
      name: "Perf: UI sluggishness",
      slug: "perf-ui-sluggishness",
      org_id: root_org.id,
      repo_url: "https://example.invalid/perf.git"
    })

  # 3 stacks x 4 members, members counted inside the status mix (taken from
  # backlog / planning / in_progress so the totals stay exact).
  member_statuses = ~w(in_progress planning backlog backlog)

  stack_members =
    for s <- 1..3 do
      stack =
        Repo.insert!(%Stack{
          project_id: project.id,
          sponsor_user_id: dev_user.id,
          slug: "perf-stack-#{s}",
          rollup_branch: "stack/perf-stack-#{s}",
          name: "Perf stack #{s}",
          description: "Seeded stack #{s} for the ui_sluggishness measurement.",
          status: "in_progress"
        })

      for {status, pos} <- Enum.with_index(member_statuses, 1) do
        task =
          seed_task.(status, s * 10 + pos, %{
            project_id: project.id,
            stack_id: stack.id,
            stack_position: pos
          })

        seed_plan.(task)
        status
      end
    end
    |> List.flatten()
    |> Enum.frequencies()

  for {status, count} <- status_mix do
    remaining = count - Map.get(stack_members, status, 0)

    for i <- 1..remaining//1 do
      task = seed_task.(status, i, %{project_id: project.id})
      seed_plan.(task)
    end
  end

  :created
end

task_part =
  case Repo.get_by(Project, slug: "perf-ui-sluggishness") do
    nil ->
      {:ok, result} = Repo.transaction(seed_tasks, timeout: :infinity)
      result

    %Project{id: id} ->
      count = Repo.aggregate(from(t in Task, where: t.project_id == ^id), :count)

      if count != task_total,
        do:
          raise("project perf-ui-sluggishness exists with #{count} tasks, expected #{task_total}")

      :existing
  end

# ── Chat ───────────────────────────────────────────────────────────────────

ensure_space = fn slug, name ->
  space =
    case Chat.get_space_by_slug(slug) do
      nil ->
        {:ok, s} =
          Chat.create_space(%{
            name: name,
            slug: slug,
            kind: "channel",
            org_id: root_org.id,
            created_by: dev_user.id,
            description: "ui_sluggishness measurement seed"
          })

        s

      s ->
        s
    end

  participants =
    for u <- people, into: %{} do
      p =
        case Repo.get_by(Platform.Chat.Participant,
               space_id: space.id,
               participant_type: "user",
               participant_id: u.id
             ) do
          nil ->
            {:ok, p} =
              Chat.add_participant(space.id, %{
                participant_type: "user",
                participant_id: u.id,
                display_name: u.name,
                joined_at: ago.(20_000)
              })

            p

          p ->
            p
        end

      {u.id, p}
    end

  {space, participants}
end

top_level_count = fn space_id ->
  Repo.aggregate(
    from(m in Platform.Chat.Message, where: m.space_id == ^space_id and is_nil(m.thread_id)),
    :count
  )
end

long_markdown = """
## Notes from the rollout review

The second pass of the migration is where most of the cost sits. We measured
three things on the rig:

1. **Join payload**: the first frame after mount, which carries every static.
2. **Per-click payload**: what a single `select_task` pushes after the patch.
3. **Main-thread time**: long tasks reported by the browser, summed per action.

| Surface | Before | After |
|---|---|---|
| board join | large | smaller |
| click | large | small |

> The numbers are rig numbers. Production confirmation happens after deploy.

```elixir
def refresh_board(socket) do
  socket |> assign(:columns, Tasks.list_by_status(opts))
end
```

Follow-ups: keep the ids the drag hook resolves, and do not reintroduce
template locals inside the card loop.
"""

short_lines = [
  "render farm finished overnight, frames 400-900 are clean",
  "any drift on the shadow pass?",
  "slight, only where the volumetrics overlap",
  "I can reshoot those twelve this afternoon",
  "sounds good, shipping it",
  "the cache invalidation is the tricky part here",
  "agreed, let's keep the old key for one release",
  "board feels slow again after the last deploy"
]

embed_html = fn i ->
  rows =
    for r <- 1..40,
        do: "<tr><td>row #{r}</td><td>#{r * i}</td><td>#{rem(r * 7, 13)}</td></tr>"

  """
  <!doctype html><html><head><style>
  body{font-family:system-ui;margin:0;padding:16px;background:#fafafa}
  table{border-collapse:collapse;width:100%}td{border:1px solid #ddd;padding:4px}
  .hero{height:120px;background:linear-gradient(90deg,#eee,#ccc);margin-bottom:12px}
  </style></head><body><div class="hero"></div><h2>Embed mockup #{i}</h2>
  <table>#{Enum.join(rows)}</table></body></html>
  """
end

canvas_doc = fn kind, i, prototype_id ->
  root_child =
    case kind do
      :table ->
        %{
          "id" => "t#{i}",
          "type" => "table",
          "props" => %{
            "columns" => ["Task", "Owner", "Status", "Notes"],
            "rows" =>
              for(
                r <- 1..30,
                do: %{
                  "Task" => "#{pick.(verbs)} #{pick.(objects)}",
                  "Owner" => pick.(people).name,
                  "Status" => pick.(~w(done in_progress backlog in_review)),
                  "Notes" => "row #{r} of seeded table #{i}"
                }
              )
          }
        }

      :markdown ->
        %{"id" => "m#{i}", "type" => "markdown", "props" => %{"content" => long_markdown}}

      :code ->
        %{
          "id" => "c#{i}",
          "type" => "code",
          "props" => %{
            "language" => "elixir",
            "source" =>
              Enum.map_join(1..60, "\n", fn l -> "  def step_#{l}(x), do: x + #{l * i}" end)
          }
        }

      :embed ->
        %{
          "id" => "e#{i}",
          "type" => "embed",
          "props" => %{"srcdoc" => embed_html.(i), "height" => 480}
        }

      :prototype ->
        %{
          "id" => "p#{i}",
          "type" => "prototype",
          "props" => %{"prototype_id" => prototype_id, "height" => 520}
        }
    end

  %{
    "version" => 1,
    "revision" => 1,
    "root" => %{
      "id" => "root",
      "type" => "stack",
      "children" => [
        %{"id" => "h#{i}", "type" => "heading", "props" => %{"value" => "Seeded #{kind} #{i}"}},
        root_child
      ]
    }
  }
end

publish_prototype = fn space, i ->
  {1, _} = Repo.update_all(Platform.Prototypes.Settings, set: [enabled: true])

  html =
    "<!doctype html><html><body style=\"font-family:system-ui;padding:24px\">" <>
      "<h1>Prototype #{i}</h1><p>Seeded prototype frame.</p></body></html>"

  {:ok, %{prototype: p}} =
    Platform.Prototypes.publish(
      %{kind: :user, user: dev_user},
      %{org_id: root_org.id, space_id: space.id, name: "Perf prototype #{i}"},
      {:files, %{"index.html" => %{"content" => html}}}
    )

  p.id
end

seed_heavy = fn space, participants ->
  # 18 canvas positions spread through the 160, mixed kinds.
  canvas_kinds =
    List.duplicate(:table, 4) ++
      List.duplicate(:markdown, 4) ++
      List.duplicate(:code, 4) ++ List.duplicate(:embed, 4) ++ List.duplicate(:prototype, 2)

  canvas_at = canvas_kinds |> Enum.with_index() |> Map.new(fn {k, j} -> {9 + j * 8, k} end)
  thread_at = MapSet.new([20, 47, 88, 120, 140, 155])
  pids = Map.values(participants)

  ids =
    for i <- 1..160 do
      p = Enum.at(pids, rem(i, length(pids)))

      msg =
        case Map.get(canvas_at, i) do
          nil ->
            body =
              cond do
                rem(i, 6) == 0 -> long_markdown
                rem(i, 4) == 0 -> Enum.join(Enum.take_random(short_lines, 4), "\n\n")
                true -> Enum.at(short_lines, rem(i, length(short_lines)))
              end

            {:ok, m} =
              Chat.post_message(%{
                space_id: space.id,
                participant_id: p.id,
                content_type: "text",
                content: "#{i}. #{body}"
              })

            m

          kind ->
            proto = if kind == :prototype, do: publish_prototype.(space, i)

            {:ok, _canvas, m} =
              Chat.create_canvas_with_message(space.id, p.id, %{
                "title" => "Seeded #{kind} canvas #{i}",
                "document" => canvas_doc.(kind, i, proto)
              })

            m
        end

      if MapSet.member?(thread_at, i) do
        {:ok, thread} = Chat.create_thread_for_message(space.id, msg.id)

        for r <- 1..4 do
          {:ok, _} =
            Chat.post_message(%{
              space_id: space.id,
              thread_id: thread.id,
              participant_id: Enum.at(pids, rem(i + r, length(pids))).id,
              content_type: "text",
              content: "reply #{r}: #{Enum.at(short_lines, rem(i + r, length(short_lines)))}"
            })
        end
      end

      msg.id
    end

  # Spread top-level messages over the last ~160 hours, in id order, so the
  # inserted_at order and the id cursor of load_older agree by construction.
  ids
  |> Enum.sort()
  |> Enum.with_index()
  |> Enum.each(fn {id, j} ->
    from(m in Platform.Chat.Message, where: m.id == ^id)
    |> Repo.update_all(set: [inserted_at: ago.((160 - j) * 60)])
  end)

  :created
end

{heavy, heavy_participants} = ensure_space.("perf-heavy-channel", "Perf heavy channel")

heavy_part =
  case top_level_count.(heavy.id) do
    0 ->
      seed_heavy.(heavy, heavy_participants)

    160 ->
      :existing

    n ->
      raise "perf-heavy-channel has #{n} top-level messages, expected 0 or 160"
  end

{light, light_participants} = ensure_space.("perf-light-channel", "Perf light channel")

light_part =
  case top_level_count.(light.id) do
    0 ->
      for {line, i} <- short_lines |> Enum.take(6) |> Enum.with_index(1) do
        {:ok, _} =
          Chat.post_message(%{
            space_id: light.id,
            participant_id: Map.fetch!(light_participants, dev_user.id).id,
            content_type: "text",
            content: "#{i}. #{line}"
          })
      end

      :created

    _ ->
      :existing
  end

# ── Canvas-heavy channel (stage 4) ─────────────────────────────────────────

mockup_html = fn i ->
  nav = for n <- 1..18, do: ~s(<a class="nav" href="#">Section #{n}</a>)

  cards =
    for c <- 1..6,
        do:
          ~s(<div class="card"><div class="lbl">Metric #{c}</div><div class="val">#{c * 137 + i}</div><div class="spark"></div></div>)

  rows =
    for r <- 1..110,
        do:
          "<tr><td>#{r}</td><td>Job #{r * i}</td><td><span class=\"pill p#{rem(r, 4)}\">" <>
            "#{Enum.at(~w(queued running done failed), rem(r, 4))}</span></td>" <>
            "<td>#{rem(r * 37, 100)}%</td><td>#{rem(r * 13, 60)}m</td></tr>"

  """
  <!doctype html><html><head><style>
  *{box-sizing:border-box}body{margin:0;font-family:system-ui;background:#f6f7f9;color:#1f2328}
  .shell{display:grid;grid-template-columns:200px 1fr;min-height:100vh}
  .side{background:#fff;border-right:1px solid #e5e7eb;padding:12px;display:flex;flex-direction:column;gap:4px}
  .nav{display:block;padding:6px 8px;border-radius:6px;color:#444;text-decoration:none}
  .nav:hover{background:#f0f1f3}main{padding:20px}
  .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:16px}
  .card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:12px}
  .lbl{font-size:12px;color:#666}.val{font-size:24px;font-weight:600}
  .spark{height:28px;margin-top:6px;background:linear-gradient(90deg,#dfe7ff,#b7c8ff,#dfe7ff)}
  table{width:100%;border-collapse:collapse;background:#fff}td{border-bottom:1px solid #eee;padding:6px 8px;font-size:13px}
  .pill{padding:2px 8px;border-radius:999px;font-size:11px}.p0{background:#eef}.p1{background:#ffe}.p2{background:#efe}.p3{background:#fee}
  </style></head><body><div class="shell"><aside class="side">#{Enum.join(nav)}</aside>
  <main><h1>Mockup #{i}: render queue</h1><div class="cards">#{Enum.join(cards)}</div>
  <table>#{Enum.join(rows)}</table></main></div></body></html>
  """
end

scripted_html = fn i ->
  """
  <!doctype html><html><head><style>
  body{margin:0;font-family:system-ui;padding:16px;background:#fff}
  #grid{display:grid;grid-template-columns:repeat(50,1fr);gap:1px;margin-top:12px}
  #grid div{height:10px;border-radius:2px}
  canvas{width:100%;height:220px;border:1px solid #e5e7eb;border-radius:8px}
  </style></head><body><h2>Interactive mockup #{i}</h2><canvas id="chart" width="1000" height="220"></canvas>
  <div id="stats"></div><div id="grid"></div>
  <script>
  (function(){
    var seed=#{i}*7919;function rnd(){seed=(seed*16807)%2147483647;return seed/2147483647}
    var pts=[];for(var k=0;k<5000;k++){pts.push(Math.sin(k/120)*60+rnd()*40)}
    var cv=document.getElementById('chart'),ctx=cv.getContext('2d');ctx.strokeStyle='#4f6bed';ctx.beginPath();
    for(var k=0;k<pts.length;k++){var x=k/pts.length*1000,y=110-pts[k];k?ctx.lineTo(x,y):ctx.moveTo(x,y)}ctx.stroke();
    for(var t=0;t<20;t++){ctx.fillText('t'+t,t*50,215)}
    var sorted=pts.slice().sort(function(a,b){return a-b});
    document.getElementById('stats').textContent='p50 '+sorted[2500].toFixed(1)+' p95 '+sorted[4750].toFixed(1);
    var g=document.getElementById('grid'),frag=document.createDocumentFragment();
    for(var c=0;c<2000;c++){var d=document.createElement('div');d.style.background='hsl('+Math.round(rnd()*240)+',70%,'+(55+Math.round(rnd()*30))+'%)';d.title='cell '+c;frag.appendChild(d)}
    g.appendChild(frag);
    g.addEventListener('click',function(e){if(e.target!==g)e.target.style.outline='2px solid #000'});
  })();
  </script></body></html>
  """
end

proto_board_html = fn i ->
  "<!doctype html><html><head><style>" <>
    "body{margin:0;font-family:system-ui;background:#f4f5f7;padding:16px}" <>
    ".cols{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}" <>
    ".col{background:#ebecf0;border-radius:8px;padding:8px}.c{background:#fff;border-radius:6px;padding:8px;margin:6px 0;" <>
    "box-shadow:0 1px 1px rgba(0,0,0,.1);font-size:13px}.tag{display:inline-block;font-size:10px;padding:1px 6px;" <>
    "border-radius:4px;background:#dfe1e6;margin-right:4px}</style></head><body>" <>
    "<h1>Prototype board #{i}</h1><div class=\"cols\" id=\"cols\"></div><script>" <>
    "(function(){var names=['Backlog','Doing','Review','Done'],root=document.getElementById('cols');" <>
    "names.forEach(function(n,ci){var col=document.createElement('div');col.className='col';" <>
    "col.innerHTML='<b>'+n+'</b>';for(var k=0;k<40;k++){var c=document.createElement('div');c.className='c';" <>
    "c.innerHTML='<div>Card '+(ci*40+k)+' for prototype #{i}</div><span class=\"tag\">ui</span><span class=\"tag\">p'+(k%3)+'</span>';" <>
    "c.onclick=function(){this.style.outline='2px solid #4f6bed'};col.appendChild(c)}root.appendChild(col)})})();" <>
    "</script></body></html>"
end

publish_board_prototype = fn space, i ->
  {1, _} = Repo.update_all(Platform.Prototypes.Settings, set: [enabled: true])

  {:ok, %{prototype: p}} =
    Platform.Prototypes.publish(
      %{kind: :user, user: dev_user},
      %{org_id: root_org.id, space_id: space.id, name: "Perf board prototype #{i}"},
      {:files, %{"index.html" => %{"content" => proto_board_html.(i)}}}
    )

  p.id
end

heavy_canvas_doc = fn kind, i, proto_id ->
  child =
    case kind do
      :mockup ->
        %{
          "id" => "e#{i}",
          "type" => "embed",
          "props" => %{"srcdoc" => mockup_html.(i), "height" => 720}
        }

      :scripted ->
        %{
          "id" => "s#{i}",
          "type" => "embed",
          "props" => %{"srcdoc" => scripted_html.(i), "height" => 560, "scripts" => true}
        }

      :prototype ->
        %{
          "id" => "p#{i}",
          "type" => "prototype",
          "props" => %{"prototype_id" => proto_id, "height" => 640}
        }

      other ->
        # table / markdown / code: reuse stage 1's shapes.
        canvas_doc.(other, i, nil)["root"]["children"] |> List.last()
    end

  %{
    "version" => 1,
    "revision" => 1,
    "root" => %{
      "id" => "root",
      "type" => "stack",
      "children" => [
        %{"id" => "h#{i}", "type" => "heading", "props" => %{"value" => "Design pass #{i}"}},
        child
      ]
    }
  }
end

seed_canvas_heavy = fn space, participants ->
  {1, _} = Repo.update_all(Platform.Prototypes.Settings, set: [enabled: true])

  # 30 canvas positions inside the newest-50 window (messages 11..60), the
  # newest message (60) left as text so the tail reads like a conversation.
  kinds =
    [:mockup, :scripted, :prototype, :mockup, :scripted, :table] ++
      [:mockup, :scripted, :prototype, :mockup, :scripted, :markdown] ++
      [:mockup, :scripted, :prototype, :mockup, :code, :prototype] ++
      [:mockup, :scripted, :prototype, :mockup, :scripted, :table] ++
      [:mockup, :prototype, :code, :markdown, :mockup, :scripted]

  canvas_at = kinds |> Enum.with_index() |> Map.new(fn {k, j} -> {12 + div(j * 47, 30), k} end)
  30 = map_size(canvas_at)
  pids = Map.values(participants)

  ids =
    for i <- 1..60 do
      p = Enum.at(pids, rem(i, length(pids)))

      msg =
        case Map.get(canvas_at, i) do
          nil ->
            body =
              if rem(i, 5) == 0,
                do: long_markdown,
                else: Enum.at(short_lines, rem(i, length(short_lines)))

            {:ok, m} =
              Chat.post_message(%{
                space_id: space.id,
                participant_id: p.id,
                content_type: "text",
                content: "#{i}. #{body}"
              })

            m

          kind ->
            proto = if kind == :prototype, do: publish_board_prototype.(space, i)

            {:ok, _canvas, m} =
              Chat.create_canvas_with_message(space.id, p.id, %{
                "title" => "Design pass #{i} (#{kind})",
                "document" => heavy_canvas_doc.(kind, i, proto)
              })

            m
        end

      msg.id
    end

  ids
  |> Enum.sort()
  |> Enum.with_index()
  |> Enum.each(fn {id, j} ->
    from(m in Platform.Chat.Message, where: m.id == ^id)
    |> Repo.update_all(set: [inserted_at: ago.((60 - j) * 30)])
  end)

  :created
end

{canvas_heavy, canvas_heavy_participants} =
  ensure_space.("perf-canvas-heavy-channel", "Perf canvas-heavy channel")

canvas_heavy_part =
  case top_level_count.(canvas_heavy.id) do
    0 -> seed_canvas_heavy.(canvas_heavy, canvas_heavy_participants)
    60 -> :existing
    n -> raise "perf-canvas-heavy-channel has #{n} top-level messages, expected 0 or 60"
  end

canvas_heavy_canvases =
  Repo.aggregate(
    from(m in Platform.Chat.Message,
      where: m.space_id == ^canvas_heavy.id and m.content_type == "canvas"
    ),
    :count
  )

project = Repo.get_by!(Project, slug: "perf-ui-sluggishness")

counts =
  from(t in Task,
    where: t.project_id == ^project.id,
    group_by: t.status,
    select: {t.status, count()}
  )
  |> Repo.all()
  |> Map.new()

canvas_count =
  Repo.aggregate(
    from(m in Platform.Chat.Message,
      where: m.space_id == ^heavy.id and m.content_type == "canvas"
    ),
    :count
  )

IO.inspect(
  %{
    tasks: task_part,
    heavy_channel: heavy_part,
    light_channel: light_part,
    project_id: project.id,
    task_counts_by_status: counts,
    task_total: counts |> Map.values() |> Enum.sum(),
    heavy_space_id: heavy.id,
    heavy_slug: heavy.slug,
    heavy_top_level_messages: top_level_count.(heavy.id),
    heavy_canvas_messages: canvas_count,
    light_space_id: light.id,
    light_slug: light.slug,
    canvas_heavy_channel: canvas_heavy_part,
    canvas_heavy_space_id: canvas_heavy.id,
    canvas_heavy_top_level_messages: top_level_count.(canvas_heavy.id),
    canvas_heavy_canvas_messages: canvas_heavy_canvases,
    assumption:
      "status mix (done 1040, cancelled 110, backlog 80, planning 30, in_progress 45, " <>
        "blocked 10, in_review 30, deploying 18) is assumed; the prod Done share was not measured"
  },
  label: "ui_sluggishness seed"
)
