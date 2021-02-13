# NAT Traversal

ここでは、以下の tailscale の記事をかいつまんで NAT traversal の手法についてまとめてみる。

https://tailscale.com/blog/how-nat-traversal-works/


前提として、UDPを使ってソケットを直接操作することを念頭において説明する。

ソケット直接操作は煩雑だけれども、ローカルproxyレイヤーをおいてNAT traversalを行わせることで、
もとのプログラムを変更せずに目的を達成できるようになる。


障害となるのは、ステートフルなファイヤーウォールとNATデバイス。


## ファイヤーウォール

* Windows Defender firewall
* Ubuntu's ufw
* BSD's pf
* AWS's Security Groups

インバウンドとアウトバウンド。



