
* https://tools.ietf.org/html/draft-ietf-quic-transport

# イントロ

* stream の多重化
* stream、connection単位での流量制御
* 低遅延のconnection確立
* NAT切り替わり時のconnection復帰
* 暗号化通信

# Stream

軽量、順序保証のバイトストリーム抽象。
単方向、双方向。単方向は無限 "message" の抽象化。

Stream の生成はデータ送信で行われ、全ての操作が最小限のオーバーヘッドになるように設計されている。
たとえば、1 フレームでオープン、データ送信、クローズの操作をおこなえる。
Stream は長期間、connection が維持されている間、維持される。

Steam はエンドポイントのどちらからでも生成できて、並行にデータ送信され、キャンセルできる。
異なる stream 間では順序を保証しない。

流量制御や stream の制限に従って、いくつでも stream を並行に操作でき、いくつでもデータを stream で送信できます。

## 2.1.  Stream Types and Identifiers

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

## 2.2.  Sending and Receiving Data

エンドポイントは順序を保証しつつストリームデータを配送しなければならない(MUST)。
順不同で受信したデータは、流量制限までは溜め込む必要がある。

順不同のストリームデータを許容しないものの、実実装では採用されるかもしれない(MAY)。

同じ stream offset で何度もデータを受信することがおこりえる。
受信済みだった場合は破棄できる。指定されたオフセットのデータは、何度送られたとしても、変わってはならない(MUST NOT)。
同じ stream offset で異なるデータを取得した場合は、PROTOCOL_VIOLATION としてみなすかもしれない(MAY)。

Stream は順序付きバイトストリーム抽象である他は、データ構造が露呈しない。
このため、転送やパケロス後の再送、受信者への配送などで、フレーム境界が保持されるとは期待されない。

エンドポイントは流量制御に従わずにデータ送信してはならない(MUST NOT)。

## 2.3.  Stream Prioritization

Steam の多重化はアプリケーションのパフォーマンスに大きな影響を与えるので、
ただしい優先順位でリソース管理に注意する必要がある。

QUICには、優先順位の管理機構は規定されていない。
その代わり、アプリケーションから提示される優先順位情報を活用できる。

QUIC実装では、アプリケーションがstreamの相対優先度を提示できるようにすべきである(SHOULD)。
また、その情報を活用するべきである(SHOULD)。

# 3. Stream States

ここでは、データの送受信について 2 つのステートマシンを例にだして解説する。
一つはエンドポイントでのデータ送信、もうひとつはデータ受信について解説する。

単方向通信では 1 つのステートマシンを、双方向通信では 2 つのステートマシンを用いる。
多くの部分について、ステートマシンの使い方は単方向・双方向通信によらず同じである。
双方向通信でのstreamを確立するのは若干複雑である。


Stream IDは単調増加しなければならない(MUST)。

注意：説明に便利なのでステートマシンを使うが、実装では必ずしもステートマシンでを用いる必要はない。

## 3.1.  Sending Stream States

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


## 3.2.  Receiving Stream States

図2はデータ受信の状態遷移図である。
受信部分の状態は、相手側の送信部分の状態を反映しただけのものである。
受信部分は観測できない送信側の状態、"Ready" 状態を捕捉しない。
その代わり、受信部分はアプリケーションへのデータ配送を補足し、こちらは送信者には観測できない。

```
          o
          | Recv STREAM / STREAM_DATA_BLOCKED / RESET_STREAM
          | Create Bidirectional Stream (Sending)
          | Recv MAX_STREAM_DATA / STOP_SENDING (Bidirectional)
          | Create Higher-Numbered Stream
          v
      +-------+
      | Recv  | Recv RESET_STREAM
      |       |-----------------------.
      +-------+                       |
          |                           |
          | Recv STREAM + FIN         |
          v                           |
      +-------+                       |
      | Size  | Recv RESET_STREAM     |
      | Known |---------------------->|
      +-------+                       |
          |                           |
          | Recv All Data             |
          v                           v
      +-------+ Recv RESET_STREAM +-------+
      | Data  |--- (optional) --->| Reset |
      | Recvd |  Recv All Data    | Recvd |
      +-------+<-- (optional) ----+-------+
          |                           |
          | App Read All Data         | App Read RST
          v                           v
      +-------+                   +-------+
      | Data  |                   | Reset |
      | Read  |                   | Read  |
      +-------+                   +-------+
```

