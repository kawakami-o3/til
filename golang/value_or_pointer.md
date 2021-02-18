# A Aalue Or Pointer


[Go: Should I Use a Pointer instead of a Copy of my Struct?](https://medium.com/a-journey-with-go/go-should-i-use-a-pointer-instead-of-a-copy-of-my-struct-44b43b104963)

実体を使うかポインターか問題。
素朴に考えると、コピーが走る分遅くなりそうだけど、実際はそうではなくてGCが働く分逆にポインターの方が遅くなることもある、という話。

Go自体のガイドラインを見てみると、この点については言及されていて

https://github.com/golang/go/wiki/CodeReviewComments#receiver-type

上記のリンクは、レシーバとしてはどちらを選ぶべきかというガイドラインで、「実体を選ぶならちゃんと計測するように（意訳）」という文言がある。
いくつか例外があるものの、基準が曖昧な部分もあり、「迷ったらポインターでよい」とされている。

