# 小ネタ


## [Ruby] ブロック中のreturn

以下のコードは意図した通りには動かない。

```
def hogehoge?(arr)
  arr.any? do |i|
    return true if ...
    return true if ...
    false
  end
end
```

return は `any?` のブロックに利用されることを想定されているが、メソッドの返り値を返すために使われてしまう。

こういう時はnextを使う

```
def hogehoge?(arr)
  arr.any? do |i|
    next true if ...
    next true if ...
    false
  end
end
```

https://docs.ruby-lang.org/ja/latest/doc/spec=2fcontrol.html#next
