defmodule Wiregrid.LFE do
  @moduledoc """
  Discovery helpers for Wiregrid's optional LFE acceleration layer.

  Core Wiregrid never requires LFE at runtime. Projects that compile the shipped
  bindings can use `available?/0` and `modules/0` to verify the optimized layer
  was loaded on a node before selecting an LFE worker in a supervision tree.
  """

  @modules [
    :wiregrid,
    :wiregrid_macros,
    :wiregrid_fast,
    :wiregrid_kernel,
    :wiregrid_worker,
    :wiregrid_batch_worker,
    :wiregrid_adaptive_worker,
    :wiregrid_lane,
    :wiregrid_flow,
    :wiregrid_projection
  ]

  @spec modules() :: [atom()]
  def modules, do: @modules

  @spec available?() :: boolean()
  def available?, do: Enum.all?(@modules, &Code.ensure_loaded?/1)

  @spec status() :: %{available: boolean(), loaded: [atom()], missing: [atom()]}
  def status do
    {loaded, missing} = Enum.split_with(@modules, &Code.ensure_loaded?/1)
    %{available: missing == [], loaded: loaded, missing: missing}
  end
end
