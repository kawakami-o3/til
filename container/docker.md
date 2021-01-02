# docker

## docker run が失敗するケース1

```
docker: Error response from daemon: failed to create endpoint pedantic_margulis on network bridge: failed to add the host (...) <=> sandbox (...) pair interfaces: operation not supported.
```

というエラーが出る場合は、カーネル更新が行われた可能性がある。再起動後に再度 `docker run` を試してみると良い。

* https://qastack.jp/server/738773/docker-failed-to-add-the-pair-interfaces-operation-not-supported

