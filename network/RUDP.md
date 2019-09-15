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

