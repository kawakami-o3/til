# 03. キャッシュを意識したインメモリ B+-Tree (CSS-Tree, CSB+-Tree)

background.md 1.5 の2つの構造を、自分で書けるように書き下す。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* 普通の B+-Tree の操作 (分割の考え方、区切りキーの意味) は [01-slotted-btree.md](01-slotted-btree.md) を前提にする。
* ノード内の分岐なし二分探索・SIMD 比較は [00-primitives.md](00-primitives.md) の部品を名前で使う。

両方とも原典は **4バイトの整数キー、4バイトのポインタ (32ビット機)** を前提にしている。
ここでは 64 ビット機に合わせて、キー `u32`、ポインタ 8 バイトでレイアウトを作り直した。ノードあたりのキー数は原典の数字と違う (各節に明記)。

## 目次

1. [なぜ論文はこれらを採らないか (ページングとの対比)](#1-なぜ論文はこれらを採らないか-ページングとの対比)
2. [CSS-Tree](#2-css-tree)
3. [CSB+-Tree](#3-csb-tree)
4. [参考資料](#4-参考資料)

---

## 1. なぜ論文はこれらを採らないか (ページングとの対比)

論文 8章の評価は1文だけ。

> these reduce the size of nodes to a degree that makes paging infeasible (B-Trees Are Back, Sec. 8)

以下はこの1文を実装の視点で展開したもの。**論文が明示しているのは上の1文だけで、以下の項目は筆者の解釈**。

| 観点 | CSS / CSB+ | 論文の B-Tree (4 KiB ページ) |
|---|---|---|
| ノードの大きさ | 64 B (キャッシュライン1本) | 4096 B |
| 子の参照 | 配列の添字計算 / 生ポインタ + オフセット | `PageId` (バッファマネージャ経由) |
| 確保の単位 | ノードグループ (可変長、最大で fanout × 64 B) | ページ1枚 |
| 追い出し | 不可 (生ポインタが散らばる) | ページ単位で SSD へ |

* **I/O 単位と合わない**: SSD の読み書きは 4 KiB 単位。64 B のノードを1つ読むために 4 KiB を読むことになる。ノードを束ねてページに詰めると、今度は「ページ内のどのノードか」の管理が要る。
* **可変長のノードグループ**: CSB+-Tree は「兄弟ノードを連続配置」するため、グループの大きさが 1〜fanout ノードで変わる。固定サイズのページ枠に載らない。
* **生ポインタ**: CSB+-Tree の `first_child` は仮想アドレス。追い出すには pointer swizzling ([11-buffer-management.md](11-buffer-management.md)) が必要で、64 B ごとに swip を持つとオーバーヘッドが大きい。
* **CSS-Tree は静的**: 添字計算で子を求めるため、木全体が1本の配列。部分的に追い出す単位がない。
* 論文の方針: **ノードは 4 KiB のまま**、ページ内の並べ方 (heads, hints, fingerprint, dense) でキャッシュミスを減らす。CSS/CSB+ の「キーを詰めてキャッシュラインの利用率を上げる」発想は、論文ではページ内の hints 配列 (01 の 4.5) に形を変えて残っている (これも筆者の解釈)。

---

## 2. CSS-Tree

### 2.1 目的と原典との関係

* Rao & Ross, VLDB 1999。**ソート済み配列の上に置く、静的な探索ディレクトリ**。
* 内部ノードはキーだけを持ち、子ポインタを持たない。子はヒープ (二分ヒープ) と同じ添字計算で求める。
* 葉はディレクトリの外にある**元のソート済み配列そのもの**。配列は並べ替えない。
* 更新はできない。バッチで溜めて丸ごと作り直す (原典: 2500 万件の構築が1秒未満)。
* 2種類ある。
  * **full CSS-Tree**: 1ノードに m 個のキー、分岐数 m+1。
  * **level CSS-Tree**: m = 2^t のスロットのうち m-1 個だけ使い、分岐数 m。ノード内の二分探索が完全二分木になり比較回数が揃う。

### 2.2 データ配置

ノード = キャッシュライン1本 = `u32` を 16 個。

```rust
const M: usize = 16;                 // full: キー数 = 16, 分岐 17
                                     // level: スロット 16 (キー 15 + 予備 1), 分岐 16
#[repr(C, align(64))]
struct CssNode { keys: [u32; M] }    // offset 0..64

struct CssTree<'a> {
    dir: Vec<CssNode>,               // 内部ノードだけ。添字 = ノード番号
    a: &'a [u32],                    // 元のソート済み配列 (葉)。長さ n
    n_internal: usize,               // 内部ノード数 I
    n_nodes: usize,                  // I + 葉ノード数 N
    first_deep: usize,               // 最深レベルの最初の葉のノード番号 y
}
```

ノード番号の付け方 (full, m=4 の原典 Figure 3 の例。N = 65 葉):

```
ノード番号 (BFS 順、ヒープと同じ)
  0                     ← 根
  1 .. 5                ← 深さ1
  6 .. 30               ← 深さ2: 6..15 は内部、16..30 は「浅い葉」
  31 .. 80              ← 深さ3: すべて「深い葉」

ディレクトリ配列 dir:  [0][1]...[15]            (内部ノードだけ)
ソート済み配列 a:      [31][32]...[80][16]...[30]   (葉、ノード単位)
                       └ 深い葉が前半 ┘└ 浅い葉が後半 ┘
```

* 木の自然な順では浅い葉 (16..30) が深い葉 (31..80) より**キーが大きい**。ヒープ順でも番号は小さい。
* 配列 `a` はキー順のまま触らないので、番号 → 配列位置の変換で前後半を入れ替える。

**子の番号** (ノード b の i 番目の子、i は 0 始まり):

```rust
fn child_full(b: usize, i: usize) -> usize  { b * (M + 1) + 1 + i }   // i in 0..=M
fn child_level(b: usize, i: usize) -> usize { b * M + 1 + i }         // i in 0..M
```

**ノード数の計算** (原典 Lemma 4.1。full の場合、分岐 f = m+1):

```
N = ceil(n / m)                    葉ノード数
k = ceil(log_f N)                  木の深さ (f^k >= N となる最小の k)
y = (f^k - 1) / m                  最深レベルの最初の葉の番号 (= 完全木の内部ノード数)
I = y - floor((f^k - N) / m)       内部ノード数
```

* 検算 (m=4, f=5, N=65): k=3, f^k=125, y=124/4=31, I=31-floor(60/4)=16。Figure 3 と一致。
* level の場合は f = m, 分母も m-1 になる: `y = (m^k - 1)/(m - 1)`, `I = y - floor((m^k - N)/(m - 1))`。
  原典は full の式しか示していない。level の式は筆者が同じ導出で置き換えたもので、手で検算した (m=4, 分岐 4: N=10 → y=5, I=3。N=11 → y=5, I=4 で、ノード 3 の子 15, 16 がぶら下がり)。テストでも I + N = n_nodes と各葉の写像を確かめること。

**葉の番号 → 配列 `a` 上の位置** (ノード単位。キー位置はこれに m を掛ける):

```rust
fn leaf_to_pos(t: &CssTree, b: usize) -> usize {
    debug_assert!(b >= t.n_internal && b < t.n_nodes);
    if b >= t.first_deep {
        b - t.first_deep                                   // 深い葉 → 前半
    } else {
        (b - t.n_internal) + (t.n_nodes - t.first_deep)    // 浅い葉 → 後半
    }
}
```

* 検算: ノード 31 → 0、ノード 80 → 49、ノード 16 → 50、ノード 30 → 14 + 50 = 64。原典本文の「ノード 30 の先頭キーは配列上のノード 64 の先頭」と一致。

### 2.3 不変条件

* `dir[b].keys[i]` = 子 i の部分木に入る最大キー。
* ノード内のキーは昇順 (重複可)。
* 子 i の部分木のキーは `keys[i-1] < x <= keys[i]` (lower_bound の意味。重複時は左端に寄る)。
* `I + N == n_nodes`。葉の写像は全単射で、`a` をちょうど覆う。
* 存在しない子に対応するキー (後述の「ぶら下がりスロット」) には、前半の最後の要素 `a[deep_n * m - 1]` が入る。

### 2.4 構築 (ソート済み配列から)

原典は「各スロットに左部分木の最大キーを入れる。右端の枝を葉まで辿って求める」。
ここでは同じ値を**後ろから**1回の走査で求める形に書き直す。

```rust
fn build(a: &[u32]) -> CssTree {
    let n = a.len();
    let n_leaves = (n + M - 1) / M;                  // 端数は 2.6 参照
    let (k, fk) = smallest_power_ge(M + 1, n_leaves);// f^k >= N となる k と f^k
    let y = (fk - 1) / M;
    let n_internal = y - (fk - n_leaves) / M;
    let n_nodes = n_internal + n_leaves;
    let deep_n = n_nodes - y;                        // 深い葉の数
    let dangling = a[(deep_n * M).min(n) - 1];       // 前半の最後の要素

    let mut dir = vec![CssNode { keys: [0; M] }; n_internal];
    let mut sub_max = vec![0u32; n_internal];        // 各内部ノードの部分木の最大キー
    // 子の番号は親より大きいので、後ろから処理すれば子の sub_max は確定済み
    for b in (0..n_internal).rev() {
        let mut last = dangling;
        for i in 0..=M {
            let c = child_full(b, i);
            let mx = if c >= n_nodes {
                dangling                              // 存在しない子
            } else if c >= n_internal {
                let p = leaf_to_pos(c) * M;           // 葉: その葉の最後のキー
                a[(p + M).min(n) - 1]
            } else {
                sub_max[c]
            };
            if i < M { dir[b].keys[i] = mx; }
            if c < n_nodes { last = mx; }
        }
        sub_max[b] = last;                            // 最後の「存在する」子の最大
    }
    CssTree { dir, a, n_internal, n_nodes, first_deep: y }
}
```

* 葉が1つ (N <= 1) のときは k = 0, I = 0 になる。ディレクトリなしで `a` を直接二分探索する。
* `smallest_power_ge` は整数のループで求める (浮動小数の log は丸めで k がずれる)。

### 2.5 探索 (lower_bound)

```rust
/// a の中で key 以上の最初の位置。なければ n。
fn lower_bound(t: &CssTree, key: u32) -> usize {
    let mut b = 0;
    while b < t.n_internal {
        // ノード内: key 以上の最初のスロット = key より小さいキーの個数
        let i = count_less_u32x16(&t.dir[b].keys, key);   // 0..=M
        b = child_full(b, i);
    }
    let p = leaf_to_pos(t, b) * M;
    let end = (p + M).min(t.a.len());
    p + t.a[p..end].partition_point(|&x| x < key)
}
```

* `count_less_u32x16` は 16 個の `u32` と比較してマスクの popcount を取るだけ (00-primitives.md の SIMD 比較の `u32` 版)。原典は if-else に展開した二分探索だが、今の CPU では SIMD 1回のほうが速い。
* 葉の中で末尾まで行ったら `p + M`。これは次の葉の先頭位置でもある (`a` がキー順なので、深い葉の最後 → 浅い葉の最初 もつながっている)。
* level CSS-Tree では `child_level` を使い、スロットは m-1 個だけ比べる。予備スロットには構築時に「最後の子の最大キー」を入れておくと、構築で部分木を辿らずに済む (原典 4.2)。

### 2.6 境界条件と落とし穴

* **n が m の倍数でない**: 最後の葉が半端になる。上の擬似コードは `min(n)` で切った。代わりに `a` を `u32::MAX` で m の倍数まで論理的に埋めてもよい。ただし `u32::MAX` 自体を検索したときに埋め草に当たるので、結果を `min(n)` で切ること。
* **ぶら下がりスロット**: 最深レベルの最後の葉の祖先は、子が m+1 個そろわないことがある。そのスロットに前半の最大値を入れるので、ノード内に重複キーができる。lower_bound は左端に寄るので、存在しない子には降りない。
* **前半の最大値より大きいキー**: 上位のノードで浅い葉側へ振り分けられるので、ぶら下がりスロットには到達しない。テストで「全キー + 各キー±1 + 最小未満 + 最大超」を検索して確かめる。
* **浅い葉がない場合** (N = f^k ちょうど): `first_deep == n_internal`、写像は前半だけになる。
* **重複キー**: lower_bound は先頭の一致を返す。原典も「左端の一致」を返す。
* **整数の桁あふれ**: `f^k` は N の f 倍未満なので usize で十分。ただし `smallest_power_ge` は乗算前にあふれを確認する。

### 2.7 テスト方針

* オラクルは `a.partition_point(|&x| x < key)` そのもの (ソート済み配列の二分探索)。
* n = 0, 1, m-1, m, m+1, (m+1)^k ± 1 など境界のサイズを全部試す。m を 2〜5 に下げた版でも回す (形が手で検算できる)。
* 不変条件チェッカー: 各内部ノードの各スロットについて、子の部分木を再帰で辿って最大キーを計算し、`keys[i]` と一致するか (ぶら下がりは dangling と一致するか) を見る。
* 葉の写像: すべての葉番号を `leaf_to_pos` に通し、0..N の置換になっているかを見る。

### 2.8 原典との違い・簡略化

* キー `u32`、ノード 64 B、m = 16 で固定した。原典は m を可変にして性能を比較している。
* ノード内探索は原典の「if-else 展開の二分探索」ではなく SIMD の比較 + popcount にした。
* 構築は原典の「右端の枝を辿る」方式ではなく、後ろから1回の走査で部分木の最大を伝える方式に書き直した (結果は同じ)。
* レコード ID の扱い、ドメイン ID 化 (長いキーを整数に置き換える話) は省いた。

---

## 3. CSB+-Tree

### 3.1 目的と原典との関係

* Rao & Ross, SIGMOD 2000。CSS-Tree の速さを保ちつつ、**1件ずつの挿入**を可能にした B+-Tree。
* ある内部ノードの子をすべて連続したメモリ (**ノードグループ**) に置く。内部ノードは**先頭の子へのポインタ1本**だけを持つ。
  i 番目の子は `first_child + i`。
* ポインタが1本で済むので、キャッシュライン1本に入るキーが増える (原典: 64 B, 4 B キー/ポインタで B+-Tree 7 キー → CSB+ 14 キー)。
* 変種が3つある。
  * **基本形**: 分割のたびに、グループを1ノード大きいものに作り直してコピー。
  * **segmented**: 子を2〜3個のセグメントに分け、セグメントごとにポインタを持つ。コピーは1セグメント分で済む。
  * **full**: グループを最初から最大サイズで確保する。分割は同じグループ内で後ろ半分を1ノードずらすだけ。
* 原典の結論: full CSB+-Tree が探索・更新ともに B+-Tree より速い (空間は少し多い)。

### 3.2 データ配置

64 B ノード、`u32` キー、8 B ポインタ。**以下のキー数は筆者が 64 ビット向けに計算し直したもの**。

```rust
const NODE: usize = CACHE_LINE;              // 64
const IK: usize = 13;                        // 内部ノードのキー数の上限 (2d)
const LK: usize = 7;                         // 葉のペア数の上限

#[repr(C, align(64))]
struct Inner {                 // offset  size
    first_child: *mut Node,    // 0       8    子のグループの先頭 (葉でも内部でも Node 配列)
    n_keys: u16,               // 8       2    使っているキーの数 (子は n_keys + 1 個)
    _pad: u16,                 // 10      2
    keys: [u32; IK],           // 12      52   keys[i] = 子 i の部分木の最大キー
}                              // 合計 64

#[repr(C, align(64))]
struct Leaf {                  // offset  size
    n: u16,                    // 0       2
    _pad: u16,                 // 2       2
    keys: [u32; LK],           // 4       28   昇順
    tids: [u32; LK],           // 32      28   値 (タプル ID)
    _pad2: u32,                // 60      4
}                              // 合計 64

#[repr(C, align(64))]
union Node { inner: Inner, leaf: Leaf }       // どちらかは木の高さで決まる (タグ不要)

/// full CSB+ のノードグループ。最大 fanout 個ぶんを最初から確保する。
#[repr(C, align(64))]
struct Group {                 // offset  size
    len: u16,                  // 0       2    使用中のノード数
    _pad: [u8; 6],             // 2       6
    prev: *mut Group,          // 8       8    葉のグループのみ: 左隣のグループ
    next: *mut Group,          // 16      8    葉のグループのみ: 右隣のグループ
    _pad2: [u8; 40],           // 24      40
    nodes: [Node; IK + 1],     // 64      14 * 64 = 896
}                              // 合計 960
```

```
内部ノード p:  [first_child | n_keys=3 | k0 k1 k2 . . . ]
                    │
                    ▼  Group (連続配置)
               [hdr][ 子0 ][ 子1 ][ 子2 ][ 子3 ][ 空 ]...[ 空 ]
                     ≤k0   ≤k1   ≤k2   残り
```

* 原典は「グループ内の葉は隣が連続しているので、兄弟ポインタはグループの最初の葉 (後ろ向き) と最後の葉 (前向き) にだけ持てばよい」として葉に 7 ペアを詰めている。
  ここではそのポインタを `Group` のヘッダに移した (どの葉が端かを気にしなくてよい)。**この配置は筆者の変更**。
* `first_child` は `Group` ではなく `nodes[0]` を指す。ヘッダは `first_child` から 64 B 前にある (`Group` が 64 B 境界なので計算で戻れる)。

### 3.3 不変条件

* 全葉が同じ深さ。
* 内部ノード: `n_keys + 1 == 子グループの len`。キーは昇順。
* 子 i の全キー `x` について `keys[i-1] < x <= keys[i]` (最後の子は `keys[n_keys-1] < x`)。
* 葉: `keys[0..n]` が昇順。
* 葉グループの `prev/next` は、葉を左から順に並べたときの隣のグループを指す。
* 遅延削除を採るので、充填率の下限 (d 以上) は**保証しない** (原典もそう運用している)。

### 3.4 探索

```rust
fn child_index(p: &Inner, key: u32) -> usize {
    // key 以下のキーを持つ最初の子 = key より小さいキーの数
    // 未使用スロットを u32::MAX で埋めておけば、n_keys を見ずに 13 個全部と比べてよい
    count_less_u32(&p.keys, key)      // 0..=n_keys
}

// 以下、生ポインタの参照外し ((*n).inner など) は unsafe。ブロックは省略する。
fn find_leaf(root: *mut Node, height: usize, key: u32) -> *mut Leaf {
    let mut n = root;
    for _ in 0..height {                       // height = 内部ノードの段数
        let p = unsafe { &(*n).inner };
        n = unsafe { p.first_child.add(child_index(p, key)) };   // 子 = 先頭 + 添字
    }
    unsafe { &mut (*n).leaf }
}

fn lookup(t: &Tree, key: u32) -> Option<u32> {
    let l = find_leaf(t.root, t.height, key);
    let i = l.keys[..l.n as usize].partition_point(|&x| x < key);
    (i < l.n as usize && l.keys[i] == key).then(|| l.tids[i])
}
```

* 未使用キーを `u32::MAX` で埋める話は原典 3.1.2 の「uniform approach」(未使用スロットを最大キーで埋めて、展開済みの比較をそのまま使う)。
  ただし本物の `u32::MAX` が入ると区別できない。キー空間から `u32::MAX` を除くか、`count_less` の結果を `n_keys` で `min` する。
* 親の `first_child` を読むのと、子のノードを読むのとで、キャッシュミスは各段1回。B+-Tree と同じ回数で、分岐数が倍なので段数が減る。

### 3.5 挿入 (full CSB+、上から先に分割する版)

原典は B+-Tree と同じく**葉から上へ**分割を伝える。ここでは実装を単純にするため、**降りながら満杯の子を先に分割する** (top-down の予防的分割) で書く。
親に必ず空きがある状態で子を分割できるので、「親も満杯」の場合分けが消える。**この変更は簡略化として明記する**。

ノードグループ内の分割 (親 p に空きがある前提):

```rust
/// p の子 i を2つに割る。p.n_keys < IK を前提とする。
fn split_child(p: &mut Inner, i: usize, child_is_leaf: bool) {
    let g = group_of(p.first_child);                 // ヘッダへ戻る
    let len = g.len as usize;                        // == p.n_keys + 1
    // 1) グループ内で i+1 以降を1ノード右へずらす (memmove。重なりあり)
    g.nodes.copy_within(i + 1..len, i + 2);
    g.len += 1;
    // 2) 子 i の後ろ半分を、空いた i+1 に移す
    let sep = if child_is_leaf {
        let (l, r) = (&mut g.nodes[i].leaf, &mut g.nodes[i + 1].leaf);
        let h = l.n as usize / 2;
        r.keys[..l.n as usize - h].copy_from_slice(&l.keys[h..l.n as usize]);
        r.tids[..l.n as usize - h].copy_from_slice(&l.tids[h..l.n as usize]);
        r.n = l.n - h as u16; l.n = h as u16;
        l.keys[h - 1]                                // 左の最大 = 区切りキー
    } else {
        split_inner_into(&mut g.nodes[i].inner, &mut g.nodes[i + 1].inner)  // 下記
    };
    // 3) 親に区切りキーを差し込む (キーも1つ右へずらす)
    p.keys.copy_within(i..p.n_keys as usize, i + 1);
    p.keys[i] = sep;
    p.n_keys += 1;
}
```

内部ノードの分割は、**そのノードの子グループも2つに割る**のが CSB+ 固有の部分。

```rust
/// 満杯の内部ノード l を l と r に割り、区切りキーを返す。
/// l の子グループ g を g (前半) と新しいグループ g2 (後半) に分ける。
fn split_inner_into(l: &mut Inner, r: &mut Inner) -> u32 {
    let nk = l.n_keys as usize;                      // == IK
    let h = nk / 2;                                  // l は keys[0..h], 子 0..=h を残す
    let sep = l.keys[h];                             // 子 h の最大 = 上に上がる区切り
    let g = group_of(l.first_child);
    let g2 = alloc_group();                          // 64 B 境界、最大サイズ
    let moved = nk - h;                              // 子 h+1..=nk を移す
    g2.nodes[..moved].copy_from_slice(&g.nodes[h + 1..=nk]);
    g2.len = moved as u16;  g.len = (h + 1) as u16;
    if is_leaf_level(g) {                            // 葉グループの鎖をつなぎ直す
        g2.next = g.next; g2.prev = g;
        if !g.next.is_null() { (*g.next).prev = g2; }
        g.next = g2;
    }
    r.keys[..nk - h - 1].copy_from_slice(&l.keys[h + 1..nk]);
    r.n_keys = (nk - h - 1) as u16;
    r.first_child = &mut g2.nodes[0];
    l.n_keys = h as u16;
    fill_unused_with_max(l); fill_unused_with_max(r);
    sep
}
```

木全体の挿入:

```rust
fn insert(t: &mut Tree, key: u32, tid: u32) {
    // 根が満杯なら、新しい根と長さ1のグループを作ってから割る (木が1段高くなる)
    if is_full(t.root, t.height) {
        let g = alloc_group();
        g.nodes[0] = *t.root;  g.len = 1;            // 旧根をグループに移す
        free_root(t.root);
        let new_root = alloc_root_inner(&mut g.nodes[0]);   // n_keys = 0
        split_child(new_root, 0, t.height == 0);
        t.root = new_root; t.height += 1;
    }
    let mut n = t.root;
    for level in 0..t.height {
        let p = &mut (*n).inner;
        let mut i = child_index(p, key);
        let child = p.first_child.add(i);
        let child_is_leaf = level + 1 == t.height;
        if is_full(child, child_is_leaf) {
            split_child(p, i, child_is_leaf);
            if key > p.keys[i] { i += 1; }           // 割った後どちらへ行くか
        }
        n = p.first_child.add(i);                    // グループが動いていないので再計算でよい
    }
    leaf_insert_sorted(&mut (*n).leaf, key, tid);    // 空きは保証済み。既存キーなら上書き
}
```

* `is_full`: 葉は `n == LK`、内部は `n_keys == IK`。
* full CSB+ ではグループは移動しないので、`first_child` は分割後も有効。基本形 (グループを作り直す版) では `split_child` の後に `p.first_child` が変わる。
* 上書きの扱い (同じキーの再挿入) は B+-Tree と同じ。ここでは上書きにした。

### 3.6 基本形と segmented の差分

**基本形 (グループを毎回作り直す)**

* グループは `len` ちょうどの大きさで確保する。`split_child` の 1) を「`len+1` ノードの新グループを確保 → 0..=i をコピー → 分割結果を i, i+1 に書く → 残りを i+2 以降にコピー → 親の `first_child` を差し替え → 旧グループを解放」に置き換える。
* コピー量は毎回グループ全体 (原典: 128 B 行で最大約 4 KB)。

**segmented (2セグメント)**

```rust
#[repr(C, align(64))]
struct SegInner {              // offset  size
    seg: [*mut Node; 2],       // 0       16   各セグメントの先頭
    seg0_len: u8,              // 16      1    セグメント0の子の数
    n_keys: u8,                // 17      1
    _pad: u16,                 // 18      2
    keys: [u32; 11],           // 20      44
}                              // 合計 64 (キー 11 個。原典は 4 B ポインタで 13 個)

fn seg_child(p: &SegInner, i: usize) -> *mut Node {
    let s0 = p.seg0_len as usize;
    if i < s0 { p.seg[0].add(i) } else { p.seg[1].add(i - s0) }   // 余分な比較が1回
}
```

* bulk load でセグメントに均等に配る。挿入では**新しいノードが属するセグメントだけ**を1つ大きく作り直す。
* 親も分割するときは両方のセグメントをコピーする。
* セグメントを1つ増やすごとに、ポインタとサイズでキー2つ分を失う (原典 Table 1)。

### 3.7 削除

* 原典は**遅延削除**: 葉からエントリを消すだけで、充填率の回復 (併合・再分配) をしない。「ファイルは普通は縮まず伸びる」が理由。
* 葉が空になっても残す。探索は空の葉に降りても「見つからない」を返すだけで正しい。

```rust
fn remove(t: &mut Tree, key: u32) -> bool {
    let l = find_leaf(t.root, t.height, key);
    let n = l.n as usize;
    let i = l.keys[..n].partition_point(|&x| x < key);
    if i == n || l.keys[i] != key { return false; }
    l.keys.copy_within(i + 1..n, i);
    l.tids.copy_within(i + 1..n, i);
    l.n -= 1;
    true          // 親の区切りキーは「最大の上界」なので古いままでも正しい
}
```

* 区切りキーは子の最大キーの**上界**として働けばよいので、消した後に直さなくても探索は正しい。
* 本格的な併合をするなら、グループ内で隣と併合 → グループを詰める (`copy_within` で左へ) → 親のキーを1つ消す。【未検証】原典に手順の記述はない。

### 3.8 範囲走査

* 葉グループの中は `nodes[0..len]` を順に読む。グループの端に来たら `Group.next` へ移る。
* ハードウェアのプリフェッチが効く。連続配置の副次的な利点。

### 3.9 bulk load

原典 3.1.1 の手順。

1. 葉を左から詰める。**同じ親に入る葉が1つのグループ**になるよう、葉の段をまとめて確保する (full 版では親ごとに最大サイズのグループ)。
2. 1段上のノード数を計算し、その段をまとめて確保する。各親のキーに「子の最大キー」をコピーし、`first_child` を設定する。
3. 1段のノードが1個になるまで繰り返す。それが根。

* 原典の実験では内部ノードを1スロット空けて (満杯にしないで) 構築している。理由は原典に書かれていない。直後の挿入で即分割が連鎖しないため、というのは筆者の解釈。

### 3.10 境界条件と落とし穴

* **空の木**: 根は空の葉 (`height = 0`)。最初の挿入で葉が満杯になるまで内部ノードはない。
* **根の分割**: 旧根を長さ1のグループに移してから割る。根だけはグループに属さない単独確保になる。
* **アラインメント**: `Node` が 64 B 境界にないとキャッシュライン2本にまたがり、利点が消える。グループ確保は `Layout::from_size_align(960, 64)`。
* **`copy_within` は重なりあり**: Rust の `copy_within` は memmove 相当なので安全。生ポインタで書くなら `ptr::copy` (重なり可) を使い、`copy_nonoverlapping` は使わない。
* **ポインタの寿命**: 基本形・segmented ではグループが作り直されるので、降りる途中で持っていた子へのポインタは無効になる。分割の後は親から取り直す。
* **区切りキーの意味**: 「子の最大キー」方式なので、`key == keys[i]` は子 i に入る。`<` と `<=` を取り違えると、区切りキーと等しいキーが見つからなくなる。
* **`u32::MAX` を埋め草に使うとき**: 本物のキーと衝突する (3.4 参照)。

### 3.11 テスト方針

* オラクル: `BTreeMap<u32, u32>`。insert / remove / lookup / 範囲走査をランダムに 10 万回流し、毎回の結果を比べる。
* 定数を小さくした版 (IK = 3, LK = 2) でも回す。分割・グループの分割・根の分割が頻繁に起きる。
* 不変条件チェッカー (各操作の後):
  * 全葉の深さが等しい。
  * 各内部ノードで `n_keys + 1 == group.len`、キー昇順、子の全キーが区切りの範囲内。
  * 葉グループの `prev/next` を左から辿った順と、木を再帰で辿った葉の順が一致する。
  * `first_child` が 64 B 境界で、`group_of(first_child).nodes[0]` と一致する。
* 狙い撃ち: 昇順挿入 (右端だけが分割され続ける)、降順挿入、同じキーの繰り返し、全削除してから再挿入。

### 3.12 原典との違い・簡略化

* 64 ビットのポインタに合わせてノードのキー数を計算し直した (内部 13 キー、葉 7 ペア。segmented は 11 キー)。原典の数字 (14 / 7 / 13) とは違う。
* 葉の兄弟ポインタを、葉ではなくグループのヘッダに移した。
* 挿入を top-down の予防的分割で書いた。原典は葉から上へ伝える bottom-up。分割の回数がわずかに増える (満杯でも分割不要だった場合まで割る)。
* 削除は原典どおり遅延削除のみ。併合は書いていない。
* ノード内探索は原典の if-else 展開 (basic / uniform / variable) ではなく、`count_less` の SIMD 版にした。
* 3セグメント版、並行制御、回復は扱わない (原典も並行制御は対象外)。

---

## 4. 参考資料

* Jun Rao, Kenneth A. Ross. *Cache Conscious Indexing for Decision-Support in Main Memory*. VLDB 1999. https://courses.cs.duke.edu/spring03/cps216/papers/rao-ross-1999.pdf
  * 4.1 Full CSS-Trees (Lemma 4.1、葉の写像、構築と探索), 4.2 Level CSS-Trees。
* Jun Rao, Kenneth A. Ross. *Making B+-Trees Cache Conscious in Main Memory*. SIGMOD 2000. https://courses.cs.duke.edu/spring03/cps216/papers/rao-ross-2000.pdf
  * 3.1 (ノード構造、bulk load、探索、挿入、削除), 3.1.2 (ノード内探索), 3.2 segmented, 3.3 full, 5章 (葉の兄弟ポインタの省略)。
* Marcus Müller, Lawrence Benson, Viktor Leis. *B-Trees Are Back: Engineering Fast and Pageable Node Layouts*. SIGMOD 2025. Section 8 (In-Memory B-Trees)。
