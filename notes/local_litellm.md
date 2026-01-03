# ローカルAIエージェント開発環境 (LiteLLM + Ollama) セットアップ手順

Docker Desktopを使用して、ローカル環境にLLMバックエンドを構築します。
仮想キー（認証）は使用せず、シンプルなプロキシ構成とします。
コンテナ起動時にOllamaサーバーが立ち上がり、指定したモデルを自動でダウンロード・ロードします。

## 1. ディレクトリ構成

プロジェクトルートに以下のファイルを配置します。

```text
my-agent-env/
├── docker-compose.yml     # 構成定義
├── litellm_config.yaml    # モデルルーティング設定
└── entrypoint.sh          # Ollama起動・自動ダウンロードスクリプト
```

---

## 2. ファイルの作成

### entrypoint.sh
Ollamaの起動を待ち、指定されたモデルがない場合は自動でPullするスクリプトです。
ポーリング処理を入れているため、起動タイミングによる接続エラーを防ぎます。

```bash
#!/bin/bash

# 1. Ollamaサーバーをバックグラウンドで起動
/bin/ollama serve &

# プロセスIDを取得
pid=$!

echo "⏳ Waiting for Ollama server to start..."

# 2. ポーリング処理
# localhost:11434 に接続できるまで待機（タイムアウトなし）
while ! (echo > /dev/tcp/localhost/11434) >/dev/null 2>&1; do
    sleep 1
done

echo "✅ Ollama server is active!"

# 3. モデルの取得処理
echo "🔴 Checking model: ${OLLAMA_MODEL}..."
ollama pull ${OLLAMA_MODEL}
echo "🟢 Model ${OLLAMA_MODEL} is ready!"

# 4. サーバープロセスが終了しないように待機し続ける
wait $pid
```

### litellm_config.yaml
エージェントからのリクエストをOllamaコンテナへ転送する設定です。
`api_base` にはDockerコンテナ名（`ollama-container`）を指定します。

```yaml
model_list:
  - model_name: local-gpt   # エージェントから指定するモデル名
    litellm_params:
      model: ollama/llama3.2:3b  # 実際に使用するOllamaモデル
      api_base: http://ollama-container:11434
```

### docker-compose.yml
2つのサービス（Ollama, LiteLLM）を定義します。
`OLLAMA_HOST=0.0.0.0` を指定することで、コンテナ外（LiteLLM）からのアクセスを許可します。

```yaml
services:
  # 1. ローカルLLMエンジン (Ollama)
  ollama:
    image: ollama/ollama:latest
    container_name: ollama-container
    ports:
      - "11434:11434"
    volumes:
      - ollama_storage:/root/.ollama
      - ./entrypoint.sh:/entrypoint.sh
    entrypoint: ["/bin/bash", "/entrypoint.sh"]
    environment:
      - OLLAMA_MODEL=llama3.2:3b  # ここで使用したいモデルを指定
      - OLLAMA_HOST=0.0.0.0       # 外部接続許可（必須）

  # 2. プロキシサーバ (LiteLLM)
  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    container_name: litellm-backend
    ports:
      - "4000:4000"
    volumes:
      - ./litellm_config.yaml:/app/config.yaml
    # LITELLM_MASTER_KEY は設定しない（認証なしモード）
    command: [ "--config", "/app/config.yaml", "--port", "4000", "--detailed_debug"]
    depends_on:
      - ollama

volumes:
  ollama_storage:
```

---

## 3. 起動手順

ターミナルでディレクトリに移動し、以下のコマンドを実行します。

```bash
# 1. スクリプトに実行権限を付与（初回のみ必要）
chmod +x entrypoint.sh

# 2. コンテナの起動
docker-compose up -d
```

初回起動時はモデル（Llama 3.2など）のダウンロードが行われるため、数分かかる場合があります。
以下のコマンドで進捗を確認できます。
```bash
docker logs -f ollama-container
```
`Model llama3.2:3b is ready!` と表示されれば準備完了です。

---

## 4. エージェントコード実装例 (Python)

OpenAI互換クライアントとして実装します。APIキーはダミー文字列で動作します。

```python
from openai import OpenAI

client = OpenAI(
    api_key="sk-dummy",              # LiteLLM (No Auth) なので何でもOK
    base_url="http://localhost:4000" # ローカルのLiteLLMに向ける
)

try:
    response = client.chat.completions.create(
        model="local-gpt",           # configで定義した名前
        messages=[
            {"role": "system", "content": "あなたは親切なアシスタントです。"},
            {"role": "user", "content": "こんにちは、テスト中ですか？"}
        ]
    )
    print(response.choices[0].message.content)

except Exception as e:
    print(f"Error: {e}")
```

## 5. 運用コマンド

- **停止:** `docker-compose down`
- **モデル変更:** `docker-compose.yml` の `OLLAMA_MODEL` を書き換えて `docker-compose up -d`
- **ログ確認:** `docker-compose logs -f`

