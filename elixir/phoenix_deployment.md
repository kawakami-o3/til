# Phoenix Deployment


```
# Initial setup
$ mix deps.get --only prod
$ MIX_ENV=prod mix compile

# Compile assets
$ cd assets && webpack --mode production && cd ..

$ mix phx.digest

# Custom tasks (like DB migrations)
$ MIX_ENV=prod mix ecto.migrate

# Finally run the server
$ PORT=4001 MIX_ENV=prod mix phx.server
```

```
$ env MIX_ENV=prod elixir --detached -S mix do compile, phx.server
```

