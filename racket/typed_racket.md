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

```racket
(: x Number)
(define x 7)

(define x : Number 7)
(define (id [z : Number]) : Number z)
; (-> Number Number)

(let ([x : Number 7])
  (add1 x))
(let-values ([([x : Number] [y : String]) (values 7 "hello")])
  (+ x (string-length y)))
  
(lambda ([x : String] . [y : Number *]) (apply + y))
; y is a list of Numbers
; (-> String Number * Number)

(case-lambda [() 0]
             [([x : Number]) x])
; (case-> (-> Number) (-> Number Number))

(let ([#{x : Number} 7]) (add1 x))
```

```
> (ann "not a number" Number)
eval:2:0: Type Checker: type mismatch
  expected: Number
  given: String
  in: Number
```

```
(define-type NN (-> Number Number))
```

## Types in Typed Racket

再帰型

```
(define-type BinaryTree (U Number (Pair BinaryTree BinaryTree)))
```

## Occurrence Typing

## こまごましたこと

* 型を表示する
  * :print-type



