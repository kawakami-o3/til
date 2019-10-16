# RUDP


* https://tools.ietf.org/html/draft-ietf-sigtran-reliable-udp-00

## 1.3 Data Structure Format

### 1. Six octet minimum RUDP header for data transmissions

少なくとも 6 つのオクテット。

* ビットフラグ
* ヘッダー長
* シーケンスナンバー
* Acknowledgment ナンバー
* チェックサム (2 オクテット)


```
    0 1 2 3 4 5 6 7 8            15
   +-+-+-+-+-+-+-+-+---------------+
   |S|A|E|R|N|C|T| |    Header     |
   |Y|C|A|S|U|H|C|0|    Length     |
   |N|K|K|T|L|K|S| |               |
   +-+-+-+-+-+-+-+-+---------------+
   |  Sequence #   +   Ack Number  |
   +---------------+---------------+
   |            Checksum           |
   +---------------+---------------+

        Figure 1, RUDP Header
```

#### Control bits

* SYN : a syhchronization seggment がある
* ACK : the acknowledgment number が正しい
* EACK : an extended acknoledge segment がある
* RST : このパケットが a reset segment
* NUL : このパケットが a null segment
* CHK : チェックサムがヘッダーのみに対してか(0)、ヘッダーとボディーに対してか(1)
* TCS : このパケットが a transfer connection state segment

SYN, EACK, RST, TCS は同時にフラグが立つことはない。
ACK ビットは NUL ビットがセットされている時は必ずある。

#### Sequence number

接続時の初期値はランダムである。
送信者は sequence number をインクリメントする、
データを送信する時も、null や reset を送るときでも。

#### Acknowledgement number

受信者が最後に受け取ったパケット(in-sequcne)を送信者に知らせるもの。

#### Checksum

完全性を保証するために必ず計算される。
CHK ビットが 1 なら、ヘッダーとボディーに対してチェックサムが計算される。
アルゴリズムは、UDP, TCP と同じで、対象バイトの補数の合計の 16 ビットの補数。


### 2. SYN Segment

SYN は connection の確立と sequence number の同期に使われる。
SYN segment は connection の交渉可能な(negotiable)パラメータも含む。
相手側が知る必要がある、すべての設定可能なパラメータは、この segment に含まれている。
これは、local RUDP が受け入れ可能な segment の最大数を含み、
確立された connection の機能を示す option flags も含む。
SYN segment は user data と混合してはならない。
SYN segment は connection の auto reset を実行するのにも使われる。
Auto reset については後述する。

Figure 2 に SYN segment の構造を示す。

```
    0             7 8            15
   +-+-+-+-+-+-+-+-+---------------+
   | |A| | | | | | |               |
   |1|C|0|0|0|0|0|0|       28      |
   | |K| | | | | | |               |
   +-+-+-+-+-+-+-+-+---------------+
   +  Sequence #   +   Ack Number  |
   +---------------+---------------+
   | Vers  | Spare | Max # of Out  |
   |       |       | standing Segs |
   +---------------+---------------+
   | Option Flags  |     Spare     |
   +---------------+---------------+
   |      Maximum Segment Size     |
   +---------------+---------------+
   | Retransmission Timeout Value  |
   +---------------+---------------+
   | Cumulative Ack Timeout Value  |
   +---------------+---------------+
   |   Null Segment Timeout Value  |
   +---------------+---------------+
   | Transfer State Timeout Value  |
   +---------------+---------------+
   |  Max Retrans  | Max Cum Ack   |
   +---------------+---------------+
   | Max Out of Seq| Max Auto Reset|
   +---------------+---------------+
   |    Connection Identifier      |
   +                               +
   |      (32 bits in length)      |
   +---------------+---------------+
   |           Checksum            |
   +---------------+---------------+

        Figure 2, SYN segment
```

* Sequence Number
  * Sequence number フィールドは、この connection のために選ばれた、最初の sequence number を含む。
* Acknoledgment Number
  * このフィールドが正しいのは、ACK フラグが立っているときのみである。その場合、
		このフィールドは、他のRUDPから届いた SYN segment の sequence number を含んでいるだろう。
