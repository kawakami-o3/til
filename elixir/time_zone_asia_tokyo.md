# Time Zone

https://github.com/lau/tzdata

```elixir
  defp deps do
    [
			...
			{:tzdata, "~> 1.0.0"},
			...
		]
	end
```


* config/config.exs

```elixir
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
```


* Example

```elixir
iex(11)> DateTime.shift_zone(DateTime.utc_now(), "Asia/Tokyo", Tzdata.TimeZoneDatabase)
{:ok, #DateTime<2019-11-11 11:11:11.111111+09:00 JST Asia/Tokyo>}
```
