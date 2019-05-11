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

(define-type BinaryTree (U BinaryTreeLeaf BinaryTreeNode))
(define-type BinaryTreeLeaf Number)
(define-type BinaryTreeNode (Pair BinaryTree BinaryTree))
```

a parameterized type

```
(struct None ())
(struct (a) Some ([v : a]))
 
(define-type (Opt a) (U None (Some a)))
```

Polymorphic Functions

```
(: list-length (All (A) (-> (Listof A) Integer)))
(define (list-length l)
  (if (null? l)
      0
      (add1 (list-length (cdr l)))))
```


Lexically Scoped Type Variables

```
(: my-id (All (a) (-> a a)))
(define my-id
  (lambda ([x : a])
    (: helper (All (a) (-> a a)))
    (define helper
      (lambda ([y : a]) y))
    (helper x)))
```

Uniform Variable-Arity Functions

```
#lang typed/racket
(: sum (-> Number * Number))
(define (sum . xs)
  (if (null? xs)
      0
      (+ (car xs) (apply sum (cdr xs)))))
```

Non-Uniform Variable-Arity Functions

```
#lang typed/racket
(: fold-left
   (All (C A B ...)
        (-> (-> C A B ... B C) C (Listof A) (Listof B) ... B
            C)))
(define (fold-left f i as . bss)
  (if (or (null? as)
          (ormap null? bss))
      i
      (apply fold-left
             f
             (apply f i (car as) (map car bss))
             (cdr as)
             (map cdr bss))))
```

???

## Occurrence Typing

## こまごましたこと

* 型を表示する
  * :print-type