相手起因の送信部分 ( クライアントにとっての type 1, 3、サーバーにとっての type 0, 2 ) は、
最初に STREAM, STREAM_DATA_BLOCKED, RESET_STREAM のいずれかを受信したときに作られる。
双方向ストリームでは、MAX_STREAM_DATA か STOP_SENDING フレームが発行された場合でも受信部分が作られる。
受信部分の初期状態は "Recv" である。

また、エンドポイント起因 ( クライアントにとっての type 0、サーバーにとっての type 1 ) の双方向ストリームでは、
送信部分が "Ready" 状態に移行したときに受信部分は "Recv" 状態に移行する。

エンドポイントが双方向ストリームを開くのは、MAX_STREAM_DATA や STOP_SPENDING フレームを受信したときである。
MAX_STREAM_DATA を最初に受信するケースは、相手側はストリームをすでに開いていて、輻輳制御クレジット(flow control credit)を
提供していることを示す。
STOP_SENDING を最初に受信するケースは、相手側はデータを受信するつもりがもうないということを示している。
パケットロスやリオーダーが発生した場合は、STREAM や STREAM_DATA_BLOCKED フレームを受信する前にこれらのフレームを
受信する可能性はある。

Stream が作られる前に、同じタイプで低いIDの stream はすべて生成されていなければならない。
これにより双方のエンドポイントで正しい順序でストリームが生成されていることを保証する。

"Recv"状態では、エンドポイントは STREAM と STREAM_DATA_BLOCKED フレームを受信する。
受信したデータはバッファリングされ、アプリケーションに届く前に正しい順序に再構成され得る。
データがアプリケーションによって消費され、バッファ空間が利用可能になるにつれて、
エンドポイントは MAX_STREAM_DATA フレームを送り、相手にさらなるデータ送信を許可できるようになる。

FIN ビットを伴う STREAM フレームを受信した場合は、stream の最終サイズは判明している。
その後、受信部分は "Size Known" 状態に移行する。この状態では、エンドポイントは
もはや MAX_STREAM_DATA フレームを送信する必要はなく、再送データのみを受け取る。

一度すべてのデータを受信した場合は、受信部分は "Data Recvd" 状態に移行する。
これは、"Size Known" 状態へ遷移する、同じ STREAM フレームを受信した結果として発生する。
すべてのデータが受信された後は、STREAM や STREAM_DATA_BLOCKED フレームは破棄されうる。

"Data Recvd"状態は、ストリームデータがアプリケーションに届くまで継続する。
ストリームデータが届いたなら、stream は "Data Read" 状態に移行する。これが終状態である。

"Recv" や "Size Known" 状態で RESET_STREAM フレームを受信した場合は、
stream は "Reset Recvd" 状態に移行する。
これは、ストリームデータのアプリケーションへの配送が邪魔された場合に起こる。

RESET_STREAM を受信したときにすべてのストリームデータが受信されることもありえる ( "Data Recvd" 状態でおこりうる )。
同様に、RESET_STREAM を受信したときにストリームデータが届かずにのこっていることもありえる
( "Reset Recvd" 状態のとき )。実装ではこれらの状況を自由に管理してよい。

RESET_STREAM が送信されるということは、エンドポイントがストリームデータの配送を保証できないことを意味する。
ただし、RESET_STREAM を受信した場合にストリームデータを配送しないという要件はない。
実装ではデータ配送を邪魔したり、消費されていないデータを破棄したり、RESET_STREAMの受領を発行するかもしれない(MAY)。
ストリームデータが完全に受信され、アプリケーションに読まれるためにバッファリングされている場合に、
RESET_STREAM の発行は抑制されるかもしれない。REST_STREAMの発行が抑制された場合、
受信部分は "Data Recvd" 状態のままである。

Stream がリセットされたことを示すシグナルをアプリケーションが受信した場合、
受信部分は "Reset Read" 状態に移行する。これが終状態である。

## 3.3.  Permitted Frame Types

送信者が送るフレームは 3 種類あり、これらが送受信者の状態に影響する。
3 種類とは、STREAM、STREAM_DATA_BLOCKED、RESET_STREAM のことである。