* Version
  * Version フィールドは RUDP のバージョンを含む。初期バージョンは 1 である。
* Maximum Number of Outstanding Segments
	* Acknowledgment を受け取らずに送れる segment の最大数。受信者はこれを流量制御に用いる。
    この数値は接続開始時に選ばれ、connection が生きている間は変わらない。
    これは交渉可能ではない。データを送る際は、お互いにお互いが提供した値を使用しなければならない。
* Options Flag Field
  * この 2 オクテットのフィールドは、options flag の集合を含み、options flag はこの connection に対して
    望まれる付加的な機能の集合を特定する。
    ```
    Bit #   Bit Name   Description
    0       not used   使われていない。常に 1 にでなければならない。
    1       CHK        Data Checksum 有効。もしこのビットが立っていたら、checksum フィールドは
                       RUDP パケット全体(header + body)の checksum を含んでいる。交渉可能。
    2       REUSE      このビットは an auto reset 中は立っていなければならず、前回の交渉可能
                       パラメータが使用されるべきであるということを示している。このビットが
                       立っているときは、SYN の後続するフィールドはゼロにされて送信されなけ
                       ればならず、受信者は無視しなければならない。Maximum Segment Size,
                       Retransmission Timeout Value, Cumulative Ack Timeout Value, Max
                       Retransmissions, Max Cumulative Ack, Max Out of Sequence, and Max
                       Auto Reset.
    3-7     Spare
    ```
* Maximum Segment Size
  * SYN を送ってきたピアが受信できるオクテットの最大数。ピアは互いに異なる値を指定する。
    コネクション交渉中は、互いの指定された値以上のパケットを送ってはならない。
    この数値はRUDPヘッダーのサイズも含む。これは交渉可能ではない。
* Retransmission Timeout Value
  * 伝達されていないパケットの再送に使われるタイムアウト値。この値はミリ秒で指定される。
    100 から 65536 の範囲でしていする。これは交渉可能で、両ピアが同じ値で合意しなければならない。
* Cumulative Ack Timeout Value
  * 他の segment が送られていない場合に、an acknowledgment segment を送るためのタイムアウト値。
    この値はミリ秒で、100 から 65536 の範囲で指定する。このパラメータは交渉可能であり、両方の
    ピアで同じ値で合意する必要がある。加えて、このパラメータは the Retransmission Timeout Value
    よりちいさくなければならない。
* Null Segment Timeout Value
  * A data segment が送られていないときに null segment を送るタイムアウト値。すなわち、the null
    segment は keep-alive 機構として働く。この値はミリ秒として指定される。
    値の範囲は 0 から 65536 である。0の値は null segments を無効化する。
    交渉可能で、ピア間で共有。
* Transfer State Timeout Value
  * An auto reset が発生する前に、状態を保存するためのタイムアウト値。
    ミリ秒、0 から 65536、交渉可能でピア間で共有。
* Max Retrans
  * Connection が切断されたと判断する前に、consectutive retransmission(s) を試みる時間の最大値。
    0 から 255 までの値を指定する。0 は永遠に再送することを示す。
    交渉可能で、ピア間で共有。
* Max Cum Ack
  * Acknowledgments を蓄積する最大数。0 から 255 まで。0 は、受け取ったデータが null や reset segment
    であっても acknowledgment を即座に送る。
    交渉可能で、ピア間で共有。
* Max Out of Seq
  * EACK segment が送られる前に蓄積される、順序外パケットの最大数。
    0 から 255。0は EACK が即座に送信されることを示す。
    交渉可能で、ピア間で共有。
* Max Auto Reset
  * Connection をリセットする前に行う consecutive auto resetの最大数。
    0 から 255。0 は auto reset を試みないことをしめし、connection は即座にリセットされる、
    auto reset 条件が発生していても。
    交渉可能で、ピア間で共有。
    Consecutive auto reset counter は connection が開かれた時にクリアされる。
* Connection Identifier
  * 新しい connection を開くとき、各ピアは a connection identifier を送信する。
    A connection identifier はすべての RUDP current connections でユニークである。
    互いに送られてきた the connection ID を保存する。An auto reset が実行された場合、
    ピアは保存された connection ID を送り、auto reset が実行されていることを伝える。

