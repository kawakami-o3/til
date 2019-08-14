# WebTransport

https://github.com/WICG/web-transport/blob/master/explainer.md

* UDP
  * UDP sockets lack encryption, congestion control, and a mechanism for consent to send (to prevent DDoS attacks).
* WebSockets
  * All messages must be sent and received in order even if they are independent and some of them are no longer needed.


## 一連のRFC

https://tools.ietf.org/html/draft-vvv-webtransport-overview-00


https://tools.ietf.org/html/draft-vvv-webtransport-http3-00


https://tools.ietf.org/html/draft-vvv-webtransport-quic-00


## 関連事項

* Head of Line Blocking
  * https://qiita.com/Jxck_/items/0dbdee585db3e21639a8
* 詳解 HTTP/3
  * https://http3-explained.haxx.se/ja/
