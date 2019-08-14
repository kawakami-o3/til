# WebTransport

https://github.com/WICG/web-transport/blob/master/explainer.md

* UDP
  * UDP sockets lack encryption, congestion control, and a mechanism for consent to send (to prevent DDoS attacks).
* WebSockets
  * All messages must be sent and received in order even if they are independent and some of them are no longer needed.