送信者が終状態 ("Data Recvd" か "Reset Recvd") のときは、これらのフレームを送ってはならない (MUST NOT)。
送信者は、RESET_STREAM を送った後は STREAM や STREAM_DATA_BLOCKED フレームを送ってはならない (MUST NOT)。
これは、終状態の "Reset Sent" 状態に入っているためである。
受信者はどのような状態にあってもこれら 3 種類のフレームを受け取る可能性がある。
なぜなら、パケットの配送が遅延している可能性があるためだ。

受信者が送るのは、MAX_STREAM_DATA と STOP_SENDING である。

受信者が MAX_STREAM_DATA を送信するのは "Recv" 状態のときだけである。
受信者が STOP_SENDING を送信するのは、RESET_STREAM を受信していないときだけである。
これは、"Reset Recvd" や "Reset Read" 状態ではないときである。
ただし、すべてのデータを受信してから"Data Recvd" 状態で STOP_SENDING フレームを送るまでに若干の遅れがある。
この遅延のため、送信者はこれらの 2 種類のフレームを受信する可能性がある。

## 3.4.  Bidirectional Stream States

双方向 stream は送信部分と受信部分からなる。
実装では、双方向 stream の状態を送信と受信のストリーム状態として表現するかもしれない。
もっともシンプルなモデルとしては、"open"状態として送信部分か受信部分のどちらかが終状態でないことを表現し、
"closed" 状態として送信部分も受信部分もどちらも終状態であることを表現できる。

Table 2 はより複雑な双方向ストリームの対応表であり、HTTP/2 の劣化版である。
これは、送信部分と受信部分の各々の状態を複合状態として示したものである。
注意点としては、これは対応関係の一例であって、この対応関係では "closed" や "half-closed" 状態に遷移する前に、
データ受信が確認される必要がある。


```
   +-----------------------+---------------------+---------------------+
   | Sending Part          | Receiving Part      | Composite State     |
   +-----------------------+---------------------+---------------------+
   | No Stream/Ready       | No Stream/Recv *1   | idle                |
   |                       |                     |                     |
   | Ready/Send/Data Sent  | Recv/Size Known     | open                |
   |                       |                     |                     |
   | Ready/Send/Data Sent  | Data Recvd/Data     | half-closed         |
   |                       | Read                | (remote)            |
   |                       |                     |                     |
   | Ready/Send/Data Sent  | Reset Recvd/Reset   | half-closed         |
   |                       | Read                | (remote)            |
   |                       |                     |                     |
   | Data Recvd            | Recv/Size Known     | half-closed (local) |
   |                       |                     |                     |
   | Reset Sent/Reset      | Recv/Size Known     | half-closed (local) |
   | Recvd                 |                     |                     |
   |                       |                     |                     |
   | Reset Sent/Reset      | Data Recvd/Data     | closed              |
   | Recvd                 | Read                |                     |
   |                       |                     |                     |
   | Reset Sent/Reset      | Reset Recvd/Reset   | closed              |
   | Recvd                 | Read                |                     |
   |                       |                     |                     |
   | Data Recvd            | Data Recvd/Data     | closed              |
   |                       | Read                |                     |
   |                       |                     |                     |
   | Data Recvd            | Reset Recvd/Reset   | closed              |
   |                       | Read                |                     |
   +-----------------------+---------------------+---------------------+

           Table 2: Possible Mapping of Stream States to HTTP/2

   Note (*1):  A stream is considered "idle" if it has not yet been
      created, or if the receiving part of the stream is in the "Recv"
      state without yet having received any frames.
```

## 3.5.  Solicited State Transitions

エンドポイントが受信中のデータに興味がないなら、STOP_SENDING フレームを送って相手側が stream を閉じれるようにしてもよい(MAY)。
これが起こるのは通常は、受信しているアプリケーションがもうデータを読んでいないが、受信中のデータが無視されるとは保証されない場合である。

STREAM フレームは、STOP_SENDING の後に受信されたとしても、輻輳制御のためにカウントされる。
たとえ受領後に捨てられるとしてもカウントされる。

