# Module rig (ADR 0055 stage 4, task 01a0ee08): the rows exercise_core.exs
# created are still there after the build switch. Evaluated with a binding:
#   Code.eval_string(File.read!("/rig/verify_core.exs"), task_id: ..., experiment_id: ...)
alias Platform.Experiments.Experiment
alias Platform.Repo
alias Platform.Tasks.Task, as: TaskRecord

task = Repo.get(TaskRecord, task_id)
experiment = Repo.get(Experiment, experiment_id)

IO.puts("RIG task_intact=#{not is_nil(task)}")
IO.puts("RIG experiment_intact=#{not is_nil(experiment)}")
