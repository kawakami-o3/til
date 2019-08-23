# WebTransport

https://github.com/WICG/web-transport/blob/master/explainer.md

* 生UDPでは、暗号化、輻輳制御、DDoS防止機構が足りない
* WebSocket では、必要なくなった通信についても順に送受信される必要がある(HoLB)


## 用語

* Transport
* Transport protocol
* Datagram
* Stream
* Message
* Transport feature
* Transport property
* Server
* Client
* User agent


## 概要

https://tools.ietf.org/html/draft-vvv-webtransport-overview-00

* TLS 1.3 or later
* A connection establishment and keep-alive mechanisms
* Rate limit (a feedback-based congestion control mechanism)
* simultaneously establishing multiple sessions
* prevent the clients from establishing transport sessions to the network endpoints that are not WebTransport servers.
* a way to filter the clients that can access the servers by the origin


## Http3Transport

https://tools.ietf.org/html/draft-vvv-webtransport-http3-00


## QuicTransport

https://tools.ietf.org/html/draft-vvv-webtransport-quic-00


### Quic

#### イントロ

* stream の多重化
* stream、connection単位での流量制御
* 低遅延のconnection確立
* NAT切り替わり時のconnection復帰
* 暗号化通信

#### Stream

軽量、順序保証のバイトストリーム抽象。
単方向、双方向。単方向は無限 "message" の抽象化。

Stream の生成はデータ送信で行われ、全ての操作が最小限のオーバーヘッドになるように設計されている。
たとえば、1 フレームでオープン、データ送信、クローズの操作をおこなえる。
Stream は長期間、connection が維持されている間、維持される。

Steam はエンドポイントのどちらからでも生成できて、並行にデータ送信され、キャンセルできる。
異なる stream 間では順序を保証しない。

流量制御や stream の制限に従って、いくつでも stream を並行に操作でき、いくつでもデータを stream で送信できます。

##### 2.1.  Stream Types and Identifiers

#### メモ

* RFC
  * https://tools.ietf.org/html/draft-ietf-quic-transport
* Rust実装
  * https://github.com/djc/quinn
* 現状
  * 実装リスト https://github.com/quicwg/base-drafts/wiki/Implementations
  * 互換性表 https://docs.google.com/spreadsheets/d/1D0tW89vOoaScs3IY9RGC0UesWGAwE6xyLk0l4JtvTVg/edit#gid=161203809
  * ドラフトバージョンが更新されていることがある。
* 参考
  * https://qiita.com/flano_yuki/items/251a350b4f8a31de47f5
  * https://asnokaze.hatenablog.com/entry/2017/08/13/022447


## 関連事項

* Head of Line Blocking
  * https://qiita.com/Jxck_/items/0dbdee585db3e21639a8
* 詳解 HTTP/3
  * https://http3-explained.haxx.se/ja/

* QUIC はじめました by V
  * https://medium.com/@voluntas/quic-%E3%81%AF%E3%81%98%E3%82%81%E3%81%BE%E3%81%97%E3%81%9F-fdf0c5654df7

* QUICの話 (QUICプロトコルの簡単なまとめ)
  * https://asnokaze.hatenablog.com/entry/2018/10/31/020215