### 3. ACK Segment

The ACK segment は in-sequence segments を通知するために使われる。
The next sequence number と acknowledgment sequence numberがヘッダーに含まれている。
The ACK segment は a separate segment として送られるかもしれない。
ただし、可能であればデータと共に送られるべきである。
Data and Null segments はいつでも ACK ビットと Acknoledgement Number フィールドを含む。
単独の ACK segment のサイズは 6 オクテットである。

```
    0 1 2 3 4 5 6 7 8            15
   +-+-+-+-+-+-+-+-+---------------+
   |0|1|0|0|0|0|0|0|       6       |
   +-+-+-+-+-+-+-+-+---------------+
   | Sequence #    |   Ack Number  |
   +---------------+---------------+
   |           Checksum            |
   +---------------+---------------+

    Figure 3, Stand-alone ACK segment
```

### 4. EACK Segment

The EACK segment は、順序外に受信された segments を通達するために使われる。
The EACK は受信した segments の sequence nubmers を、一つまたは複数含んでいる。
The EACK は常に ACK と混合され、最後に受信された順通りの sequence number を与える。
ヘッダー長は可変で、最小で 7、最大で the maximum receive queue length となる。

```
    0 1 2 3 4 5 6 7 8            15
   +-+-+-+-+-+-+-+-+---------------+
   |0|1|1|0|0|0|0|0|     N + 6     |
   +-+-+-+-+-+-+-+-+---------------+
   | Sequence #    |   Ack Number  |
   +---------------+---------------+
   |1st out of seq |2nd out of seq |
   |  ack number   |   ack number  |
   +---------------+---------------+
   |  . . .        |Nth out of seq |
   |               |   ack number  |
   +---------------+---------------+
   |            Checksum           |
   +---------------+---------------+

       Figure 4, EACK segment
```

### 5. RST Segment

The RST segment は connection の切断やリセットを行うために使われる。
An RST segment の受信まで、送信者は新しいパケットの送信をやめなければならない。
また、the APIから既に受理されたパケットの転送を試み続けなければならない。
The RST は独立した segment として送られ、他のデータを含まない。


```
    0 1 2 3 4 5 6 7 8            15
   +-+-+-+-+-+-+-+-+---------------+
   | |A| | | | | | |               |
   |0|C|0|1|0|0|0|0|        6      |
   | |K| | | | | | |               |
   +-+-+-+-+-+-+-+-+---------------+
   | Sequence #    |   Ack Number  |
   +---------------+---------------+
   |         Header Checksum       |
   +---------------+---------------+

          Figure 5, RST segment
```

### 6. NUL Segment

The NUL segment は他方の connection がまだ生きているか判断するために使われる。
すなわち keep-alive として働く。
A NUL segment が受信されると、RUDP実装はただちに ACK を送らなければならない。
ただし、connectionが存在し、sequence number が順通り出会った場合に限る。


```
    0 1 2 3 4 5 6 7 8            15
   +-+-+-+-+-+-+-+-+---------------+
   |0|1|0|0|1|0|0|0|       6       |
   +-+-+-+-+-+-+-+-+---------------+
   | Sequence #    |  Ack Number   |
   +---------------+---------------+
   |            Checksum           |
   +---------------+---------------+

        Figure 6, NUL segment
```


### 7. TCS Segment

The TSC は connection の状態を転送するために使われる。

```
    0 1 2 3 4 5 6 7 8            15
   +-+-+-+-+-+-+-+-+---------------+
   | |A| | | | | | |               |
   |0|C|0|0|0|0|1|0|       12      |
   | |K| | | | | | |               |
   +-+-+-+-+-+-+-+-+---------------+
   | Sequence #    |   Ack Number  |
   +---------------+---------------+
   | Seq Adj Factor|      Spare    |
   +---------------+---------------+
   |      Connection Identifier    |
   +                               +                                                                                                                     +
   |       (32 bits in length)     |
   +---------------+---------------+
   |            Checksum           |
   +---------------+---------------+

          Figure 7, TCS segment
```

