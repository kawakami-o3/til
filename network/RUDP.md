# RUDP


* https://tools.ietf.org/html/draft-ietf-sigtran-reliable-udp-00

## 1.3 Data Structure Format

### 1. Six octet minimum RUDP header for data transmissions

$B>/$J$/$H$b(B 6 $B$D$N%*%/%F%C%H!#(B

* $B%S%C%H%U%i%0(B
* $B%X%C%@!<D9(B
* $B%7!<%1%s%9%J%s%P!<(B
* Acknowledgment $B%J%s%P!<(B
* $B%A%'%C%/%5%`(B (2 $B%*%/%F%C%H(B)


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

