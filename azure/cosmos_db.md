# Azure Cosmos DB

## エミュレーター

https://learn.microsoft.com/ja-jp/azure/cosmos-db/docker-emulator-linux?tabs=sql-api%2Cssl-netstd21

* linux, macOS では docker で立ち上げられる
  * docker pull mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator
* その場合の制限として、NoSQL, MongoDB API のみとなる

NoSQL 用API を立ち上げるなら、以下のようなスクリプトになる

```bash
#!/bin/sh
ipaddr="`ifconfig | grep "inet " | grep -Fv 127.0.0.1 | awk '{print $2}' | head -n 1`"
docker run \
    --publish 8081:8081 \
    --publish 10250-10255:10250-10255 \
    --memory 3g --cpus=2.0 \
    --name=test-linux-emulator \
    --env AZURE_COSMOS_EMULATOR_PARTITION_COUNT=10 \
    --env AZURE_COSMOS_EMULATOR_ENABLE_DATA_PERSISTENCE=true \
    --env AZURE_COSMOS_EMULATOR_IP_ADDRESS_OVERRIDE=$ipaddr \
    --interactive \
    --tty \
    mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator
```

