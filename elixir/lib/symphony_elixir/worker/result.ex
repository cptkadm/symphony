defmodule SymphonyElixir.Worker.Result do
  @moduledoc """
  A worker's report, never independent verification or permission to merge.
  Retry times are Unix milliseconds; absent usage/session data means unknown.
  Raw provider payloads and credentials must not be included.
  """

  @classes [
    :success,
    :implementation_failure,
    :provider_capacity,
    :rate_limited,
    :authentication_failure,
    :transport_failure,
    :input_required,
    :cancelled,
    :unknown_failure
  ]
  defstruct class: :unknown_failure, retry_at_ms: nil, session_id: nil, usage: nil, quota: nil

  @type t :: %__MODULE__{
          class: atom(),
          retry_at_ms: non_neg_integer() | nil,
          session_id: String.t() | nil,
          usage: map() | nil,
          quota: map() | nil
        }

  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = result) do
    if valid_result?(result) do
      result
    else
      %__MODULE__{}
    end
  end

  def normalize(_), do: %__MODULE__{}

  defp valid_result?(%__MODULE__{
         class: class,
         retry_at_ms: retry,
         session_id: session,
         usage: usage,
         quota: quota
       }) do
    valid_class?(class) and valid_retry?(retry) and valid_session?(session) and valid_map?(usage) and
      valid_map?(quota)
  end

  defp valid_class?(class), do: class in @classes

  defp valid_retry?(nil), do: true
  defp valid_retry?(retry), do: is_integer(retry) and retry >= 0

  defp valid_session?(nil), do: true
  defp valid_session?(session), do: is_binary(session)

  defp valid_map?(nil), do: true
  defp valid_map?(m), do: is_map(m)
end
