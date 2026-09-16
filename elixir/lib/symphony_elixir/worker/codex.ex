defmodule SymphonyElixir.Worker.Codex do
  @moduledoc "Codex App Server implementation of the common worker boundary."
  @behaviour SymphonyElixir.Worker
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Worker.{CodexTelemetry, Result}

  @impl true
  def identity, do: %{provider: "openai", model: nil, harness: "codex-app-server"}

  @impl true
  def capabilities, do: %{conversation: true, resume: false, usage: true, quota: true}

  @impl true
  def start(context) do
    case AppServer.start_session(context.workspace, worker_host: context.worker_host) do
      {:ok, handle} -> {:ok, handle}
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  @impl true
  def run(handle, context, on_update) do
    case AppServer.run_turn(handle, context.prompt, context.issue, on_message: fn update -> on_update.(CodexTelemetry.normalize(update)) end) do
      {:ok, result} -> %Result{class: :success, session_id: result[:session_id]}
      {:error, reason} -> classify(reason)
    end
  end

  @impl true
  def stop(handle), do: AppServer.stop_session(handle)

  @doc "Classifies structured App Server errors without guessing from message text."
  @spec classify(term()) :: Result.t()
  def classify({kind, payload}) when kind in [:turn_failed, :response_error] do
    %Result{class: error_class(payload, kind)}
  end

  def classify({kind, _}) when kind in [:turn_input_required, :approval_required], do: %Result{class: :input_required}
  def classify({:turn_cancelled, _}), do: %Result{class: :cancelled}
  def classify({:port_exit, _}), do: %Result{class: :transport_failure}
  def classify(reason) when reason in [:turn_timeout, :response_timeout], do: %Result{class: :transport_failure}
  def classify(_), do: %Result{}

  defp error_class(%{"code" => -32001}, _), do: :provider_capacity
  defp error_class(%{"error" => error}, kind), do: error_class(error, kind)
  defp error_class(%{"turn" => %{"error" => error}}, kind), do: error_class(error, kind)
  defp error_class(%{"codexErrorInfo" => info}, kind), do: info_class(info, kind)
  defp error_class(_, :turn_failed), do: :implementation_failure
  defp error_class(_, _), do: :unknown_failure

  defp info_class("serverOverloaded", _), do: :provider_capacity
  defp info_class(info, _) when info in ["usageLimitExceeded", "sessionBudgetExceeded"], do: :rate_limited
  defp info_class("unauthorized", _), do: :authentication_failure
  defp info_class(info, _) when info in ["httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts"], do: :transport_failure

  defp info_class(info, kind) when is_map(info) do
    case Map.keys(info) do
      [key] -> info_class(key, kind)
      _ -> :unknown_failure
    end
  end

  defp info_class(info, _) when info in ["contextWindowExceeded", "sandboxError", "badRequest"], do: :implementation_failure
  defp info_class(_, _), do: :unknown_failure
end
