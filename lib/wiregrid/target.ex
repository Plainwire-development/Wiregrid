defmodule Wiregrid.Target do
  @moduledoc """
  Zero-cost constructors for heterogeneous `Wiregrid.dispatch/4` targets.

  Target terms remain plain BEAM tuples so Erlang/LFE/Gleam and Elixir all use
  the same ABI and dispatch planner.
  """

  @type t :: {:topic, term()} | {:room, term()} | {:user, term()} | {:session, binary()}

  def topic(topic), do: {:topic, topic}
  def room(room), do: {:room, room}
  def user(user_id), do: {:user, user_id}
  def session(session_id), do: {:session, session_id}
end
