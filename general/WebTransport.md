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

https://tools.ietf.org/html/draft-ietf-quic-transport-16

## 関連事項

* Head of Line Blocking
  * https://qiita.com/Jxck_/items/0dbdee585db3e21639a8
* 詳解 HTTP/3
  * https://http3-explained.haxx.se/ja/

* QUIC はじめました by V
  * https://medium.com/@voluntas/quic-%E3%81%AF%E3%81%98%E3%82%81%E3%81%BE%E3%81%97%E3%81%9F-fdf0c5654df7
