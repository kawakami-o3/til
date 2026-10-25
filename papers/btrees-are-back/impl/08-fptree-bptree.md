# 08. FPTree と fingerprinting リーフ、BP-Tree

background.md 4.1 (FPTree) と 4.3 (BP-Tree) を、自分で書けるように書き下す。
あわせて、論文 3.4 の **DRAM 向け fingerprinting リーフ**を参照実装に沿って書く。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* 4 KiB のスロット付きページ (ヘッダ、スロット、heap、fence、prefix) は [01-slotted-btree.md](01-slotted-btree.md) を前提にする。
* SIMD の比較 (`simd_eq_mask_u8x16`) とマスクのビットを `countr_zero` で順に取り出す書き方は [00-primitives.md](00-primitives.md) の部品を使う。
* 並行制御 (OLC) は [12-concurrency.md](12-concurrency.md)。ここでは単一スレッドで書く。

## 目次

1. [FPTree (永続メモリ向け)](#1-fptree-永続メモリ向け)
2. [論文の fingerprinting リーフ (DRAM 向け)](#2-論文の-fingerprinting-リーフ-dram-向け)
3. [BP-Tree](#3-bp-tree)
4. [参考資料](#4-参考資料)

---

## 1. FPTree (永続メモリ向け)

### 1.1 目的と論文との関係

* Oukid et al., SIGMOD 2016。**SCM (storage class memory、永続メモリ) と DRAM の混在**を前提にした B+-Tree。
* 3つの柱。
  * **selective persistence**: 葉だけを SCM に置く。内部ノードは DRAM に置き、再起動時に葉から作り直す。
  * **unsorted leaves + bitmap**: 葉をソートしない。挿入はエントリを書いてからビットマップの1ビットを立てるだけ。ずらし書きが起きない。
  * **fingerprinting**: キーの1バイトハッシュを葉の先頭キャッシュラインに並べる。成功する検索で本体の比較は平均約1回。
* 論文 (B-Trees Are Back) が持ち込んだのは3番目だけ。永続化の部分は論文には出てこない。
* ここでは**固定長キー (8 B 整数) の単一スレッド版**を詳しく書き、可変長キーと並行版 (HTM) は要約にとどめる。

### 1.2 永続化の基本操作

SCM に書いた値は、CPU キャッシュから追い出されるまで永続化されていない。
明示的に「書き戻し + 順序付け」をする必要がある。

```rust
use core::arch::x86_64::{_mm_clwb, _mm_sfence};

/// [p, p+len) を含むキャッシュラインをすべて書き戻し、以降の書き込みより先に完了させる。
unsafe fn persist(p: *const u8, len: usize) {
    let start = p.addr() & !(CACHE_LINE - 1);
    let mut a = start;
    while a < p.addr() + len {
        _mm_clwb(p.with_addr(a));     // 書き戻すがキャッシュからは追い出さない
        a += CACHE_LINE;
    }
    _mm_sfence();                     // clwb の完了を後続のストアより前に順序付ける
}
```

* 原典の時代は `CLFLUSH` を `MFENCE` で挟むか、non-temporal store + `MFENCE` を使っていた。`CLWB` は追い出さないので、直後に同じ行を読むなら速い。
* **p-atomic な書き込み**は 8 バイトの整列したストアだけ。それより大きい書き込みは、途中で電源が落ちると一部だけ残る (partial write)。
  FPTree の整合性は「8 バイトのビットマップの書き込みが p-atomic」であることに依存する。
* **永続ポインタ**: 再起動後は仮想アドレスが変わる。SCM 上のポインタは `(file_id: u64, offset: u64)` の 16 B で持ち、起動時に仮想アドレスへ変換する。
* **リークの防止**: アロケータは「確保したアドレスを、呼び出し側が指定した永続ポインタに書き込んで persist してから返す」。解放も「その永続ポインタを null にして persist」までやる。クラッシュ後、データ構造は自分の永続ポインタを見れば確保が済んだかが分かる。

### 1.3 データ配置

原典の評価で FPTree (単一スレッド・固定長) の葉は 56 エントリ (Table 1。並行版 FPTreeC は 64)。fingerprint 56 B + ビットマップ 8 B でちょうど1キャッシュラインになる。

```rust
const LEAF_N: usize = 56;

#[repr(C)]
struct PPtr { file_id: u64, offset: u64 }      // 永続ポインタ。(0,0) を null とする

#[repr(C, align(64))]
struct PLeaf {                     // offset  size
    bitmap: u64,                   // 0       8     ビット i = slot i が有効 (下位 56 ビットだけ使う)
    fp: [u8; LEAF_N],              // 8       56    fingerprint。ここまでで1キャッシュライン
    next: PPtr,                    // 64      16    右隣の葉 (永続の連結リスト)
    lock: u8,                      // 80      1     並行版の葉ロック。永続化しない
    _pad: [u8; 15],                // 81      15
    kv: [(u64, u64); LEAF_N],      // 96      896   未ソート
}                                  // 合計 992 (64 の倍数に丸めて確保)
```

```
line 0:  [bitmap 8B][fp0 fp1 ... fp55]      ← 検索はまずここだけ読む
line 1:  [next 16B][lock][pad]
line 2..: [k0 v0][k1 v1] ...                 ← fingerprint が一致したスロットだけ読む
```

* 原典 Figure 2 は「fingerprints, bitmap, pNext, KV, lock」の順に描いている。ここではビットマップを先頭に置き、8 B 整列を保証した (p-atomic のため)。**並びは筆者の変更**。
* 内部ノードは DRAM 上の普通の B+-Tree の内部ノード (ソート済みキー + 子ポインタ)。01 の内部ノードをそのまま使ってよい。
* 単一スレッド版の原典は、葉を数個まとめて確保する **leaf group** を使う (確保の回数を減らす)。並行版では使わない。下の擬似コードでは1枚ずつ確保する。

### 1.4 fingerprint

```rust
fn fingerprint(key: u64) -> u8 { (hash64(key) & 0xff) as u8 }
```

* 原典は「一様に分布するハッシュ」を仮定するだけで、具体的な関数を本文で指定していない。【未検証】参照実装があるかは確認していない。
* 期待される本体比較の回数 (成功する検索、キーは一意、葉に m 件):
  * 探すキー以外の m-1 件が、それぞれ確率 1/256 で同じ fingerprint を持つ。一致数の期待値は `1 + (m-1)/256`。
  * m = 56 なら約 1.2。一致したものを先頭から順に確かめるので、比較回数の期待値はさらに小さい (約 1.1)。原典は「約1」と述べている。

### 1.5 不変条件

* ビットマップで有効なスロットのキーは葉の中で一意。
* 有効スロット i について `fp[i] == fingerprint(kv[i].0)`。
* 葉の連結リストを先頭 (`PHead`) から辿ると、キー範囲が昇順に並ぶ (葉の中は未ソート)。
* 内部ノードの区切りキー: 子の葉のキーは `(sep[i-1], sep[i]]`。
* 無効スロットの中身は意味を持たない (ゴミでよい)。

### 1.6 lookup

```rust
fn leaf_find(l: &PLeaf, key: u64) -> Option<u64> {
    let f = fingerprint(key);
    // 56 個の fp を 16 個ずつ SIMD で比較し、ビットマップとの AND を取る
    let bytes: &[u8; 992] = as_bytes(l);             // 葉をバイト列として見る
    let mut m: u64 = 0;
    for c in 0..4 {                                   // 16*4 = 64 >= 56。fp[56..64] は next の先頭8B (下で消える)
        let chunk: &[u8; 16] = bytes[8 + c * 16..][..16].try_into().unwrap();
        m |= (simd_eq_mask_u8x16(f, chunk) as u64) << (c * 16);
    }
    m &= l.bitmap;                                    // 有効スロットだけ
    while m != 0 {
        let i = m.trailing_zeros() as usize;
        if l.kv[i].0 == key { return Some(l.kv[i].1); }
        m &= m - 1;
    }
    None
}
```

* `fp` は 56 B なので、16 B 単位で読むと最後の読み込みが `next` にはみ出す。読み出し自体は同じ構造体内なので安全だが、余分なビットは `bitmap` の上位 8 ビットが 0 であることで消える。
* 木全体の lookup は「DRAM の内部ノードを辿る → 葉で `leaf_find`」。

### 1.7 insert (分割なし)

```rust
/// 前提: 葉は満杯でない (満杯なら先に split する)。満杯だと trailing_zeros が 64 を返す。
fn leaf_insert(l: &mut PLeaf, key: u64, val: u64) {
    let free = (!l.bitmap) & ((1u64 << LEAF_N) - 1);
    let i = free.trailing_zeros() as usize;           // FindFirstZero
    l.kv[i] = (key, val);
    l.fp[i] = fingerprint(key);
    persist(&l.kv[i], 16);
    persist(&l.fp[i], 1);                             // 1) 中身を永続化 (この2つの順序は問わない)
    l.bitmap |= 1 << i;                               // 2) 8 B の p-atomic ストア = コミット
    persist(&l.bitmap, 8);
}
```

* **コミット点はビットマップの1ストア**。ビットマップが永続化される前に落ちれば、書いたスロットは無効のまま (挿入はなかった)。後なら挿入済み。どちらも回復処理は不要。
* `kv` と `fp` の persist はビットマップの書き込みより**前に完了**していなければならない。`persist` 内の `sfence` がこれを保証する。
* 既存キーの上書き (update) は「新しいスロットに書く → ビットマップで新しいビットを立て、古いビットを落とす、を1回のストアで」。葉が満杯でない限り分割が要らない (原典 Algorithm 8)。

### 1.8 leaf split (micro-log)

分割はビットマップ1回では済まないので、**micro-log** (永続ポインタ2本) を使う。

```rust
#[repr(C)]
struct SplitLog { cur: PPtr, new: PPtr }   // PCurrentLeaf, PNewLeaf。両方 null = 未使用
```

```rust
/// 満杯の葉 l を割り、(split_key, 右の新しい葉) を返す。
fn split_leaf(log: &mut SplitLog, l: &mut PLeaf) -> (u64, *mut PLeaf) {
    log.cur = pptr_of(l);            persist(&log.cur, 16);       // (1)
    palloc(&mut log.new, size_of::<PLeaf>());                     // (2) アロケータが log.new を書いて persist
    let r = vptr(log.new);
    split_copy_phase(log, l, r)                                   // (3)〜(7)
}

fn split_copy_phase(log: &mut SplitLog, l: &mut PLeaf, r: &mut PLeaf) -> (u64, *mut PLeaf) {
    *r = *l;  persist(r, size_of::<PLeaf>());                     // (3) 丸ごとコピー (next もコピーされる)
    let (split_key, right_bits) = find_split_key(l);              // (4) 中央値より大きいキーのビット
    r.bitmap = right_bits;  persist(&r.bitmap, 8);
    split_finish_phase(log, l, r, split_key)
}

fn split_finish_phase(log: &mut SplitLog, l: &mut PLeaf, r: &mut PLeaf, split_key: u64)
    -> (u64, *mut PLeaf) {
    l.bitmap = !r.bitmap & FULL_MASK;  persist(&l.bitmap, 8);     // (5) 左は残りのビット
    l.next = pptr_of(r);               persist(&l.next, 16);      // (6) リストにつなぐ
    *log = SplitLog::NULL;             persist(log, 32);          // (7) ログを空に
    (split_key, r)
}

fn find_split_key(l: &PLeaf) -> (u64, u64) {
    let mut keys: [u64; LEAF_N] = l.kv.map(|e| e.0);              // 満杯なので全スロット有効
    let mid = LEAF_N / 2 - 1;
    let (_, &mut k, _) = keys.select_nth_unstable(mid);           // 中央値 (ソート不要)
    let mut bits = 0;
    for i in 0..LEAF_N { if l.kv[i].0 > k { bits |= 1 << i; } }
    (k, bits)                                                     // 左: <= k, 右: > k
}
```

分割の後、DRAM 側で親に `(split_key, r)` を挿入する。新しいキーは `key <= split_key` なら `l`、そうでなければ `r` に `leaf_insert` する。
(原典 Algorithm 2 は分割後も常に元の葉に挿入するように書いているが、キーの範囲を考えると挿入先は選ぶ必要がある。【未検証】原典の意図は確認できていない。)

**回復 (原典 Algorithm 4)**:

```rust
fn recover_split(log: &mut SplitLog) {
    if log.cur.is_null() { return; }                       // 何も始まっていない
    if log.new.is_null() { reset(log); return; }           // (2) の前に落ちた
    let (l, r) = (vptr(log.cur), vptr(log.new));
    if l.bitmap == FULL_MASK {
        split_copy_phase(log, l, r);                       // (5) の前に落ちた: コピーからやり直す
    } else {
        // (5) の後に落ちた: (5)〜(7) をやり直す。
        // split_key は親への挿入にしか使わず、回復では内部ノードを作り直すので不要
        split_finish_phase(log, l, r, 0);
    }
}
```

* 「左の葉のビットマップが満杯か」で (5) の前後を判定する。分割は満杯の葉にしか起きないので、満杯でなければ (5) は済んでいる。
* (5)〜(7) はどれも冪等 (何度やっても同じ結果)。
* `split_key` は回復時には要らない。内部ノードはこのあと葉から作り直すので。

### 1.9 delete

* 葉にキーが他にもある場合: そのビットを落として persist。これがコミット点。

```rust
fn leaf_delete(l: &mut PLeaf, i: usize) { l.bitmap &= !(1 << i); persist(&l.bitmap, 8); }
```

* 葉が唯一のキーを失う場合: 葉ごと外す。**delete 用の micro-log** (`cur`, `prev`) を使う (原典 Algorithm 6, 7)。
  1. `log.cur = l` を persist。
  2. `l` がリストの先頭なら `PHead = l.next` を persist。そうでなければ `log.prev = prev` を persist → `prev.next = l.next` を persist。
  3. `pfree(&mut log.cur)` (アロケータが `log.cur` を null にする)。
  4. ログを空にする。
* 回復: `cur` と `prev` が両方セット → 2 の後半からやり直す。`cur == PHead` → 2 の前半からやり直す。`cur.next == PHead` → 先頭の付け替えは済んだので 3 からやり直す。それ以外 → ログを空にする。
* DRAM 側では親から区切りキーと子を消す (普通の B+-Tree の削除)。

### 1.10 回復 (再起動時)

1. 初期化中に落ちたかを状態ビットで確認する。
2. split ログと delete ログを全部処理する (1.8, 1.9)。
3. `PHead` から葉のリストを辿る。各葉で
   * `lock` を 0 に戻す (ロックは永続化しない値なのでゴミが入っている)。
   * 有効スロットの**最大キー**を求める (未ソートなので全有効スロットを見る)。
4. (最大キー, 葉) の列から、bulk load と同じ要領で内部ノードを下から作る。最後の葉の区切りは +∞。
5. 並行版ではログのキューを作り直す。

### 1.11 範囲走査

* 葉は未ソートなので、走査のたびに「有効スロットを集めてソート」する。

```rust
fn leaf_scan(l: &PLeaf, from: u64, cb: &mut dyn FnMut(u64, u64) -> bool) -> bool {
    let mut tmp: ArrayVec<(u64, u64), LEAF_N> = valid_slots(l).filter(|e| e.0 >= from).collect();
    tmp.sort_unstable_by_key(|e| e.0);
    tmp.iter().all(|&(k, v)| cb(k, v))
}
```

* 次の葉へは `next` で移る。SCM 上の葉は書き換えない (書き込みは高いので、ソート結果は DRAM の一時配列に置く)。

### 1.12 可変長キーと並行版 (要約)

* **可変長キー**: `kv` にはキー本体ではなく、キーへの永続ポインタを置く。挿入はキー用の永続確保を伴うので、そのぶん micro-log が増える (原典 Appendix C)。【未検証】Appendix C は読めていない。
* **並行版**: 内部ノードの走査は HTM (Intel TSX) のトランザクション内で行い、葉の書き込み (persist を伴う) はトランザクションの外で葉ロックを取って行う ("selective concurrency")。`CLWB` などのキャッシュ操作はトランザクションを abort させるため、この分離が必要。
  Rust で書くなら、HTM の代わりに 12-concurrency.md の OLC を内部ノードに使い、葉は排他ロックにするのが現実的 (筆者の提案)。

### 1.13 境界条件と落とし穴

* **ビットマップの上位ビット**: 56 スロットなら上位 8 ビットは常に 0。`!bitmap` で空きを探すときにマスクしないと、存在しないスロット 56〜63 を空きと誤認する。
* **persist の順序**: `kv` と `fp` の persist を省くと、ビットマップだけ永続化されてゴミのキーが有効になる。テストで検出しにくいので、persist をラップしてログを取る。
* **コンパイラの並べ替え**: `persist` の前後でストアが入れ替わらないよう、`_mm_sfence` に加えて `compiler_fence(SeqCst)` を置くか、`write_volatile` を使う。
* **find_split_key の重複**: キーは葉の中で一意なので、中央値で割ると左右とも空にならない。上書きを「新スロット + 旧ビット落とし」でやっていれば一意性は保たれる。
* **永続メモリが無い環境**: 開発時は `mmap` したファイル + `msync` で代用できる。`persist` をフックしてクラッシュを注入する (下記)。

### 1.14 テスト方針

* オラクル: `BTreeMap<u64, u64>`。ランダムな insert / update / delete / lookup / scan を流して比べる。
* 不変条件チェッカー: 1.5 の各項目に加え、DRAM の内部ノードを葉のリストから作り直したものと、実行中の内部ノードが同じ区切りを持つか。
* **クラッシュテスト**:
  * `persist` をフックし、「N 回目の persist の直後に、永続化されていない書き込みをすべて捨てて停止」をシミュレートする。SCM を模した2つのバッファ (キャッシュ側と永続側) を持ち、`persist` で永続側へコピーする実装にすると書きやすい。
  * N を 1 から最後まで全部試す。各回で回復 → オラクルと比べる。期待値は「最後にコミット点 (ビットマップの persist) を越えた操作までが反映されている」。
  * 分割の途中 (1)〜(7) の各点、delete ログの各点で必ず落ちるケースを含める。
* 回復を2回続けて走らせても結果が同じ (冪等) ことも確かめる。

### 1.15 原典との違い・簡略化

* 単一スレッド・固定長キーに絞った。HTM による並行制御、可変長キーは要約のみ。
* leaf group (葉のまとめ確保) は省いた。
* 葉のフィールド順を変えた (ビットマップを先頭へ)。
* 分割後の挿入先を「キーで選ぶ」形にした。
* 範囲走査は原典で詳しく書かれていないので、DRAM の一時配列でソートする素直な形にした。

---

## 2. 論文の fingerprinting リーフ (DRAM 向け)

### 2.1 目的と論文との関係

* 論文 3.4。FPTree の fingerprint を、**4 KiB のスロット付きページの葉**に移植したもの。
* 永続化は関係ない。目的は**キー本体 (heap 上でランダムな位置にある) へのアクセスを減らす**こと。
* 文字列キーで効く (lookup が最大 20% 速い)。整数キーでは逆効果 (1ページに入る件数が多く、fingerprint の衝突も、配列が占めるキャッシュラインも増える)。
* 論文側の工夫:
  * エントリ配列を **ソート済みの範囲 + 未ソートの範囲** に分ける。挿入は未ソートの末尾に追記するだけ。
  * **scan の前に遅延ソート**する。split の前にもソートする。
  * ソートでは fingerprint 配列を並べ替えず、**全部計算し直す** (別々の場所にある2つの配列を同じ置換で並べ替える汎用ルーチンがないため)。
  * fingerprint は **prefix を除いたキー**から計算する。prefix 長が変わる (split / merge) と再計算が要る。

### 2.2 データ配置

参照実装 `btree-cpp: btree/btree2020.hpp:HashNode` を整理したもの。

```rust
#[repr(C)]
struct HashLeafHeader {        // offset  size
    tag: u8,                   // 0       1    Leaf の種類 (Hash)
    range_ops: u8,             // 1       1    適応用のカウンタ (論文 5章。ここでは使わない)
    count: u16,                // 2       2    エントリ数
    sorted_count: u16,         // 4       2    slot[0..sorted_count] がソート済み
    space_used: u16,           // 6       2    heap 上の生きているバイト数 (kv + fences)
    data_offset: u16,          // 8       2    heap の先頭
    prefix_len: u16,           // 10      2
    fp_capacity: u16,          // 12      2    fingerprint 配列の容量
    fp_offset: u16,            // 14      2    fingerprint 配列のページ内位置
    lower_fence_len: u16,      // 16      2
    upper_fence_len: u16,      // 18      2
}                              // 20 バイト

#[repr(C, packed)]
struct HashSlot { offset: u16, key_len: u16, payload_len: u16 }   // 6 B。head はない
```

```
0     20                                     fp_offset           4096
+------+-- slot[0..count] --+---- 空き ----+--[fp; fp_capacity]--+-- heap: kv, fences --+
       |<- sorted ->|<- unsorted ->|                ↑
                    sorted_count            fingerprint 配列は heap の中に置く (確保して伸ばす)
```

* fingerprint 配列は**ページの heap 領域の中**に置く。容量を超えたら、heap から一回り大きい領域を取り直してコピーする。空きがなければ compaction のついでに作り直す。
* 容量の見積もり (`estimateCapacity`): 「平均エントリサイズで埋めたら何件入るか」。`available * count / (entry_bytes + count)`。空のときは 4096/64 = 64。
* スロットは 01 の 10 B スロットから head を抜いた 6 B。キー比較に head を使わないため。

### 2.3 fingerprint

```rust
fn fp(key_suffix: &[u8]) -> u8 { hash_bytes(key_suffix) as u8 }   // 下位1バイト
```

* 参照実装は `std::hash<std::string_view>` (libstdc++ では murmur 系) の下位1バイト。CRC32 版も選べる (`config.hpp: hashUseCrc32`、既定は false)。
* Rust では `ahash` / `FxHash` などの 64 ビットハッシュの下位1バイトで十分。**入力は prefix を除いた部分**。

### 2.4 不変条件

* `fp[i] == fp(key_suffix(i))` (全 i < count)。
* `slot[0..sorted_count]` はキー順。`slot[sorted_count..count]` は順不同。
* キーはノード内で一意。
* 01 と同じく、全キーが fence の範囲内で、prefix を共有する。

### 2.5 lookup

```rust
fn find_index(n: &HashLeaf, key: &[u8]) -> Option<usize> {
    let suffix = &key[n.prefix_len as usize..];
    let f = fp(suffix);
    let fps = n.fps_padded();                            // 下の定義を参照
    let mut base = 0;
    while base < n.count as usize {
        // 末尾の16バイト読みは余白に収まる。count を超えた分は下でマスクする
        let chunk: &[u8; 16] = fps[base..][..16].try_into().unwrap();
        let mut m = simd_eq_mask_u8x16(f, chunk) as u32;
        m &= mask_below(n.count as usize - base);
        while m != 0 {
            let i = base + m.trailing_zeros() as usize;
            if n.key_suffix(i) == suffix { return Some(i); }      // 長さ比較 + memcmp
            m &= m - 1;
        }
        base += 16;
    }
    None
}

impl HashLeaf {
    /// fingerprint 配列。長さ count を 16 の倍数に切り上げた分だけ返す。
    /// fp_capacity を確保するときに、常に 15 B の余白を足しておくこと (次の箇条書き参照)。
    fn fps_padded(&self) -> &[u8] {
        let len = (self.count as usize + 15) & !15;
        &self.bytes()[self.fp_offset as usize..][..len]
    }
}

/// 下位 n ビットだけ立てたマスク (n >= 32 なら全ビット)
fn mask_below(n: usize) -> u32 { if n >= 32 { !0 } else { (1u32 << n) - 1 } }
```

* **ソート済みの範囲も含めて全エントリを fingerprint で探す**。ソート済み範囲を二分探索で別扱いすることはしない (参照実装 `hash.cpp:findIndexSimd`)。
* 参照実装は 32 B ずつ (AVX2) 比較し、配列の先頭が 32 B 境界にないときは境界まで戻って読み、ずれをシフトで消している。Rust では `fps` の後ろに 15 B の余白を必ず確保しておけば、境界を気にせず読める。
* 文字列キーでは、一致した fingerprint のエントリだけが heap にアクセスする。これが比較ベースの二分探索 (毎回 heap に飛ぶ) より速い理由。

### 2.6 insert

```rust
fn insert(n: &mut HashLeaf, key: &[u8], val: &[u8]) -> bool /* false = 分割が必要 */ {
    let suffix = &key[n.prefix_len as usize..];
    if !request_slot_and_space(n, suffix.len() + val.len()) { return false; }
    let f = fp(suffix);
    match find_index(n, key) {
        Some(i) => {                                    // 上書き: 同じスロットに新しい kv を書く
            n.space_used -= old_kv_len(n, i) as u16;     // 古い kv は heap にゴミとして残る
            store_kv(n, i, suffix, val, f);
        }
        None => {                                       // 未ソート範囲の末尾に追記
            store_kv(n, n.count as usize, suffix, val, f);
            n.count += 1;
        }
    }
    true
}

fn request_slot_and_space(n: &mut HashLeaf, kv: usize) -> bool {
    // 1) fp 配列に空きがあり、スロット + kv が入るならそのまま
    // 2) fp 配列が満杯なら、容量を見積もり直して heap に新しい配列を取りコピー
    // 3) それでも入らなければ compaction (fp 配列も新しい容量で作り直す)
    // 4) compaction しても数件しか増えないなら false (分割させる)
    todo!("hash.cpp:requestSlotAndSpace の手順。省略したのは容量計算の細部")
}
```

* 上書きでもスロット位置は変わらないので、`sorted_count` はそのまま正しい (キーが同じだから順序も同じ)。

### 2.7 remove

```rust
fn remove(n: &mut HashLeaf, key: &[u8]) -> bool {
    let Some(i) = find_index(n, key) else { return false };
    n.space_used -= kv_len(n, i) as u16;
    n.slots_mut().copy_within(i + 1..n.count as usize, i);    // 順序を保ってずらす
    n.fps_mut().copy_within(i + 1..n.count as usize, i);      // fp も同じだけずらす
    n.count -= 1;
    if i < n.sorted_count as usize { n.sorted_count -= 1; }
    true
}
```

* 「末尾と入れ替えて消す」とソート済み範囲が壊れる。ずらして消すこと。

### 2.8 遅延ソート

```rust
fn sort(n: &mut HashLeaf) {
    if n.sorted_count == n.count { return; }
    let s = n.sorted_count as usize;
    let slots = n.slots_mut();                                // 6 B のスロットを並べ替える
    slots[s..].sort_unstable_by(|a, b| cmp_suffix(n, a, b));  // 未ソート部分だけソート
    merge_in_place(slots, s, |a, b| cmp_suffix(n, a, b));     // [0,s) と [s,count) をマージ
    for i in 0..n.count as usize { n.fps_mut()[i] = fp(n.key_suffix(i)); }   // fp は全部計算し直す
    n.sorted_count = n.count;
}
```

* 参照実装は `std::sort` + `std::inplace_merge`。Rust にはインプレースマージがないので、スロット配列 (最大で数百 × 6 B) を一時配列にマージしてから書き戻せばよい。
* スロットだけ並べ替えて fp を計算し直すのは、論文の記述どおり。ハッシュの計算は heap へのアクセスを伴うが、ソート自体が heap を読むので追加のミスは少ない。
* 呼ばれるのは **scan の直前**と **split の直前**。

### 2.9 scan

```rust
fn scan(n: &mut HashLeaf, from: &[u8], cb: ScanCallback) -> bool {
    sort(n);                                       // ここでノードを書き換える
    let mut i = lower_bound_binary(n, from);       // ソート済みなので普通の二分探索
    while i < n.count as usize {
        if !cb(&full_key(n, i), n.payload(i)) { return false; }
        i += 1;
    }
    true
}
```

* **読み取り操作がノードを書き換える**。並行制御では scan も排他ロック (または OLC の書き込みロック) を取る必要がある。論文もこの点を「並行実装を複雑にしうる」と書いている。
* 降順 scan も同じ (ソート後に逆向き)。

### 2.10 split と merge

* split: `sort()` → 01 と同じ区切りキー選び (suffix truncation) → 左右のノードへコピー。コピー先では **prefix 長が変わるので fp を計算し直す** (`hash.cpp:copyKeyValueRange` は1件ずつ `updateHash` を呼ぶ)。コピー後の左右は全体がソート済み (`sorted_count = count`)。
* merge: 左右を新しいノードにコピーし、親から区切りを消す。参照実装はマージ後の `sorted_count` を 0 にしている (保守的。左右ともソート済みなら `count` にしてもよい)。
* 適応型 B-Tree (論文 5章) では、split のときに「heads が十分に一意か」「範囲操作が多いか」を見て、比較ベースの葉に変換することがある。変換の判断は 01 / 論文 5章の担当で、ここでは扱わない。

### 2.11 境界条件と落とし穴

* **fp 配列の読みはみ出し**: SIMD で 16/32 B 読むので、配列の後ろに余白が要る。heap の中に置くなら、余白ぶんも `space_used` に数えるか、配列の後ろが必ずページ内であることを保証する。
* **prefix の変化**: fence が変わると prefix 長が変わり、全 fp が無効になる。split / merge / fence の更新で必ず計算し直す。
* **キーの長さが違うが接頭辞が同じ**: `key_suffix(i) == suffix` は長さも比べること (memcmp だけだと短い方の長さで一致してしまう)。
* **空のノード**: `count == 0` のとき SIMD ループに入らない。
* **整数キー**: 1ページに数百件入ると、fp の偶然一致が増え、fp 配列も複数キャッシュラインになる。論文の結論どおり、整数キーには比較ベースの葉を使う。

### 2.12 テスト方針

* 01 と同じオラクルテスト (`BTreeMap<Vec<u8>, Vec<u8>>`) を、葉の型だけ差し替えて流す。
* scan を混ぜる比率を変えて回す (0%, 5%, 50%)。遅延ソートの経路を確実に通す。
* 不変条件チェッカー: 全 i で `fp[i] == fp(key_suffix(i))`、`slot[0..sorted_count]` が昇順、キーの一意性。
* 狙い撃ち: 全キーの fingerprint が同じになるハッシュ (定数関数) に差し替えても正しく動くこと (性能は落ちるが結果は同じ)。

### 2.13 原典との違い・簡略化

* ヘッダの並びは参照実装を整理したもの。適応用カウンタは型だけ残した。
* `request_slot_and_space` の容量計算は手順だけ書き、式の細部は省いた (`hash.cpp:estimateCapacity` 参照)。
* インプレースマージを一時配列のマージに置き換えた。

---

## 3. BP-Tree

### 3.1 目的と論文との関係

* Xu et al., VLDB 2023。点操作に最適なノードサイズは小さく (~1 KiB)、範囲操作に最適なサイズは大きい。その両立を狙う。
* 内部ノードは普通のソート済み配列 (既定 1024 B)。**葉だけを大きくし** (既定 17408 B)、中身を **buffered partitioned array (BPA)** にする。
* BPA = 未ソートのログ + ソート済みのヘッダ + 未ソートのブロック群。挿入はログに追記し、ときどきまとめてブロックへ流す。
* 論文 (B-Trees Are Back) が採らない理由 (8章):
  * 固定長キー専用。
  * スロット配列に移植すると find がキャッシュ非友好的になる。
  * 大きな葉は fingerprinting と相性が悪く、メモリに載らないときにも不利。

### 3.2 データ配置

要素は固定長の (key, value) = 8 B + 8 B。原典の既定値はヘッダ 32 スロット、ブロック 32 スロット。

```rust
const LOG: usize = 32;          // log_size
const NB: usize = 32;           // num_blocks (= header_size)
const BS: usize = 32;           // block_size
type Elem = (u64, u64);

#[repr(C)]
struct Bpa {
    log: [Elem; LOG],           // offset 0       512 B   未ソート (追記順)
    header: [Elem; NB],         // offset 512     512 B   ソート済み。header[i] = ブロック i の最小要素
    blocks: [[Elem; BS]; NB],   // offset 1024    16384 B 各ブロック内は未ソート
}                               // 合計 17408 B (原典の既定の葉サイズと一致)

struct BpaMeta {                // 原典は「block marker」で空を表すが、ここでは長さを別に持つ
    log_len: u8,
    n_header: u8,               // 使用中のブロック数
    block_len: [u8; NB],
    sorted: u32,                // ビット i = ブロック i がソート済み
    log_sorted: bool,
    num_elts: u32,              // 重複を含む要素数 (葉の満杯判定に使う)
}
```

* ログ 32 スロットという値は、17408 B = 16 B × 1088 = 16 B × (32 + 32 + 32×32) から逆算した。【未検証】原典は log_size の既定値を明記していない。
* **ヘッダの要素は本物のデータ**。ブロック i の最小要素をヘッダに置き、残りをブロックに置く。
* 空き・使用中の表し方 (marker か長さか) は筆者の選択。原典は「block marker」とだけ書いている。

```
[ log: 8 25 _ _ ... ][ header: 7 | 17 | 32 | 93 ][ blk0: 15 13 8 _ ][ blk1: 19 22 _ ][ blk2: 50 _ ][ blk3: 95 _ ]
   未ソート、新しい       ソート済み (各ブロックの最小)     各ブロックは header[i] 以上 header[i+1] 未満、順不同
```

### 3.3 不変条件

* 挿入の完了後、**ログにもブロックにも空きが最低1つある**。
* `header[0..n_header]` は昇順。ブロック i の要素 `x` は `header[i].0 < x.0 < header[i+1].0`。
* 同じキーがログとブロック (またはヘッダ) の両方にあってよい。その場合**ログの方が新しく、正しい値**。
* ログの中では同じキーは1つ (挿入時に置き換える)。
* `sorted` のビットが立っているブロックは本当にソート済み。
* `num_elts` は実際の異なるキーの数以上、かつ差は `LOG` 以下。

### 3.4 find

```rust
fn find(b: &Bpa, m: &BpaMeta, key: u64) -> Option<u64> {
    for e in &b.log[..m.log_len as usize] {                // 1) ログ (最新)
        if e.0 == key { return Some(e.1); }
    }
    let h = &b.header[..m.n_header as usize];
    let i = h.partition_point(|e| e.0 <= key);             // 2) ヘッダで担当ブロックを決める
    if i == 0 { return None; }                             //    最小要素より小さい
    let i = i - 1;
    if h[i].0 == key { return Some(h[i].1); }              //    ヘッダそのものに一致
    b.blocks[i][..m.block_len[i] as usize]                 // 3) ブロックを線形に
        .iter().find(|e| e.0 == key).map(|e| e.1)
}
```

* 触るのはログ (先頭の数ライン)、ヘッダ (512 B)、ブロック1つ (512 B)。葉が 17 KiB あっても、点操作で触る範囲は小さい。

### 3.5 insert と flush

```rust
fn insert(b: &mut Bpa, m: &mut BpaMeta, key: u64, val: u64) {
    if let Some(e) = b.log[..m.log_len as usize].iter_mut().find(|e| e.0 == key) {
        e.1 = val; return;                                 // ログ内の上書き
    }
    b.log[m.log_len as usize] = (key, val);
    m.log_len += 1;  m.log_sorted = false;
    if (m.log_len as usize) < LOG { return; }              // Case 1: まだ空きがある
    flush(b, m);                                           // Case 2: ログが満杯
}

fn flush(b: &mut Bpa, m: &mut BpaMeta) {
    sort_log(b, m);
    if m.n_header == 0 {                                   // 初回: ログをそのままヘッダへ
        b.header[..m.log_len as usize].copy_from_slice(&b.log[..m.log_len as usize]);
        m.n_header = m.log_len;  m.log_len = 0;
        return;
    }
    // 各ログ要素の行き先ブロックを数える (ヘッダ/ブロック内の既存キーと同じなら数えない)
    let mut dest = [0usize; NB];
    for e in log_elems(b, m) {
        let i = dest_block(b, m, e.0);
        if !exists_in_header_or_block(b, m, i, e.0) { dest[i] += 1; }
    }
    if (0..m.n_header as usize).all(|i| m.block_len[i] as usize + dest[i] < BS) {
        // Case 2a: 全ブロックに収まる → 上書き or 追記
        for e in log_elems(b, m) {
            let i = dest_block(b, m, e.0);
            if !replace_in_header_or_block(b, m, i, e) {
                push_block(b, m, i, e);                    // 末尾に追記。sorted ビットを落とす
            }
        }
        m.log_len = 0;
    } else {
        redistribute(b, m);                                // Case 2b
    }
}
```

* `dest_block` は find の 2) と同じ。ただしヘッダの最小より小さいキーはブロック 0 へ。
  このときブロック 0 の最小がヘッダより小さくなるので、**新しいキーとヘッダを入れ替える** (新しいキーをヘッダに、旧ヘッダをブロックに)。【未検証】原典はこの場合の扱いを書いていない。入れ替えは筆者の選択。
* 2a の判定は `< BS` (1つ空きを残す)。

### 3.6 redistribute

```rust
fn redistribute(b: &mut Bpa, m: &mut BpaMeta) {
    // 1) 各ブロックをソート (sorted ビットが立っていれば省略)
    // 2) ヘッダとブロックを順につないだ列 = 全体がソート済み
    // 3) ソート済みのログとマージ。同じキーはログ側を採る
    let all: Vec<Elem> = merge_dedup(sorted_log(b, m), header_and_blocks_in_order(b, m));
    // 4) NB 個のブロックに均等に配る (各ブロックの先頭 1 個はヘッダへ)
    let t = all.len();
    let nb = NB.min(t);                                    // 要素が少なければ使うブロックを減らす
    let mut pos = 0;
    for i in 0..nb {
        let cnt = t / nb + (i < t % nb) as usize;          // 先頭の t%nb 個のブロックに1つ多く
        b.header[i] = all[pos];
        let rest = &all[pos + 1..pos + cnt];
        b.blocks[i][..rest.len()].copy_from_slice(rest);
        m.block_len[i] = rest.len() as u8;
        pos += cnt;
    }
    m.n_header = nb as u8;  m.log_len = 0;
    m.sorted = ((1u64 << nb) - 1) as u32;                  // 配った直後は全ブロックがソート済み (nb = 32 でもあふれない)
    m.num_elts = t as u32;                                 // 重複が消えたので正確な数に戻る
}
```

* redistribute は**全ブロック**をまとめて行う (PMA のような局所的な再配置はしない、と原典が明記)。
* 各ブロックに空きが1つ残るには `t <= NB * BS` が要る (ヘッダぶんで各ブロック `BS` 個 = ブロック内 `BS-1` 個 + ヘッダ1個)。これを超える前に木のレベルで葉を split する。

### 3.7 葉の split (木のレベル)

* 葉が満杯 = `num_elts == NB * BS` (ログを除いたスロット数)。
* split: ログを flush (必要なら redistribute) → 全要素をソート順に取り出す → 前半を元の葉、後半を新しい葉に redistribute → 親に区切りキー (後半の最小) を挿入 → 新しいキーを該当する葉に挿入。
* ログは葉に比べて十分小さいので、ログが全部重複でも split できるだけの要素がある (原典)。

### 3.8 range iteration

```rust
/// start 以上のキーを最大 len 個、昇順で f に渡す。
fn iterate_range(b: &mut Bpa, m: &mut BpaMeta, start: u64, mut len: usize, f: &mut dyn FnMut(u64, u64)) {
    sort_log(b, m);                                         // ログをソート (書き換えあり)
    let mut lp = b.log[..m.log_len as usize].partition_point(|e| e.0 < start);
    let mut blk = dest_block(b, m, start);
    ensure_block_sorted(b, m, blk);                         // sorted ビットを見て必要ならソート
    let mut bp = BlockCursor::seek(b, m, blk, start);       // ヘッダ要素 → ブロック要素の順に進む
    while len > 0 {
        let lk = (lp < m.log_len as usize).then(|| b.log[lp]);
        let bk = bp.peek(b, m);                             // ブロック末尾で次のブロックへ (ensure_block_sorted して)
        let e = match (lk, bk) {
            (None, None) => break,
            (Some(l), None) => { lp += 1; l }
            (None, Some(x)) => { bp.next(); x }
            (Some(l), Some(x)) if l.0 < x.0 => { lp += 1; l }
            (Some(l), Some(x)) if l.0 > x.0 => { bp.next(); x }
            (Some(l), Some(_)) => { lp += 1; bp.next(); l } // 同じキー: ログが新しい
        };
        f(e.0, e.1);  len -= 1;
    }
}
```

* 2本の指 (`log_ptr`, `blocks_ptr`) による合流。
* ソートは必要なブロックだけ、必要になったときに行う。
* 葉をまたぐときは、次の葉で同じことを繰り返す。並行版では、ログか該当ブロックが未ソートなら読みロックを書きロックに取り替えてソートする。
* **range map** (順序が不要な走査): ログをコピーしてソートしておき、ブロックは順不同のまま走査して「範囲外」「ログに同じキーがある」ものを飛ばす。

### 3.9 境界条件と落とし穴

* **ヘッダより小さいキー**: 3.5 の入れ替えを忘れると「ヘッダ = ブロックの最小」が崩れ、find の 2) で `i == 0` の判定を誤る。
* **ログとブロックの重複**: find・scan ともログを優先する。flush で置き換えを忘れると古い値が復活する。
* **num_elts の過大評価**: 重複を含むので、split の判定が早めに起きることがある。正しさには影響しない。
* **削除**: 原典は「tombstone で対称に扱える」とだけ書いて省略している。実装するなら、ログに tombstone を入れ、flush / redistribute で対応する要素ごと消す。
* **キーが固定長**: 可変長キーにはそのままでは使えない (論文が採らない理由の1つ)。

### 3.10 テスト方針

* オラクル: `BTreeMap<u64, u64>`。BPA 単体 (葉1枚) と木全体の両方でランダムな insert / find / iterate_range を流す。
* 定数を小さくした版 (LOG = 4, NB = 4, BS = 4) で、flush の 2a / 2b、初回 flush、split が頻繁に起きるようにする。
* 不変条件チェッカー: 3.3 の全項目。特に「ブロック i の全要素が header[i] と header[i+1] の間」「sorted ビットの正しさ」。
* 狙い撃ち: 同じキーの上書きを繰り返す (ログとブロックの重複)、昇順挿入 (最後のブロックだけが溢れて 2b が連発)、ヘッダの最小未満のキーの挿入。

### 3.11 原典との違い・簡略化

* 並行制御 (reader-writer ロックの hand-over-hand、楽観的な1回目の降下と悲観的な2回目の降下) は省いた。
* 空き表現を marker ではなく長さの配列にした。ヘッダ最小未満のキーの扱いは筆者の選択。
* 削除は書いていない (原典も省略)。
* log_size は葉サイズからの逆算。

---

## 4. 参考資料

* Ismail Oukid, Johan Lasperas, Anisoara Nica, Thomas Willhalm, Wolfgang Lehner. *FPTree: A Hybrid SCM-DRAM Persistent and Concurrent B-Tree for Storage Class Memory*. SIGMOD 2016. https://tud.qucosa.de/api/qucosa%3A80443/attachment/ATT-0/
  * 2章 (persist、永続ポインタ、リーク対策), 4章 (selective persistence, fingerprinting の期待値, leaf group), 5章 (Algorithm 1〜9)。
* Helen Xu, Amanda Li, Brian Wheatman, Manoj Marneni, Prashant Pandey. *BP-Tree: Overcoming the Point-Range Operation Tradeoff for In-Memory B-Trees*. PVLDB 16(11), 2023. https://www.vldb.org/pvldb/vol16/p2976-xu.pdf
  * 3章 (BPA: layout, insert, find, range iteration, range map), 5章 (BP-tree の insert / split), 6.1 (既定のサイズ)。
* Marcus Müller, Lawrence Benson, Viktor Leis. *B-Trees Are Back*. SIGMOD 2025. Section 3.4 (Fingerprinting), 4.5, 8 (BP-Tree)。
* 参照実装 [btree-cpp](https://github.com/m-mueller678/btree-cpp/tree/sigmod25)
  * `btree/btree2020.hpp:HashNodeHeader, HashSlot`
  * `btree/hash.cpp:compute_hash, findIndexSimd, requestSlotAndSpace, estimateCapacity, insert, removeSlot, sort, splitNode, copyKeyValueRange, mergeNodes, range_lookup`
  * `btree/anynode.cpp:splitNodeWithParent` (split の前に `sort()` を呼ぶ)
  * `btree/config.hpp` (`hashUseCrc32`, `hashSimdWidth`)
