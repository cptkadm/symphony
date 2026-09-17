defmodule SymphonyElixir.CIProbeTest do
  use ExUnit.Case, async: true

  test "deliberate CI failure proves the fork runs pull-request checks" do
    assert false
  end
end
