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
  @callback identity() :: %{
              optional(:protocol) => String.t(),
              provider: String.t(),
              model: String.t() | nil,
              harness: String.t()
            }
  @callback capabilities() :: %{
              optional(:acp) => boolean(),
              conversation: boolean(),
              resume: boolean(),
              usage: boolean(),
              quota: boolean()
            }
  @callback start(context()) :: {:ok, term()} | {:error, Result.t()}
  @callback run(term(), context(), (map() -> term())) :: Result.t()
  @callback stop(term()) :: :ok
  @callback resume(context(), String.t()) :: {:ok, term()} | {:error, Result.t()}
  @optional_callbacks resume: 2

  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:symphony_elixir, :worker_adapter) do
      nil -> adapter_from_config()
      module when is_atom(module) -> module
    end
  end

  defp adapter_from_config do
    try do
      case SymphonyElixir.Config.settings() do
        {:ok, %{worker: %{adapter: adapter}}} when is_binary(adapter) ->
          resolve_adapter_name(adapter)

        {:ok, %{worker: %{kind: kind}}} when is_binary(kind) ->
          resolve_adapter_name(kind)

        _ ->
          Codex
      end
    rescue
      _ -> Codex
    catch
      :exit, _ -> Codex
    end
  end

  @spec resolve_adapter_name(String.t() | atom()) :: module()
  def resolve_adapter_name("openhands"), do: SymphonyElixir.Worker.OpenHands
  def resolve_adapter_name(:openhands), do: SymphonyElixir.Worker.OpenHands
  def resolve_adapter_name("acp"), do: SymphonyElixir.Worker.ACP
  def resolve_adapter_name(:acp), do: SymphonyElixir.Worker.ACP
  def resolve_adapter_name("codex"), do: SymphonyElixir.Worker.Codex
  def resolve_adapter_name(:codex), do: SymphonyElixir.Worker.Codex
  def resolve_adapter_name(_), do: Codex

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
    result = adapter.run(handle, context, on_update) |> Result.normalize()

    case result.attribution do
      nil ->
        identity =
          try do
            adapter.identity()
          rescue
            _ -> nil
          end

        if is_map(identity) do
          %{result | attribution: identity} |> Result.normalize()
        else
          result
        end

      _ ->
        result
    end
  rescue
    _ -> %Result{}
  end
end
