# 05. HOT (Height Optimized Trie)

background.md の 3.3 を、自分で実装できる粒度まで書き下す。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* トライ・Patricia trie・キー終端の基本は [04-trie-art.md](04-trie-art.md) を参照。ここでは繰り返さない。
* `load_be_u64`, `prefetch_node`, `alloc_aligned`, `for_each_set_bit_u32` は [00-primitives.md](00-primitives.md) の部品を名前で使う。
* 単一スレッド版だけを扱う。原典の並行版 (ROWEX) は [12-concurrency.md](12-concurrency.md) の範囲。

参照実装は著者の [speedskater/hot](https://github.com/speedskater/hot) (`libs/hot/commons/include/hot/commons/` と `libs/hot/single-threaded/include/hot/singlethreaded/`)。
論文の比較では btree-cpp の `btree/hot_adapter.cpp` がこれを `HOTSingleThreaded<Tuple*, ...>` として使っている。
擬似コードは書き直したもので、コードの直訳ではない。

## 目次

1. [目的と論文との関係](#1-目的と論文との関係)
2. [先に決めること (実装方針)](#2-先に決めること-実装方針)
3. [論理モデル: BiNode と複合ノード](#3-論理モデル-binode-と複合ノード)
4. [部分キー (sparse partial key)](#4-部分キー-sparse-partial-key)
5. [データ配置](#5-データ配置)
6. [不変条件](#6-不変条件)
7. [部品: pext / pdep と部分キーの抽出・検索](#7-部品-pext--pdep-と部分キーの抽出検索)
8. [lookup](#8-lookup)
9. [ノード内の編集: ビットの追加・エントリの追加・分割](#9-ノード内の編集-ビットの追加エントリの追加分割)
10. [insert](#10-insert)
11. [delete (要約)](#11-delete-要約)
12. [scan と lower_bound](#12-scan-と-lower_bound)
13. [境界条件と落とし穴](#13-境界条件と落とし穴)
14. [テスト方針](#14-テスト方針)
15. [原典との違い・簡略化](#15-原典との違い簡略化)
16. [参考資料](#16-参考資料)

---

## 1. 目的と論文との関係

* ART は span (1段で消費するビット数) が 8 で固定。キーが疎だと下の段の fan-out が小さくなり、木が深くなる。
* HOT は逆に **fan-out の上限 k を固定し、span をノードごとに変える**。k = 32。
* 2分の Patricia trie を作り、その節 (BiNode) を最大 31 個ずつまとめて 1 つのノードにする。
* まとめ方は「木の高さが最小になる」ように、挿入のたびに局所的に調整する。
* 論文 (B-Trees Are Back) では 6.1 節の比較対象。
  * 文字列 lookup は適応型 B-Tree と同程度 (5% 速い〜14% 遅い)。
  * HOT は値として 63 ビットの TID しか持たない。キーは TID から取り出せる必要がある。論文ではヒープ上のタプルへのポインタを TID にしている。
  * HOT は**最大キー長をコンパイル時に固定**する。論文では整数 4 バイト、文字列 256 バイト。

## 2. 先に決めること (実装方針)

原典をそのまま移すと分かりにくい点が多い。以下の方針で書く。原典との差は 15 節にもまとめる。

| 項目 | この資料の方針 | 原典 (コード) |
|---|---|---|
| ビット番号 | 絶対ビット位置 `a = 8 * byte + bit`。`bit` は 0 = バイトの最上位ビット。**小さいほど上位** | 同じ |
| キー | 256 バイトの固定長バッファに 0 埋めして扱う。キーに 0x00 を含めない | 同じ (`toFixSizedKey`) |
| 8バイト窓の読み方 | **ビッグエンディアン** (`load_be_u64`) | リトルエンディアンで読み、マスクのビット番号を `8*relByte + 7 - bit` にする |
| 部分キーの並び | 上位のビット位置ほど部分キーの上位ビット。**部分キーはエントリ順に厳密に増加する** | バイトをまたぐと整数順にならない (コードのコメントで明言) |
| 葉と子ノードの区別 | 子ポインタの最下位ビット。葉 = `(tid << 1) | 1` | 同じ。論文本文は「最上位ビット」と書いている |
| ノードの作り直し | 編集は一度「論理ノード」に展開し、作り直して詰め直す | 型ごとのテンプレートで直接コピーと再符号化 |

ビッグエンディアンにする理由。

* 部分キーが整数として増加列になる。分割点が「最上位ビットが立っている最初のエントリ」で決まり、検査も簡単になる。
* PEXT の結果のビット順を考えずに済む。

## 3. 論理モデル: BiNode と複合ノード

### 3.1 2分 Patricia trie

* 各内部節 (BiNode) は 1 つの**判別ビット位置** (discriminative bit) を持つ。
* そのビットが 0 のキーは左、1 のキーは右の部分木に入る。
* 子が 1 つしかない節は作らない (path compression)。
* 根から葉に向かうと、判別ビット位置は**厳密に増加する** (下位のビットへ進む)。

```
キー (5ビット):  v1=00101  v2=00110  v3=01100  v4=11000
          (bit0)
          /    \
      (bit1)    v4
      /   \
   (bit3)  v3
   /   \
  v1    v2
```

### 3.2 複合ノード (k-constrained)

* HOT のノードは、この 2分木を**連結な部分木**に切り分けたもの。1ノードに BiNode 最大 k-1 = 31 個、エントリ (葉か子ノード) 最大 k = 32 個。
* エントリ = ノードの部分木の「下端」。TID (葉) か、別の HOT ノードへのポインタ。
* **高さ** h: 葉は 0。ノードは「子の高さ + 1」以上。
* 目標は木全体の高さ (根の h) を最小にすること。B-Tree と同じく、**根を新しく作るときだけ高さが増える**。

## 4. 部分キー (sparse partial key)

ノード内の BiNode の判別ビット位置の集合を D とする (|D| ≤ 31)。

* **dense 部分キー**: キーから D の各ビットを取り出して並べたもの。探索キーに対して作る。
* **sparse 部分キー**: エントリごとに保存する値。根からそのエントリまでの経路上の BiNode のビットだけを取り出し、**それ以外は 0** にしたもの。

3.1 の例 (D = {0,1,3}, 部分キーは bit0 が最上位):

| エントリ | 経路 | sparse 部分キー (bit0 bit1 bit3) |
|---|---|---|
| v1 | bit0=0, bit1=0, bit3=0 | `000` |
| v2 | bit0=0, bit1=0, bit3=1 | `001` |
| v3 | bit0=0, bit1=1 | `010` |
| v4 | bit0=1 | `100` |

**探索規則** (コードで確認: `SparsePartialKeys::search` と `HOTSingleThreadedNodeBase::toResultIndex`)。

```
エントリ i が一致  ⇔  (pk[i] & dense) == pk[i]
結果 = 一致したエントリのうち、添字が最大のもの
```

* 正しい理由: 探索キーの経路上のエントリ e は、自分の 1 ビットがすべて dense にも立っているので一致する。
* e より右のエントリ j は、e と分かれる BiNode で 1 を持つ。dense ではそこが 0 なので一致しない。
* e より左のエントリは一致することがある。だから「最大の添字」を取る。
* `pk[0]` は常に 0 なので、一致は必ず 1 つ以上ある。
* 論文の Listing 2 は `clz` と書いているが、コードは「`used_mask & 一致マスク` の最上位ビットの位置」を取る。

**sparse にする理由**: 新しい判別ビットが増えても、既存エントリの新ビットを「元のキーを読み直さずに」決められる (9.2 節)。

**隣接エントリの性質** (ビット集合としての性質なので、部分キーのビット配置によらず成り立つ。原典の `getRelevantBitsForRange` もこれに頼っている。整数として増加列になることだけがビッグエンディアン方式に固有)。

* `pk[i] & !pk[i-1]` はちょうど 1 ビット。それは i-1 と i を分ける BiNode のビット。
* 理由: 分かれる BiNode では i-1 が 0、i が 1。i はその右部分木の最左なので、それより下のビットは全部 0。
* よって `relevant(range) = OR_{i in range, i > first} (pk[i] & !pk[i-1])` が、範囲内の BiNode のビット集合になる (コード: `getRelevantBitsForRange`)。

## 5. データ配置

### 5.1 子ポインタ (8バイト)

```
葉:      [ TID (63 bit)                          | 1 ]
ノード:  [ ノードのアドレス (32 バイト境界) | layout (4 bit) | 0 ]
          63                                 5      1      0
```

```rust
#[derive(Clone, Copy, PartialEq, Eq)]
struct ChildPtr(u64);          // 0 は「空の木」専用

impl ChildPtr {
    const EMPTY: ChildPtr = ChildPtr(0);
    fn leaf(tid: u64) -> Self { debug_assert!(tid < 1 << 63); ChildPtr((tid << 1) | 1) }
    fn is_leaf(self) -> bool { self.0 & 1 == 1 }
    fn tid(self) -> u64 { self.0 >> 1 }
    fn layout(self) -> Layout9 { Layout9::from_u8(((self.0 >> 1) & 0xF) as u8) }
    // strict provenance: 実際には *mut NodeHeader を持ち、map_addr でタグを付け外しする。
    fn node(self) -> *mut NodeHeader { todo!("addr & !0x1F に戻す (strict provenance API)") }
}
```

* ノードは 32 バイト境界に置く。下位 5 ビットが空くので、葉フラグ 1 ビット + layout 4 ビットが入る。
* layout をポインタに入れるのは原典の最適化 (論文 4.5)。ノードを読む前に型が分かり、分岐予測ミスとキャッシュミスが重なる。

### 5.2 ノード

```rust
#[repr(C, align(32))]
struct NodeHeader {            // offset
    height: u16,               // 0   高さ (>= 1)
    n: u8,                     // 2   エントリ数 2..=32
    layout: u8,                // 3   Layout9 (ポインタのタグと同じ値)
    used_mask: u32,            // 4   下位 n ビットが 1
    msb_bit: u16,              // 8   D の最小の絶対ビット位置 (= 根 BiNode のビット)
    nbits: u8,                 // 10  |D| (1..=31)
    _pad: [u8; 5],             // 11
}                              // 16 バイト
// この後に: ビット位置部 → 部分キー配列 → 値配列 (8 バイト境界)
```

ビット位置部は 2 種類 (論文 Figure 6)。

```
single-mask:  [offset: u8][pad 7][mask: u64]                      16 B
multi-mask m: [offsets: u8 × m][masks: u8 × m]                     2m B  (m = 8, 16, 32)
```

* **single-mask**: キーの `offset` バイト目から 8 バイトを読み、64 ビットのマスクで PEXT する。D の最上位と最下位のバイト差が 8 未満のとき使える。
* **multi-mask**: D のビットを含むバイトを最大 m 個集め、各バイトに 8 ビットのマスクを持つ。

部分キー配列は 8 / 16 / 32 ビット幅。組み合わせは 9 種類 (論文 Figure 6)。

| layout | ビット位置部 | 部分キー | n | 論文のサイズ |
|---|---|---|---|---|
| SM_8 | single | u8 | 2–32 | 64–320 B |
| SM_16 | single | u16 | 9–32 | 128–352 B |
| SM_32 | single | u32 | 17–32 | 240–416 B |
| MM8_8 | 8 バイト | u8 | 3–32 | 72–328 B |
| MM8_16 | 8 バイト | u16 | 9–32 | 136–360 B |
| MM8_32 | 8 バイト | u32 | 17–32 | 248–424 B |
| MM16_16 | 16 バイト | u16 | 9–32 | 152–376 B |
| MM16_32 | 16 バイト | u32 | 17–32 | 264–440 B |
| MM32_32 | 32 バイト | u32 | 17–32 | 296–472 B |

* 12 通りでなく 9 通りなのは、MM16 なら 8 バイト超 → 8 ビット超、MM32 なら 16 バイト超 → 16 ビット超、となるため。
* n とサイズの列は論文 Figure 6 の値をそのまま写したもの。実装では「その layout が現れうる範囲」の目安として読めばよい。
* **コードとの差**: コードの `NodeType` は 8 種類で、MM16_32 がない。16 バイト以下でも 16 ビットを超えると MM32_32 にする (`ToDiscriminativeBitsRepresentation<MultiMaskPartialKeyMapping<2>, uint32_t>` → `<4>`)。

```
ノード全体 (SM_8, n = 5 の例)
+--------+---------+------------------------+-------------------------+
| header | offset  | pk[0..5] (5 B) + 余白   | value[0..5] (5 × 8 B)    |
| 16 B   | +mask   | SIMD 用に読み出し可能   | 8 バイト境界             |
+--------+---------+------------------------+-------------------------+
```

* 値配列は**ちょうど n 個**。編集のたびに作り直す (copy-on-write)。
* SIMD で 32 レーンを一度に読むので、部分キー配列の先頭から `32 * size_of::<P>()` バイトが**同じ割り当ての中**にあるようにする。値配列にはみ出して読むのは構わない (結果は `used_mask` で消す)。割り当ての外を読むのは UB。

### 5.3 layout の選び方

```rust
enum PkWidth { W8, W16, W32 }
enum BitRepr { Single { offset: u8, mask: u64 }, Multi { offsets: Vec<u8>, masks: Vec<u8> } }

/// bits: D を昇順 (上位ビットから) に並べたもの。1..=31 個 (編集途中は 32 個まで)。
fn choose_layout(bits: &[u16]) -> (BitRepr, PkWidth) {
    let nbits = bits.len();
    let mut w = if nbits <= 8 { PkWidth::W8 } else if nbits <= 16 { PkWidth::W16 } else { PkWidth::W32 };
    let first_byte = bits[0] / 8;
    let last_byte = bits[nbits - 1] / 8;
    if last_byte - first_byte < 8 {
        let offset = last_byte.saturating_sub(7);            // コード: max(0, lsbByte - 7)
        let mut mask = 0u64;
        for &a in bits {
            let rel = a - offset * 8;                        // 0..64
            mask |= 1u64 << (63 - rel);                      // ビッグエンディアン方式
        }
        return (BitRepr::Single { offset: offset as u8, mask }, w);
    }
    // バイトごとにまとめる (昇順)
    let (offsets, masks) = group_by_byte(bits);              // masks[i] のビット 7 = バイト内 bit 0
    let m = offsets.len();
    if m > 16 { w = PkWidth::W32 } else if m > 8 && matches!(w, PkWidth::W8) { w = PkWidth::W16 }
    (BitRepr::Multi { offsets, masks }, w)                   // m を 8/16/32 に切り上げて配置する
}
```

* offset を `last_byte - 7` にするのは、8 バイト窓がキー末尾 (256 バイト) を越えないため。
* layout は**作り直すたびにゼロから選び直す**。原典は挿入時に段階的に昇格させるが、毎回最小を選んでも結果は正しい (簡略化として 15 節に記載)。

## 6. 不変条件

ノードごと。

1. `2 <= n <= K` (K = 32)、`used_mask == (1 << n) - 1` (n = 32 のときのシフトに注意)。
2. `pk[0] == 0`。
3. `pk[i-1] < pk[i]` (ビッグエンディアン方式のときのみ。原典の配置では成り立たない)。
4. `i >= 1` で `popcount(pk[i] & !pk[i-1]) == 1`。
5. D = 4 で出てくるビットの和集合。`nbits <= 31`。layout は 5.3 の最小のもの。
6. すべての i で `search_pk(pk[i]) == i` (自分の部分キーで検索すると自分に当たる。原典が `getInsertInformation` で assert している性質。layout によらない)。
7. 子ノード c について `height(c) < height(node)`。
8. エントリ i の部分木に入るすべてのキーは、i の経路上の各 BiNode のビットについて、`pk[i]` と同じ値を持つ。
9. `msb_bit == bits[0]`、かつ子ノードの `msb_bit` は親の経路上のどのビットより大きい。

木全体。

* 葉を左から順に読むとキーが厳密に増加する。
* 同じキーは 2 回現れない。
* **注意**: 「`height(node) == 1 + max(height(子))`」は成り立つとは限らない。分割で生じた半分のノードは元の高さを引き継ぐため (コード: `compressEntries` は `sourceNode.mHeight` を使う)。検査は 7 の不等式にとどめる。

## 7. 部品: pext / pdep と部分キーの抽出・検索

### 7.1 pext / pdep

```rust
/// x の、mask で 1 のビットを下位へ詰めて返す。BMI2 の PEXT と同じ。
fn pext_u64(x: u64, mut mask: u64) -> u64 {
    #[cfg(target_arch = "x86_64")]
    if is_x86_feature_detected!("bmi2") {       // 実際は起動時に 1 回だけ判定して関数ポインタを選ぶ
        return unsafe { core::arch::x86_64::_pext_u64(x, mask) };
    }
    let (mut out, mut k) = (0u64, 0);
    while mask != 0 {
        let low = mask & mask.wrapping_neg();     // 最下位の 1
        if x & low != 0 { out |= 1 << k; }
        k += 1;
        mask &= mask - 1;
    }
    out
}

/// x の下位ビットから順に、mask で 1 の位置へ配る。BMI2 の PDEP と同じ。
fn pdep_u64(x: u64, mut mask: u64) -> u64 {
    let (mut out, mut k) = (0u64, 0);
    while mask != 0 {
        let low = mask & mask.wrapping_neg();
        if (x >> k) & 1 != 0 { out |= low; }
        k += 1;
        mask &= mask - 1;
    }
    out
}
```

* 【未検証: 一般に知られている話で、この資料の出典では確認していない】AMD Zen 1/2 の PEXT/PDEP はマイクロコード実装で非常に遅い。ベンチマーク環境の CPU を記録する。
* aarch64 には同等命令がない (SVE2 の BEXT/BDEP は別)。ソフトウェア版で正しく動くことを先に確かめる。

### 7.2 dense 部分キーの抽出

```rust
/// key: 256 バイトに 0 埋めした探索キー。戻り値の下位 nbits ビットが dense 部分キー。
fn extract(node: &Node, key: &[u8; 256]) -> u32 {
    match node.bit_repr() {
        BitRepr::Single { offset, mask } => {
            let w = load_be_u64(key, offset as usize);
            pext_u64(w, mask) as u32
        }
        BitRepr::Multi { offsets, masks } => {
            // 8 バイトずつ「語」にまとめ、語ごとに PEXT して上位から連結する。
            let mut out = 0u64;
            for chunk in 0..offsets.len().div_ceil(8) {
                let (mut w, mut m) = (0u64, 0u64);
                for j in 0..8 {
                    let i = chunk * 8 + j;
                    if i >= offsets.len() { break; }
                    w |= (key[offsets[i] as usize] as u64) << (56 - 8 * j);   // ビッグエンディアン
                    m |= (masks[i] as u64) << (56 - 8 * j);
                }
                out = (out << m.count_ones()) | pext_u64(w, m);
            }
            out as u32
        }
    }
}
```

* 原典の MM8 は `keyParts` のバイト i に `key[offsets[i]]` を入れる (リトルエンディアン)。MM16/32 は SIMD のシャッフルでバイトを集め、2 回 / 4 回 PEXT する。
* 語ごとのマスク `m` はノード作成時に前計算しておく。上のループは説明用。

### 7.3 部分キーの検索 (SIMD)

```rust
/// 一致マスクを返す。ビット i = エントリ i が一致。
fn search_mask(node: &Node, dense: u32) -> u32 {
    let mut m = 0u32;
    for i in 0..node.n() {
        let pk = node.pk(i);                 // u8/u16/u32 を u32 に広げたもの
        if pk & dense == pk { m |= 1 << i; }
    }
    m & node.used_mask()
}

fn search_index(node: &Node, dense: u32) -> usize {
    let m = search_mask(node, dense);
    debug_assert!(m & 1 == 1);               // pk[0] == 0 なので必ず立つ
    31 - m.leading_zeros() as usize          // 最上位の 1 = 最大の添字
}
```

AVX2 版 (8 ビット部分キー)。16 / 32 ビットは 2 / 4 レジスタに分けて同じことをし、`packs` で 8 ビットに詰めてから movemask する (コード: `SparsePartialKeys<uint16_t/uint32_t>::search`)。

```rust
// unsafe: pk8 から 32 バイトが割り当て内 (5.2)。avx2 が有効。
unsafe fn search_mask_u8_avx2(pk8: *const u8, dense: u8, used: u32) -> u32 {
    let hay = _mm256_loadu_si256(pk8 as *const __m256i);
    let key = _mm256_set1_epi8(dense as i8);
    let sel = _mm256_and_si256(hay, key);
    let eq  = _mm256_cmpeq_epi8(sel, hay);
    (_mm256_movemask_epi8(eq) as u32) & used
}
```

## 8. lookup

```rust
trait KeySource { fn key_of(&self, tid: u64) -> &[u8]; }   // TID から完全なキーを得る

fn lookup(root: ChildPtr, key: &[u8], src: &impl KeySource) -> Option<u64> {
    if root == ChildPtr::EMPTY { return None; }
    let kbuf = pad256(key);                          // 0 埋めした [u8; 256]
    let mut cur = root;
    while !cur.is_leaf() {
        let node = node_ref(cur);                    // layout はポインタのタグから
        prefetch_node(node.as_ptr(), 4 * CACHE_LINE);   // 論文 4.5: 先頭 4 ライン
        let i = search_index(node, extract(node, &kbuf));
        cur = node.value(i);
    }
    let tid = cur.tid();
    // Patricia trie は途中のビットしか見ないので、最後に必ず全体を比べる。
    if src.key_of(tid) == key { Some(tid) } else { None }
}
```

* 最後の比較を省くと、存在しないキーで別のキーの TID を返す (偽陽性)。
* 論文 (B-Trees Are Back) が指摘する点: HOT の原論文はこの「タプルを読みに行く」コストを測っていなかった。

## 9. ノード内の編集: ビットの追加・エントリの追加・分割

編集は「論理ノード」に展開して行い、最後に 5.3 で layout を選んで詰め直す。

```rust
struct LNode {
    height: u16,
    bits: Vec<u16>,          // D の絶対ビット位置 (昇順)
    pks: Vec<u64>,           // 部分キー。ビット (W-1-r) = bits[r] (W = bits.len())。編集中は 32 ビットを超えうるので u64
    vals: Vec<ChildPtr>,
}

fn decode(p: ChildPtr) -> LNode;            // 物理ノード → LNode (部分キーは u64 に広げるだけ)
fn encode(ln: &LNode) -> ChildPtr;          // n == 1 なら呼ばない。layout を選び、ちょうど n 個で確保
fn rank_mask(ln: &LNode, r: usize) -> u64 { 1u64 << (ln.bits.len() - 1 - r) }
```

### 9.1 新しいビットを D に加える (全部分キーの再符号化)

```rust
/// bit を D に加え、そのビットに対応する部分キー上のマスクを返す。
fn add_bit(ln: &mut LNode, bit: u16) -> u64 {
    let w = ln.bits.len();
    match ln.bits.binary_search(&bit) {
        Ok(r) => rank_mask(ln, r),                       // すでにある: 再符号化しない
        Err(r) => {
            // 新しい幅 w+1 で、ビット位置 (w - r) に 0 を差し込む。
            let all = (1u64 << (w + 1)) - 1;
            let newbit = 1u64 << (w - r);
            let conv = all & !newbit;
            for pk in ln.pks.iter_mut() { *pk = pdep_u64(*pk, conv); }
            ln.bits.insert(r, bit);
            newbit
        }
    }
}
```

* 論文 4.4 の例: 5 ビット {3,4,6,8,9} に bit 7 を足すと `_pdep_u32(pk, 0b111011)`。この資料の並びでも同じマスクになる (bit 7 は上から 4 番目に入り、w = 5, r = 3 なので `newbit = 0b000100`, `conv = 0b111011`)。
* コード: `getConversionInformation` が `conversionMask = 新しい全ビット & !追加ビット (ビットが新規のときだけ)`、`additionalMask = 追加ビットのマスク` を作る。

### 9.2 影響を受けるエントリ (affected subtree)

新しい BiNode をどこに差し込むかを、BiNode を明示的に持たずに求める。

```rust
/// entry: 探索で到達したエントリ。bit: 新しい判別ビット (D に追加済み)。
/// 戻り値: 新 BiNode の下に入る既存エントリの範囲 [first, first + count)。
fn affected_range(ln: &LNode, entry: usize, bit: u16) -> (usize, usize, u64) {
    // bit より上位の D のビット = 新 BiNode の祖先が使いうるビット
    let r = ln.bits.partition_point(|&b| b < bit);
    let w = ln.bits.len();
    let prefix_bits = ((1u64 << w) - 1) & !((1u64 << (w - r)) - 1);   // 上位 r ビット
    let prefix = ln.pks[entry] & prefix_bits;
    let idx: Vec<usize> = (0..ln.pks.len()).filter(|&i| ln.pks[i] & prefix_bits == prefix).collect();
    (idx[0], idx.len(), prefix)            // 一致は必ず連続する
}
```

* 正しい理由: 範囲外のエントリは、新 BiNode の祖先のどれかで entry と逆の値を持つ。祖先のビットは bit より上位なので `prefix_bits` に含まれる。
* 範囲内の BiNode のビットはすべて bit より下位なので、`prefix_bits` に入らない。
* コード: `getInsertInformation` (`getPrefixBitsMask` + `getAffectedSubtreeMask`)。

### 9.3 エントリを 1 つ追加する

新しいキーの bit の値を `v` (0 / 1) とする。

```rust
fn add_entry(ln: &mut LNode, entry: usize, bit: u16, v: bool, newval: ChildPtr) {
    let m = add_bit(ln, bit);
    let (first, count, prefix) = affected_range(ln, entry, bit);
    let at;
    if v {
        // 新キーは右。既存の影響エントリは新ビット = 0 のまま。
        at = first + count;
        ln.pks.insert(at, prefix | m);
    } else {
        // 新キーは左。既存の影響エントリに新ビット = 1 を立てる。
        for i in first..first + count { ln.pks[i] |= m; }
        at = first;
        ln.pks.insert(at, prefix);
    }
    ln.vals.insert(at, newval);
    ln.pks[0] = 0;                 // コードも毎回 0 に戻す。v=0, first=0 のときは prefix=0 なので元から 0
}
```

```
例: D={0,1,3} の 3.1 のノードに、新キー 00000 を入れる
  探索: dense = 000。pk ⊆ 000 となるのは v1 (000) だけなので v1 に着く
  v1 = 00101 との最初の違いは bit 2。新キー側の値 v = 0
  bit 2 は bits の 3 番目 (r = 2) → 幅 4、新ビットのマスク m = 0b0010
  再符号化 (pdep, conv=0b1101):  v1 000→0000  v2 001→0001  v3 010→0100  v4 100→1000
  affected: prefix_bits = 上位 2 ビット (bit0, bit1) = 0b1100。v1 の prefix = 0b0000
            → 一致するのは v1, v2 (first=0, count=2)
  v=0 なので、影響エントリに m を立て (v1 0010, v2 0011)、新エントリは添字 0、pk = prefix = 0b0000
  結果: new 0000, v1 0010, v2 0011, v3 0100, v4 1000
  検査: 隣接差 0010, 0001, 0100, 1000 はすべて 1 ビット。増加列。pk[0] = 0
```

### 9.4 範囲の圧縮と分割

```rust
/// [first, first+len) を独立したノード (または単独エントリ) にする。
fn compress(ln: &LNode, first: usize, len: usize) -> ChildPtr {
    if len == 1 { return ln.vals[first]; }               // 1 エントリのノードは作らない
    let mut rel = 0u64;
    for i in first + 1..first + len { rel |= ln.pks[i] & !ln.pks[i - 1]; }
    let w = ln.bits.len();
    let bits = (0..w).filter(|&r| rel & rank_mask(ln, r) != 0).map(|r| ln.bits[r]).collect();
    let pks: Vec<u64> = (first..first + len).map(|i| pext_u64(ln.pks[i], rel)).collect();
    debug_assert!(pks[0] == 0);
    encode(&LNode { height: ln.height, bits, pks, vals: ln.vals[first..first + len].to_vec() })
}

struct BiNode { bit: u16, height: u16, left: ChildPtr, right: ChildPtr }

/// 根 BiNode で 2 つに割る。根 BiNode は D の最上位ビット。
fn split(ln: &LNode) -> BiNode {
    let top = rank_mask(ln, 0);
    let j = ln.pks.iter().position(|&pk| pk & top != 0).unwrap();   // 右半分の先頭
    BiNode {
        bit: ln.bits[0],
        height: ln.height + 1,
        left: compress(ln, 0, j),
        right: compress(ln, j, ln.pks.len() - j),
    }
}

fn two_entry_node(b: &BiNode) -> ChildPtr {
    encode(&LNode { height: b.height, bits: vec![b.bit], pks: vec![0, 1], vals: vec![b.left, b.right] })
}

/// 既存の部分木 existing と新しい葉を、判別ビット bit で分ける BiNode。
fn binode_from(bit: u16, v: bool, existing: ChildPtr, newleaf: ChildPtr) -> BiNode {
    let height = height_of(existing) + 1;             // 葉は 0
    if v { BiNode { bit, height, left: existing, right: newleaf } }
    else { BiNode { bit, height, left: newleaf, right: existing } }
}
```

* 分割の半分は**元のノードの高さを引き継ぐ** (コードと同じ)。半分が 1 エントリなら、そのエントリ (葉でもよい) をそのまま使う。
* コード: `split` は先に半分に割ってから、影響範囲のある側に新エントリを足す (`compressEntriesAndAddOneEntryIntoNewNode`)。この資料は「33 エントリの論理ノードを作ってから割る」。新 BiNode が根 BiNode より下にあるとき (10 節の条件) は同じ結果になる。

## 10. insert

### 10.1 4 つのケース (論文 3.2, Figure 4, Listing 1)

| ケース | 条件 | 処理 |
|---|---|---|
| normal insert | 影響ノードに空きがある | ノードに BiNode を 1 つ足す (9.3) |
| leaf-node pushdown | 不一致 BiNode が葉で、ノードの高さ > 1 | 葉を「葉 + 新キー」の 2 エントリノードに置き換える |
| parent pull-up | 溢れたノード n で `h(n) + 1 == h(親)` | n を根 BiNode で割り、その BiNode を親に足す。親が溢れたら再帰。根なら新しい根 |
| intermediate node creation | 溢れたノード n で `h(n) + 1 < h(親)` | 根 BiNode を新しい中間ノード (2 エントリ) にして、親の該当エントリを置き換える |

コードではこれらが 1 つの判定にまとまっている。BiNode (高さ hb) を、親 P のエントリ e の位置に組み込むとき、次のように分ける。

* `h(P) > hb` なら、新しい 2 エントリノードで置き換える。これが pushdown または中間ノード作成。
* `h(P) == hb` なら、P に取り込む (pull-up)。溢れたら P を割って上へ。
* P がない (根) なら、新しい根を作る。

### 10.2 擬似コード

最大 fan-out は定数 `K` (原典は 32。テストで小さくできるように引数にしておく。`K <= 32`)。

```rust
const K: usize = 32;

struct Frame { slot: *mut ChildPtr, node: ChildPtr, entry: usize, msb: u16 }

fn insert(root: &mut ChildPtr, tid: u64, src: &impl KeySource) -> bool {
    let newleaf = ChildPtr::leaf(tid);
    let key = pad256(src.key_of(tid));
    if *root == ChildPtr::EMPTY { *root = newleaf; return true; }
    if root.is_leaf() {
        let Some((bit, v)) = first_mismatch(&pad256(src.key_of(root.tid())), &key) else { return false };
        *root = two_entry_node(&binode_from(bit, v, *root, newleaf));
        return true;
    }

    // 1. 降りながらスタックを積む
    let mut stack: Vec<Frame> = Vec::new();
    let mut slot: *mut ChildPtr = root;
    while unsafe { !(*slot).is_leaf() } {
        let node = unsafe { *slot };
        let i = search_index(node_ref(node), extract(node_ref(node), &key));
        stack.push(Frame { slot, node, entry: i, msb: node_ref(node).msb_bit() });
        slot = node_ref(node).value_slot(i);
    }
    let leaf = unsafe { *slot };
    let leaf_depth = stack.len();

    // 2. 到達した葉のキーと比べ、最初に違うビットを求める
    let Some((bit, v)) = first_mismatch(&pad256(src.key_of(leaf.tid())), &key) else { return false };

    // 3. 新 BiNode が入るノードの深さ d を決める
    //    子ノードの根ビットより bit が下位である限り、さらに下へ (葉の msb は +∞ 扱い)
    let mut d = 0;
    while d + 1 < leaf_depth && bit > stack[d + 1].msb { d += 1; }

    let f = &stack[d];
    let ln = decode(f.node);
    let mut tmp = ln.clone();
    add_bit(&mut tmp, bit);
    let (_first, count, _) = affected_range(&tmp, f.entry, bit);

    if count == 1 && d + 1 == leaf_depth {
        // (a) 影響は葉 1 つだけ: 高さ 1 の BiNode を、このノードのエントリ位置に組み込む
        integrate(&mut stack, d + 1, binode_from(bit, v, leaf, newleaf), root);
    } else if count == 1 {
        // (b) 影響は子ノード C 1 つだけ: C の新しい根 BiNode にする
        let c = stack[d + 1].node;
        if node_ref(c).n() < K {
            let mut lc = decode(c);
            add_entry(&mut lc, 0, bit, v, newleaf);      // bit は C の全ビットより上位 → 全エントリが影響
            replace(stack[d + 1].slot, encode(&lc));     // 旧 C を解放
        } else {
            integrate(&mut stack, d + 1, binode_from(bit, v, c, newleaf), root);
        }
    } else if ln.pks.len() < K {
        // (c) normal insert
        let mut l = ln; add_entry(&mut l, f.entry, bit, v, newleaf);
        replace(f.slot, encode(&l));
    } else if bit > f.msb {
        // (d) 満杯で、新 BiNode は根 BiNode より下: 足してから根で割る
        let mut l = ln; add_entry(&mut l, f.entry, bit, v, newleaf);
        let b = split(&l);                               // 高さ h(N)+1
        integrate(&mut stack, d, b, root);               // 旧 N を解放
    } else {
        // (e) 満杯で、新 BiNode が N 全体の上に来る: N を丸ごと片側にする
        integrate(&mut stack, d, binode_from(bit, v, f.node, newleaf), root);
    }
    true
}
```

```rust
/// BiNode b を、深さ depth のスロット (= stack[depth-1] のエントリ) に組み込む。
fn integrate(stack: &mut [Frame], depth: usize, b: BiNode, root: &mut ChildPtr) {
    if depth == 0 { *root = two_entry_node(&b); return; }      // 新しい根: 木の高さ +1
    let p = &stack[depth - 1];
    let hp = node_ref(p.node).height();
    if hp > b.height {
        // leaf-node pushdown / intermediate node creation
        unsafe { *node_ref_mut(p.node).value_slot(p.entry) = two_entry_node(&b); }
        return;
    }
    debug_assert!(hp == b.height);
    // parent pull-up: エントリ e を (left, right) の 2 つに置き換える
    let mut lp = decode(p.node);
    add_entry(&mut lp, p.entry, b.bit, true, b.right);   // 右を e の直後に足す (影響は e だけ)
    lp.vals[p.entry] = b.left;
    if lp.pks.len() <= K {
        replace(p.slot, encode(&lp));
    } else {
        let nb = split(&lp);                              // 高さ hp + 1
        integrate(stack, depth - 1, nb, root);
    }
    // いずれも旧 P は解放する
}

/// 最初に違うビット。(絶対ビット位置, 新キー側のビット値)。同じなら None。
fn first_mismatch(existing: &[u8; 256], new: &[u8; 256]) -> Option<(u16, bool)> {
    for j in 0..256 {
        let x = existing[j] ^ new[j];
        if x != 0 {
            let b = x.leading_zeros() as u16;            // 0 = 最上位ビット
            return Some((8 * j as u16 + b, new[j] & (0x80 >> b) != 0));
        }
    }
    None
}
```

* (a) の `integrate` は、親 (= 深さ d のノード) の高さが 1 なら取り込み、2 以上なら pushdown になる。論文の normal insert と leaf-node pushdown がここで分かれる。
* (b) を子に入れるのはコードの選択 (`insertNewValueResultingInNewPartitionRoot`)。境界の BiNode は親ノードにも子ノードにも置けるが、子に置けば親の fan-out を使わない。
* (d) の条件 `bit > msb` は「新 BiNode が根 BiNode の下にある」こと。そうでなければ (e)。
* 深さ d を決めるループの比較で `bit == msb` は起きない。探索キーは各 BiNode で自分のビットの側へ進むので、到達した葉とは経路上のビットで一致している。
* pull-up で `add_entry(..., v = true, ...)` の影響範囲がエントリ e 1 つになる理由: b.bit は e の上の BiNode より下位で、e はその側をまるごと占めている。

### 10.3 copy-on-write とメモリ

* 部分キーの追加は既存ノードを書き換えず、新しいノードを作って親のスロットを差し替える。旧ノードはその後に解放する。
* pushdown / 中間ノード作成では、親のスロット 1 つを書き換えるだけ (コードも in-place)。
* Rust: ノードは `alloc_aligned(size, 32)` で確保し、`Layout` はヘッダの n と layout から再計算できるようにする。`Box` は使わない (可変長のため)。
* 並行版では「スロット差し替え」を原子的に行い、旧ノードをエポックで回収する。単一スレッドなら即時解放でよい。

## 11. delete (要約)

論文 3.2 末尾とコード (`HOTSingleThreaded::remove`, `getDeletionInformation`, `removeEntry`, 合併処理) の要約。完全な擬似コードは書かない。

1. lookup と同じく降りて葉を見つけ、キー全体を比べる。違えば false。
2. 葉のエントリ i をノード N から除く。
   * i の親 BiNode が消える。兄弟側の部分木のエントリから、その BiNode のビットを 0 にする (コード: `deleteUnusedBitMask`)。
   * 残るエントリについて `relevant` (4 節) を計算し直し、D を縮めて `pext` で詰め直す (コード: `getRelevantBitsForAllExceptOneEntry`)。
3. N が 1 エントリになったら、N を消して親のスロットにそのエントリを直接入れる。
4. 下限割れ (underflow) の扱いは挿入の逆。
   * 隣のノードと合わせて 32 以下なら合併する (pushdown の逆)。
   * または、親に直接リンクを移す (中間ノード作成の逆)。
5. 削除の仕方と簡略化: 4 を省いても正しさは保たれる。木が少し高くなるだけ。**この資料の推奨は 1〜3 だけを実装すること** (15 節)。

btree-cpp の HOT アダプタは remove を実装していない (`abort()`)。論文のベンチマークに削除は出てこない。

## 12. scan と lower_bound

### 12.1 イテレータ

* スタックに `(ノード, 現在の添字)` を積む。最大の深さは 64 で足りる (コードの `insertStack` も 64)。
* `next`: 一番深いノードの添字を進める。溢れたら pop して親の添字を進める。そこから最左の葉まで降りる。
* 各ノードのエントリはキー順に並んでいるので、これで昇順になる。

### 12.2 lower_bound (コード: `lower_or_upper_bound`)

1. lookup と同じく葉まで降りる。スタックを残す。
2. 葉のキー == 探索キーなら、その葉。
3. 違えば、最初に違うビット (bit, v) を求める。
4. insert の 3. と同じく、bit が入るノードの深さまでスタックを戻す。
5. そのノードで `affected_range(entry, bit)` を求める (D に bit がない場合も、9.2 は仮に足した D で計算すればよい)。
6. v = 0 (探索キーの方が小さい) なら、影響範囲の先頭エントリから最左の葉へ。
7. v = 1 (探索キーの方が大きい) なら、影響範囲の直後のエントリから最左の葉へ。範囲がノードの末尾まで来ていたら、親へ戻って次へ進む。

## 13. 境界条件と落とし穴

* **キーの終端**: 0 埋めで比べるので、`"ab"` と `"ab\0"` は区別できない。キーが互いの接頭辞にならないようにする ([04-trie-art.md](04-trie-art.md) 9 節、[02-key-encoding.md](02-key-encoding.md))。区別できないと、`first_mismatch` が None を返して「重複」と誤判定する。
* **最大キー長**: 256 バイト (B-Trees Are Back の記述。ビット位置は 0..2048 で u16 に収まる)。単一マスクの offset は u8 で、`last_byte - 7 <= 248` なので収まる。
  * 原典のコードの既定 `MAX_STRING_KEY_LENGTH` は 255 で、`strncpy` で固定長バッファにコピーする (`idx/contenthelpers/KeyUtilities.hpp:toFixSizedKey`)。それより長いキーは**黙って切り詰められ**、先頭 255 バイトが同じキーは区別できない。Rust 版では長すぎるキーを挿入時に拒否するか、バッファ長を定数引数にする。
* **8 バイト読みの範囲外**: `load_be_u64(key, offset)` は `offset + 8 <= 256` を満たす。可変長のスライスのまま読むとパニックか UB になるので、必ず 256 バイトのバッファにコピーする。
* **SIMD の読み過ぎ**: 5.2 のとおり、割り当ての中に収める。
* **u32 のシフト**: `(1u32 << n) - 1` は n = 32 でオーバーフロー。`u32::MAX >> (32 - n)` を使う。
* **論理ノードの幅**: 32 エントリのノードに足すと一時的に 33 エントリ・最大 32 ビットになる。部分キーを u64 で持つ理由。
* **pk[0] = 0 の維持**: 作り直すたびに強制する。忘れると「一致なし」で添字計算が壊れる。
* **TID の範囲**: 63 ビットまで。ポインタを TID にするなら、最上位ビットが 0 であることを assert する。
* **ノード種別の昇格・降格**: layout を毎回選び直すなら、16 ビットから 8 ビットに戻ることもある。原典は挿入では降格しない。
* **高さの計算**: 葉の高さは 0。`binode_from` で「既存の高さ + 1」、`split` で「ノードの高さ + 1」。ここを間違えると pushdown と pull-up の判定が逆になる。

## 14. テスト方針

### 14.1 オラクル比較

* `BTreeMap<Vec<u8>, u64>` を正解にする。TID はキーと値を持つタプルへの添字にする (`KeySource` はベクタ参照)。
* 操作列: insert (既存キーを含む) / lookup (存在しないキーを含む) / lower_bound + 数件の scan。delete を実装したら混ぜる。
* キーの生成: 次をすべて試す。
  * ランダムな 4 バイト整数 (ビッグエンディアン)。
  * 1..N の連番 (dense)。
  * 長い共通接頭辞を持つ文字列 (URL 風)。判別ビットが 8 バイト以上離れるので multi-mask が出る。
  * 1 バイトだけ違うキーの組。

### 14.2 不変条件チェッカー

各操作の後に、木全体を走査して 6 節を検査する。

* 各ノード: 1〜6, 9。とくに「すべての i で `search_index(pk[i]) == i`」。
* 各ノードの各エントリ i: その下の全葉のキーから dense 部分キーを作り、`search_index` が i を返すこと (不変条件 8 の検査)。
* 高さ: `height(子) < height(親)`。
* 葉の列がキー順で、件数がオラクルと一致すること。
* layout: `choose_layout(bits)` の結果と一致すること。

### 14.3 構造のテスト

* **k を小さくする**: 10.2 の `K` を 3 にして、normal insert / leaf-node pushdown / parent pull-up (新しい根を含む) / intermediate node creation の 4 ケースが**それぞれ 1 回以上起きる**ことを、ケースごとのカウンタで確かめる。
  * 論文 Figure 4 は可変長のビット列キー (0010, 010, 0011000, 1111) を使う。バイト列のキーにそのまま移すと形が一致するとは限らない。各ビット列を先頭から詰めて 1 バイトに入れ、残りを 0 にする…とすると "0010" と "00100" が同じになるので、末尾に 1 ビットの印を付けるなど符号化を決めてから比べる。
* **挿入順に依存しないか**: 同じキー集合を別の順で入れ、木の形 (ノードごとの bits と葉の並び) を比べる。論文は「実験上はそうなる」と予想しているだけなので、不一致は失敗でなく記録にとどめる。
* **高さの上限**: ランダムな 1M キーで、根の高さが `ceil(log_32(N))` 程度に収まるかを記録する。
* **再符号化の単体テスト**: 9.3 の例を表どおりに検査する。

## 15. 原典との違い・簡略化

* **ビッグエンディアン方式** (2 節): 原典はリトルエンディアンで 8 バイトを読み、部分キーはバイトをまたぐと整数順にならない。この資料では部分キーが増加列になる。探索規則と結果は同じ。
* **論理ノード経由の編集** (9 節): 原典は型ごとに直接コピーと再符号化を行う。この資料は展開 → 編集 → 再符号化。速度は落ちるが、正しさは同じ。
* **layout を毎回選び直す** (5.3): 原典は挿入時に段階的に昇格し、降格しない。
* **9 種類と 8 種類**: 論文は 9 種類、コードは 8 種類 (MM16_32 なし)。この資料は論文に従う。
* **分割の順序** (9.4): 原典は「割ってから片側に足す」。この資料は「足してから割る」。
* **葉の印**: 論文は最上位ビット、コードは最下位ビット。この資料はコードに従う。
* **探索結果の添字**: 論文 Listing 2 は `clz`。コードは「最上位の 1 の位置」。この資料はコードに従う。
* **delete**: 合併・リンク移動 (underflow 処理) を省略してよいとした。木の高さが最適でなくなるだけで、検索は正しい。
* **並行制御**: ROWEX を省略。
* **ノード先頭 4 ラインのプリフェッチ**: 論文 4.5。正しさには関係しない。
* 【未検証】5.2 の表の「n の下限」とサイズは論文 Figure 6 の値の転記。ヘッダの大きさが原典と違うので、この資料の配置ではサイズが一致しない。
* 【未検証】12.2 の lower_bound で、影響範囲がノード末尾まで続く場合の親への戻り方は、コードの `++it` の挙動から読み取ったもの。

## 16. 参考資料

* Binna, Zangerle, Pichl, Specht, Leis. "HOT: A Height Optimized Trie Index for Main-Memory Database Systems". SIGMOD 2018. https://dl.acm.org/doi/10.1145/3183713.3196896
  * 3.2 節 (insert の 4 ケース, Listing 1), 4.1〜4.4 節 (部分キー, Figure 5/6, Listing 2)。
* 参照実装: https://github.com/speedskater/hot
  * `commons/SparsePartialKeys.hpp`: `search`, `findMasksByPattern`, `getRelevantBitsForRange`, `getRelevantBitsForAllExceptOneEntry`, `determineValueOfDiscriminatingBit`
  * `commons/SingleMaskPartialKeyMapping.hpp`: `extractMask`, `getSuccessiveMaskForBit`, `convertToIndexOfOtherEndiness`, `insert`
  * `commons/MultiMaskPartialKeyMapping.hpp`: `extractMask`, `getPrefixBitsMask`
  * `commons/DiscriminativeBit.hpp`: `getMismatchingBit`, `executeForDiffingKeys`
  * `commons/NodeType.hpp`, `commons/BiNode.hpp`: `createFromExistingAndNewEntry`
  * `singlethreaded/HOTSingleThreaded.hpp`: `lookup`, `insert`, `insertWithInsertStack`, `insertNewValueIntoNode`, `insertNewValue`, `insertNewValueResultingInNewPartitionRoot`, `integrateBiNodeIntoTree`, `lower_or_upper_bound`
  * `singlethreaded/HOTSingleThreadedNode.hpp`: `searchForInsert`, `getInsertInformation`, `addEntry`, `split`, `compressEntries`, `getConversionInformation`, `getMaskForLargerEntries`
  * `singlethreaded/HOTSingleThreadedNodeBase.hpp`: `toResultIndex`
  * `singlethreaded/HOTSingleThreadedChildPointer.hpp`: `isLeaf`, `getTid` (タグ付け)
* 論文での使われ方: https://github.com/m-mueller678/btree-cpp `btree/hot_adapter.cpp` (`HotBTreeAdapter::lookupImpl`, `insertImpl`, `range_lookupImpl`)。
