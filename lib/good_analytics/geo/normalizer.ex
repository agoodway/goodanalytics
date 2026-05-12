defmodule GoodAnalytics.Geo.Normalizer do
  @moduledoc """
  Behaviour for translating provider-specific lookup results into the canonical
  geo map stored in `ga_visitors.geo`.

  The canonical shape (also documented in
  `priv/good_analytics/sql/versions/v01/v01_up.sql:56`):

      %{
        country: String.t() | nil,
        country_code: String.t() | nil,
        region: String.t() | nil,
        city: String.t() | nil,
        timezone: String.t() | nil,
        continent: String.t() | nil,
        latitude: float() | nil,
        longitude: float() | nil
      }

  The shipped implementation is `GoodAnalytics.Geo.Normalizer.MaxMind`, which
  understands MaxMind GeoLite2-City and GeoIP2-City MMDB output.
  """

  @type normalized :: %{
          country: String.t() | nil,
          country_code: String.t() | nil,
          region: String.t() | nil,
          city: String.t() | nil,
          timezone: String.t() | nil,
          continent: String.t() | nil,
          latitude: float() | nil,
          longitude: float() | nil
        }

  @callback normalize(provider_specific :: map()) :: normalized
end
