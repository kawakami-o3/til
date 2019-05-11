# Typed Racket

## まずはじめに

Typed Racket指定で実行するなら

```racket
#lang typed/racket
```

REPLをTyped Racketモードで起動するなら

```
racket -I typed/racket
```

## 型を定義する

* 型を定義する
  * define-type
* union
  * U
  
```
> (struct leaf ([val : Number]))
> (struct node ([leaf : Tree] [right : Tree]))
> (define-type Tree (U leaf node))
> (leaf 1)
- : leaf
#<leaf>
> (leaf? (leaf 1))
- : Boolean [more precisely: True]
```

## こまごましたこと

* 型を表示する
  * :print-type