STOP_SENDING フレームは、受信しているエンドポイントが RESET_STREAM フレームを送信することを要求する。
STOP_SENDING フレームを受け取ったエンドポイントは、Ready, Send状態であれば再送する代わりに
RESET_STREAM を送信しなければならない(MUST)。

エンドポイントは STOP_SENDING フレームから RESET_STREAM へとエラーコードをコピーすべきである(SHOULD)。
ただし、エンドポイントはアプリケーションエラーを使用するかもしれない(MAY)。
STOP_SENDING フレームを送信するエンドポイントは、RESET_STREAM のエラーコードを無視するかもしれない(MAY)。

STOP_SENDING フレームを "Data Sent" 状態で受け取った場合は、エンドポイントは前回の STREAM フレームの再送を中止し、
まず RESET_STREAM フレームを送信しなければならない(MUST)。

STOP_SENDING が送られるのは、相手側によってリセットされていない stream に対してのみであるべきである(SHOULD)。
STOP_SENDING は、"Recv" や "Size Known" 状態のストリームに対してもっとも役に立つ。

エンドポイントは、STOP_SENDING のパケットロスが起きた場合はもう一度 STOP_SENDING を送ることを期待されている。
しかしながら、全ストリームデータが RESET_STREAM フレームが受信されたなら、この場合 stream は
"Recv" や "Size Known" 以外の状態になっていて、STOP_SENDING フレームを送る必要はない。

エンドポイントは、双方向 stream の送受信を停止したい場合、RESET_STREAM フレームを送信して一方を停止できる。
また、前もって STOP_SENDING フレームを送信して反対方向の停止を促すことが出来る。


# 4. Flow Control

TODO

# 5. Connections


QUICのコネクション確立では、バージョンネゴシエーションに
the cryptographic and transport handshakes を用いて、
コネクション確立のレイテンシーを低減している。Section 7を参照。
一度確立されると、コネクションは異なるIPやポートに引き継がれるかもしれない。Section 9参照。
最後に、コネクションはどちらか一方から閉じられるかもしれない。Section 10参照。


## 5.1. Connection ID

各コネクションは、それぞれを識別するために connection ID を保持している。
Connection ID はエンドポイントによって独立的に選ばれる。
すなわちエンドポイントは相手側が使っている connection ID を選択する。

Connection ID の最重要な機能は、低レイヤー(UDP, IP)でのアドレス変化が起きたとしても
エンドポイントにパケットが届くことを保証することである。
エンドポイントの connection ID 選択は、実装やデプロイの詳細に依存しており、
その connection ID に紐づくパケットがエンドポイントに配送され、受信側に特定されることを許可する。

Connection ID は、同じコネクションに対して使われている connection ID と相関を取れるような
情報を含んではならない(MUST NOT)。
自明な例としては、これが意味するのは同じコネクション中で同じ connection ID を
使いまわしてはならないということである。

長いヘッダーを持つパケットは、Source Connection ID と Destination Connection ID を持つ。
これらは新しいコネクションに使用される。Section 7.2 参照。

短いヘッダーを持つパケット (Section 17.3 参照) は Destination Connection ID のみを持ち、
陽に長さを含まない。Destination Connection ID フィールドの長さはエンドポイントに
知らされていると期待される。Connection ID によってルーティングするロードバランサを
使用している場合、エンドポイントは connection ID に対して固定長としてロードバランサと
合意するか、エンコード方式を合意してよい。固定部分は陽に表された長さをエンコードでき、
connection ID の長さを変更しつつ、ロードバランサが使用し続けることができる。

Version Negotiation (Section 17.2.1) パケットはクライアントによって指定された
connection ID を通知し、クライアントへの正しいルーティングを保証しつつ、
最初のパケットに対するレスポンスパケットを検証できる。

ゼロ長の connection ID が使用される事があるのは、connection ID がルーティングに
必要とされず、アドレスとポート部分でコネクションの特定に十分である場合である。
相手側がゼロ長の connection ID を選んだ場合、エンドポイントはそのコネクションが
生きている間はゼロ長 connection ID を使い続けなければならない(MUST)。
また、よかのローカルアドレスからパケットを送ってはならない(MUST NOT)。

