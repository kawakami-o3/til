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
* Transfer State Timeout Value
* Max Retrans
* Max Cum Ack
* Max Out of Seq
* Max Auto Reset
* Connection Identifier
		

### 3. ACK Segment

### 4. EACK Segment

### 5. RST Segment

### 6. NUL Segment

### 7. TCS Segment

## 1.3.1 Detaild Design

## 1.3.2 Feature Description

### 1. Retransmission Timer

### 2. Retransmission Counter

### 3. Stand-alone Acknoledgments

### 4. Piggyback Acknoledgments

### 5. Cumulative Acknoledge Counter

### 6. Out-of-sequence Acknoledgments Counter

### 7. Cumulative Acknoledge Timer

### 8. Null Segment Timer

### 9. Auto Reset

### 10. Receiver Input Queue Size

### 11. Congestion Control And Slow Start

### 12. UDP Port Numbers

### 13. Support For Redundant Connections

### 14. Broken Connection Handling

### 15. Retransmission Algorithm

### 16. Single To Upper Layer Protocol (ULP)

### 17. Checksum Algorithm

### 18. FEC

### 19. Security

## 1.4 Feature Negotiation

## 2.0 Future Potential Enchancements

