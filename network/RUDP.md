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




