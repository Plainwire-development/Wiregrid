defmodule Wiregrid.Topic do
  @moduledoc """
  Zero-cost constructors for Wiregrid's generic topic terms.

  These functions return the ordinary tuples used by the runtime; there is no
  wrapper struct or conversion step on publish/fanout hot paths.
  """

  @type t ::
          {:user, term()}
          | {:channel, term()}
          | {:thread, term()}
          | {:room, term()}
          | {:game, term()}
          | {:document, term()}
          | {:custom, term(), term()}

  def user(id), do: {:user, id}
  def channel(id), do: {:channel, id}
  def thread(id), do: {:thread, id}
  def room(id), do: {:room, id}
  def game(id), do: {:game, id}
  def document(id), do: {:document, id}
  def custom(namespace, value), do: {:custom, namespace, value}
end