* Sequence Number
  * The sequence number は初期値を含む。
* Acknoledgment Number
  * The acknoledgment number は受信者が受け取ったパケットのうち、順通りの最後のパケットを示している。
* Seq Adj Factor
  * この値は、新旧の connection で sequence number を調整するために使われる。
* Connection Identifier
  * 新しい connection を開くとき、各ピアは a connection identifier を転送する。
    これはすべての確立中 RUDP connection 中で一意である。どちらの側も受け取った the connection ID を保存する。
    この値は、この connection に転送されている相手の connection を通知するために使われる。



## 1.3.1 Detaild Design

別ドラフトで詳細を検討中。

## 1.3.2 Feature Description

RUDP では以下の機能をサポートしている。
以下では、送信者と受信者はクライアントとサーバーとされ、a connection にデータセグメントを送信するか、
受信するかに対応している。
クライアントは the connection を初期化する側のピアであり、サーバーは a connection に対して待機している側のピアを指す。
A connection は、一意なIP address/UDP port のペアを提供するインターフェースとして定義される。
サーバーとクライアントは特定のIP address/UDP portに対して多重に connections を持つことができる。
それぞれの connection は一意な IP address/UDP port のペアを持つ。

### 1. Retransmission Timer

送信者は再送タイマーを持ち、これは調整可能なタイムアウト値である。
このタイマーは、データや null や reset segment が送られるたびに初期化され、
確認待ちの segment がなくなったときにも初期化される。
このデータsegmentに対しての受信確認を時間内に受け取れなかった場合、
すべての確認待ちsegmentを再送する。
確認待ちのsegmentを受信した時に再送タイマーはリセットされる。
たとえ、確認待ちのsegmentが他にあったとしても。
再送タイマーの推奨値は 600 ms である。

### 2. Retransmission Counter

送信者は a segment を再送した回数のカウンターを管理する。
このカウンターの最大値は調整可能で、推奨値は 2 である。
このカウンターが最大値を超えた場合、
connection が切断されているとみなされる。
切断された connection の取り扱いについては No. 14 を参照。

### 3. Stand-alone Acknowledgments

A stand-alone acknoledgment segment とは、受信確認情報のみを含む segment である。
その sequence number は次に送られる segment (nullやreset含む) の sequence number を含む。

### 4. Piggyback Acknowledgments

受信者が送信者に segment を送るときはいつでも、受信者は最後に受信した順通りの sequence number を
the acknowledgment number field に含める。

### 5. Cumulative Acknowledge Counter

受信者は、受信確認できていない segments のカウンターを管理する。
このカウンターの最大値は調整可能である。このカウンターの最大値を超えた場合、
受信者は a stand-alone scknowledgment か an extended acknowledgment 送り、
順除外の segments があることを知らせる。
推奨値は 3 である。

### 6. Out-of-sequence Acknowledgments Counter

順序外に届いた segment についてもカウンターを管理する。
最大値は調整可能。
最大値を超えた場合は、an extended acknoledgment segment を送信する。
その中には順序外に届いたすべての segments の sequence number が含まれている。
推奨値は 3 である。

An etended acknoledgments を受け取った送信者は、ロストしたと思われる segments を送信する。

### 7. Cumulative Acknowledge Timer

Ack が送れていない segment、もじくは順序から外れた segment がある場合、
受信者は the cumulative acknowledge timer のタイムアウトを待った上で
a stand-alone acknowledgment か an extended acknowledgment を送る。
順序から外れた segment があるなら an extended acknowledgment、
Ack を送っていない segment なら a stand-alone acknowledgment。
推奨値は 300 ms。

The cumulative acknowledge timer は、順序から外れた segment がない場合、
ack を送る時に再起動される(再び ack を送るべき segment がたまるまでは待機)。
順序から外れた segment がある場合は、再起動されず、タイムアウトのたびに
an extended acknowledgment が送られる。

### 8. Null Segment Timer

