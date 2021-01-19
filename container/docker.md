# docker

https://docs.docker.com/get-started/

https://jawsdays2019.jaws-ug.jp/session/1527/


## 逆引きtips

### イメージビルド

```
cd dockerfile-dir
docker build -t image-name:image-tag .
```

### コンテナ起動

```
docker run --rm -it --init -p 3000:3000 -v from-dir:to-dir -u `id -u`:`id -g` image-name:image-tag
```

* `--rm` : 終了時にコンテナ削除
* `--it` : `-i` と `-t`. 入手力を保持. 逆は `-d`.
* `-p` : ポート指定
* `-v` : ディレクトリ指定
* `-u` : UID, GID 指定


### イメージ削除

```
docker image rm image-id
docker image prune
```

### コンテナ削除

```
docker container rm container-id
docker container prune
```

## docker run が失敗するケース1

```
docker: Error response from daemon: failed to create endpoint pedantic_margulis on network bridge: failed to add the host (...) <=> sandbox (...) pair interfaces: operation not supported.
```

というエラーが出る場合は、カーネル更新が行われた可能性がある。再起動後に再度 `docker run` を試してみると良い。

* https://qastack.jp/server/738773/docker-failed-to-add-the-pair-interfaces-operation-not-supported

