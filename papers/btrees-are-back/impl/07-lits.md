# 07. learned index の基本と LITS

background.md の 3.6 を、自分で実装できる粒度まで書き下す。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* LITS は部分木として HOT を使う。HOT は [05-hot.md](05-hot.md) をそのまま使う前提で書く。
* `pext_u64` などの部品は 05-hot.md 7.1、`alloc_aligned` は [00-primitives.md](00-primitives.md) のものを名前で使う。

参照実装は著者の [schencoding/lits](https://github.com/schencoding/lits) の `LITS/lits/*.hpp` (VLDB 2024 版)。
論文 (B-Trees Are Back) は btree-cpp の `in-memory-structures/lits` に、このリポジトリのコミット `512688e` を取り込んで使っている。
アダプタは btree-cpp の `btree/lits_adapter.cpp`。
擬似コードは書き直したもので、コードの直訳ではない。

## 目次

1. [目的と論文との関係](#1-目的と論文との関係)
2. [learned index の基本](#2-learned-index-の基本)
3. [LITS の全体像](#3-lits-の全体像)
4. [データ配置](#4-データ配置)
5. [不変条件](#5-不変条件)
6. [HPT (Hash-enhanced Prefix Table)](#6-hpt-hash-enhanced-prefix-table)
7. [model-based node と位置の予測](#7-model-based-node-と位置の予測)
8. [GPKL と PMSS](#8-gpkl-と-pmss)
9. [bulkload](#9-bulkload)
10. [lookup](#10-lookup)
11. [insert と再構築](#11-insert-と再構築)
12. [delete (要約)](#12-delete-要約)
13. [scan と lower_bound](#13-scan-と-lower_bound)
14. [再学習と学習データの量](#14-再学習と学習データの量)
15. [境界条件と落とし穴](#15-境界条件と落とし穴)
16. [テスト方針](#16-テスト方針)
17. [原典との違い・簡略化](#17-原典との違い簡略化)
18. [参考資料](#18-参考資料)

---

## 1. 目的と論文との関係

* LITS は「キーの累積分布 (CDF) を学習して、キーの位置を計算で求める」索引の文字列版。
* 文字列は長く可変長で、接頭辞が偏っている。整数用の learned index をそのまま使うとうまく区別できない。LITS はこれに 3 つの工夫で対処する。
  1. 接頭辞ごとの次の文字の分布を表 (HPT) にして CDF を推定する。
  2. 小さな葉をまとめた compact leaf を使う。
  3. 学習が効きにくい部分を HOT に任せる (PMSS で判定)。
* 論文 (B-Trees Are Back) 6.3 節での扱い。
  * 値は 8 バイトを kv エントリに直接持つ。ART / HOT のように TID を経由させると LITS は大きく遅くなる、と論文は書いている。
  * urls では適応型 B-Tree が 42% 速く、wiki では同等。整数では LITS の方が速い。scan では B-Tree の方が速い。
  * 非 ASCII 文字はエスケープが必要で、その分 LITS に不利。
  * **学習データの量に強く依存する**。index 作成時に全キーの 50% を渡す (LITS の著者と同じ) 設定を、5% に減らすとスループットが -69%〜+41% 変わる (14 節)。

## 2. learned index の基本

### 2.1 CDF モデル

* ソート済み配列 `A[0..N)` で、キー x の位置は `N * CDF(x)` (x 以下のキーの割合 × N)。
* CDF を関数 F で近似すれば、位置を `floor(N * F(x))` で計算できる。
* 一番単純な F は線形モデル `F(x) = a * x + b`。最小二乗法や、両端点を通る直線で決める。

### 2.2 誤差上限つき (error-bounded) 方式

* RMI, PGM-index など。
* 構築時に、各キーの「予測位置 - 実際の位置」の最大誤差 ε を記録する。
* 検索では予測位置の前後 `[p - ε, p + ε]` を二分探索する (last-mile search)。
* 欠点: 文字列ではこの最後の比較が重い (長いキーの比較が何度も起きる)。

### 2.3 衝突駆動 (collision-driven) 方式 (LIPP)

* 配列を隙間ありにして、各スロットに「空 / キー 1 つ / 子ノード」のどれかを入れる。
* モデルが同じスロットに予測したキーが 2 つ以上あれば、そのスロットに**子ノードを作って再帰**する。
* 予測位置は常に正確なので、last-mile search がない。
* 条件: モデルが**単調** (キーが大きければ予測位置も大きいか等しい) であること。そうでないと scan の順序が壊れる。
* LITS はこの方式を使う。

### 2.4 文字列での難しさ

* 既存の線形モデルは文字列を数 `x = Σ s_k / 256^k` に変換してから直線を当てる。
* これは「どの接頭辞の後でも、次の文字は一様に分布する」と仮定するのと同じ (LITS 論文 3.2 の式 3)。
* 実データは接頭辞が偏っているので、多くのキーが同じスロットに集まり、木が深くなる。

## 3. LITS の全体像

```
             root Item
                │
        ┌───────▼────────────────────────────────────┐
        │ model-based node: header | prefix | items  │
        │ items: [0][1][2] ... [L-2][L-1]             │
        └──┬──────┬──────┬──────────┬────────────────┘
           │      │      │          │
          Null   kv     cnode      model node / HOT subtrie
                 entry  (2..=16    (再帰)
                        h-pointer)
```

* **model-based node**: 共通接頭辞と局所線形モデル (k, b) を持つ。スロット配列の長さは構築時のキー数の 2 倍。
* **スロット 0 と L-1 は予約**。キーの接頭辞がノードの共通接頭辞より小さい / 大きいときに使う。
* **compact leaf (cnode)**: 最大 16 件の kv エントリへの h-pointer をキー順に並べた配列。
* **HOT subtrie**: GPKL (8 節) が大きい部分は HOT に任せる。
* **HPT**: 索引全体で 1 つの表。全ノードが共有する。

## 4. データ配置

### 4.1 Item (8 バイト)

```
 63 61 60          48 47                                   0
+-----+--------------+--------------------------------------+
| typ |   (未使用)    |     ポインタ (48 bit)                |
+-----+--------------+--------------------------------------+
typ: 000 Null, 001 kv エントリ, 010 model node, 011 HOT subtrie, 100 cnode
```

```rust
#[derive(Clone, Copy)]
struct Item(u64);

#[repr(u8)]
enum ItemType { Null = 0, Single = 1, Model = 2, Trie = 3, CNode = 4 }

impl Item {
    const TYPE_SHIFT: u32 = 61;
    const PTR_MASK: u64 = (1 << 48) - 1;
    fn ty(self) -> ItemType { /* (self.0 >> 61) & 7 */ todo!() }
    fn ptr(self) -> *mut u8 { todo!("self.0 & PTR_MASK を strict provenance でポインタに戻す") }
    fn trie_root(self) -> u64 { self.0 & !(7 << 61) }   // HOT の根の子ポインタ
}
```

* Null は値 0 全体 (`set_null` は 0 を書く)。
* **HOT の根を Item に直接埋め込む** (コード: `ST_ASSERT(sizeof(HOTIndex) == 8)`, `set_index`)。HOT の根は 8 バイトの子ポインタ 1 つなので、上位 3 ビットを LITS の型で上書きして入れる。ポインタの間接参照が 1 回減る (論文 3.4 "Implementation Consideration")。
* ポインタが 48 ビットに収まることを前提にしている。5 段ページング (LA57) やハードウェアのポインタタグ (ARM TBI, Intel LAM) と衝突する。

### 4.2 kv エントリ

```rust
#[repr(C)]
struct Kv {                // offset
    v: u64,                // 0  値
    key: [u8; 0],          // 8  NUL 終端のキー (可変長)
}
```

* キーは NUL 終端の C 文字列。比較はすべて「NUL まで」。
* 文字は 1..=127 (ASCII) だけ。HPT の列が 128 しかないため (15 節)。

### 4.3 compact leaf (cnode)

```rust
#[repr(C)]
struct CNode {             // offset
    ccpl: u32,             // 0  確定済みの共通接頭辞長 (比較で読み飛ばしてよい長さ)
    key_cnt: u32,          // 4  2..=16
    data: [u64; 0],        // 8  h-pointer × key_cnt (キー順)
}
// h-pointer: [ hash16 (63..48) | Kv へのポインタ (47..0) ]
```

* 配列はちょうど `key_cnt` 個。挿入のたびに 1 つ大きいノードを作り直す (論文 3.3 の第 2 の方式)。
* ハッシュ: `hash(key) = len ^ key[len/2] ^ key[2*len/3] ^ key[4*len/5]` を u16 で計算 (コード: `hashStr`)。キー全体は読まない。

### 4.4 model-based node

```rust
#[repr(C)]
struct ModelNodeHeader {   // offset
    item_array_len: u64,   // 0   L (構築時のキー数 × 2)
    num_keys: u64,         // 8   部分木内のキー数 (挿入・削除で増減)
    k: f64,                // 16  局所線形モデルの傾き
    b: f64,                // 24  切片
    prefix_len: u32,       // 32  icpl: このノードで新たに確定する共通接頭辞の長さ
    header_offset: u32,    // 36  prefix_len を 8 の倍数に切り上げたもの
}                          // 40 バイト
// この後に: prefix (header_offset バイト) → items: [Item; L]
```

### 4.5 HPT

```rust
const PS_BITS: usize = 5;      // 位置ハッシュ 32 通り
const FC_BITS: usize = 5;      // 直前の文字ハッシュ 32 通り
const MAX_CH: usize = 128;

#[derive(Clone, Copy, Default)]
struct Uni { cdf: f64, prob: f64 }     // 16 バイト

struct Hpt { m: Box<[[[Uni; MAX_CH]; 1 << FC_BITS]; 1 << PS_BITS]> }   // 32*32*128*16 = 2 MiB
```

* 2 MiB はスタックに置けない。必ずヒープに確保する (`Box::new([...])` は一度スタックに作るので、`vec!` から変換するか `alloc_zeroed` を使う)。

## 5. 不変条件

* model node:
  * `L == item_array_len >= 4` (構築時 n > 16 なので実際は 34 以上)。
  * `items[1..L-1]` の部分木に入るキーは、すべて接頭辞 `key[0..ccpl+icpl]` がノードの接頭辞と一致する。`items[0]` は小さい側、`items[L-1]` は大きい側に外れたキーだけ。
  * スロット順にキーが増加する (q < r なら items[q] のどのキーも items[r] のどのキーより小さい)。
  * `num_keys` は部分木のキー数と一致する。
  * `num_keys < 2 * L` かつ `4 * num_keys > L` (作り直し直後を除く)。
* cnode: `2 <= key_cnt <= 16`、キー順、各 h-pointer の上位 16 ビット == `hash16(key)`。
* kv エントリ: キーは 1..=127 の文字だけで、NUL 終端。
* HOT subtrie: 05-hot.md の不変条件。
* 全体: 左から順に読むとキーが厳密に増加し、件数がオラクルと一致する。

## 6. HPT (Hash-enhanced Prefix Table)

### 6.1 考え方 (論文 3.2)

文字列 `S = s_1 ... s_n` の接頭辞を `P_k` とすると、CDF は次の漸化式で書ける。

```
cdf(P_0) = 0,              prob(P_0) = 1
cdf(P_{k+1})  = cdf(P_k) + prob(P_k) × Σ_{c < s_{k+1}} prob(c | P_k)
prob(P_{k+1}) = prob(P_k) × prob(s_{k+1} | P_k)
```

* 必要なのは条件付き確率 `prob(c | P)` だけ。
* すべての (接頭辞, 文字) を記録すると大きすぎる。接頭辞をハッシュして表の行にまとめる。
* 各セルには `cdf = Σ_{c' < c} prob(c'|行)` と `prob = prob(c|行)` を持つ。和の計算が 1 回の参照で済む。

### 6.2 行の選び方 (コードで確認)

* **論文**: 接頭辞全体のハッシュ (逐次的に更新する)。
* **コード**: 行 = `(位置 k & 31, 直前の文字 s[k-1] & 31)`。位置 0 では直前の文字を 0 とする。
* つまりコードの「接頭辞のハッシュ」は、位置と直前の 1 文字だけで決まる。この資料はコードに従う。

```rust
fn row(key: &[u8], k: usize) -> (usize, usize) {
    let ps = k & 31;
    let fc = if k == 0 { 0 } else { (key[k - 1] & 31) as usize };
    (ps, fc)
}
```

### 6.3 学習 (コード: `HPT::train`)

入力はソート済みで重複のないキー列。

```rust
fn train(keys: &[&[u8]]) -> Hpt {
    let mut h = Hpt::zeroed();
    let n = keys.len();
    let gcpl = cpl(keys[0], keys[n - 1]);                // 全体の共通接頭辞長
    // 位置 b の重み = 0.5^(b - gcpl)。先頭に近い文字ほど重く数える。
    let weight = |b: usize| 0.5f64.powi((b - gcpl) as i32);
    for i in 0..n {
        // そのキーを隣と区別するのに必要な長さ (distinguishing prefix) まで数える
        let dpl = match i {
            0 => cpl(keys[0], keys[1]) + 1,
            _ if i == n - 1 => cpl(keys[n - 1], keys[n - 2]) + 1,
            _ => cpl(keys[i], keys[i - 1]).max(cpl(keys[i], keys[i + 1])) + 1,
        };
        for b in gcpl..keys[i].len().min(dpl) {
            let (ps, fc) = row(keys[i], b);
            h.m[ps][fc][keys[i][b] as usize].cdf += weight(b);   // まず頻度として足す
        }
    }
    // 行ごとに正規化して、prob と累積 cdf にする
    for ps in 0..32 { for fc in 0..32 {
        let line = &mut h.m[ps][fc];
        let total: f64 = line.iter().map(|u| u.cdf).sum();
        if total <= 0.0 { continue; }                       // 使われない行は全部 0 のまま
        let mut acc = 0.0;
        for c in 0..MAX_CH {
            let p = line[c].cdf / total;
            line[c].prob = p;
            line[c].cdf = acc;                               // c より小さい文字の確率の和
            acc += p;
        }
    }}
    h
}
```

* 論文は「データの一部 (例: 1%) を無作為に抽出して学習する」と書く。**コードは bulkload に渡されたキー全部で学習する**。抽出はしない。
* 論文本文の説明は「各 (接頭辞, 文字) の出現を数える」だけ。0.5 の減衰と「区別に必要な長さまで」の打ち切りはコードにだけある。
* 使われない行 (total = 0) では、その行を通る予測で `prob = 0` になり、ループがそこで止まる (6.4)。

### 6.4 CDF の計算 (論文 Algorithm 1, コード: `getCdf`, `getPos`)

```rust
/// key の skip 文字目以降について CDF を推定する (共通接頭辞は飛ばす)。
fn get_cdf(h: &Hpt, key: &[u8], skip: usize) -> f64 {
    let (mut cdf, mut prob) = (0.0, 1.0);
    let min = 1.0 / (1u64 << 52) as f64;
    let mut i = skip;
    while i < key.len() && prob >= min {
        let (ps, fc) = row(key, i);
        let u = h.m[ps][fc][key[i] as usize];
        cdf += prob * u.cdf;
        prob *= u.prob;
        i += 1;
    }
    cdf
}

/// スロット数 size に対する位置。局所線形モデル (k, b) を掛けた形で計算し、
/// 区間幅 (ps) が 1 スロット未満になったら止める。
fn get_pos(h: &Hpt, key: &[u8], size: usize, skip: usize, k: f64, b: f64) -> i64 {
    let (mut ps, mut c) = (size as f64 * k, size as f64 * b);
    let mut i = skip;
    while i < key.len() && ps >= 1.0 {
        let (r, f) = row(key, i);
        let u = h.m[r][f][key[i] as usize];
        c += ps * u.cdf;
        ps *= u.prob;
        i += 1;
    }
    c as i64                                // 0 方向への切り捨て
}
```

* `get_pos` は `size * (k * cdf + b)` を、必要な桁まで計算したもの。区間幅 `ps` が 1 未満になれば、それ以降の文字はスロットを変えない。
* 単調性: 同じ行で `c1 < c2` なら `cdf[c2] >= cdf[c1] + prob[c1]` なので、残りの寄与 (< prob[c1]) を足しても順序は逆転しない。途中で打ち切っても、非負の項を捨てるだけなので順序は保たれる。ただし**浮動小数点の丸めで崩れうる** (15 節)。
* コードの `getPos` / `getCdf` は `key[i-1]` を読む。`skip == 0` のとき `key[-1]` になるので、コードは `getPos_woGCPL` を別に用意して先頭を行 (0, 0) で読む。ただし `getCdf` には分岐がなく、bulkload で `gcpl == 0` だと範囲外を読む。この資料の `row` は k == 0 を特別扱いしてこれを避ける。

## 7. model-based node と位置の予測

### 7.1 予測 (コード: `predictPos`)

```rust
/// ccpl: これまでに確定した共通接頭辞長。接頭辞が一致したときだけ増える。
fn predict_pos(h: &Hpt, node: &ModelNode, key: &[u8], ccpl: &mut usize) -> usize {
    let l = node.item_array_len as usize;
    let icpl = node.prefix_len as usize;
    if icpl > 0 {
        // ノードの接頭辞と key[ccpl .. ccpl+icpl] を比べる (key が短ければ NUL=0 として比べる)
        match cmp_prefix(node.prefix(), &key[*ccpl..], icpl) {
            Ordering::Less => return l - 1,      // key の方が大きい → 最後のスロット
            Ordering::Greater => return 0,       // key の方が小さい → 先頭のスロット
            Ordering::Equal => {}
        }
    }
    let p = get_pos(h, key, l - 2, *ccpl + icpl, node.k, node.b) + 1;
    *ccpl += icpl;
    p.clamp(1, (l - 2) as i64) as usize
}
```

* 予測の範囲は `[1, L-2]`。0 と L-1 は接頭辞が合わないキーのために空けておく。
* 接頭辞が合わないときは ccpl を増やさない。

### 7.2 局所線形モデルの決め方 (コード: `_try_rebulk_as_model_node`)

キー列 `keys[l..r)` (ソート済み) からノードを作る。

```
gcpl = cpl(keys[l], keys[r-1])          // このノードで確定する接頭辞の終わり
min_cdf = get_cdf(keys[l],   gcpl)
max_cdf = get_cdf(keys[r-1], gcpl)
k = 1 / (max_cdf - min_cdf)
b = -min_cdf / (max_cdf - min_cdf)       // コード: min_cdf / (min_cdf - max_cdf)
```

* 先頭のキーが 0、最後のキーが 1 に写るように、HPT の CDF を引き伸ばす。
* `max_cdf <= min_cdf` なら HPT が区別できていない。ノードは作れない (失敗)。

## 8. GPKL と PMSS

### 8.1 GPKL (Group Partial Key Length, 論文 Definition 3.2, 3.3)

```
pkl(L, S_i) = max(cpl(S_{i-1}, S_i), cpl(S_i, S_{i+1})) + 1 - cpl(L)
gpkl(L)     = (1/|L|) Σ_i pkl(L, S_i)
```

* 端のキーは片側の隣だけを使う。
* 意味: 「キーを互いに区別するのに、共通接頭辞の後ろで平均何バイト読む必要があるか」。大きいほどモデルで区別しにくい。
* 論文は 32 件ずつの「局所 GPKL」も定義するが、**コードの判定 (`getGPKL`) は範囲全体の GPKL を使う**。

### 8.2 PMSS (Performance Model for Structure Selection, 論文 3.4)

* オフラインで、合成データを使って「LIT (LITS から HOT を除いたもの) だけ」と「HOT だけ」の性能を測っておく。
* 軸は 2 つ。キー数 n (log2 で 5〜27) と GPKL (3〜20)。
* 格子点ごとに 4 つの表を持つ: LIT の読み、LIT の書き、HOT の読み、HOT の書き。
* 判定時は双線形補間で 4 つの値を求め、読み書きの比率で重み付けして比べる。

```rust
enum SubType { Items, Trie, CNode }

fn decide(n: usize, gpkl: f64, fr: f64, t: &PmssTables) -> SubType {
    if n <= 16 { return SubType::CNode; }
    let das = (n as f64).log2().clamp(5.0, 27.0) - 5.0;       // 0..=22
    let pkl = gpkl.clamp(3.0, 20.0) - 3.0;                     // 0..=17
    let lit = fr * t.lit_read.interp(das, pkl) + (1.0 - fr) * t.lit_write.interp(das, pkl);
    let hot = fr * t.hot_read.interp(das, pkl) + (1.0 - fr) * t.hot_write.interp(das, pkl);
    if lit < hot { SubType::Items } else { SubType::Trie }     // 小さい方 (推定レイテンシ) を選ぶ
}

impl Table {   // [[f64; 18]; 23]
    fn interp(&self, x: f64, y: f64) -> f64 {
        let (x0, y0) = (x.floor() as usize, y.floor() as usize);
        let (x1, y1) = ((x0 + 1).min(22), (y0 + 1).min(17));   // コードはここを切り詰めない (15 節)
        let (fx, fy) = (x - x0 as f64, y - y0 as f64);
        self[x0][y0] * (1.0 - fx) * (1.0 - fy) + self[x0][y1] * (1.0 - fx) * fy
            + self[x1][y0] * fx * (1.0 - fy) + self[x1][y1] * fx * fy
    }
}
```

* コードの既定は `read_ratio = 1`。つまり読みの表だけで決まる。
* 表の値は論文の実験機で測ったもの。単位はコードに書かれていない。論文は「レイテンシの推定」と書いている。【未検証: 単位】
* **自分の実装では表を自分で測り直す**。手順は論文 3.4 のとおり。
  * 合成データを n と GPKL の格子ごとに作る (論文は、接頭辞を差し込んで GPKL を目標値まで上げる方法を書いている)。
  * LIT だけ / HOT だけで bulkload し、lookup と insert の平均時間を測る。
  * 表の数値をそのまま写さないこと。機械が違えば意味がない。
* PMSS を使う場面 (論文 3.4)。
  1. bulkload で 16 件を超える範囲。
  2. 満杯の cnode への挿入。
  3. model node の作り直し (resize)。
* 論文はさらに「1 つのスロットに 50% を超えるキーが集まったら、その子は必ず HOT にする」と書く (木の高さを O(log N) に抑えるため)。**コードにはこの規則が見当たらない**。【未検証: コードでの実装】

## 9. bulkload

### 9.1 全体 (コード: `LITS::_bulkload`)

* 入力はソート済みで重複のないキー。**1000 件未満なら失敗する** (`min_bulk_load_size`)。空の LITS からは始められない。
* HPT を学習する (6.3)。HPT はこの後**固定**で、挿入では更新しない。
* `root = build(keys, 0, n, ccpl = 0)`。

### 9.2 範囲からの構築 (コード: `pmss_bulk`)

```rust
fn build(kvs: &[KvRef], ccpl: usize, h: &Hpt, t: &PmssTables) -> Item {
    let n = kvs.len();
    if n == 1 { return Item::single(kvs[0]); }
    if n <= 16 { return Item::cnode(new_cnode(kvs, ccpl)); }
    if decide(n, gpkl(kvs), 1.0, t) == SubType::Items {
        if let Some(node) = try_build_model_node(kvs, ccpl, h, t) { return Item::model(node); }
    }
    Item::trie(hot_bulkload(kvs))          // PMSS が HOT を選んだか、model node が作れなかった
}

fn try_build_model_node(kvs: &[KvRef], ccpl: usize, h: &Hpt, t: &PmssTables) -> Option<ModelNode> {
    let n = kvs.len();
    let l = 2 * n;                                          // ScaleFactor = 2
    let gcpl = cpl(kvs[0].key, kvs[n - 1].key);
    let icpl = gcpl - ccpl;
    let (mn, mx) = (get_cdf(h, kvs[0].key, gcpl), get_cdf(h, kvs[n - 1].key, gcpl));
    if mx <= mn { return None; }
    let mut node = ModelNode::new(l, n, 1.0 / (mx - mn), mn / (mn - mx), &kvs[0].key[ccpl..gcpl]);

    // 先頭と末尾が別のスロットに行かなければ失敗
    let (p0, p1) = (predict_pos(h, &node, kvs[0].key, &mut ccpl.clone()),
                    predict_pos(h, &node, kvs[n - 1].key, &mut ccpl.clone()));
    if p0 >= p1 { return None; }

    // 同じスロットに行く連続したキーをグループにする。単調でなければ失敗。
    let mut groups: Vec<(usize, Range<usize>)> = vec![];
    let mut last = usize::MAX;
    for i in 0..n {
        let p = predict_pos(h, &node, kvs[i].key, &mut ccpl.clone());
        if last != usize::MAX && p < last { return None; }   // 浮動小数点で逆転した
        if p != last { groups.push((p, i..i + 1)); last = p; } else { groups.last_mut().unwrap().1.end = i + 1; }
    }
    for (p, r) in groups {
        node.items[p] = build(&kvs[r], gcpl, h, t);         // 子の ccpl はこのノードの gcpl
    }
    Some(node)
}
```

* 子の ccpl を gcpl にしてよい理由: このノードのスロット 1..L-2 に来たキーは、接頭辞 `key[0..gcpl]` が一致している。
* 失敗したら HOT にする。model node を「作りかけ」で残さない (確保したメモリを解放する)。

## 10. lookup

```rust
fn lookup<'a>(root: Item, key: &[u8], h: &Hpt) -> Option<&'a Kv> {
    let mut ccpl = 0;
    let mut item = root;
    loop {
        match item.ty() {
            ItemType::Null => return None,
            ItemType::Single => {
                let kv = item.as_kv();
                // ccpl までの接頭辞は確定済みなので、その後ろだけ比べればよい
                return (kv.key()[ccpl..] == key[ccpl..]).then_some(kv);
            }
            ItemType::CNode => return cnode_search(item.as_cnode(), key),
            ItemType::Trie => return hot_lookup(item.trie_root(), key),
            ItemType::Model => {
                let node = item.as_model();
                let p = predict_pos(h, node, key, &mut ccpl);
                item = node.items[p];
            }
        }
    }
}

fn cnode_search<'a>(c: &'a CNode, key: &[u8]) -> Option<&'a Kv> {
    let hv = hash16(key);
    for &hp in c.data() {
        if (hp >> 48) as u16 != hv { continue; }        // ハッシュが違えば読みに行かない
        let kv = kv_from_hptr(hp);
        if kv.key()[c.ccpl as usize..] == key[c.ccpl as usize..] { return Some(kv); }
    }
    None
}
```

* cnode は線形に走査する。論文によると 16 ビットハッシュの偽陽性率は 0.0015%。
* 論文 Algorithm 2 は Trie → Single → CNode → Null → Model の順に型を調べる。順序は性能だけの問題。

## 11. insert と再構築

### 11.1 擬似コード (論文 Algorithm 3, コード: `LITS::_insert`)

```rust
fn insert(root: &mut Item, key: &[u8], val: u64, h: &Hpt, t: &PmssTables) -> bool {
    let mut ccpl = 0;
    let mut item: *mut Item = root;
    let mut path: Vec<(*mut Item, usize)> = vec![];    // (model node を指す Item, その時点の ccpl)
    let inserted = loop {
        let it = unsafe { &mut *item };
        match it.ty() {
            ItemType::Null => { *it = Item::single(new_kv(key, val)); break true; }
            ItemType::Single => {
                let old = it.as_kv();
                match old.key()[ccpl..].cmp(&key[ccpl..]) {
                    Ordering::Equal => break false,                    // すでにある
                    o => {
                        // 2 件の cnode にする (キー順)
                        let (a, b) = if o == Ordering::Greater { (new_kv(key, val), old) } else { (old, new_kv(key, val)) };
                        *it = Item::cnode(cnode_of(&[a, b], ccpl));
                        break true;
                    }
                }
            }
            ItemType::CNode => break cnode_insert(it, key, val, h, t),
            ItemType::Trie => break hot_insert(it, key, val),         // 根が変わったら Item を書き戻す
            ItemType::Model => {
                path.push((item, ccpl));
                let node = it.as_model_mut();
                let p = predict_pos(h, node, key, &mut ccpl);
                item = &mut node.items[p];
            }
        }
    };
    if inserted { inc_count(&path, h, t); }
    inserted
}

fn cnode_insert(it: &mut Item, key: &[u8], val: u64, h: &Hpt, t: &PmssTables) -> bool {
    let c = it.as_cnode();
    let ccpl = c.ccpl as usize;
    let pos = match c.position_of(key) {              // キー順の挿入位置。同じキーがあれば Err
        Ok(p) => p, Err(()) => return false,
    };
    if c.key_cnt < 16 {
        *it = Item::cnode(c.with_inserted(pos, new_hptr(key, val)));   // 1 つ大きい cnode を作り直す
    } else {
        // 17 件を取り出して作り直す。PMSS が model node か HOT を選ぶ。
        let all = c.kvs_with_inserted(pos, new_kv(key, val));
        *it = build(&all, ccpl, h, t);
    }
    free_old_cnode(c);                                // kv エントリ自体は解放しない
    true
}
```

* cnode の位置探しは、論文は二分探索、コードは先頭からの線形走査。どちらでもよい。
* HOT への挿入で HOT の根が変わる (新しい根ができる) ことがある。Item に埋め込んだ根を**必ず書き戻す** (コード: `trie_insert` が `set_coded_index` し直している)。

### 11.2 キー数の更新と再構築 (resize)

```rust
fn inc_count(path: &[(*mut Item, usize)], h: &Hpt, t: &PmssTables) {
    for &(item, ccpl) in path {                         // 根に近い方から
        let it = unsafe { &mut *item };
        let node = it.as_model_mut();
        node.num_keys += 1;
        if node.num_keys >= 2 * node.item_array_len {
            // この部分木のキーを全部取り出し (キー順)、作り直す
            let kvs = collect_in_order(*it);            // 部分木のノードは解放、kv エントリは残す
            *it = build(&kvs, ccpl, h, t);              // ← 親の Item に書き戻す
            return;                                     // 下の段は作り直しに含まれる
        }
    }
}
```

* 作り直しは、キー数が構築時の 4 倍 (L の 2 倍) に達したとき。削除では `4 * num_keys <= L` のとき作り直す。
* **参照実装の不具合 (と思われるもの)**: コードの `PathStack::change_num` は、作り直した `new_item` を親の Item に書き戻していない。部分木は `recursive_extract` ですでに解放されているので、親は解放済みのノードを指したままになる。この資料の擬似コードでは書き戻す。【未検証: 実際に発生するかは実行して確かめていない】
* コードの upsert は「戻り値 0 = 新規挿入」と扱う。古い値が 0 だった更新も新規挿入と数えてしまう。Rust では `Option<u64>` で返す。

## 12. delete (要約)

* 降り方は insert と同じ。
* kv エントリ: 一致すれば Null にする。
* cnode: 3 件以上なら 1 つ小さい cnode を作り直す。2 件なら残りの 1 件を kv エントリに戻す (`_cnode_degrade`)。
* HOT: HOT の delete を呼ぶ。
  * 論文は「HOT に delete がないので削除リストを持ち、一定割合を超えたら作り直す」と書く。
  * コード (同梱の HOT) は HOT の `remove` を直接呼ぶ。
* 成功したら経路上の `num_keys` を減らし、`4 * num_keys <= L` なら作り直す (11.2 と同じく親に書き戻す)。
* btree-cpp のアダプタは remove を実装していない (`abort()`)。

## 13. scan と lower_bound

### 13.1 イテレータ (コード: `litsIter`)

* スタックに段ごとの `(配列, 長さ, 添字)` を積む。model node なら Item 配列、cnode なら h-pointer 配列。HOT に入ったら HOT のイテレータを持つ。
* `next`: 今の段の添字を進める。Null は飛ばす。配列の終わりに来たら pop して親を進め、そこから最左へ降りる。
* model node の Item と cnode の h-pointer はどちらもキー順なので、これで昇順になる (論文 3.1 "Scan")。

### 13.2 lower_bound

* **コードの `find` は完全一致**。キーがなければイテレータは無効になる (`cnod_find`, `sing_find` で `set_invalid`)。btree-cpp のアダプタも `find` から走査するので、存在しないキーから始めると何も返さない。
* Rust 版では lower_bound を次のように定義する。

```rust
/// item の部分木で key 以上の最小のキーに位置づける。なければ false。
fn seek(it: &mut Iter, item: Item, key: &[u8], ccpl: usize, h: &Hpt) -> bool {
    match item.ty() {
        ItemType::Null => false,
        ItemType::Single => { if item.as_kv().key() >= key { it.push_single(item); true } else { false } }
        ItemType::CNode => {
            let c = item.as_cnode();
            match c.kvs().position(|kv| kv.key() >= key) {     // キー全体で比べる
                Some(i) => { it.push_cnode(c, i); true }
                None => false,
            }
        }
        ItemType::Trie => it.push_hot_lower_bound(item.trie_root(), key),   // 05-hot.md 12.2
        ItemType::Model => {
            let node = item.as_model();
            let mut cc = ccpl;
            let p = predict_pos(h, node, key, &mut cc);
            it.push_model(node, p);
            if seek(it, node.items[p], key, cc, h) { return true; }
            // スロット p の中に key 以上がなければ、p より右の最初の空でないスロットの最小キー
            for q in p + 1..node.items.len() {
                if !node.items[q].is_null() { it.set_index(q); return it.descend_leftmost(node.items[q]); }
            }
            it.pop();
            false
        }
    }
}
// lower_bound(key) = seek(root)。false が返ったら、スタックの親の段で右へ進める (next と同じ処理)。
```

* 正しい理由: 予測が単調なので、スロット q < p のキーは key より小さく、q > p のキーは key より大きい。
* この資料独自の定義 (コードにない)。15 節の浮動小数点の注意がそのまま当てはまる。

## 14. 再学習と学習データの量

* 論文 3.2 "Dealing with Data Distribution Changes":
  * 1% 程度のクエリで性能を抜き取り測定する。
  * bulkload 直後の平均の 50% など、決めた水準を下回ったら HPT を学習し直し、**索引全体を作り直す**。
* コードには再学習の仕組みはない。HPT は bulkload で一度作ったきり。【未検証: 論文の方法の具体的な閾値と頻度】
* **B-Trees Are Back の観測**: index 作成時に渡すキーの割合を 50% から 5% に減らすと、LITS のスループットが -69%〜+41% 変わる。
  * コードでは「学習に使うキー」=「bulkload するキー」。したがってこの割合は、HPT の精度と、最初の木の形 (model node の大きさ、どこが HOT になるか) の両方を変える。
  * どちらの効果が大きいかは論文に書かれていない (この解釈はこの資料のもの)。
  * 実装を評価するときは、学習量を必ず記録し、少なくとも 2 通りで測る。

## 15. 境界条件と落とし穴

* **文字の範囲**: HPT の列は 128。コードは `char` (x86 では符号付き) で添字を取るので、0x80 以上のバイトは負の添字になる (UB)。非 ASCII はエスケープする (例: 0x80 以上を 2 バイトに展開する)。エスケープ後も順序が保たれる方式にする ([02-key-encoding.md](02-key-encoding.md))。
* **NUL**: キーに 0x00 を含められない。
* **HOT subtrie のキー長**: 同梱の HOT は `MAX_STRING_KEY_LENGTH = 255` の固定長バッファに `strncpy` でキーを写す (`hot_src/include/KeyUtilities.hpp`)。255 バイトを超えるキーは切り詰められ、先頭 255 バイトが同じキーは HOT の中で区別できない。URL のような長いキーでは起こりうる。Rust 版では長さの上限を決めて挿入時に拒否するか、05-hot.md のバッファ長を定数引数にする。
* **`key[-1]`**: 6.4 のとおり。位置 0 は行 (0, 0) を使う。
* **PMSS の表の範囲外**: コードは補間の上側の添字を切り詰めない。n >= 2^27 や GPKL >= 20 で、上側の添字が表の外を指す。Rust では `min(22)` / `min(17)` で止める (8.2 の擬似コード)。
* **浮動小数点の単調性**: 理論上は単調でも、丸めで隣のキーの予測が逆転しうる。bulkload では検出して HOT に切り替える。挿入では検出されない。scan の順序が壊れたらここを疑う。対策としては、`get_pos` の結果を同じキーで再計算しても同じになるよう、計算順序を固定する (FMA の有無で変わる)。
* **48 ビットのポインタ**: Item と h-pointer は上位ビットを使う。5 段ページングなどで 48 ビットを超えるアドレスが返ると壊れる。確保したアドレスを assert する。strict provenance の API でタグを付け外しする (README の注意点)。
* **HPT の大きさ**: 2 MiB。スタックに置かない。HOT と同じく、これを L2 / L3 に置けることが性能の前提。
* **bulkload の下限**: 1000 件未満は失敗。テストで小さい木を作るときは、この下限を引数で変えられるようにする。
* **kv エントリの所有権**: cnode や model node を作り直すとき、kv エントリは**移すだけで解放しない**。ノードの解放と kv の解放を分ける (コード: `recursive_extract` はノードだけ解放し、kv をベクタに集める)。
* **upsert の戻り値**: 11.2 のとおり。

## 16. テスト方針

### 16.1 オラクル比較

* `BTreeMap<Vec<u8>, u64>` を正解にする。
* まず 1000 件以上のソート済み・重複なしのキーで bulkload し、同じキーをオラクルにも入れる。
* 操作列: insert (既存キーを含む) / lookup (存在しないキー、接頭辞が外れるキーを含む) / lower_bound + 数件の scan / delete。
* キーの生成:
  * 英単語、URL 風 (長い共通接頭辞)、メールアドレス風。
  * ランダムな 4 バイト整数をエスケープしたもの。
  * **bulkload とは分布の違うキーを後から挿入する** (HPT が合わない状況)。
  * 1 文字だけ違うキー、互いに接頭辞になるキー ("ab" と "abc")。

### 16.2 不変条件チェッカー

* 5 節をすべて検査する。
* model node では、各スロットのすべてのキーについて `predict_pos` を計算し直し、そのスロットに戻ることを確かめる (スロット 0 と L-1 は接頭辞の比較結果を確かめる)。
* `num_keys` は部分木を数え直して比べる。

### 16.3 部品ごとのテスト

* HPT: 学習後、使われた行で `cdf[c] + prob[c] == cdf[c+1]` (誤差 1e-12 程度)、最後の列で `cdf + prob ≈ 1`。
* `get_cdf`: ソート済みキー列に対して結果が非減少であることを確かめる (多数のランダム列で)。
* PMSS: 格子点ちょうどで表の値が返ること。範囲外の入力でパニックしないこと。
* GPKL: 論文の定義 (8.1) を素直に書いた版と比べる。
* resize: 同じスロットに大量に挿入し、作り直しが起き、その後も 16.2 が通ることを確かめる (11.2 の不具合の回帰テスト)。

### 16.4 性能の記録

* 学習量 (bulkload の割合) を 50% と 5% で測り、論文の観測 (14 節) と比べる。

## 17. 原典との違い・簡略化

* **HPT の行**: 論文は接頭辞のハッシュ、コードは (位置 & 31, 直前の文字 & 31)。この資料はコードに従う。
* **学習データ**: 論文は 1% を抽出、コードは bulkload の全キー。この資料はコードに従う。抽出したい場合は、train に渡す前に間引けばよい。
* **重みと打ち切り** (6.3): コードにだけある。この資料はコードに従う。
* **GPKL**: 論文は局所 GPKL も定義するが、判定は範囲全体の GPKL (コードと同じ)。
* **PMSS の表**: 数値は写さず、自分で測る前提にした。
* **50% 規則**: 論文にあるがコードにない。この資料では任意とする。
* **再学習**: 論文にあるがコードにない。
* **resize の書き戻し**: コードの不具合と思われる箇所を直した。
* **lower_bound**: コードは完全一致の `find` だけ。この資料は 13.2 で lower_bound を定義した。
* **HOT の削除**: 論文は削除リスト、コードは HOT の remove。
* **HOT の根の埋め込み**: 原典どおりの最適化。簡単にしたいなら、Item に「HOT の根を入れた箱へのポインタ」を入れてもよい。1 回間接参照が増えるだけで、正しさは変わらない。
* **並行制御**: 論文は楽観的ロックに触れるが、ここでは扱わない。
* **LITS+ (TODS 2026)**: 同じリポジトリに拡張版があるが、論文 (B-Trees Are Back) が使ったのは VLDB 2024 版。この資料も VLDB 2024 版だけを扱う。

## 18. 参考資料

* Yang, Chen. "LITS: An Optimized Learned Index for Strings". PVLDB 17(11), 2024. https://www.vldb.org/pvldb/vol17/p3415-chen.pdf
  * 拡張版: arXiv:2407.11556 (付録 A.2 に Algorithm 2, 3)。
  * 3.1 節 (全体像, 操作), 3.2 節 (HPT, Algorithm 1), 3.3 節 (compact leaf), 3.4 節 (GPKL, PMSS)。
* Wu et al. "Updatable Learned Index with Precise Positions" (LIPP). PVLDB 14(8), 2021. 衝突駆動方式の元。
* Kraska et al. "The Case for Learned Index Structures". SIGMOD 2018. CDF モデルと RMI。
* 参照実装: https://github.com/schencoding/lits (`LITS/lits/`)
  * `lits_base.hpp`: `MAX_CH`, `PTR_MASK`, `CNODE_SIZE`, `ScaleFactor`
  * `lits_model.hpp`: `HPT::train`, `HPT::getPos`, `HPT::getPos_woGCPL`, `HPT::getCdf`
  * `lits_node.hpp`: `ItemType`, `FlaggedPtr`, `InnerNode`, `Item`, `PathStack::change_num`, `predictPos`, `_try_rebulk_as_model_node`, `pmss_bulk`, `sing_insert`, `cnod_insert`, `cnod_remove`
  * `lits_cnode.hpp`: `Cnode`, `new_cnode`, `_cnode_search`, `_cnode_withRoom_insert`, `try_extract_keys_if_valid_insert`, `_cnode_degrade`
  * `lits_kv.hpp`: `kv`, `new_hash_kv`, `getHashVal`
  * `lits_utils.hpp`: `hashStr`
  * `lits_gpkl.hpp`: `ucpl`, `getGPKL`, `ustrcmp`
  * `lits_pmss.hpp`: `PMSS::decideSubType`
  * `lits_hot.hpp`: `HOTInsert`, `HOTLookup` (HOT の根を 8 バイトで埋め込む)
  * `lits_iter.hpp`: `litsIter`, `recordPath_find`, `cnod_find`, `trie_find`
  * `lits.hpp`: `LITS::_bulkload`, `_lookup`, `_insert`, `_remove`, `_upsert`, `_find`
* 論文での使われ方: https://github.com/m-mueller678/btree-cpp `btree/lits_adapter.cpp` (`bulkInsert` は全キーの半分を渡す、`range_lookupImpl` は `find` から走査)。
