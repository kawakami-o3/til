# logger_file_backend

* mix.exs

```elixir
  defp deps do
    [
			...
			{:logger_file_backend, "~> 0.0.10"},
			...
		]
	end
```


* config/prod.exs

```elixir
config :logger, backends: [{LoggerFileBackend, :error_log}]

config :logger, :error_log,
  path: "/var/log/phoenix/error.log",
  level: :error
```

