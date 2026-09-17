defmodule SymphonyElixir.Worker do
  @moduledoc """
  Provider-neutral boundary, called only inside AgentRunner's workspace ownership.

  `start/1` receives the assigned issue, workspace, optional assigned branch, host,
  task prompt and turn budget, never workflow settings or credentials. Branch nil
  means the existing workflow owns branch selection. Adapters use host-side auth.
  `run/3` blocks until a normalized result and streams compact status via its callback.
  Handles are opaque and must never be placed in scheduler state or logs.

  `stop/1` is idempotent and must leave valid workspace files intact. Resources must
  also terminate on owner process death (including untrappable cancellation), retaining
  workspace activity ownership until all mutating children stop. Persistent sessions
  are optional: a session identifier alone is not a promise of resumability.
  """

  alias SymphonyElixir.Worker.{Codex, Result}

  @type context :: %{
          issue: SymphonyElixir.Tracker.Issue.t(),
          workspace: Path.t(),
          branch: String.t() | nil,
          worker_host: String.t() | nil,
          prompt: String.t(),
          turn: pos_integer(),
          max_turns: pos_integer()
        }
  @callback identity() :: %{provider: String.t(), model: String.t() | nil, harness: String.t()}
  @callback capabilities() :: %{conversation: boolean(), resume: boolean(), usage: boolean(), quota: boolean()}
  @callback start(context()) :: {:ok, term()} | {:error, Result.t()}
  @callback run(term(), context(), (map() -> term())) :: Result.t()
  @callback stop(term()) :: :ok
  @callback resume(context(), String.t()) :: {:ok, term()} | {:error, Result.t()}
  @optional_callbacks resume: 2

  @spec adapter() :: module()
  def adapter, do: Application.get_env(:symphony_elixir, :worker_adapter, Codex)

  @spec start(module(), context()) :: {:ok, term()} | {:error, Result.t()}
  def start(adapter, context) do
    case adapter.start(context) do
      {:ok, handle} -> {:ok, handle}
      {:error, result} -> {:error, Result.normalize(result)}
      _ -> {:error, %Result{}}
    end
  rescue
    _ -> {:error, %Result{}}
  end

  @spec run(module(), term(), context(), (map() -> term())) :: Result.t()
  def run(adapter, handle, context, on_update) do
    adapter.run(handle, context, on_update) |> Result.normalize()
  rescue
    _ -> %Result{}
  end
end
