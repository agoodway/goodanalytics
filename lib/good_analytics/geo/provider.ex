defmodule GoodAnalytics.Geo.Provider do
  @moduledoc """
  Behaviour for GeoIP providers.

  An implementation receives a parsed IP address (`:inet.ip_address/0` tuple) and
  returns either `{:ok, raw_map}` (provider-specific shape) or `{:error, reason}`.
  Raw output is passed to a `GoodAnalytics.Geo.Normalizer` which maps it to the
  canonical field set returned by `GoodAnalytics.Geo.lookup/1`.

  The shipped implementation is `GoodAnalytics.Geo.Locus`.
  """

  @type ip :: :inet.ip_address()
  @type raw_result :: map()
  @type reason :: :not_found | :loader_not_ready | atom() | tuple()

  @callback lookup(ip) :: {:ok, raw_result} | {:error, reason}
end
