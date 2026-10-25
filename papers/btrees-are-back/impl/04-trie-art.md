# 04. トライの基本と ART

background.md の 3.1 (トライの基本) と 3.2 (ART) を、自分で書けるように書き下す。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* キーの作り方 (終端の付け方) は [02-key-encoding.md](02-key-encoding.md)、`simd_eq_mask_u8x16` などの部品は [00-primitives.md](00-primitives.md) を参照。
* 単一スレッド・全データがメモリ上、という前提で書く。並行版 (ROWEX / OLC) は [12-concurrency.md](12-concurrency.md) の考え方を当てはめる。

参照実装は2つ読んだ。擬似コードは読みやすさを優先して書き直したもので、コードの直訳ではない。

* 論文の比較で使われた ART: [btree-cpp](https://github.com/m-mueller678/btree-cpp/tree/sigmod25) の `in-memory-structures/ART/ART.cpp` (Leis 本人の実装を移植したもの)
* 葉にキー全体を持つ版: [armon/libart](https://github.com/armon/libart) の `src/art.c`

## 目次

1. [目的と論文との関係](#1-目的と論文との関係)
2. [トライの基本](#2-トライの基本)
3. [ART のデータ配置](#3-art-のデータ配置)
4. [不変条件](#4-不変条件)
5. [lookup](#5-lookup)
6. [insert](#6-insert)
7. [delete](#7-delete)
8. [範囲走査 (scan)](#8-範囲走査-scan)
9. [キーの終端が必要な理由](#9-キーの終端が必要な理由)
10. [Rust での書き方](#10-rust-での書き方)
11. [境界条件と落とし穴](#11-境界条件と落とし穴)
12. [テスト方針](#12-テスト方針)
13. [原典との違い・簡略化](#13-原典との違い簡略化)
14. [参考資料](#14-参考資料)

---

## 1. 目的と論文との関係

* ART (Adaptive Radix Tree) は、キーを1バイトずつ見て子を選ぶ基数木。子の数に応じてノードの形を4種類から選ぶ。
* 論文の Section 6.1 の比較相手。
  * 整数キーの lookup では ART が最速 (適応型 B-Tree より sparse で 129%、dense で 73% 速い)。
  * 文字列キーの lookup では適応型 B-Tree より 34〜37% 遅い。
  * scan では B-Tree が圧勝する。trie は1回の scan で多数のノードを渡り歩くため。
* 論文では、ART の葉に「ヒープに確保したタプル (キーと値のコピー入り) へのポインタ」を置いて比べている。葉からキー全体を取り出せることが ART の前提だから (§2.4)。

## 2. トライの基本

### 2.1 span

* **span** = 1段で消費するビット数。ART は 8 (= 1バイト) に固定する。
* span が s なら、ノードの子は最大 2^s 個。木の高さは `キー長 (ビット) / s` 段。
* 高さはキーの**長さ**で決まり、件数には依存しない。比較も再平衡もいらない。
* span を大きくすると浅くなるが、子の配列が疎になってメモリを無駄にする。ART は「span 8 + ノードの形を子の数で変える」でこれを解決する。

### 2.2 path compression (経路圧縮)

子が1つしかない内部ノードの連鎖を、1つのノードの「prefix」にまとめる。

```
圧縮前:            圧縮後:
  (root)             (root)
    | 'a'              | 'a'
   ( )               (prefix="nd", 子2つ)
    | 'n'             /      \
   ( )              'e'      'y'
    | 'd'           ...      ...
   ( )  ← 子2つ
   /  \
 'e'  'y'
```

* prefix の長さだけ深さが進む。ノードの数は「分岐の数」に比例する。

### 2.3 lazy expansion (遅延展開)

* 葉の上に「その葉にしか通じない」内部ノードを作らない。葉を、区別が必要になった最初の深さに直接ぶら下げる。
* 例: キーが "and" と "dog" だけなら、root の子 'a' と 'd' に直接葉が付く。"nd" と "og" の部分はどこにも書かれない。

### 2.4 キー全体の照合が必要な理由

* lazy expansion で省いたバイトは、木のどこにも残っていない。
* 2.2 の prefix も、後述の「楽観的な読み飛ばし」をすると検査されない。
* したがって、葉に着いた時点では「探索キーと途中まで一致した」としか言えない。
* **最後に葉のキー全体と照合する**。そのため、葉 (または値) からキー全体を取り出せる必要がある。

## 3. ART のデータ配置

### 3.1 子スロット (タグ付きポインタ)

内部ノードの子スロットは8バイト1語。3種類の値をとる。

```
 63                                         1   0
+--------------------------------------------+---+
| 0 ................................. 0       | 0 |  空 (null)
+--------------------------------------------+---+
| 内部ノードのアドレス (8 の倍数)            | 0 |  内部ノード
+--------------------------------------------+---+
| 葉のアドレス (8 の倍数) または 63bit の値  | 1 |  葉
+--------------------------------------------+---+
```

* 内部ノードも葉も8バイト境界に確保するので、アドレスの最下位ビットは常に0。そこを「葉かどうか」の印に使う。
* 葉の表し方は2通りある (ART 論文は他に multi-value leaves も挙げているが、ここでは使わない)。
  * **single-value leaf**: 別に確保した `Leaf { key, value }` を指す。キーも値も可変長でよい。この資料の既定。
  * **combined pointer/value slot**: スロットに値そのもの (タプル ID) を `(tid << 1) | 1` として埋め込む。葉の確保が要らず、間接参照が1回減る。ただしタプル ID からキー全体を作る関数 `load_key(tid)` が外から与えられる必要がある。二次索引向き。ART.cpp はこの形 (`makeLeaf`, `getLeafValue`, `isLeaf`)。

```rust
#[repr(C)]
struct Leaf {              // single-value leaf
    key: Box<[u8]>,        // キー全体 (02 で正規化 + 終端付き)
    value: Value,
}
```

### 3.2 共通ヘッダ (16 バイト)

```rust
const MAX_PREFIX: usize = 8;

#[repr(u8)]
enum NodeType { N4 = 0, N16 = 1, N48 = 2, N256 = 3 }

#[repr(C)]
struct Header {                    // offset  size
    prefix_len: u32,               // 0       4   圧縮した経路の「本当の」長さ (8 を超えてよい)
    count: u16,                    // 4       2   空でない子の数 (Node256 で 256 まで入るので u16)
    node_type: NodeType,           // 6       1
    prefix: [u8; MAX_PREFIX],      // 7       8   経路の先頭 min(prefix_len, 8) バイト
    _pad: u8,                      // 15      1
}                                  // 合計 16 バイト
```

* **ハイブリッド方式** (ART 論文 III-E):
  * prefix_len ≤ 8 なら、prefix の全バイトが `prefix` にある。lookup で全部照合できる (pessimistic)。
  * prefix_len > 8 なら、先頭8バイトだけがある。残りは照合せずに読み飛ばし (optimistic)、葉でまとめて照合する。
  * insert / delete で残りのバイトが必要になったら、その部分木の任意の葉 (§6.2 では最小の葉) のキーから取り出す。部分木の葉はすべて同じ prefix を持つから。
* 参照実装の値は ART.cpp が 9、libart が 10。論文は 8。どれでも動く。ここでは論文に合わせて 8 にした。

### 3.3 4種類のノード

```rust
#[repr(C)]
struct Node4 {                     // offset  size
    h: Header,                     // 0       16
    keys: [u8; 4],                 // 16      4   ソート済み、count 個だけ有効
    _pad: [u8; 4],                 // 20      4   (Slot の 8 バイト境界合わせ)
    children: [Slot; 4],           // 24      32
}                                  // 56 バイト

#[repr(C)]
struct Node16 {
    h: Header,                     // 0       16
    keys: [u8; 16],                // 16      16  ソート済み、count 個だけ有効
    children: [Slot; 16],          // 32      128
}                                  // 160 バイト

const EMPTY48: u8 = 0xFF;          // child_index の「子なし」。48 以上なら何でもよい

#[repr(C)]
struct Node48 {
    h: Header,                     // 0       16
    child_index: [u8; 256],        // 16      256  バイト値 → children の添字。空は EMPTY48
    children: [Slot; 48],          // 272     384  順不同。削除で穴が空く
}                                  // 656 バイト

#[repr(C)]
struct Node256 {
    h: Header,                     // 0       16
    children: [Slot; 256],         // 16      2048 バイト値で直接引く。空は null
}                                  // 2064 バイト
```

```
Node4 / Node16:  [hdr][k0 k1 k2 ..][p0 p1 p2 ..]     k_i と p_i が対応。k はソート済み
Node48:          [hdr][idx[0] .. idx[255]][p0 .. p47]
                       idx[b] = i なら p_i がバイト b の子
Node256:         [hdr][p[0] .. p[255]]                p[b] がバイト b の子
```

* 論文の表 (Node4 = 52 B) はパディングなしの値。`#[repr(C)]` だと `children` が 8 バイト境界に揃うので 56 B になる。他の3つは論文と同じ値。
* Node16 の keys はここでは**生のバイト値**で持つ。ART.cpp は SSE の符号付き比較を使うため `b ^ 0x80` で持っている (`flipSign`)。§5.3 を参照。
* Node48 の空の表し方は実装ごとに違う。ART.cpp は `48`、libart は `0` を空にして添字に +1 する。ここでは `0xFF` を空にした。

### 3.4 子の数の範囲 (ヒステリシス付き)

| 型 | 大きくなる条件 | 小さくなる条件 | 子の数の範囲 |
|---|---|---|---|
| Node4 | 5個目の追加で Node16 へ | 1個になったら消える (§7.3) | 2〜4 |
| Node16 | 17個目の追加で Node48 へ | 3個になったら Node4 へ | 4〜16 |
| Node48 | 49個目の追加で Node256 へ | 12個になったら Node16 へ | 13〜48 |
| Node256 | なし | 37個になったら Node48 へ | 38〜256 |

* 縮小の閾値 (3, 12, 37) は、拡大の境界 (4, 16, 48) より小さい。境界ちょうどで insert と delete を交互に繰り返すと、毎回ノードを作り直すことになる。それを防ぐため (libart のコメントにもある)。
* 両方の参照実装が同じ値を使っている (ART.cpp `eraseNode16/48/256`、libart `remove_child16/48/256`)。

## 4. 不変条件

1. 内部ノードの子は2つ以上 (root を含む)。子が1つになった Node4 はその場で消す。
2. ノードの型と count は §3.4 の範囲にある。count は空でない子の数と一致する。
3. Node4 / Node16 の `keys[0..count]` は狭義単調増加。
4. Node48: `child_index[b] != EMPTY48` の b がちょうど count 個。それらが指す添字はすべて異なり、指す先の `children` は null でない。どこからも指されない `children` は null。
5. Node256: null でない子がちょうど count 個。
6. 内部ノード N の部分木にある全ての葉 L について、L.key の `[depth(N) .. depth(N) + N.prefix_len]` が N の (本当の) prefix に等しい。
   `prefix` バッファには、その先頭 `min(prefix_len, 8)` バイトが入っている。
   * depth(N) = 親までに消費したバイト数 = Σ (祖先の prefix_len + 1)。
7. 葉 L が親 N のバイト b の子なら、`L.key[depth(N) + N.prefix_len] == b`。
8. どのキーも他のキーの接頭辞ではない (§9)。

## 5. lookup

### 5.1 全体

```rust
fn lookup(root: Slot, key: &[u8]) -> Option<&Value> {
    let mut node = root;
    let mut depth = 0;
    loop {
        if node.is_null() { return None; }
        if node.is_leaf() {
            let leaf = node.as_leaf();               // unsafe: 生ポインタの参照外し
            // 照合は必須 (§2.4)。depth より前も、読み飛ばした prefix があれば一致の保証がない
            return if &*leaf.key == key { Some(&leaf.value) } else { None };
        }
        let h = node.header();
        if h.prefix_len > 0 {
            if !check_prefix_optimistic(h, key, depth) { return None; }
            depth += h.prefix_len as usize;
        }
        if depth >= key.len() { return None; }       // 終端付きキーなら、存在するキーではここに来ない
        node = find_child(node, key[depth]);
        depth += 1;
    }
}

/// バッファにある分 (先頭 min(len, 8) バイト) だけ照合する。
/// len > 8 の残りは照合しない (optimistic)。葉の照合で拾う。
fn check_prefix_optimistic(h: &Header, key: &[u8], depth: usize) -> bool {
    let n = (h.prefix_len as usize).min(MAX_PREFIX);
    if depth + n > key.len() { return false; }
    key[depth..depth + n] == h.prefix[..n]
}
```

* ART.cpp の `lookup` は、len ≥ 9 (`prefixLength < maxPrefixLength` でないとき) にバッファの照合もせず全部読み飛ばす。バッファ分だけ照合しておくと、早めに打ち切れる。どちらでも正しい。
* combined pointer/value slot の場合は、葉の照合を `load_key(tid) == key` に置き換える。
* ART.cpp は「一度も読み飛ばしておらず、depth == key.len() なら照合を省く」最適化をしている。終端付きキーを前提にした最適化なので、まずは常に照合する形で書く。

### 5.2 find_child

```rust
fn find_child(node: Slot, b: u8) -> Slot {
    match node.header().node_type {
        N4 => {
            let n = node.as_n4();
            for i in 0..n.h.count as usize {
                if n.keys[i] == b { return n.children[i]; }
            }
            Slot::NULL
        }
        N16 => {
            let n = node.as_n16();
            // 00-primitives.md: 16 バイトを b と一斉比較し、一致した位置のビットを立てた u16 を返す
            let mask = simd_eq_mask_u8x16(b, &n.keys) & ((1u32 << n.h.count) - 1) as u16;
            if mask == 0 { Slot::NULL } else { n.children[mask.trailing_zeros() as usize] }
        }
        N48 => {
            let n = node.as_n48();
            let i = n.child_index[b as usize];
            if i == EMPTY48 { Slot::NULL } else { n.children[i as usize] }
        }
        N256 => node.as_n256().children[b as usize],
    }
}
```

* insert / delete では、見つけた子スロットを書き換えるので、`&mut Slot` を返す版 (`find_child_mut`) も用意する。
* Node16 のマスクは**必ず** `(1 << count) - 1` で切る。count より後ろの keys は 0 のままなので、b = 0 を探すと空きの位置に一致してしまう。

### 5.3 Node16 と SIMD

* 一致の判定 (`find_child`) は符号の有無に関係ない。生のバイト値のまま `simd_eq_mask_u8x16` で比べればよい。
* 挿入位置 (「b より大きい最初の位置」) を SIMD で求める場合は注意が要る。SSE2 の `_mm_cmplt_epi8` は**符号付き**比較。
  * ART.cpp は keys を `b ^ 0x80` で格納し、符号付き比較で符号なしの順序を得ている。
  * この場合、Node4 → Node16 の拡大で `^ 0x80` を掛け、Node16 → Node4 / Node48 で外す必要がある。忘れると順序が壊れる。
* ここでは keys を生のまま持ち、挿入位置は16回以下のスカラーループで求める。insert は lookup より少ないので十分。

### 5.4 pessimistic な prefix 照合 (insert / delete 用)

insert と delete では、prefix の**どこで**食い違うかを正確に知る必要がある。読み飛ばしは使わない。

```rust
/// N の prefix と key[depth..] が一致する長さ (0..=prefix_len) を返す。
fn prefix_mismatch(node: Slot, key: &[u8], depth: usize) -> usize {
    let h = node.header();
    let len = h.prefix_len as usize;
    let n = len.min(MAX_PREFIX);
    let mut i = 0;
    while i < n {
        if depth + i >= key.len() || key[depth + i] != h.prefix[i] { return i; }
        i += 1;
    }
    if len > MAX_PREFIX {
        // バッファにない部分は、部分木の最小の葉から取る (不変条件6 によりどの葉でもよい)
        let full = minimum_leaf(node).key();
        while i < len {
            if depth + i >= key.len() || key[depth + i] != full[depth + i] { return i; }
            i += 1;
        }
    }
    i
}

/// 部分木の最小の葉。Node4/16 は children[0]、Node48/256 はバイト値 0 から最初の空でない子。
fn minimum_leaf(mut node: Slot) -> &Leaf {
    while !node.is_leaf() {
        node = match node.header().node_type {
            N4 => node.as_n4().children[0],
            N16 => node.as_n16().children[0],
            N48 => { let n = node.as_n48();
                     let b = (0..256).find(|&b| n.child_index[b] != EMPTY48).unwrap();
                     n.children[n.child_index[b] as usize] }
            N256 => *node.as_n256().children.iter().find(|c| !c.is_null()).unwrap(),
        };
    }
    node.as_leaf()
}
```

## 6. insert

### 6.1 全体

`slot` は「このノードを指している親のスロット」。ノードを作り直したら、ここを書き換えて親に反映する (ART.cpp の `nodeRef`)。

```rust
/// 既存のキーなら値を置き換えて古い値を返す。
fn insert(slot: &mut Slot, key: &[u8], depth: usize, value: Value) -> Option<Value> {
    if slot.is_null() {                                  // 空の木
        *slot = Slot::new_leaf(Leaf::new(key, value));
        return None;
    }
    if slot.is_leaf() {
        return insert_at_leaf(slot, key, depth, value);  // §6.2
    }
    let mut depth = depth;
    let plen = slot.header().prefix_len as usize;
    if plen > 0 {
        let m = prefix_mismatch(*slot, key, depth);
        if m < plen {
            split_prefix(slot, key, depth, m, value);    // §6.3
            return None;
        }
        depth += plen;
    }
    let b = key[depth];                                  // 終端があるので範囲内 (§9)
    if let Some(child) = find_child_mut(*slot, b) {
        return insert(child, key, depth + 1, value);
    }
    add_child(slot, b, Slot::new_leaf(Leaf::new(key, value)));   // §6.4。拡大で *slot が変わりうる
    None
}
```

### 6.2 葉に当たったとき (lazy expansion の解消)

```
前:  slot → [Leaf "abcX.."]
key = "abcY..", depth = 1 (先頭 'a' は親で消費済み)

後:  slot → Node4 (prefix_len=2, prefix="bc")
              'X' → [Leaf "abcX.."]
              'Y' → [Leaf "abcY.."]   (新規)
```

```rust
fn insert_at_leaf(slot: &mut Slot, key: &[u8], depth: usize, value: Value) -> Option<Value> {
    let old = slot.as_leaf_mut();
    if &*old.key == key {                                // 同じキー: 値の更新
        return Some(core::mem::replace(&mut old.value, value));
    }
    // depth 以降の共通部分の長さ。終端により、どちらかのキーの末尾を越える前に必ず食い違う (§9)
    let mut p = 0;
    while key[depth + p] == old.key[depth + p] { p += 1; }

    let mut n4 = Node4::new();
    n4.h.prefix_len = p as u32;
    let c = p.min(MAX_PREFIX);
    n4.h.prefix[..c].copy_from_slice(&key[depth..depth + c]);
    let old_byte = old.key[depth + p];
    let new_leaf = Slot::new_leaf(Leaf::new(key, value));
    n4_insert_sorted(&mut n4, old_byte, *slot);          // 古い葉はそのまま子にする (再確保しない)
    n4_insert_sorted(&mut n4, key[depth + p], new_leaf);
    *slot = Slot::new_inner(n4);
    None
}
```

* ここが「先に完全一致を調べる」必要がある場所。調べずに共通部分を数えると、同じキーでは食い違う位置がなく、配列の外まで読む。
* p が 8 を超えたら、バッファには先頭8バイトだけ入れる。新しいノードは最初から optimistic になる。

### 6.3 prefix の途中で食い違ったとき

```
前:  slot → N (prefix_len=5, prefix="abcde")
key[depth..] = "abXYZ..."   → m = 2 で食い違う

後:  slot → Node4 (prefix_len=2, prefix="ab")
              'c' → N (prefix_len=2, prefix="de")    ← 5 - (2 + 1) = 2
              'X' → [Leaf key]                        (新規)
```

```rust
fn split_prefix(slot: &mut Slot, key: &[u8], depth: usize, m: usize, value: Value) {
    let node = slot.header_mut();
    let plen = node.prefix_len as usize;

    let mut n4 = Node4::new();
    n4.h.prefix_len = m as u32;
    // 新ノードの prefix = 古い prefix の先頭 m バイト。バッファの先頭 min(m, 8) バイトをそのまま写せる
    let c = m.min(MAX_PREFIX);
    n4.h.prefix[..c].copy_from_slice(&node.prefix[..c]);

    let branch: u8;
    let new_len = plen - (m + 1);
    if plen <= MAX_PREFIX {
        // 全バイトがバッファにある: m バイト目が分岐、m+1 以降を先頭へ詰める
        branch = node.prefix[m];
        node.prefix.copy_within(m + 1..plen, 0);
    } else {
        // バッファにない部分がある: 最小の葉のキーから取る (書き換える前に読むこと)
        let full = minimum_leaf(*slot).key();
        branch = full[depth + m];
        let c2 = new_len.min(MAX_PREFIX);
        node.prefix[..c2].copy_from_slice(&full[depth + m + 1..depth + m + 1 + c2]);
    }
    node.prefix_len = new_len as u32;

    n4_insert_sorted(&mut n4, branch, *slot);
    n4_insert_sorted(&mut n4, key[depth + m], Slot::new_leaf(Leaf::new(key, value)));
    *slot = Slot::new_inner(n4);
}
```

* plen > 8 のときに `node.prefix[m]` を使うのは誤り。m ≥ 8 ならバッファの外になる。m < 8 でも、詰め直した後のバッファの後半はバッファの外のバイトで埋める必要がある。だから両方とも葉のキーから取る。
* m < 8 かつ plen > 8 の場合も、上の else 側で正しく動く (葉のキーは prefix 全体を含むので)。

### 6.4 add_child と拡大 (grow)

```rust
fn add_child(slot: &mut Slot, b: u8, child: Slot) {
    match slot.header().node_type {
        N4 => {
            let n = slot.as_n4_mut();
            if n.h.count < 4 { n4_insert_sorted(n, b, child); return; }
            // Node4 → Node16: ヘッダ (prefix_len, prefix) と keys/children をそのまま写す (既にソート済み)
            let mut g = Node16::new();
            g.h = n.h.with_type(N16);
            g.keys[..4].copy_from_slice(&n.keys);
            g.children[..4].copy_from_slice(&n.children);
            replace_node(slot, g);                       // 古い Node4 を解放し *slot を差し替える (§10.3)
            add_child(slot, b, child);
        }
        N16 => {
            let n = slot.as_n16_mut();
            if n.h.count < 16 { n16_insert_sorted(n, b, child); return; }
            // Node16 → Node48: children は 0..16 に詰めて置き、索引を張る
            let mut g = Node48::new();                   // child_index は全部 EMPTY48、children は全部 null
            g.h = n.h.with_type(N48);
            for i in 0..16 {
                g.child_index[n.keys[i] as usize] = i as u8;
                g.children[i] = n.children[i];
            }
            replace_node(slot, g);
            add_child(slot, b, child);
        }
        N48 => {
            let n = slot.as_n48_mut();
            if n.h.count < 48 {
                // 削除で穴が空くので、count の位置が空いているとは限らない。null の位置を探す
                let pos = n.children.iter().position(|c| c.is_null()).unwrap();
                n.children[pos] = child;
                n.child_index[b as usize] = pos as u8;
                n.h.count += 1;
                return;
            }
            // Node48 → Node256: バイト値の順に索引をたどって置き直す
            let mut g = Node256::new();
            g.h = n.h.with_type(N256);
            for v in 0..256 {
                let i = n.child_index[v];
                if i != EMPTY48 { g.children[v] = n.children[i as usize]; }
            }
            replace_node(slot, g);
            add_child(slot, b, child);
        }
        N256 => {
            let n = slot.as_n256_mut();
            n.children[b as usize] = child;
            n.h.count += 1;
        }
    }
}

fn n4_insert_sorted(n: &mut Node4, b: u8, child: Slot) {   // n16 版も同じ形
    let cnt = n.h.count as usize;
    let pos = (0..cnt).find(|&i| n.keys[i] > b).unwrap_or(cnt);
    n.keys.copy_within(pos..cnt, pos + 1);
    n.children.copy_within(pos..cnt, pos + 1);
    n.keys[pos] = b;
    n.children[pos] = child;
    n.h.count += 1;
}
```

* Node48 の空き位置探しは、ART.cpp だと「まず `children[count]` を見て、埋まっていたら先頭から探す」。libart は常に先頭から探す。どちらでもよい。

## 7. delete

### 7.1 全体

```rust
fn remove(slot: &mut Slot, key: &[u8], depth: usize) -> Option<Value> {
    if slot.is_null() { return None; }
    if slot.is_leaf() {                                  // root が葉1枚のときだけここに来る
        if slot.as_leaf().key() != key { return None; }
        return Some(take_leaf(slot));                    // *slot = null にして葉を解放、値を返す
    }
    let mut depth = depth;
    let plen = slot.header().prefix_len as usize;
    if plen > 0 {
        if prefix_mismatch(*slot, key, depth) != plen { return None; }
        depth += plen;
    }
    if depth >= key.len() { return None; }
    let b = key[depth];
    let child = find_child_mut(*slot, b)?;
    if child.is_leaf() {
        if child.as_leaf().key() != key { return None; }
        let leaf = *child;
        remove_child(slot, b);                           // §7.2。縮小・消滅で *slot が変わりうる
        return Some(free_leaf(leaf));
    }
    remove(child, key, depth + 1)
}
```

* 内部ノードは子が2つ以上なので、子を再帰で処理しても、子のスロットは null にならない (1つの子に置き換わるだけ)。親の count は変わらない。

### 7.2 remove_child と縮小 (shrink)

```rust
fn remove_child(slot: &mut Slot, b: u8) {
    match slot.header().node_type {
        N256 => {
            let n = slot.as_n256_mut();
            n.children[b as usize] = Slot::NULL;
            n.h.count -= 1;
            if n.h.count == 37 {
                // Node256 → Node48: バイト値の順に詰めて置く。children は 0..37 が埋まる
                let mut s = Node48::new();
                s.h = n.h.with_type(N48);
                let mut pos = 0;
                for v in 0..256 {
                    if !n.children[v].is_null() {
                        s.children[pos] = n.children[v];
                        s.child_index[v] = pos as u8;
                        pos += 1;
                    }
                }
                replace_node(slot, s);
            }
        }
        N48 => {
            let n = slot.as_n48_mut();
            let i = n.child_index[b as usize];
            n.children[i as usize] = Slot::NULL;         // 穴が空く (詰めない)
            n.child_index[b as usize] = EMPTY48;
            n.h.count -= 1;
            if n.h.count == 12 {
                // Node48 → Node16: バイト値 0..256 の順に走査するので、keys は自動的にソート済みになる
                let mut s = Node16::new();
                s.h = n.h.with_type(N16);
                let mut k = 0;
                for v in 0..256 {
                    let j = n.child_index[v];
                    if j != EMPTY48 {
                        s.keys[k] = v as u8;
                        s.children[k] = n.children[j as usize];
                        k += 1;
                    }
                }
                replace_node(slot, s);                   // s.h.count は 12 のまま
            }
        }
        N16 => {
            let n = slot.as_n16_mut();
            let pos = position_of(&n.keys[..n.h.count as usize], b);
            remove_at(&mut n.keys, &mut n.children, pos, n.h.count);   // 後ろを1つ前に詰める
            n.h.count -= 1;
            if n.h.count == 3 {
                let mut s = Node4::new();
                s.h = n.h.with_type(N4);
                s.keys[..3].copy_from_slice(&n.keys[..3]);
                s.children[..3].copy_from_slice(&n.children[..3]);
                replace_node(slot, s);
            }
        }
        N4 => {
            let n = slot.as_n4_mut();
            let pos = position_of(&n.keys[..n.h.count as usize], b);
            remove_at(&mut n.keys, &mut n.children, pos, n.h.count);
            n.h.count -= 1;
            if n.h.count == 1 { collapse_n4(slot); }     // §7.3
        }
    }
}
```

* Node48 の `children` に穴を残すのは、詰めると `child_index` の書き換えが必要になるから。穴は次の add_child で再利用する (§6.4)。

### 7.3 子が1つになった Node4 の消去 (prefix の連結)

```
前:  slot → N (prefix_len=p, prefix=P)
              k → C (prefix_len=c, prefix=Q)       ← 残った唯一の子

後:  slot → C (prefix_len = p + 1 + c, prefix = 先頭8バイト of (P ++ [k] ++ Q))
```

```rust
fn collapse_n4(slot: &mut Slot) {
    let n = slot.as_n4();
    let child = n.children[0];
    if child.is_leaf() {
        // 葉はキー全体を持つので、N の prefix は捨ててよい
        replace_with_child(slot, child);                 // *slot = child、N を解放
        return;
    }
    let p = n.h.prefix_len as usize;
    let c = child.header().prefix_len as usize;

    // 新しいバッファ = (N の本当の prefix) ++ [k] ++ (C の本当の prefix) の先頭 min(p+1+c, 8) バイト
    let mut buf = [0u8; MAX_PREFIX];
    let mut l = p.min(MAX_PREFIX);
    buf[..l].copy_from_slice(&n.h.prefix[..l]);
    if l < MAX_PREFIX {
        buf[l] = n.keys[0];
        l += 1;
    }
    if l < MAX_PREFIX {
        let take = c.min(MAX_PREFIX - l);
        buf[l..l + take].copy_from_slice(&child.header().prefix[..take]);
        l += take;
    }
    let ch = child.header_mut();
    ch.prefix[..l].copy_from_slice(&buf[..l]);
    ch.prefix_len = (p + 1 + c) as u32;
    replace_with_child(slot, child);
}
```

* これで不変条件6 (「バッファ = 本当の prefix の先頭 min(len, 8) バイト」) が保たれる理由:
  * **p ≥ 8 のとき**: N のバッファは N の prefix の先頭8バイト。それは連結結果の先頭8バイトでもある。k も Q も使わない。
  * **p < 8 のとき**: N の prefix は全部バッファにある。次が k。残り `8 - p - 1` バイトは Q の先頭から取る。C のバッファには Q の先頭 `min(c, 8)` バイトがあり、これは必要な `min(c, 8 - p - 1)` 以上ある。
  * **c > 8 のとき**: Q のバッファ外の部分は使わない (連結結果の8バイト目より後ろになる)。
* 連結後の長さが 8 を超えたら、C はこの時点から optimistic になる。バッファの外は葉のキーで補う (§5.4)。
* `l` を `MAX_PREFIX` で抑えないと、バッファを書きあふれる。両参照実装とも同じ3段の `if` で抑えている (ART.cpp `eraseNode4`、libart `remove_child4`)。

## 8. 範囲走査 (scan)

### 8.1 全件を順に (in-order)

```rust
/// 部分木の葉をキー順に cb へ渡す。cb が false を返したら false を返して打ち切る。
fn iterate_all(node: Slot, cb: ScanCallback) -> bool {
    if node.is_leaf() { let l = node.as_leaf(); return cb(&l.key, l.value.as_bytes()); }
    match node.header().node_type {
        N4  => { let n = node.as_n4();  (0..n.h.count as usize).all(|i| iterate_all(n.children[i], cb)) }
        N16 => { let n = node.as_n16(); (0..n.h.count as usize).all(|i| iterate_all(n.children[i], cb)) }
        N48 => { let n = node.as_n48();
                 // children は順不同なので、必ず child_index をバイト値 0..256 の順にたどる
                 (0..256).all(|v| { let i = n.child_index[v];
                                    i == EMPTY48 || iterate_all(n.children[i as usize], cb) }) }
        N256 => { let n = node.as_n256();
                  (0..256).all(|v| n.children[v].is_null() || iterate_all(n.children[v], cb)) }
    }
}
```

* Node48 で `children[0..48]` を順に回すのは誤り。挿入順・穴の再利用順になっていて、キー順ではない。

### 8.2 開始キー以上を順に (lower bound から)

```rust
/// start 以上のキーを順に cb へ渡す。
fn scan_from(node: Slot, start: &[u8], depth: usize, cb: ScanCallback) -> bool {
    if node.is_null() { return true; }
    if node.is_leaf() {
        let l = node.as_leaf();
        return if &*l.key >= start { cb(&l.key, l.value.as_bytes()) } else { true };
    }
    let h = node.header();
    let plen = h.prefix_len as usize;
    // prefix のバイト列 (バッファ外は最小の葉から)
    let full_prefix: &[u8] = if plen <= MAX_PREFIX { &h.prefix[..plen] }
                             else { &minimum_leaf(node).key()[depth..depth + plen] };
    for i in 0..plen {
        if depth + i >= start.len() { return iterate_all(node, cb); }   // start が尽きた: 部分木は全部 start より大きい
        let (s, p) = (start[depth + i], full_prefix[i]);
        if s < p { return iterate_all(node, cb); }                       // 部分木は全部 start より大きい
        if s > p { return true; }                                        // 部分木は全部 start より小さい
    }
    let d = depth + plen;
    if d >= start.len() { return iterate_all(node, cb); }
    let b = start[d];
    // b と等しい子は再帰、b より大きい子は全件、小さい子は飛ばす
    for_each_child_from(node, b, |cb_byte, child| {
        if cb_byte == b { scan_from(child, start, d + 1, cb) } else { iterate_all(child, cb) }
    })
}
```

* `for_each_child_from(node, b, f)` は、バイト値 b 以上の子をバイト値の順に f へ渡す。f が false を返したら止める。
  * Node4 / Node16: `keys[i] >= b` となる最初の i から count まで。
  * Node48 / Node256: v を b..256 で回す。
* ART.cpp の `scan` は、prefix_len > 9 のとき、バッファの外の位置で `n->prefix[pos]` と比べている (配列の外を読む)。写さないこと。上のように最小の葉のキーと比べる。
* 1回の scan で多数のノードを渡り歩く。これが論文で B-Tree が scan で圧勝する理由 (§1)。

## 9. キーの終端が必要な理由

ART は「どのキーも他のキーの接頭辞ではない」ことを前提にしている (ART 論文 IV-d)。

**壊れる例**: "ab" と "abc" を入れる。

```
"ab" の葉がある所に "abc" を入れる (depth = 0):
  p = 共通部分の長さ → "ab" の2バイトが一致し、"ab" の 2 バイト目 (= 3文字目) を読もうとして配列の外
  仮に長さで止めても、"ab" 側に分岐用のバイトがない → Node4 のどのキーにも割り当てられない
```

* lookup でも、"ab" を探して depth = 2 で key が尽きる (§5.1 の `depth >= key.len()`)。"ab" はどこにも置けない。

**解決**: 02-key-encoding.md の方式で、可変長のキーに**終端**を付けて符号化する。

* 02 の符号に求める性質は2つ。**順序を保つこと**と、**どの符号も他の符号の接頭辞にならないこと** (prefix-free)。
* 02 の文字列の符号 (CockroachDB 方式) はこの2つを満たす。キー中の `0x00` を `0x00 0xFF` に置き換え、末尾に `0x00 0x01` を付ける。
  * 順序: `00 01` (終端) < `00 FF` (キー中の 0) < `01` 以上 (普通のバイト)。短いキーが先に終端に来ると、必ず小さくなる。
  * prefix-free: `00` の直後は必ず `FF` (エスケープ) か `01` (終端) なので、終端の `00 01` はキーの途中に現れない。
* **1バイトの終端では足りない**。`0x00 → 0x00 0xFF` + 末尾 `0x00` だと、"a" は `61 00`、"a\0" は `61 00 FF 00` になり、前者が後者の接頭辞になる。
* 終端付きキーの集合は接頭辞を含まない (prefix-free)。2つの異なるキーは、どちらかの末尾を越える前に必ずどこかで食い違う。
  * そのため §6.2 の `while key[depth+p] == old.key[depth+p]` は範囲内で止まる。
  * §6.4 / §7.1 の `key[depth]` も範囲内になる。
* 固定長キー (4バイト整数をビッグエンディアンにしたもの、など) は、全部同じ長さなので、そのままで prefix-free。終端は要らない。
* 別解として「キーがここで終わる場合の値」を各内部ノードに持たせる実装もある。ART 論文と参照実装はこれを採らないので、ここでも採らない。

## 10. Rust での書き方

### 10.1 タグ付きポインタ (strict provenance)

```rust
#[derive(Clone, Copy, PartialEq)]
#[repr(transparent)]
struct Slot(*mut u8);

impl Slot {
    const NULL: Slot = Slot(core::ptr::null_mut());
    fn is_null(self) -> bool { self.0.is_null() }
    fn is_leaf(self) -> bool { self.0.addr() & 1 == 1 }

    fn new_inner<T>(node: T) -> Slot {                   // T は Node4/16/48/256
        Slot(Box::into_raw(Box::new(node)) as *mut u8)   // 8 バイト境界なので最下位ビットは 0
    }
    fn new_leaf(leaf: Leaf) -> Slot {
        let p = Box::into_raw(Box::new(leaf)) as *mut u8;
        Slot(p.map_addr(|a| a | 1))                      // 由来 (provenance) を保ったままビットを立てる
    }
    fn leaf_ptr(self) -> *mut Leaf {
        self.0.map_addr(|a| a & !1) as *mut Leaf         // 外してから参照外し
    }
    fn header(self) -> &Header { unsafe { &*(self.0 as *const Header) } }   // unsafe
}
```

* `as usize` → 演算 → `as *mut` と書くと provenance が失われる。`addr()` / `map_addr()` / `with_addr()` を使う。
* **combined pointer/value slot** (タプル ID を直接埋め込む) の場合は、ポインタではないので `core::ptr::without_provenance_mut((tid << 1) | 1)` で作り、`addr() >> 1` で値を取り出す。**絶対に参照外ししない**。値は 63 ビットに収まる必要がある。
* 葉と内部ノードを `enum Child { Empty, Inner(Box<..>), Leaf(Box<Leaf>) }` にすると、1スロット 16 バイトになりノードの大きさが倍近くになる。最初の版としては分かりやすいが、サイズ表 (§3.3) とは合わなくなる。

### 10.2 型の取り出し

* `#[repr(C)]` で Header を先頭に置くので、`*mut Header` を `*mut Node16` などにキャストしてよい。ヘッダの `node_type` を見てから行う。
* 解放は**確保したときの型で**行う。`drop(Box::from_raw(p as *mut Node48))`。`Header` 型で解放すると Layout が違い、未定義動作になる。

### 10.3 ノードの差し替えと所有権

* `replace_node(slot, new)`: 新ノードを確保 → 子スロットの値 (ポインタ) を新ノードに**ビットコピー** → `*slot` を新ノードに → 古いノードの**箱だけ**解放する。
* 子スロットはコピーで「移動」したので、古いノードを解放するときに子を解放してはいけない。
  * ノード型に子を再帰的に解放する `Drop` を実装すると、grow / shrink / collapse のたびに子を二重解放する。
  * 木全体の解放は、`Drop for Art` から明示的な再帰関数 `free_subtree(slot)` を呼んで行う。ノード型自体には `Drop` を付けない。
* `insert(slot: &mut Slot, ..)` で子へ再帰するとき、`find_child_mut` は親ノード内のスロットへの `&mut` を返す。親ノード自体を作り直す処理 (add_child) は、子への再帰が終わってからしか起きないので、借用は重ならない。

## 11. 境界条件と落とし穴

* **空の木**: root は null。最初の insert で root が葉になる。最後の delete で null に戻る。
* **root が葉1枚**: lookup / delete は葉の照合だけ。insert は §6.2 で Node4 を作る (depth = 0)。
* **root の Node4 が子1つになる**: collapse で root が子 (葉か内部ノード) に置き換わる。`slot` が root を指していれば特別扱いは要らない。
* **prefix_len が 8 ちょうど**: 全部バッファにある (≤ 8 の側)。ART.cpp は lookup で `< 9`、prefixMismatch で `> 9` と比較の向きが混在している。ここでは「≤ 8 ならバッファに全部、> 8 なら optimistic」に統一した。
* **prefix_len の上限**: u32 なので実質無制限。キーの最大長を超えないことだけ確認する。
* **Node16 の空きスロット**: keys の未使用部分は 0。マスクを count で切らないと b = 0 で誤一致する (§5.2)。
* **Node48 の穴**: `children[count]` が空とは限らない (§6.4)。
* **Node48 の走査順**: children の順は不定。必ず child_index をバイト順に回す (§8.1)。
* **縮小直後の再拡大**: §3.4 のヒステリシスがないと、境界で insert / delete を繰り返すたびにノードを作り直す。
* **同じキーの insert**: 値の置き換え。葉の照合を先にしないと共通部分の計算が配列の外へ出る (§6.2)。
* **存在しないキーの delete**: prefix の途中で食い違う、子がない、葉のキーが違う、の3通りで None。
* **楽観的 lookup の誤答**: 読み飛ばした prefix が違っていても、葉に着いてしまう。葉の照合を省くと別のキーの値を返す。

## 12. テスト方針

### 12.1 オラクルとの比較

* `BTreeMap<Vec<u8>, u64>` を正解として、同じ操作列を ART と BTreeMap の両方に流す。
* 操作の比率は insert 40%、delete 30%、lookup 20%、scan 10% など。scan は「開始キー + 最大件数」で両方の結果を比べる。
* 毎操作 (または N 操作ごと) に §12.2 の不変条件チェッカーを走らせる。
* 最後に、全件の in-order 走査の結果が `BTreeMap::iter()` と一致することを確かめる。

### 12.2 不変条件チェッカー

木を再帰でたどり、§4 を全部確かめる。

* 型ごとの count の範囲 (§3.4)。root は「子2つ以上」だけ確認する。
* Node4/16 の keys が狭義単調増加。Node48 の child_index と children の対応 (不変条件4)。count と実際の子の数の一致。
* 経路の再構成: 親から渡された `path: Vec<u8>` (depth までのバイト) を持って降りる。
  * 各内部ノードで、部分木の全ての葉について `leaf.key[..depth] == path` を確認する。
  * `prefix[..min(len, 8)] == leaf.key[depth..depth + min(len, 8)]` を確認する (バッファの不変条件)。
  * `leaf.key[depth + len] == 子のバイト` を確認する。
* 全ての葉のキーが prefix-free (隣り合う葉どうしで、一方が他方の接頭辞でない)。

### 12.3 狙い撃ちのケース

* **キーの分布**: 4バイト整数の乱数 (sparse)、連番 (dense)、URL のような長い共通接頭辞 (> 8 バイト、optimistic 経路を通す)、アルファベット2〜3文字だけのランダム文字列 (深い木)。
* **grow / shrink の全遷移**: 同じ親の下にバイト値 0..=255 を全部入れて (4→16→48→256)、逆順・ランダム順に消す (256→48→16→4→消滅)。各境界 (4/5, 16/17, 48/49, 37/38, 12/13, 3/4) で insert と delete を交互に繰り返す。
* **Node48 の穴の再利用**: 30 個入れて、間を飛び飛びに消し、また入れる。child_index の整合を確認する。
* **prefix の連結**: p と c が 0, 7, 8, 9, 20 の組み合わせで collapse を起こす。例: 共通接頭辞 p バイトの後で2つに分かれ、片方の下がさらに c バイト共通で分かれる、という3キーを入れ、1つ消す。
* **prefix の分割**: 長さ 20 の prefix の 0, 3, 7, 8, 9, 19 バイト目で食い違うキーを入れる。
* **バイト値の端**: 0x00 と 0xFF を含むキー (終端の符号化を通した後で)。
* **符号の prefix-free 性**: 生成した元のキー集合 (`"a"`, `"a\0"`, `"a\0\0"`, `""` などを必ず含める) を 02 の符号に通し、どの符号も他の符号の接頭辞でないこと、符号の順序が元のキーの順序と一致することを確認する。ART に入れる前の前提条件のテスト。

## 13. 原典との違い・簡略化

* **prefix バッファ**: 論文どおり 8 バイト。ART.cpp は 9、libart は 10。
* **ヘッダの並び**: 自分で決めた (§3.2)。ART.cpp は `prefixLength (u32), count (u16), type (i8), prefix[9]`、libart は `partial_len (u32), type (u8), num_children (u8), partial[10]`。
* **Node4 のサイズ**: `#[repr(C)]` のパディングで 56 B (論文は 52 B)。
* **Node16 のキー**: 生のバイト値で持ち、挿入位置はスカラーで求める。ART.cpp は `^ 0x80` して SSE の符号付き比較を使う。
* **Node48 の空**: `0xFF`。ART.cpp は `48`、libart は `0` (添字 +1)。
* **lookup**: 葉で常にキー全体を照合する。ART.cpp の「読み飛ばしなし & 末尾到達なら照合を省く」最適化は省略した。
* **葉の形**: single-value leaf を既定にした。論文の測定 (タプルへのポインタ) に近い。combined pointer/value slot は §3.1 / §10.1 で書き方だけ示した。
* **delete**: ART.cpp の論文用アダプタ (`ArtBTreeAdapter::removeImpl`) は `abort()` で、論文の測定に delete は含まれない。delete は ART.cpp の `erase` と libart の `art_delete` に基づく。
* **scan**: §8.2 は自分で書いた。ART.cpp の `scan` は §8.2 末尾の問題があるので写していない。
* **並行制御**: 省略。ART の並行版 (ROWEX, OLC) は Leis ら "The ART of Practical Synchronization" (DaMoN 2016) にある。
* 【未検証】論文の文字列キー (urls, wiki) を ART に入れる際、btree-cpp 側でどのように prefix-free を保証しているか (終端を付けているか) は確認していない。

## 14. 参考資料

* ART 論文: Leis, Kemper, Neumann. The Adaptive Radix Tree: ARTful Indexing for Main-Memory Databases. ICDE 2013. https://db.in.tum.de/~leis/papers/ART.pdf
  * III-C (ノードの構造), III-D (葉の3つの形), III-E (lazy expansion と path compression、ハイブリッド方式), III-F (アルゴリズム), IV (キーの binary-comparable 化と終端)
* 論文: Müller, Benson, Leis. B-Trees Are Back: Engineering Fast and Pageable Node Layouts. SIGMOD 2025. Section 6.1
* 参照実装 (論文で使われたもの): https://github.com/m-mueller678/btree-cpp/tree/sigmod25 (コミット `774b9fd`)
  * `in-memory-structures/ART/ART.cpp`: `findChild`, `minimum`, `prefixMismatch`, `lookup`, `lookupPessimistic`, `insert`, `insertNode4/16/48/256`, `erase`, `eraseNode4/16/48/256`, `iterateAll`, `scan`, `ArtBTreeAdapter::insertImpl`
* 参照実装 (葉にキー全体): https://github.com/armon/libart (コミット `3010468`)
  * `src/art.c`: `find_child`, `check_prefix`, `prefix_mismatch`, `recursive_insert`, `add_child4/16/48/256`, `recursive_delete`, `remove_child4/16/48/256`, `recursive_iter`
* Leis, Scheibner, Kemper, Neumann. The ART of Practical Synchronization. DaMoN 2016 (並行版)
