defmodule SymphonyElixir.Worker.Result do
  @moduledoc """
  A worker's report, never independent verification or permission to merge.
  Retry times are Unix milliseconds; absent usage/session data means unknown.
  Raw provider payloads and credentials must not be included.
  """

  @classes [:success, :implementation_failure, :provider_capacity, :rate_limited, :authentication_failure, :transport_failure, :input_required, :cancelled, :unknown_failure]
  defstruct class: :unknown_failure, retry_at_ms: nil, session_id: nil, usage: nil, quota: nil

  @type t :: %__MODULE__{
          class: atom(),
          retry_at_ms: non_neg_integer() | nil,
          session_id: String.t() | nil,
          usage: map() | nil,
          quota: map() | nil
        }

  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{class: class, retry_at_ms: retry, session_id: session, usage: usage, quota: quota} = result)
      when class in @classes and (is_nil(retry) or (is_integer(retry) and retry >= 0)) and
             (is_nil(session) or is_binary(session)) and (is_nil(usage) or is_map(usage)) and
             (is_nil(quota) or is_map(quota)),
      do: result

  def normalize(_), do: %__MODULE__{}
end
