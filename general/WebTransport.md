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

Stream ID で同定される。62 bit整数(0 ～ 2^62-1)。
var int https://tools.ietf.org/html/draft-ietf-quic-transport-22#section-16 にエンコードされる。再利用はしてはならない。

Stream IDの最下位ビットが、サーバー起因か(奇数)、クライアント起因か(偶数)を示す。
また、下位第二位ビットが、単方向(1)か、双方向(0)かを示す。


|  値  |  タイプ  |
| ---- | ---- |
|  0x0  |  クライアント起因、双方向 |
|  0x1  |  サーバー起因、双方向  |
|  0x2  |  クライアント起因、単方向 |
|  0x3  |  サーバー起因、単方向  |

Stream ID は単調増加させる。

最初のクライアント起因双方向 stream は ID 0 となる。

##### 2.2.  Sending and Receiving Data

エンドポイントは順序を保証しつつストリームデータを配送しなければならない(MUST)。
順不同で受信したデータは、流量制限までは溜め込む必要がある。

順不同のストリームデータを許容しないものの、実実装では採用されるかもしれない(MAY)。

同じ stream offset で何度もデータを受信することがおこりえる。
受信済みだった場合は破棄できる。指定されたオフセットのデータは、何度送られたとしても、変わってはならない(MUST NOT)。
同じ stream offset で異なるデータを取得した場合は、PROTOCOL_VIOLATION としてみなすかもしれない(MAY)。

Stream は順序付きバイトストリーム抽象である他は、データ構造が露呈しない。
このため、転送やパケロス後の再送、受信者への配送などで、フレーム境界が保持されるとは期待されない。

エンドポイントは流量制御に従わずにデータ送信してはならない(MUST NOT)。

##### 2.3.  Stream Prioritization

Steam の多重化はアプリケーションのパフォーマンスに大きな影響を与えるので、
ただしい優先順位でリソース管理に注意する必要がある。

QUICには、優先順位の管理機構は規定されていない。
その代わり、アプリケーションから提示される優先順位情報を活用できる。

QUIC実装では、アプリケーションがstreamの相対優先度を提示できるようにすべきである(SHOULD)。
また、その情報を活用するべきである(SHOULD)。

##### 3. Stream States

ここでは、データの送受信について 2 つのステートマシンを例にだして解説する。
一つはエンドポイントでのデータ送信、もうひとつはデータ受信について解説する。

単方向通信では 1 つのステートマシンを、双方向通信では 2 つのステートマシンを用いる。
多くの部分について、ステートマシンの使い方は単方向・双方向通信によらず同じである。
双方向通信でのstreamを確立するのは若干複雑である。


Stream IDは単調増加しなければならない(MUST)。

注意：説明に便利なのでステートマシンを使うが、実装では必ずしもステートマシンでを用いる必要はない。

##### 3.1.  Sending Stream States

```

          o
          | Create Stream (Sending)
          | Peer Creates Bidirectional Stream
          v
      +-------+
      | Ready | Send RESET_STREAM
      |       |-----------------------.
      +-------+                       |
          |                           |
          | Send STREAM /             |
          |      STREAM_DATA_BLOCKED  |
          |                           |
          | Peer Creates              |
          |      Bidirectional Stream |
          v                           |
      +-------+                       |
      | Send  | Send RESET_STREAM     |
      |       |---------------------->|
      +-------+                       |
          |                           |
          | Send STREAM + FIN         |
          v                           v
      +-------+                   +-------+
      | Data  | Send RESET_STREAM | Reset |
      | Sent  |------------------>| Sent  |
      +-------+                   +-------+
          |                           |
          | Recv All ACKs             | Recv ACK
          v                           v
      +-------+                   +-------+
      | Data  |                   | Reset |
      | Recvd |                   | Recvd |
      +-------+                   +-------+
```

Stream の送信部分については、エンドポイントのアプリケーションによって開かれる。
"Ready"は、Streamが新規で作られ、受信可能な状態になっていることを示している。
この状態では、送信に備えてデータはバッファされる。

STREAM か STREAM_DATA_BLOCKED フレームの送信で、送信側の状態は "Send" になる。
この状態になるまで stream ID の発行を遅延させてもよい。

相手側から開始された双方向 stream では、受信側(サーバーにとってはtype 0でクライアント駆動、クライアントにとってはtype 1でサーバー駆動)の
送信部分は "Ready となる。受信部分が "Recv" 状態に入った場合、ただちに "Send" 状態に移行する。

"Send" 状態では、エンドポイントは STREAM フレームでストリームデータを送信し、必要に応じて再送信を行う。
エンドポイントは相手側により与えられた流量制限に従い、MAX_STREAM_DATA を受け取り処理する。
エンドポイントで流量制限やデータ送信でブロックされた際には、STREAM_DATA_BLOCKEDを発行する。

アプリケーションがすべてのデータを送信して、STREAM フレームに FIN ビットをセットした後は、
送信部分は "Data Sent" 状態に移行する。この状態では、エンドポイントは必要に応じてデータを再送信するだけである。
エンドポイントは流量制御をチェックする必要ななく、MAX_STREAM_DATA フレームを送信する必要もない。
相手側が最後のストリームオフセットを受信するまでは、MAX_STREAM_DATA フレームが受信されるかもしれない(エンドポイントで)。
エンドポイントは、相手側から届いた MAX_STREAM_DATA フレームを安全に無視できる。

すべてのストリームデータが届いた際には、送信部分は "Data Recvd" 状態に移行する。この状態は終状態である。

"Ready", "Send", "Data Sent" のどの状態でも、アプリケーションはデータ送信の破棄を伝えることができる。
一方で、エンドポイントは STOP_SENDING フレームを相手側から受信するかもしれない。
どの場合でも、エンドポイントは RESET_STREAM フレームを送信し、stream を "Reset Sent" 状態に移行させる。

エンドポイントは最初のフレームで RESET_STREAM を送るかもしれない(MAY)。
これにより、送信部分は開かれ、直ちに "Reset Sent" 状態に移行する。


RESET_STREAM を含むパケットが一度でも通達されたなら、送信部分は
終状態である "Reset Recvd" 状態に移行する。



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
