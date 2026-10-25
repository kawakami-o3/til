# 実装ノート: 背景アルゴリズムを自分で書くための資料

[background.md](../background.md) で紹介したアルゴリズムを、**自分で実装できる粒度**まで書き下した資料。

* 解説と擬似コードだけを載せる。動くコードは置かない。
* 擬似コードは Rust の文法で書く (後述の約束事に従う)。
* 前提知識は background.md を参照。この資料は「何を・どの順で・どう書くか」に集中する。

## ファイル一覧

| ファイル | 内容 |
|---|---|
| [00-primitives.md](00-primitives.md) | 共通の部品: SIMD 比較、分岐なし二分探索、ビッグエンディアン読み込み、ページ単位のメモリ確保、mmap / madvise |
| [01-slotted-btree.md](01-slotted-btree.md) | スロット付きページの B+-Tree (fence, prefix/suffix truncation, heads, hints) と固定長キー版 (TLX 型) |
| [02-key-encoding.md](02-key-encoding.md) | キー正規化、frame-of-reference、差分圧縮 + restart point |
| [03-cache-conscious-btree.md](03-cache-conscious-btree.md) | CSS-Tree, CSB+-Tree |
| [04-trie-art.md](04-trie-art.md) | トライの基本、ART |
| [05-hot.md](05-hot.md) | HOT (Height Optimized Trie) |
| [06-masstree-wormhole.md](06-masstree-wormhole.md) | Masstree, Wormhole |
| [07-lits.md](07-lits.md) | learned index の基本、LITS |
| [08-fptree-bptree.md](08-fptree-bptree.md) | FPTree, BP-Tree |
| [09-bwtree.md](09-bwtree.md) | Bw-Tree |
| [10-lsm.md](10-lsm.md) | LSM-tree |
| [11-buffer-management.md](11-buffer-management.md) | 古典的バッファマネージャ、pointer swizzling (LeanStore)、vmcache、非同期 I/O |
| [12-concurrency.md](12-concurrency.md) | ロックカップリング、OLC、contention split、XMerge |
| [13-benchmark.md](13-benchmark.md) | Zipf 乱数生成、YCSB ワークロード |

## background.md との対応

background.md の全項目が、どこかで実装レベルまで書かれていることを示す表。

| background.md | 実装ノート |
|---|---|
| 0.1 メモリ階層とキャッシュライン | 00 (アラインメント、プリフェッチ) |
| 0.2 SIMD | 00 |
| 0.3 分岐予測 | 00 (分岐なし二分探索) |
| 0.4 ページと仮想メモリ | 00, 11 |
| 0.5 malloc のオーバーヘッド | 00 (ページ単位のアロケータ) |
| 1.1 B-Tree と B+-Tree | 01 |
| 1.2 fence key | 01 |
| 1.3 スロット付きページ | 01 |
| 1.4 split と waves of misery | 01 |
| 1.5 CSS-Tree, CSB+-Tree | 03 |
| 2.1 Key normalization | 02 |
| 2.2 Poor man's normalized keys (heads) | 01 (heads, hints), 02 |
| 2.3 prefix / suffix truncation | 01 |
| 2.4 Frame-of-reference | 02 |
| 2.5 差分圧縮 | 02 |
| 3.1 トライの基本 | 04 |
| 3.2 ART | 04 |
| 3.3 HOT | 05 |
| 3.4 Masstree | 06 |
| 3.5 Wormhole | 06 |
| 3.6 LITS | 07 |
| 3.7 TLX の B+-Tree | 01 (固定長キー版) |
| 4.1 FPTree | 08 |
| 4.2 Bw-Tree | 09 |
| 4.3 BP-Tree | 08 |
| 4.4 LSM-tree | 10 |
| 5.1 古典的なバッファマネージャ | 11 |
| 5.2 Pointer swizzling と LeanStore | 11 |
| 5.3 vmcache | 11 |
| 5.4 ロックカップリングと OLC | 12 |
| 5.5 Contention split と XMerge | 12 |
| 5.6 NVMe の性能 | 11 (非同期 I/O のループ) |
| 6.1 YCSB | 13 |
| 6.2 Zipf 分布 | 13 |