クライアントは、a null segment timer を接続した時にスタートし、
データを送信するたびにリセットする。
タイムアウトした場合、クライアントは a null segment をサーバーに送信する。
The null segment は、its sequence number が正しければ、サーバーで受理される。
サーバーは a null segment timer をクライアントの倍のタイムアウト値で管理する。
サーバーのタイマーはデータを受信するたびにリセットされる。
タイムアウトした場合は、接続が切れたものとして扱う。
切れた接続の扱いについては No. 14 を参照。
推奨値は 2 秒。

### 9. Auto Reset

クライアントとサーバーどちらも an auto reset を開始できる。
An auto reset が起こるのは、
the retransmission count が最大値を超えた時、
サーバーの the null segment timer がタイムアウトした時、
the transfer state timer がタイムアウトした時である。
An auto reset によって両ピアは現在の状態をリセットし、
再送と順序外のキューを開放し、sequence number を初期化し、
接続を再交渉する。
それぞれのピアが Upper Layer Protocol (ULP) を通知する。
A consecutive reset counter で auto-reset の最大数を管理する。
この最大値を超えたときに接続をリセットする。
推奨値は 3。

### 10. Receiver Input Queue Size

受信者の受信キューのサイズは調整可能なパラメータである。
推奨値は 32 パケットである。
このパラメータは流量コントロール機構として働く。

### 11. Congestion Control And Slow Start

RUDP ではサポートしていない。

### 12. UDP Port Numbers

使用するポートに制限はなく、RFC 1700 で定義されていないポートなら利用可能である。

### 13. Support For Redundant Connections

RUDP 接続に失敗した場合、the Upper Layer Protocol は通知を受け、
the transfer state timer が起動するだろう。
The ULP は API コールを通してもう一方の RUDP 接続への転送を開始でき、
RUDP は新しいコネクションに対してパケットの重複やロストを確認しながら状態を転送する。
The Transfer State Timer がタイムアウトする前に転送を開始しなかった場合、
接続情報は失われ、バッファは開放される。
タイムアウト値は調整可能である。
推奨値は 1 秒。

### 14. Broken Connection Handling

RUDP 接続は以下の条件で切断されたと判断される。

* The Retransmission Timer がタイムアウトし、the Retransmission Count が最大値を超えた
* サーバーの Null Segment Timer がタイム・アウトした

上記のどれかを満たし、the Transfer State timeout value がゼロでない場合、
the ULP は接続失敗シグナルを受け取り、the Transfer State Timer が起動する。
The Transfer State Timer がタイムアウトした場合、
Auto Reset が行われ、the ULP は auto reset シグナルを受け取る。

The transfer state timeout value がゼロなら、直ちに an auto reset が行われる。
The ULP は auto reset シグナルを通じて接続失敗を知らされる。

### 15. Retransmission Algorithm

EACKを受信したり、the Retransmission timer がタイムアウトすると再送が発生する。

EACK を受信した場合、メッセージで指定された segments は未 ACK のキューから削除される。
再送するsegmentsは、the Ack Number と最後の seq ack number を解析して決まる。
この2つの間にある segments (2つは含まない) で、未 ACK キューにあるものが再送される。

The Retransmission timer がタイムアウトした場合、すべての未 ACK キューにある
メッセージが再送される。

### 16. Single To Upper Layer Protocol (ULP)

以下に ULP に API を通じて送られるシグナルを挙げる。
これらは非同期に ULP に伝えられる。

* Connection open
  * 接続状態が Open に移行した時に発生する
* Connection refused
  * Close Wait 状態以外の状態から Close に移行した時に発生する
* Connection closed
  * Close Wait から Close に移行した時に発生する
* Connection failure
  * section 1.3.2 や No. 15 で述べたように、接続が壊れた時に発生する。
* Connection auto reset
  * auto reset が起きた時に発生する。データロストが発生し RUDP が接続状態を Open に
    戻そうとしていることを示している。

### 17. Checksum Algorithm

RUDP で用いる checksum アルゴリズムは UDP, TCP ヘッダーで使されているものと同じ。



### 18. FEC

### 19. Security

## 1.4 Feature Negotiation

## 2.0 Future Potential Enchancements

