defmodule Wiregrid.Instance do
  @moduledoc """
  Supervision-tree entry point for a Wiregrid instance.

  Embed Wiregrid in an OTP application without imperative startup:

      children = [
        {Wiregrid.Instance, [instance: {:tenant, 42}, options: [profile: :balanced]]}
      ]

  The explicit keyword shape is intentional: Wiregrid instance identifiers may
  themselves be tuples, lists, or other bounded portable terms, so an
  `{instance, opts}` convention would be ambiguous.
  """

  @allowed_keys [:instance, :options]

  def start_link(spec) when is_list(spec) do
    with :ok <- Wiregrid.Validation.keyword_opts(spec, @allowed_keys),
         {:ok, instance} <- fetch_instance(spec),
         opts <- Keyword.get(spec, :options, []),
         :ok <- Wiregrid.Validation.instance(instance),
         {:ok, config} <- Wiregrid.Config.build(opts) do
      Wiregrid.InstanceSupervisor.start_link({instance, config})
    end
  end

  def start_link(_spec), do: {:error, :invalid_instance_spec}

  def child_spec(spec) when is_list(spec) do
    case normalize_spec(spec) do
      {:ok, normalized, instance} ->
        %{
          id: {__MODULE__, instance},
          start: {__MODULE__, :start_link, [normalized]},
          restart: :permanent,
          shutdown: 30_000,
          type: :supervisor
        }

      {:error, reason} ->
        raise ArgumentError, "invalid Wiregrid.Instance child spec: #{inspect(reason)}"
    end
  end

  def child_spec(_spec),
    do: raise(ArgumentError, "Wiregrid.Instance expects a keyword child spec")

  defp normalize_spec(spec) do
    with :ok <- Wiregrid.Validation.keyword_opts(spec, @allowed_keys),
         {:ok, instance} <- fetch_instance(spec),
         opts <- Keyword.get(spec, :options, []),
         :ok <- Wiregrid.Validation.instance(instance),
         {:ok, _config} <- Wiregrid.Config.build(opts) do
      {:ok, [instance: instance, options: opts], instance}
    end
  end

  defp fetch_instance(spec) do
    case Keyword.fetch(spec, :instance) do
      {:ok, instance} -> {:ok, instance}
      :error -> {:error, :missing_instance}
    end
  end
end