## 擬似コードの約束事

### 文法

* Rust の文法で書く。**コンパイルが通ることは求めない**が、型と所有権の関係が矛盾しないように書く。
* `unsafe` ブロックやライフタイム注釈は、読みやすさのために省略してよい。省略したら、そこが unsafe であることをコメントで書く。
* ページに直接置く構造体は `#[repr(C)]` を付け、各フィールドのバイトオフセットをコメントで書く。

```rust
#[repr(C)]
struct NodeHeader {        // offset
    tag: u8,               // 0
    _pad: u8,              // 1
    count: u16,            // 2
    // ...
}
```

* 本質でない処理は `todo!()` やコメントで省略してよい。ただし、**省略したのが何か**は必ず書く。
* 名前から中身が自明な小さな関数は、定義を省略している。例えば次のようなもの。
  * 型の変換 (`as_n16()`, `as_bytes()`)
  * 配列のずらし (`shift_slots_right()`)
  * 2つの可変参照を同時に取る (`two_mut()`)
  * テスト用の乱数生成 (`gen_key()`)
  
  アルゴリズムの理解に関わる関数は、各ファイルの中で定義するか、文章で説明している。

### 共通の定義

各ファイルは、以下を再定義せずにそのまま使う。

```rust
const PAGE_SIZE: usize = 4096;
const CACHE_LINE: usize = 64;

type PageId = u64;

/// キーは正規化済みのバイト列 (memcmp の順 = 論理的な順)。02-key-encoding.md 参照。
type Key<'a> = &'a [u8];

/// キーの先頭4バイトをビッグエンディアンの u32 として読む。足りない分は 0 で埋める。
/// 00-primitives.md で定義。
fn head(key: &[u8]) -> u32;

/// 範囲走査のコールバック。false を返すと走査を打ち切る。
type ScanCallback<'a> = &'a mut dyn FnMut(&[u8], &[u8]) -> bool;
```

00-primitives.md で定義する部品 (`simd_eq_mask_u8x16` など) も、他のファイルから名前で参照してよい。

### Rust 特有の注意点

C++ の実装をそのまま Rust に移すと**未定義動作**になる箇所がある。該当するファイルでは、必ず扱い方を示す。

* **楽観的な読み取り (OLC, vmcache)**: 書き手が変更中かもしれないメモリを、ロックなしで読む。通常の参照で読むとデータ競合 = 未定義動作になる。
  アトミック操作で読むか、seqlock パターン (`read_volatile` と atomic fence の組み合わせ) で読む必要がある。12-concurrency.md で扱う。
* **メモリ回収 (Bw-Tree, OLC)**: 他スレッドが読んでいるかもしれないノードをすぐに解放できない。
  エポックベースの回収 (`crossbeam-epoch` が定番) を使う。
* **ポインタのタグ付け (ART の葉の判別、LeanStore の swip)**: ポインタの下位ビットや上位ビットに情報を埋め込む。
  `ptr.addr()` / `ptr.with_addr()` など strict provenance の API で書く。

## 各ファイルの構成

各ファイルは、扱うアルゴリズムごとに次の順で書く。

1. **目的と論文との関係**: 何のための構造か。論文のどこで出てくるか。
2. **データ配置**: Rust の構造体と、バイト数入りの ASCII 図。
3. **不変条件**: 常に成り立つべき性質 (例: スロットはキー順、fence の範囲内にキーがある)。
4. **操作ごとの擬似コード**: lookup / insert / delete / scan。split / merge、grow / shrink などがあればそれも書く。
5. **境界条件と落とし穴**: 空ノード、重複キー、最大長のキー、桁あふれなど。
6. **テスト方針**: `std::collections::BTreeMap` を正解 (オラクル) として、ランダムな操作列を流して結果を比べる。各操作の後に不変条件チェッカーを走らせる。
7. **原典との違い・簡略化**: 原典から省いたこと、変えたことを明記する。
8. **参考資料**: 原典の URL。参照実装を読んだ場合は `ファイル名:関数名` で示す。