エンドポイントが非ゼロ長の connection ID を要求した場合、相手側がエンドポイントに
送信するパケットのために選べる connection ID を供給できるか保証される必要がある。
これらの connection ID は NEW_CONNECTION_ID フレームを使ってエンドポイントから
供給される。Section 19.15 参照。


# 16. Variable-Length Integer Encoding

QUIC のパケットとフレームはともに variable-length エンコーディングを使って正数を表現している。
このエンコーディングは小さい正数に対して少ないバイト数にエンコードされることを保証する。

QUIC の variable-length エンコーディングは最上位の 2 ビットを反転させて、
2進数としてバイト長を表現している。
正数は残りのビットに、ネットワークバイトオーダーに従ってエンコードされる。

つまり、正数は 1, 2, 4, 8 バイトにエンコードされることを意味し、
それぞれ 6, 14, 30, 62 ビットの値となる。


```
          +------+--------+-------------+-----------------------+
          | 2Bit | Length | Usable Bits | Range                 |
          +------+--------+-------------+-----------------------+
          | 00   | 1      | 6           | 0-63                  |
          |      |        |             |                       |
          | 01   | 2      | 14          | 0-16383               |
          |      |        |             |                       |
          | 10   | 4      | 30          | 0-1073741823          |
          |      |        |             |                       |
          | 11   | 8      | 62          | 0-4611686018427387903 |
          +------+--------+-------------+-----------------------+

                   Table 4: Summary of Integer Encodings
```

例として、8 バイトのバイト列 c2 19 7c 5e ff 14 e8 8c (16進) は、
151288809941952652 にデコードされる。また、9d 7f 3e 7d は 494878333 へ、
7b bd は 15293、25 は 37 にデコードされる
(40 25 の 2 バイトのバイト列にエンコードされることもある)。

エラーコード(Section 20)とバージョン(Section 15)は整数であるが、このエンコーディングを使わない。



# 17. Packet Formats




# 19. Frame Types and Formats

## 19.1. PADDING Frame

PADDING フレーム (type=0x00) は意味論的な値を持たない。
PADDING フレームはパケットサイズを増やすために使える。
パディング (Padding) は、クライアントの初期パケットを必要最小サイズまで増やすために使える。
または、これによって保護パケットに対してトラフィック解析に対する保護を提供できる。

PADDING フレームはコンテントを持たない。
つまり、PADDING フレームはPADDING フレームであることを示す 1 バイトの識別子からなる。

## 19.3. ACK Frames

エンドポイントは PING フレーム (type=0x01) を使って相手側がまだ生きているか、
もしくは到達可能かを検証できる。
PING フレームは他のフィールドを持たない。

PING フレームを受信したら、単にこのフレームを含むパケットを通知しなければならない。

PING フレームを使って、アプリケーションやアプリケーションプロトコルが
接続がタイムアウトするのを防ぎたい場合に、接続を維持するために使用できる。
アプリケーションプロトコルは、PING フレームを生成するのが推奨される状況について、
アドバイスを提供するべきである(SHOULD)。
調整無しで PING フレームを送りあった場合は、パケット数が過剰になり、
パフォーマンス低下を引き起こす。

コネクションがタイム・アウトするのは、パケットが送受信されない時間が
idle_timeout transport parameter でしてされた時間を超えたときである。
ただし、middlebox にある状態はより早くタイムアウトするかもしれない。
REQ-5 (RFC4787) が 2 分のタイムアウト感覚を推奨しているけれども、
経験的に 15 から 30 秒毎にパケットを送らなければ、
middlebox の大部分が UDP 上から失われてしまう。

## 19.4. RESET_STREAM Frame

## 19.8. STREAM Frame

## 19.13. STREAM_DATA_BLOCKED

# メモ

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




# 関連事項

* Head of Line Blocking
  * https://qiita.com/Jxck_/items/0dbdee585db3e21639a8
* 詳解 HTTP/3
  * https://http3-explained.haxx.se/ja/

* QUIC はじめました by V
  * https://medium.com/@voluntas/quic-%E3%81%AF%E3%81%98%E3%82%81%E3%81%BE%E3%81%97%E3%81%9F-fdf0c5654df7

* QUICの話 (QUICプロトコルの簡単なまとめ)
  * https://asnokaze.hatenablog.com/entry/2018/10/31/020215
