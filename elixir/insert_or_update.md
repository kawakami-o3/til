# insert_or_update


```elixir
changes = %{
	key: k,
	...
}

case Repo.get_by(Foo, key: changes.key) do
	nil -> %Foo{}
	data -> data
end
|> Foo.changeset(changes)
|> Repo.insert_or_update
```

