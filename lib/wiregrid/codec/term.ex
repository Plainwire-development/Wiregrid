defmodule Wiregrid.Codec.Term do
  @behaviour Wiregrid.Codec
  @max 16_777_216

  @impl true
  def encode(term), do: Wiregrid.SafeTerm.encode(term, @max)

  @impl true
  def decode(binary), do: Wiregrid.SafeTerm.decode(binary, @max)
end
