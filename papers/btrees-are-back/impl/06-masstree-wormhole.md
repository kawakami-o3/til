# 06. Masstree と Wormhole

background.md の 3.4 (Masstree) と 3.5 (Wormhole) を、自分で書けるように書き下す。
どちらも「trie と B+-Tree の混ぜ物」だが、混ぜ方が逆になっている。

* **Masstree**: trie の各段 (8バイト単位) を B+-Tree にした。
* **Wormhole**: B+-Tree の内部ノードを、trie を詰めたハッシュ表にした。

前提:

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* キーは 02 で正規化済みのバイト列。どちらの構造も任意のバイト列を扱える (ART と違い、終端は要らない)。
* 単一スレッド・全データがメモリ上、という前提で書く。並行制御は要点だけ述べ、[12-concurrency.md](12-concurrency.md) に回す。
* 擬似コードは読みやすさを優先して書き直したもので、参照実装の直訳ではない (Wormhole の参照実装は GPL-3.0 / MIT のデュアルライセンス)。

## 目次

* Part A: Masstree
  * [A1. 目的と論文との関係](#a1-目的と論文との関係) / [A2. データ配置](#a2-データ配置) / [A3. 不変条件](#a3-不変条件) / [A4. 操作](#a4-操作) / [A5. 並行制御の要点](#a5-並行制御の要点) / [A6. 境界条件と落とし穴](#a6-境界条件と落とし穴) / [A7. テスト方針](#a7-テスト方針) / [A8. 原典との違い・簡略化](#a8-原典との違い簡略化)
* Part B: Wormhole
  * [B1. 目的と論文との関係](#b1-目的と論文との関係) / [B2. データ配置](#b2-データ配置) / [B3. anchor の作り方](#b3-anchor-の作り方) / [B4. 不変条件](#b4-不変条件) / [B5. 操作](#b5-操作) / [B6. 並行制御の要点](#b6-並行制御の要点) / [B7. 境界条件と落とし穴](#b7-境界条件と落とし穴) / [B8. テスト方針](#b8-テスト方針) / [B9. 原典との違い・簡略化](#b9-原典との違い簡略化)
* [参考資料](#参考資料)

---

# Part A: Masstree

## A1. 目的と論文との関係

* Mao, Kohler, Morris (EuroSys 2012)。並行性に強いインメモリのキー・値ストア用索引。
* キーを8バイトずつ切り (key slice)、各段 (layer) を B+-Tree にした trie。
  * layer 0 はキーの 0〜7 バイト目、layer 1 は 8〜15 バイト目、… を担当する。
  * 8バイトはビッグエンディアンの u64 として比較する。整数比較の結果が辞書順と一致する。
* 長い共通接頭辞を持つキー群は、layer を深くすることで吸収する。各 layer の中は普通の B+-Tree。
* **論文との関係**: Section 6 の比較対象には入っていない。「Wormhole より大幅に遅いので外した」とだけ書かれている (background.md 3.4)。Wormhole 論文の評価では Masstree も比べられている。

## A2. データ配置

### A2.1 key slice と長さ

```
キー "0123456789AB" (12 バイト) の扱い:

layer 0: ikey = BE("01234567")             残り 4 バイト "89AB" は suffix か下の layer へ
layer 1: ikey = BE("89AB\0\0\0\0")         長さ 4 (8 未満なので 0 で埋める)
```

```rust
/// key の先頭 8 バイトをビッグエンディアン u64 にする。8 未満なら 0 で埋める。
fn ikey(k: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    let n = k.len().min(8);
    buf[..n].copy_from_slice(&k[..n]);
    u64::from_be_bytes(buf)
}
```

* 0 で埋めるので、"ABC" と "ABC\0" は同じ ikey になる。これを**長さ**で区別する。
* 1つの ikey に対して、1つの layer の木に入りうるキーは最大10個 (Masstree 論文 4.2)。
  * 長さ 0〜8 のキー (残りがちょうどその長さのもの) が最大9個。
  * 長さ 8 超のキーが1個、または下の layer へのリンクが1個。長さ 8 超のキーが2個目に来た時点で、下の layer を作るから。

### A2.2 keylenx (長さと種別の1バイト)

| keylenx | 意味 |
|---|---|
| 0〜8 | このスロットのキーは、残りがちょうどその長さ。suffix なし |
| 64 (`KSUF`) | 残りが 8 バイト超。9 バイト目以降を suffix として別に持つ |
| 128 以上 (`LAYER`) | このスロットの値は下の layer の root へのリンク |

* 同じ ikey どうしの順序は `ord(keylenx) = min(keylenx, 9)` で決まる。0〜8 は長さ順、KSUF と LAYER はそれより後ろ (masstree-beta `masstree_key.hh: key::compare`)。
  * 長さ 0〜8 の短いキーは、0 埋めの部分も一致するなら長いキーの接頭辞。だから短い方が小さい。辞書順と一致する。
* 探索キーの側は `ord_of_len(len) = if len > 8 { 9 } else { len }`。
* 同じ ikey で ord が 9 のスロットは1つしかない (KSUF か LAYER のどちらか)。

### A2.3 border node (葉)

```rust
const WIDTH: usize = 15;
const KSUF: u8 = 64;
const LAYER: u8 = 128;

#[repr(C)]
struct Border {                              // offset  size
    version: u64,                            // 0       8    並行制御用 (A5)。単一スレッドなら不要
    keylenx: [u8; WIDTH],                    // 8       15   スロットごと
    _pad: u8,                                // 23      1
    permutation: u64,                        // 24      8    ソート順 (A2.4)
    keyslice: [u64; WIDTH],                  // 32      120  スロットごとの ikey
    lv: [LinkOrValue; WIDTH],                // 152     120  値 または 下の layer の root
    suffix: *mut [Option<Box<[u8]>>; WIDTH], // 272     8    KSUF のスロットの suffix (9 バイト目以降)
    next: *mut Border,                       // 280     8    同じ layer の葉の双方向リスト
    prev: *mut Border,                       // 288     8
    parent: *mut Interior,                   // 296     8    null なら この layer の root
}                                            // 304 バイト

#[repr(C)]
union LinkOrValue { value: u64, layer: *mut NodeBase }   // keylenx で区別する
```

* **スロットは物理的にはソートしない**。挿入は空きスロットに書き、ソート順は `permutation` だけで表す (A2.4)。
* 論文 Figure 2 の border_node は `keylen[15], permutation, keyslice[15], link_or_value[15], next, prev, parent, keysuffixes`。並びはそれに合わせた。
* suffix の置き場所は、masstree-beta では「ノード内に可変長で詰める (`iksuf_`) か、外に確保する (`ksuf_`)」を適応的に選ぶ。ここでは外に配列を確保する形に簡略化した。

### A2.4 permutation (64 ビットに詰めたソート順)

```
 63   60 59  56          11   8 7    4 3    0
+-------+-------+ ... +-------+------+------+
| p[14] | p[13] |     | p[1]  | p[0] | size |
+-------+-------+ ... +-------+------+------+
  4 ビットずつ 16 個
```

* 下位4ビット = 使用中のスロット数 (size)。
* `p[i]` (ビット `4i+4 .. 4i+8`) = **ソート順で i 番目のキーが入っている物理スロット番号** (0〜14)。
* `p[0..size]` が使用中のスロットをキー順に並べたもの。`p[size..15]` は空きスロット。
* `p[14]` (= back) が、次に使う空きスロット。
* 空の初期値は `0x0123_4567_89AB_CDE0`。`p[0] = 0xE, p[1] = 0xD, …, p[14] = 0`。back が 0 なので、空きスロットは 0, 1, 2, … の順に使われる (masstree-beta `kpermuter.hh: make_empty`)。

```rust
#[derive(Clone, Copy, PartialEq)]
struct Permuter(u64);

impl Permuter {
    const EMPTY: Permuter = Permuter(0x0123_4567_89AB_CDE0);
    fn size(self) -> usize { (self.0 & 15) as usize }
    fn get(self, i: usize) -> usize { ((self.0 >> (4 * i + 4)) & 15) as usize }
    fn back(self) -> usize { self.get(WIDTH - 1) }

    /// 空きスロット back() を取り出し、ソート順の位置 i に差し込む。size + 1。
    /// p[0..i] はそのまま、p[i..] は1つ後ろへずれる。
    fn insert_from_back(&mut self, i: usize) -> usize {
        let slot = self.back();
        let x = self.0;
        let keep_low = (16u64 << (4 * i)) - 1;                     // size と p[0..i]
        let keep_high = !((256u64 << (4 * i)).wrapping_sub(1));    // 1 ニブルずらした後の p[i+1..]
        self.0 = ((x + 1) & keep_low)                              // size + 1、下位はそのまま
               | ((slot as u64) << (4 * i + 4))                    // p[i] = slot
               | ((x << 4) & keep_high);                           // 元の p[i..14] を p[i+1..15] へ
        slot
    }

    /// ソート順の位置 i を取り除き、その物理スロットを back (p[14]) に回す。size - 1。
    fn remove_to_back(&mut self, i: usize) {
        let x = self.0;
        let mask = !((16u64 << (4 * i)) - 1);                      // p[i..] のニブル
        self.0 = ((x - 1) & !mask)                                 // size - 1、p[0..i] はそのまま
               | ((x >> 4) & mask)                                 // p[i+1..] を1つ前へ
               | ((x & mask) << (4 * (WIDTH - 1 - i)));            // 元の p[i] を p[14] へ (他は上へあふれて消える)
    }
}
```

* `i = 14` のとき `256u64 << 56` は 2^64 で 0 になる。そこから 1 を引くので `wrapping_sub` が必要 (C では符号なしの桁あふれで自然にそうなる)。Rust の debug ビルドでは普通の `-` だとパニックする。
* 同じ意味を配列で書くと次のとおり。テストの正解 (A7) にもこれを使う。
  * `insert_from_back(i)`: `let s = v.remove(14); v.insert(i, s); size += 1;`
  * `remove_to_back(i)`: `let s = v.remove(i); v.push(s); size -= 1;` (`v` は p[0..15])

**例** (3回の挿入):

| 操作 | permutation | size | p[0], p[1], p[2] | back = p[14] |
|---|---|---|---|---|
| 初期 | `0x0123456789ABCDE0` | 0 | - | 0 |
| "B" を位置 0 に (スロット 0 を使う) | `0x123456789ABCDE01` | 1 | 0 | 1 |
| "A" を位置 0 に (スロット 1 を使う) | `0x23456789ABCDE012` | 2 | 1, 0 | 2 |
| "C" を位置 2 に (スロット 2 を使う) | `0x3456789ABCDE2013` | 3 | 1, 0, 2 | 3 |

* 3行目: "A" はスロット1にあるが、ソート順では先頭。"B" (スロット0) は2番目に下がる。
* 挿入の手順は「空きスロット `back()` に keyslice / keylenx / suffix / lv を書く」→「permutation を1回の store で書き換える」。後者の1語の書き込みで、新しいキーがまとめて見えるようになる (A5)。

### A2.5 interior node (内部ノード)

```rust
#[repr(C)]
struct Interior {                            // offset  size
    version: u64,                            // 0       8
    nkeys: u8,                               // 8       1
    _pad: [u8; 7],                           // 9       7
    keyslice: [u64; WIDTH],                  // 16      120  ソート済み (permutation は使わない)
    child: [*mut NodeBase; WIDTH + 1],       // 136     128
    parent: *mut Interior,                   // 264     8
}                                            // 272 バイト
```

* `child[i]` は `keyslice[i-1] <= ikey < keyslice[i]` の範囲 (`keyslice[-1] = -∞`, `keyslice[nkeys] = +∞`)。
* 内部ノードは ikey だけを持つ。長さや suffix は持たない。同じ ikey のキーは必ず同じ border に入れるから (不変条件 A3-3)。
* `NodeBase` は Border と Interior の共通の先頭部分。ここでは version の1ビットで種別を表す想定 (masstree-beta は `isleaf` ビット)。

## A3. 不変条件

1. 各 border の `p[0..size]` は、(keyslice, ord(keylenx)) の辞書順で狭義単調増加。
2. 各 layer の border は `next` / `prev` で双方向につながり、リスト順に並べるとキーが昇順。
3. **同じ ikey のキーは、1つの layer の中で必ず同じ border にある** (Masstree 論文 4.2)。split でこれを守る (A4.6)。
4. interior の keyslice は狭義単調増加。`child[i]` の部分木の ikey は `[keyslice[i-1], keyslice[i])` に収まる。
5. 同じ ikey で ord = 9 のスロットは高々1つ。KSUF のスロットの suffix は空でない (残りが 8 バイト超だから)。
6. LAYER のスロットが指す layer は空でない。その layer に入っているキーは、全部この layer までの 8h+8 バイトを共有する。
7. layer h の木に入っているキーは、全部同じ 8h バイトの接頭辞を持つ。
8. 全ての B+-Tree の葉は同じ深さ (layer ごとに)。

## A4. 操作

### A4.1 border 内の探索

```rust
/// ソート順で (ik, ord) 以上の最初の位置と、ちょうど一致したかを返す。
fn border_lower_bound(n: &Border, ik: u64, ord: u8) -> (usize, bool) {
    let perm = Permuter(n.permutation);
    // 15 個以下なので線形でも二分でもよい。ここでは二分探索
    let (mut lo, mut hi) = (0, perm.size());
    while lo < hi {
        let mid = (lo + hi) / 2;
        let s = perm.get(mid);
        let k = (n.keyslice[s], n.keylenx[s].min(9));
        if k < (ik, ord) { lo = mid + 1 } else { hi = mid }
    }
    let found = lo < perm.size() && {
        let s = perm.get(lo);
        n.keyslice[s] == ik && n.keylenx[s].min(9) == ord
    };
    (lo, found)
}

fn ord_of_len(len: usize) -> u8 { if len > 8 { 9 } else { len as u8 } }
```

### A4.2 葉までの降下 (1つの layer の中)

```rust
fn reach_leaf(mut n: *mut NodeBase, ik: u64) -> *mut Border {
    while !is_border(n) {
        let i = as_interior(n);                              // unsafe
        // ik 以下の区切りの数 = 子の添字 (upper bound)
        let c = i.keyslice[..i.nkeys as usize].partition_point(|&s| s <= ik);
        n = i.child[c];
    }
    n as *mut Border
}
```

### A4.3 lookup

```rust
fn get(mut root: *mut NodeBase, mut key: &[u8]) -> Option<u64> {
    loop {
        let ik = ikey(key);
        let leaf = reach_leaf(root, ik);
        let (pos, found) = border_lower_bound(leaf, ik, ord_of_len(key.len()));
        if !found { return None; }
        let s = Permuter(leaf.permutation).get(pos);
        match leaf.keylenx[s] {
            0..=8 => return Some(leaf.lv[s].value),                       // 長さまで一致済み
            KSUF => return if leaf.suffix(s) == &key[8..] { Some(leaf.lv[s].value) } else { None },
            _ /* LAYER */ => { root = leaf.lv[s].layer; key = &key[8..]; }  // 次の layer へ
        }
    }
}
```

### A4.4 insert (新しいスロットの追加)

`root_ref` は「この layer の root を指している場所」(木全体の root か、上の layer のスロット `lv[s].layer`)。root の split で書き換える。

```rust
fn put(root_ref: &mut *mut NodeBase, key: &[u8], value: u64) -> Option<u64> {
    let ik = ikey(key);
    let leaf = reach_leaf(*root_ref, ik);
    let (pos, found) = border_lower_bound(leaf, ik, ord_of_len(key.len()));
    if found {
        let s = Permuter(leaf.permutation).get(pos);
        match leaf.keylenx[s] {
            0..=8 => return Some(replace(&mut leaf.lv[s].value, value)),
            LAYER => return put(&mut leaf.lv[s].layer, &key[8..], value),
            _ /* KSUF */ => {
                if leaf.suffix(s) == &key[8..] { return Some(replace(&mut leaf.lv[s].value, value)); }
                make_new_layer(leaf, s);                                   // A4.5
                return put(&mut leaf.lv[s].layer, &key[8..], value);
            }
        }
    }
    let entry = Entry { ik, keylenx: keylenx_of(key), suffix: suffix_of(key), lv: value };
    if Permuter(leaf.permutation).size() < WIDTH {
        border_insert_at(leaf, pos, entry);
    } else {
        split_border(root_ref, leaf, pos, entry);                          // A4.6
    }
    None
}

fn keylenx_of(key: &[u8]) -> u8 { if key.len() > 8 { KSUF } else { key.len() as u8 } }
fn suffix_of(key: &[u8]) -> Option<Box<[u8]>> { (key.len() > 8).then(|| key[8..].into()) }

fn border_insert_at(n: &mut Border, pos: usize, e: Entry) {
    let mut perm = Permuter(n.permutation);
    let s = perm.back();
    n.keyslice[s] = e.ik;  n.keylenx[s] = e.keylenx;  n.set_suffix(s, e.suffix);  n.lv[s].value = e.lv;
    // 並行版ではここに release fence (A5)
    perm.insert_from_back(pos);
    n.permutation = perm.0;                                                // 1 回の store
}
```

### A4.5 新しい layer を作る

KSUF のスロット s (既存キー k2) と同じ ikey・違う suffix のキー k1 が来たとき。

```
前:  border: [.. | ik="01234567" KSUF suffix="AB" val=v2 | ..]
put("01234567XY", v1)

後:  border: [.. | ik="01234567" LAYER → L1 | ..]
     L1 (layer 1 の root border): [ ik="AB\0\0.." len=2 val=v2 ]
     そのあと put(&mut lv[s].layer, "XY", v1) で L1 に "XY" が入る
```

```rust
fn make_new_layer(leaf: &mut Border, s: usize) {
    let old_suffix = leaf.take_suffix(s);                 // k2 の 9 バイト目以降
    let old_value = leaf.lv[s].value;
    let mut nl = Border::new_root();                      // parent = null、permutation = EMPTY
    border_insert_at(&mut nl, 0, Entry {
        ik: ikey(&old_suffix),
        keylenx: keylenx_of(&old_suffix),
        suffix: suffix_of(&old_suffix),                   // old_suffix がさらに 8 バイト超なら、その残り
        lv: old_value,
    });
    // 並行版の順序: keylenx を UNSTABLE にする → lv を書く → keylenx = LAYER (A5)
    leaf.lv[s].layer = Box::into_raw(nl) as *mut NodeBase;
    leaf.keylenx[s] = LAYER;
    // permutation も version の split ビットも変えない (このスロット1つの変化だから)
}
```

* k1 と k2 の残りがさらに次の8バイトも共有していると、新しい layer の中でまた KSUF 同士がぶつかる。上の書き方では、続く `put` が再び make_new_layer を呼ぶので、自然に layer の鎖ができる。
* masstree-beta は、共有が続く間の「1キーだけの layer の鎖 (twig)」を先にまとめて作ってから、最後の layer に2キーを入れる (`tcursor::make_new_layer`)。並行版で途中状態を見せないため。

### A4.6 border の split

```
16 個 (既存 15 + 新規 1) をキー順に並べて mid で分ける:
  左 (元の border) : [0, mid)
  右 (新しい border): [mid, 16)
  区切り = 右の先頭の ikey
```

```rust
fn split_border(root_ref: &mut *mut NodeBase, left: &mut Border, pos: usize, e: Entry) {
    // 1. 論理的な並び (ソート順) を作る。新規は pos に入る
    let mut items: Vec<EntryRef> = sorted_entries(left);        // p[0..15] の順
    items.insert(pos, EntryRef::New(e));

    // 2. 分割位置。基本は中央 (masstree-beta は width/2 + 1)
    let mut mid = WIDTH / 2 + 1;
    if pos == WIDTH && left.next.is_null() { mid = WIDTH; }     // 右端への追記 (昇順挿入) の最適化
    // 同じ ikey を分けない (不変条件3)。mid-1 と mid の ikey が同じなら、中央から左右に広げて境目を探す
    if items[mid - 1].ik() == items[mid].ik() {
        mid = nearest_boundary(&items, mid);                    // ikey が変わる位置のうち mid に最も近いもの
    }

    // 3. 右へ移す。右は物理スロット 0.. にソート順で詰め、permutation は「先頭 n 個がソート済み」
    let mut right = Border::new();
    for (j, it) in items[mid..].iter().enumerate() { right.write_slot(j, it); }
    right.permutation = make_sorted(items.len() - mid);
    // 4. 左は残す分だけで permutation を作り直す。新規が左に入るなら空きスロットに書く
    rebuild_left(left, &items[..mid]);

    // 5. 葉のリストにつなぐ: left <-> right <-> 元の left.next
    link_after(left, &mut right);
    let sep = right.keyslice[0];
    insert_into_parent(root_ref, left as *mut _, sep, Box::into_raw(right) as *mut _);
}

/// 先頭 n 個が p[i] = i、残りが空き n, n+1, .. の順になる permutation
fn make_sorted(n: usize) -> u64 { todo!("配列 [0, 1, .., 14] と size = n から組み立てる") }
```

* 1つの ikey のキーは最大10個 (A2.1)。16個の中には必ず2種類以上の ikey があるので、境目は必ず見つかる。
* 区切りは ikey だけ。不変条件3があるので、区切りの ikey 以上は全部右、未満は全部左になる。

### A4.7 親への区切りの挿入 (interior の split)

普通の B+-Tree と同じ。

```rust
fn insert_into_parent(root_ref: &mut *mut NodeBase, left: *mut NodeBase, sep: u64, right: *mut NodeBase) {
    let p = parent_of(left);
    if p.is_null() {
        // layer の root が split した: 新しい root を作り、root_ref を書き換える
        let r = Interior::new_with(&[sep], &[left, right]);
        set_parent(left, r); set_parent(right, r);
        *root_ref = r as *mut NodeBase;
        return;
    }
    let i = p.child_index_of(left);
    if (p.nkeys as usize) < WIDTH {
        p.insert_at(i, sep, right);                 // keyslice[i] = sep、child[i+1] = right、後ろをずらす
        set_parent(right, p);
        return;
    }
    // interior の split: 16 個の区切りと 17 個の子。中央の区切りは上へ上げる (どちらにも残さない)
    let (sep_up, new_right) = p.split_inserting(i, sep, right);    // 子の parent も付け替える
    insert_into_parent(root_ref, p as *mut _, sep_up, new_right);
}
```

* **layer の root を指す場所を更新すること**。上の layer のスロットは、その layer の root を指している。root が split して新しい root ができたら、`root_ref` (= 上の layer の `lv[s].layer`) を書き換えないと、新しい半分が見えなくなる。
  * masstree-beta は並行版のため、これを遅延で直す。古い root から `maybe_parent()` で本当の root までたどり、見つけた側がスロットを書き換える (`masstree_get.hh: find_locked`)。
  * 単一スレッドなら、上のように `&mut` で root の場所を渡して即座に直すのが簡単。

### A4.8 delete

```rust
fn remove(root_ref: &mut *mut NodeBase, key: &[u8]) -> Option<u64> {
    let ik = ikey(key);
    let leaf = reach_leaf(*root_ref, ik);
    let (pos, found) = border_lower_bound(leaf, ik, ord_of_len(key.len()));
    if !found { return None; }
    let s = Permuter(leaf.permutation).get(pos);
    let old = match leaf.keylenx[s] {
        0..=8 => leaf.lv[s].value,
        KSUF => { if leaf.suffix(s) != &key[8..] { return None; } leaf.lv[s].value }
        _ /* LAYER */ => {
            let r = remove(&mut leaf.lv[s].layer, &key[8..])?;
            if !layer_is_empty(leaf.lv[s].layer) { return Some(r); }
            free_layer(leaf.lv[s].layer);         // 空になった layer はこのスロットごと消す
            r
        }
    };
    let mut perm = Permuter(leaf.permutation);
    perm.remove_to_back(pos);                     // スロット s は次の挿入で再利用される
    leaf.permutation = perm.0;
    leaf.clear_suffix(s);
    if perm.size() == 0 && !is_only_node_of_layer(leaf) {
        unlink_and_remove_from_parent(root_ref, leaf);   // 空の border は外して解放する。中身のある border の merge はしない
    }
    Some(old)
}
```

* masstree-beta は、空になった border を外すだけで、半端に埋まった border どうしの merge はしない (Masstree 論文 4.3)。
* interior から子を1つ外したとき、区切りも1つ外す。`child[i]` を外すなら `keyslice[i-1]` (i = 0 なら `keyslice[0]`) を外す。外した範囲は隣の子が引き継ぐ。
* interior が子1つ (区切り0個) になったら、その子で置き換える。root なら `*root_ref` を子にする。【未検証】masstree-beta が子1つの interior をどの時点で回収するかは確認していない。

### A4.9 範囲走査 (scan)

layer ごとに葉のリストをたどり、LAYER のスロットに当たったら下の layer を再帰で走査する。

```rust
/// prefix = 上の layer までのキー (8h バイト)。start は「この layer での残り」(None なら全件)。
fn scan_layer(root: *mut NodeBase, prefix: &mut Vec<u8>, start: Option<&[u8]>, cb: ScanCallback) -> bool {
    let (mut leaf, mut pos) = match start {
        Some(st) => { let l = reach_leaf(root, ikey(st));
                      (l, border_lower_bound(l, ikey(st), ord_of_len(st.len())).0) }
        None => (leftmost_leaf(root), 0),
    };
    let mut first = true;
    while !leaf.is_null() {
        let perm = Permuter(leaf.permutation);
        for i in pos..perm.size() {
            let s = perm.get(i);
            let base = prefix.len();
            match leaf.keylenx[s] {
                LAYER => {
                    prefix.extend_from_slice(&leaf.keyslice[s].to_be_bytes());
                    // start と同じ ikey の layer に最初に入るときだけ、start の残りで下限をかける
                    let sub = match start {
                        Some(st) if first && st.len() > 8 && ikey(st) == leaf.keyslice[s] => Some(&st[8..]),
                        _ => None,
                    };
                    let cont = scan_layer(leaf.lv[s].layer, prefix, sub, cb);
                    prefix.truncate(base);
                    if !cont { return false; }
                }
                kl => {
                    // KSUF は ord = 9 で lower_bound に一致するが、suffix が start の残りより小さいことがある
                    if let Some(st) = start {
                        if first && kl == KSUF && st.len() > 8 && ikey(st) == leaf.keyslice[s]
                           && leaf.suffix(s) < &st[8..] { first = false; continue; }
                    }
                    let n = if kl == KSUF { 8 } else { kl as usize };
                    prefix.extend_from_slice(&leaf.keyslice[s].to_be_bytes()[..n]);
                    if kl == KSUF { prefix.extend_from_slice(leaf.suffix(s)); }
                    let cont = cb(prefix, &leaf.lv[s].value.to_ne_bytes());
                    prefix.truncate(base);
                    if !cont { return false; }
                }
            }
            first = false;
        }
        leaf = leaf.next; pos = 0;
    }
    true
}
```

* lower_bound の位置にあるのが KSUF のスロットのときだけ、suffix と start の残りを比べて小さければ飛ばす (上の `continue`)。長さ 0〜8 のスロットは (ikey, ord) の比較だけで start 以上と決まる。
* 長さ 0〜8 のスロットは、0 埋めの部分を含めず `keylenx` バイトだけを出す。

## A5. 並行制御の要点

詳細は [12-concurrency.md](12-concurrency.md) に回す。要点だけ。

* 各ノードの先頭に `version` (64 ビット) がある。lock ビット、inserting / splitting の汚れビット、vinsert / vsplit のカウンタ、isroot / isleaf / deleted などのビットを詰めている。
* **読み手はロックを取らない**。「安定した version を読む → ノードを読む → version を読み直す」。変わっていたらやり直す (OLC と同じ形)。
* **葉への挿入は permutation の1語の store で公開する** (A2.4)。スロットへの書き込みと permutation の store の間に release fence を入れる。version の insert カウンタは増やさない。
  * ただし削除で `remove_to_back` したスロットをすぐ再利用すると、読み手が古いキーと新しい値を混ぜて読む可能性がある。masstree-beta は削除の後の最初の挿入で version を上げる (`modstate`, `mark_insert`)。
* **split は version の splitting ビットを立てて行う**。読み手は、split に気付いたら `next` をたどって正しい葉へ進む (B-link tree と同じ)。
* **layer の作成**: スロットの keylenx を UNSTABLE にする → lv にリンクを書く → keylenx を LAYER にする。読み手は UNSTABLE を見たらやり直す。
* 単一スレッドの最初の版では、version とこれらの順序は全部省いてよい。
* masstree-beta では、葉のスロット0の ikey を「この葉の下限」として読み手が使う (`ikey_bound`)。そのため、先頭でない葉では、スロット0を違う ikey で再利用しない (`find_insert`)。単一スレッドなら不要。

## A6. 境界条件と落とし穴

* **0 埋めの衝突**: "ABC" と "ABC\0" は ikey が同じ。keylenx で区別する。keylenx を見ずに ikey だけで一致判定すると取り違える。
* **長さちょうど 8 のキー**: keylenx = 8 で inline。suffix も layer も作らない。長さ 9 から KSUF。
* **空のキー**: ikey = 0、keylenx = 0。layer の途中で残りが空になる場合 (キー長が 8 の倍数) も同じ。
* **permutation の桁あふれ**: `i = 14` のシフトで `wrapping_sub` が要る (A2.4)。
* **同じ ikey の分割禁止**: split の mid の調整を忘れると、interior の区切り (ikey のみ) で正しく振り分けられなくなる。
* **layer の root の split**: 上の layer のスロットを更新しないと、キーが消えたように見える (A4.7)。
* **layer の鎖**: 長い共通接頭辞 (例えば 64 バイト共通の 1000 キー) では 8 段以上の layer になる。layer ごとに B+-Tree の降下があるので遅い (Masstree 論文 4.1 でも言及)。
* **suffix の比較**: KSUF のスロットで suffix を比べ忘れると、ikey が同じだけの別のキーの値を返す。

## A7. テスト方針

* **オラクル**: `BTreeMap<Vec<u8>, u64>` に同じ操作列を流し、get / put の戻り値 / remove の戻り値 / scan の結果を比べる。
* **Permuter 単体**: `insert_from_back` / `remove_to_back` を、A2.4 の配列版 (`Vec<u8>` のモデル) とランダムな操作列 (各 10^6 回程度) で比べる。各操作の後に「p[0..15] が 0..14 の置換になっている」ことも確認する。上の3回挿入の例 (`0x3456789ABCDE2013`) を固定値のテストにする。
* **不変条件チェッカー** (毎操作または N 操作ごと):
  * 各 border で A3-1 (ソート順)、A3-5 (ord = 9 は ikey ごとに高々1つ)。
  * 各 layer で、葉のリスト順のキーが昇順。interior の区切りと子の ikey 範囲 (A3-4)。parent ポインタの整合。
  * A3-3: 隣り合う葉の境目で ikey が異なる。
  * A3-6: LAYER の先が空でない。layer 内の全キーを復元して、上の prefix を共有することを確認する。
* **狙い撃ちのケース**:
  * 長さ 0〜20 の全長さで、同じ先頭 8 バイトを持つキー群 (ikey の衝突、ord の順序)。
  * `"ABC"`, `"ABC\0"`, `"ABC\0\0"` のような 0 埋めの衝突。
  * 16, 24, 64 バイトの共通接頭辞 (layer の鎖)。その後に全部消して layer が回収されるか。
  * 1つの ikey に10キー (長さ 0〜8 と 8 超) を入れた状態で split を起こす。
  * 昇順・降順の挿入 (右端・左端の split)。

## A8. 原典との違い・簡略化

* **単一スレッド**: version、fence、UNSTABLE、modstate、ikey_bound は省いた (A5 で要点のみ)。
* **suffix の置き場所**: 外部の配列1つにした。原典は inline / 外部を適応的に選ぶ stringbag。
* **layer の作成**: twig を先に作らず、`put` の再帰で鎖を作る。単一スレッドなら結果は同じ。
* **layer の root の更新**: 原典は遅延 (`maybe_parent`)、ここでは `&mut` で即時。
* **delete**: 空の border の除去だけを書いた。空の layer は、上のスロットごと消す。【未検証】原典が「1キーだけ残った layer を上の KSUF スロットへ畳み戻す」処理をするかは確認していない。ここでは畳み戻さない。
* **ノードの並び**: 自分で決めた (論文 Figure 2 を基にした)。原典の border は `extrasize64_`, `modstate_` などを持ち、並びも違う。

---

# Part B: Wormhole

## B1. 目的と論文との関係

* Wu, Ni, Jiang (EuroSys 2019)。B+-Tree の内部ノードを「anchor の trie を詰めたハッシュ表 (MetaTrieHT)」に置き換えた順序付き索引。
* lookup は「接頭辞の長さで二分探索」するので O(log L) (L = キー長)。件数 N に依存しない。
* **論文との関係**: Section 6.4、Figure 1 の比較相手。最大のライバル。
  * lookup: ベースライン B-Tree は 53〜60% 遅い。適応型でも 26〜28% 遅い。dense だけは適応型が 27% 速い。
  * insert: 文字列では適応型が 17〜27% 速い。sparse では 21% 遅い。dense では 429% 速い (Wormhole が苦手)。
  * scan: 適応型が 88〜430% 速い。Wormhole は葉にレコードを入れず、ポインタで持つので局所性が悪い。
  * 論文では `whunsafe` API (同期なし) と Wormhole 自身のメモリアロケータを使って測っている。

## B2. データ配置

### B2.1 全体像

```
MetaTrieHT (ハッシュ表: 接頭辞 → item)
  ""   : bitmap={A,J}  lmost=L0 rmost=L3
  "A"  : bitmap={u}    lmost=L1 rmost=L1
  "Au" : bitmap={}     lmost=L1 rmost=L1      ← anchor
  "J"  : bitmap={a,o}  lmost=L2 rmost=L3
  "Ja" : bitmap={m}    ...
  "Jam": bitmap={}     lmost=L2 rmost=L2      ← anchor
  "Jo" : bitmap={s}    ...
  "Jos": bitmap={}     lmost=L3 rmost=L3      ← anchor

LeafList (双方向リスト、キー順)
  L0 (anchor "")  <->  L1 (anchor "Au")  <->  L2 (anchor "Jam")  <->  L3 (anchor "Jos")
  Abbe, Andrew          Austin, Denice        James, Jason           Joseph, Julian
```

* 各葉は **anchor** (その葉の範囲の下限を表す短い接頭辞) を持つ。
* 全ての anchor と、その**全ての接頭辞**を、ハッシュ表に item として入れる。trie のポインタは持たない。ある接頭辞の子があるかは、ハッシュ表を引けば分かる。
* 例は Wormhole 論文 Figure 3〜5 を基にした。最左の葉の anchor は、論文では ⊥、この資料では空文字列 "" (B3.3)。

### B2.2 葉

```rust
const LEAF_CAP: usize = 128;                     // 葉あたりのキー数 (wh.c の WH_KPN)
const MERGE_SIZE: usize = 96;                    // 隣と合わせてこれ未満なら merge (WH_KPN_MRG = 3/4)

struct WhLeaf {
    anchor: Box<[u8]>,
    prev: Option<LeafId>,
    next: Option<LeafId>,
    nr_keys: usize,
    nr_sorted: usize,                            // order[0..nr_sorted] がキー順。後ろは追記順
    tag: [u16; LEAF_CAP],                        // 256 B: ハッシュタグ、昇順 (0..nr_keys)
    tag_slot: [u8; LEAF_CAP],                    // 128 B: tag[i] のキーの物理スロット
    order: [u8; LEAF_CAP],                       // 128 B: 物理スロットをキー順に (前半ソート済み + 後半未ソート)
    kv: [*mut Kv; LEAF_CAP],                     // 1024 B: レコード本体へのポインタ (順不同)
}

struct Kv { key: Box<[u8]>, value: Box<[u8]> }   // 別に確保する (論文の scan が遅い原因)
```

* 葉の中には並びが2つある。
  * **タグ順** (`tag`, `tag_slot`): 点検索用。16 ビットのハッシュタグで探す。
  * **キー順** (`order`): 範囲検索と split 用。挿入は末尾に追記するだけ。ソートは必要になるまで遅らせる (incSort)。
* タグ = キー全体の CRC32C を 16 ビットに畳んだもの。0 は「空」に使うので 1 に置き換える (wh.c `wormhole_pkey`: 上位16と下位16の XOR、0 なら 1)。論文は「下位16ビット」と書いている。
* 葉を `LeafId` (Vec の添字) で持つと、`prev` / `next` / lmost / rmost を生ポインタなしで書ける。この資料はそうする。

### B2.3 MetaTrieHT の item

```rust
struct MetaItem {
    prefix: Box<[u8]>,       // この item が表す接頭辞 (anchor の接頭辞)
    hash: u32,               // prefix の CRC32C (B5.1)。ハッシュ表のキー
    bitmap: [u64; 4],        // 子のバイト値の集合: prefix + [b] も item なら b のビットが立つ
    lmost: LeafId,           // anchor が prefix で始まる葉のうち最も左
    rmost: LeafId,           // 同じく最も右
}

struct MetaTrieHT {
    table: hashbrown::HashTable<MetaItem>,   // hash で引き、prefix のバイト比較で確定する
    max_anchor_len: usize,                   // 二分探索の上限 (wh.c の maxplen)
}
```

* 論文の item は「葉 item (anchor そのもの)」と「内部 item」の2種類。葉 item は葉へのポインタを持つ。
* この資料では1種類にまとめる。prefix が anchor かどうかは `leaves[lmost].anchor.len() == prefix.len()` で分かる (anchor が prefix に等しい葉は、prefix で始まる葉の中で最も左だから)。
* wh.c の item (`struct wormmeta`) は 32 バイト + 必要なら bitmap 32 バイト。子が1つだけのときは bitmap を持たず `bitmin == bitmax` で表す。さらに `lpath` (B5.3) をキャッシュしている。

## B3. anchor の作り方

### B3.1 条件

葉 B の anchor を a_B、B の左隣を A とする。

* **順序条件**: A のどのキーよりも大きく、B のどのキー以下。`max(A) < a_B <= min(B)`。
* 最左の葉の anchor は、全てのキー以下であればよい。

### B3.2 論文の方式 (⊥ 付き)

論文はさらに **prefix 条件** (どの anchor も他の anchor の接頭辞でない) を課す。trie の葉と anchor を1対1にするため。

* キーに現れない最小のトークン ⊥ を仮定する。
* A の最大キーを `P1..Pk A1..`、B の最小キーを `P1..Pk B1..` とする (A1 < B1、P は共通接頭辞)。
* B の anchor は `P1..Pk B1`。ただし、それが右隣 C の anchor の接頭辞なら `P1..Pk B1 ⊥`。
* さらに、A の anchor `P1..Pj` (j ≤ k) が新しい anchor の接頭辞になるなら、A の anchor を `P1..Pj ⊥` に変える。
  * 論文 Algorithm 4 の l.15〜18: split で通る接頭辞が既存の葉 item なら、内部 item を作り、葉 item を `prf + 0` に付け替える (⊥ = 0)。
* 最左の葉の anchor は ⊥。
* 問題: ⊥ = 0x00 とすると、0x00 を含むキーで困る。論文 3.3 は「0 を許すと、anchor の候補が別の anchor (同じ接頭辞 + 末尾の 0 の並び) の接頭辞になって split できない場合がある。そのときは葉を容量超えの fat node にする」としている。

### B3.3 この資料の方式 (⊥ なし。wh.c と同じ)

wh.c は ⊥ を使わず、prefix 条件も課さない。anchor が別の anchor の接頭辞であってもよい。代わりに lookup の最後の一歩 (B5.3) で「prefix がちょうど anchor か」を見る。任意のバイト列のキーで動き、fat node も要らないので、Rust ではこちらを勧める。

* 最左の葉の anchor = 空文字列 ""。root item ("") は常に存在する。
* split で左に `k1` (左に残る最大キー)、右に `k2` (右へ移る最小キー) が来るとき:

```rust
/// 右の葉の anchor: k2 の先頭 (lcp(k1, k2) + 1) バイト
fn make_anchor(k1: &[u8], k2: &[u8]) -> Box<[u8]> {
    let l = lcp(k1, k2);          // k1 < k2 なので l < k2.len()
    k2[..l + 1].into()
}
```

* 順序条件を満たす: `k1 < k2[..l+1] <= k2`。
  * k1 が k2 の接頭辞 (l = k1.len()) でも、`k2[..l+1]` は k1 より長く k1 で始まるので k1 より大きい。
* 割り当て可能な最短の anchor でもある。`k2[..l]` は k1 の接頭辞なので k1 以下になってしまう。
* 2つの異なるキーの間なら必ず作れる。split が失敗することはない。

## B4. 不変条件

1. 葉のリストを左から並べると、anchor は狭義単調増加。最左の anchor は ""。
2. 各葉 B について、`B.anchor <= B の全キー < B.next.anchor` (next があれば)。
3. MetaTrieHT の item の集合 = 全 anchor の全接頭辞 (長さ 0 から anchor の長さまで) の集合。過不足なし。
   * したがって item の集合は**接頭辞について閉じている**。長さ m の接頭辞が item なら、それより短い接頭辞も全部 item。B5.2 の二分探索はこれに頼る。
4. item p の bitmap のビット b が立つ ⇔ `p + [b]` が item。
5. item p の lmost / rmost = anchor が p で始まる葉のうち最左 / 最右。p で始まる葉はリスト上で連続している。
6. `max_anchor_len >= 全 anchor の最大長`。
7. 葉の中: `tag[0..nr_keys]` は昇順。`order[0..nr_sorted]` はキー順。`{tag_slot}` と `{order}` はどちらも使用中スロットの集合に一致する。
8. 葉のキー数 ≤ LEAF_CAP。

## B5. 操作

### B5.1 CRC32C と差分ハッシュ

```rust
const CRC_SEED: u32 = 0xDEAD_BEEF;   // wh.c の KV_CRC32C_SEED

/// CRC-32C の「生の状態」を bytes の分だけ進める。最後の反転 (xor) はしない。
/// x86_64: _mm_crc32_u64 / _mm_crc32_u8、aarch64: __crc32cd / __crc32cb で書く。
/// 00-primitives.md の一覧にないので、ここで定義する。
fn crc32c_extend(state: u32, bytes: &[u8]) -> u32;
```

* 生の状態のまま続けると `crc32c_extend(crc32c_extend(s, a), b) == crc32c_extend(s, a ++ b)` が成り立つ。
* これで「長さ lo の接頭辞のハッシュ」から「長さ mid の接頭辞のハッシュ」を、`key[lo..mid]` だけ読んで作れる。二分探索の各段で、先頭から計算し直さずに済む。
* 葉のタグには、キー全体のハッシュ `crc32c_extend(CRC_SEED, key)` を使う。lookup の最初に1回だけ計算する。

**hashbrown に渡すときの注意**: `HashTable::find(hash: u64, eq)` は、ハッシュの上位7ビットを制御バイトのタグに使う。u32 をそのまま u64 にすると上位が全部 0 になり、タグが効かない (正しくは動くが遅い)。`(h as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)` などで上位まで散らしてから渡す。

### B5.2 最長一致接頭辞 (LPM) の二分探索

```rust
/// key の接頭辞で、MetaTrieHT にある最長のものを返す (item とその長さ、その長さのハッシュ)。
fn search_lpm<'a>(ht: &'a MetaTrieHT, key: &[u8]) -> (&'a MetaItem, usize, u32) {
    // 不変: 長さ lo の接頭辞は item (lo = 0 は root "")。答えは [lo, hi] にある
    let (mut lo, mut hi) = (0, key.len().min(ht.max_anchor_len));
    let mut lo_hash = CRC_SEED;
    let mut lo_item = ht.get(lo_hash, b"").unwrap();
    while lo < hi {
        // 早期終了: 次のバイトの子がなければ、lo が答え
        if !lo_item.has_child(key[lo]) { break; }
        let mid = (lo + hi + 1) / 2;
        let h = crc32c_extend(lo_hash, &key[lo..mid]);
        match ht.get(h, &key[..mid]) {                   // ハッシュで引き、prefix のバイト比較で確定
            Some(it) => { lo = mid; lo_hash = h; lo_item = it; }
            None => { hi = mid - 1; }
        }
    }
    (lo_item, lo, lo_hash)
}
```

* **二分探索が成り立つ理由**: 不変条件3 (接頭辞について閉じている)。長さ m が item なら m 未満も全部 item なので、「長さ m は item か」は m について単調。
* **ハッシュの一致だけで「ある」と判断してはいけない**。偽陽性で長い側へ進むと、単調性が崩れて答えを誤る。必ず prefix のバイト列を比べる。
  * wh.c は、まずタグだけを見る速い二分探索 (`wormhmap_peek`) をして、最後に本物の照合をする。外れたら、照合付きの遅い探索をやり直す (`wormhole_meta_lcp`)。最初の版では照合付きの1段だけでよい。
* 早期終了 (bitmap の確認) は wh.c の2段目の探索にある最適化。省いても正しい。
* 計算量は O(log min(L, max_anchor_len)) 回のハッシュ表参照。

### B5.3 葉の特定 (searchTrieHT)

LPM の item p から、key を含む葉 (anchor ≤ key の最大の葉) を決める。

```rust
fn search_leaf(ht: &MetaTrieHT, leaves: &Leaves, key: &[u8]) -> LeafId {
    let (p, plen, p_hash) = search_lpm(ht, key);
    if plen == key.len() {
        return lpath(p, leaves);                         // key そのものが接頭辞として存在
    }
    let c = key[plen];                                   // p の子に c はない (あれば LPM が伸びている)
    match p.highest_child_below(c) {                     // bitmap で c 未満の最大のビット
        None => lpath(p, leaves),                        // c より小さい子がない
        Some(d) => {
            // d の部分木の最右の葉。wh.c は「全部の子が c 未満」なら p.rmost で済ませる
            let h = crc32c_extend(p_hash, &[d]);
            let child = ht.get(h, &[&key[..plen], &[d]].concat()).unwrap();
            child.rmost
        }
    }
}

/// 「anchor が p 以下の最大の葉」。p が anchor ならその葉、そうでなければ lmost の左隣
fn lpath(p: &MetaItem, leaves: &Leaves) -> LeafId {
    let l = p.lmost;
    if leaves[l].anchor.len() == p.prefix.len() { l } else { leaves[l].prev.unwrap() }
}
```

**正しさ** (B3.3 の方式で):

* p で始まる anchor は、`p` 自身 (anchor なら)、`p + [d] + ..` (d は bitmap のビット) のどれか。
* key = `p + [c] + ..` で、c は bitmap にない。
  * `p` ≤ key。`d < c` の部分木の anchor はすべて key より小さい。`d > c` の部分木の anchor はすべて key より大きい。
  * p で始まらない anchor は、p より小さいか、p で始まる全ての文字列より大きい。
* したがって「anchor ≤ key の最大」は、c 未満の最大の子 d があればその部分木の最右 (rmost)。なければ p 自身 (anchor なら)、それもなければ p で始まる最左の葉の左隣。
* `plen == key.len()` のときも同じ理屈で lpath になる (key = p)。
* lmost の左隣は必ず存在する。p が anchor でないなら p ≠ ""、よって lmost は最左の葉 (anchor "") ではない。

* 論文 Algorithm 3 (`searchTrieHT`) は同じことを「兄弟が右側にしかなければ `child.leftmost.left`」と書いている。
* wh.c は `lpath` を item にキャッシュしている (`wormmeta_lpath_load`)。lmost を書き換えるたび、また lmost の左隣が変わるたびに更新が要る (`wormmeta_lmost_store`, `wormmeta_lpath_update`)。最初の版では上のように毎回計算する方が簡単。

### B5.4 葉の中の点検索

```rust
/// key の位置 (tag 配列の添字) を返す。なければ None。
fn leaf_find(leaf: &WhLeaf, key: &[u8], tag: u16) -> Option<usize> {
    let n = leaf.nr_keys;
    // タグが一様に散っていれば、位置はほぼ tag * n / 65536。そこから左右に調整する
    let mut i = (tag as usize * n) >> 16;
    while i > 0 && tag <= leaf.tag[i - 1] { i -= 1; }
    while i < n && tag > leaf.tag[i] { i += 1; }
    while i < n && leaf.tag[i] == tag {
        if leaf.kv(leaf.tag_slot[i]).key == key { return Some(i); }   // タグの衝突はキー全体で確定
        i += 1;
    }
    None
}
```

* 128 キーなら、たいてい1〜3回のタグ比較で終わる (Wormhole 論文 3.2)。
* wh.c は詰めた配列ではなく、128 個の枠に `tag / 512` の位置を起点に置く (空きは tag = 0)。考え方は同じ。

### B5.5 get / set / del

```rust
fn get(wh: &Wormhole, key: &[u8]) -> Option<&[u8]> {
    let h = crc32c_extend(CRC_SEED, key);
    let leaf = &wh.leaves[search_leaf(&wh.ht, &wh.leaves, key)];
    leaf_find(leaf, key, tag_of(h)).map(|i| &*leaf.kv(leaf.tag_slot[i]).value)
}

fn set(wh: &mut Wormhole, key: &[u8], value: &[u8]) {
    let tag = tag_of(crc32c_extend(CRC_SEED, key));
    let mut id = search_leaf(&wh.ht, &wh.leaves, key);
    if let Some(i) = leaf_find(&wh.leaves[id], key, tag) {
        wh.leaves[id].replace_value(i, value);
        return;
    }
    if wh.leaves[id].nr_keys == LEAF_CAP {
        let right = split(wh, id);                        // B5.6
        if key >= &*wh.leaves[right].anchor { id = right; }
    }
    leaf_insert(&mut wh.leaves[id], key, value, tag);
}

fn del(wh: &mut Wormhole, key: &[u8]) -> bool {
    let tag = tag_of(crc32c_extend(CRC_SEED, key));
    let id = search_leaf(&wh.ht, &wh.leaves, key);
    let Some(i) = leaf_find(&wh.leaves[id], key, tag) else { return false };
    leaf_remove(&mut wh.leaves[id], i);
    // 右隣と合わせて小さければ、右を左へ吸収する (wh.c: 空、または合計が MERGE_SIZE 未満)
    if let Some(r) = wh.leaves[id].next {
        if wh.leaves[id].nr_keys == 0 || wh.leaves[id].nr_keys + wh.leaves[r].nr_keys < MERGE_SIZE {
            merge(wh, id, r);                             // B5.7
            return true;
        }
    }
    // 左隣と合わせて小さければ、自分を左へ吸収する (論文 Algorithm 2 の DEL)
    if let Some(l) = wh.leaves[id].prev {
        if wh.leaves[l].nr_keys + wh.leaves[id].nr_keys < MERGE_SIZE { merge(wh, l, id); }
    }
    true
}

fn tag_of(h: u32) -> u16 { let t = (h as u16) ^ ((h >> 16) as u16); if t == 0 { 1 } else { t } }
```

**葉への挿入と削除**:

```rust
fn leaf_insert(leaf: &mut WhLeaf, key: &[u8], value: &[u8], tag: u16) {
    let slot = leaf.free_slot();                          // kv[slot] が null の位置
    leaf.kv[slot] = Kv::alloc(key, value);
    // タグ順の配列に挿入 (後ろを1つずらす)
    let pos = leaf.tag[..leaf.nr_keys].partition_point(|&t| t < tag);
    insert_at(&mut leaf.tag, &mut leaf.tag_slot, pos, tag, slot as u8, leaf.nr_keys);
    // キー順の配列には末尾に追記するだけ。ただし末尾が最大なら sorted 部分を伸ばせる
    leaf.order[leaf.nr_keys] = slot as u8;
    if leaf.nr_sorted == leaf.nr_keys && (leaf.nr_keys == 0 || key > leaf.key_at_order(leaf.nr_keys - 1)) {
        leaf.nr_sorted += 1;
    }
    leaf.nr_keys += 1;
}

fn leaf_remove(leaf: &mut WhLeaf, i: usize) {
    let slot = leaf.tag_slot[i];
    remove_at(&mut leaf.tag, &mut leaf.tag_slot, i, leaf.nr_keys);
    let j = leaf.order[..leaf.nr_keys].iter().position(|&s| s == slot).unwrap();
    leaf.order.copy_within(j + 1..leaf.nr_keys, j);       // 詰めれば sorted 部分の順序は保たれる
    if j < leaf.nr_sorted { leaf.nr_sorted -= 1; }
    leaf.nr_keys -= 1;
    Kv::free(leaf.kv[slot as usize]); leaf.kv[slot as usize] = null_mut();
}

/// order 全体をキー順にする (論文 incSort)。未ソートの後半をソートして、前半とマージする
fn inc_sort(leaf: &mut WhLeaf) {
    if leaf.nr_sorted == leaf.nr_keys { return; }
    let (s, n) = (leaf.nr_sorted, leaf.nr_keys);
    leaf.order[s..n].sort_by(|a, b| leaf.key_of(*a).cmp(leaf.key_of(*b)));
    merge_two_sorted_runs(&mut leaf.order[..n], s);       // 前半 [0, s) と後半 [s, n) のマージ
    leaf.nr_sorted = n;
}
```

* 論文は「ソート済みが少なければ全体を qsort、そうでなければ後半だけソートしてマージ」としている。

### B5.6 split (葉の分割と anchor の追加)

```rust
fn split(wh: &mut Wormhole, left: LeafId) -> LeafId {
    inc_sort(&mut wh.leaves[left]);
    let n = wh.leaves[left].nr_keys;
    // 1. 分割位置。中央 (右端の葉なら 3/4) を目安に、短い anchor が作れる位置を選ぶ
    let cut = choose_cut(&wh.leaves[left]);               // 1..n。order[..cut] が左に残る
    let k1 = wh.leaves[left].key_at_order(cut - 1);
    let k2 = wh.leaves[left].key_at_order(cut);
    let anchor = make_anchor(k1, k2);                      // B3.3

    // 2. 新しい葉を作り、order[cut..n] のキーを移す (両方の葉の tag 配列も作り直す)
    let right = wh.leaves.alloc(WhLeaf::new(anchor.clone()));
    move_keys(&mut wh.leaves, left, right, cut);

    // 3. リストにつなぐ: left <-> right <-> old_next
    let next = wh.leaves[left].next;
    link(&mut wh.leaves, left, right, next);

    // 4. MetaTrieHT に anchor とその接頭辞を反映する
    meta_insert_anchor(&mut wh.ht, &wh.leaves, right, &anchor, left, next);
    wh.ht.max_anchor_len = wh.ht.max_anchor_len.max(anchor.len());
    right
}

fn meta_insert_anchor(ht: &mut MetaTrieHT, leaves: &Leaves, new: LeafId, a: &[u8],
                      left: LeafId, next: Option<LeafId>) {
    let mut h = CRC_SEED;
    for plen in 0..=a.len() {
        if plen > 0 { h = crc32c_extend(h, &a[plen - 1..plen]); }   // 差分ハッシュ
        let p = &a[..plen];
        match ht.get_mut(h, p) {
            Some(it) => {
                if plen < a.len() { it.set_child(a[plen]); }         // 既存の item にも子のビットを立てる
                if Some(it.lmost) == next { it.lmost = new; }       // new は next の直前に入った
                else if it.rmost == left { it.rmost = new; }        // new は left の直後に入った
            }
            None => {
                let mut it = MetaItem::new(p, h, /* lmost = rmost = */ new);
                if plen < a.len() { it.set_child(a[plen]); }
                ht.insert(it);
            }
        }
    }
}
```

**lmost / rmost の更新が上の2行で足りる理由**:

* 既存の item p について、新しい葉 new の anchor は p で始まる。new はリスト上で left と next の間に入る。
* p で始まる葉は連続している (不変条件5)。new がその範囲の左端になるのは、元の左端 lmost が next だった場合だけ。右端になるのは、元の右端 rmost が left だった場合だけ。
* 両方が同時に起きることはない (lmost = next かつ rmost = left なら next ≤ left になって矛盾)。
* new が範囲の内側に入るだけなら、lmost も rmost も変わらない。

**論文との違い**: 論文 Algorithm 4 の split ループ (l.13〜24) は、既存の内部 item に子のビットを立てる処理を書いていない。新しい item を作るときに `initBitID` を立てるだけ。そのまま実装すると、既存 item の bitmap に新しい枝が反映されず、B5.3 の兄弟探索が誤る。wh.c は既存 item にもビットを立てている (`wormmeta_split_touch` → `wormmeta_bm_set_helper`)。上の擬似コードは wh.c に合わせた。

**最適化**: 長さが `lcp(left.anchor, next.anchor)` 未満の接頭辞は、left と next の両方の anchor の接頭辞。new はその範囲の内側に入るだけなので、何も変わらない。wh.c はループをそこから始める (`wormmeta_split`)。

**分割位置の選び方** (`choose_cut`):

* どの位置でも anchor は作れる (B3.3)。短い anchor ほど MetaTrieHT が小さく、二分探索の上限も短い。
* wh.c (`wormhole_split_cut_search1`) は、葉全体の最小キーと最大キーの lcp + 1 を目標の anchor 長とする。その長さで切れる位置のうち、目標位置 (中央 = 64、右端の葉なら 96) に最も近いものを二分探索で探す。
* 最初の版は「中央で切る」だけでよい。

### B5.7 merge (葉の統合と anchor の削除)

常に**右の葉 victim を左の葉 left に吸収**する。最左の葉 (anchor "") は消えない。

```rust
fn merge(wh: &mut Wormhole, left: LeafId, victim: LeafId) {
    move_all_keys(&mut wh.leaves, victim, left);          // left の nr_sorted は、連結しても順序が保たれるなら足し合わせる
    let next = wh.leaves[victim].next;
    unlink(&mut wh.leaves, victim);                       // left <-> next
    let a = wh.leaves[victim].anchor.clone();
    meta_remove_anchor(&mut wh.ht, victim, &a, left, next);
    wh.leaves.free(victim);
}

fn meta_remove_anchor(ht: &mut MetaTrieHT, victim: LeafId, a: &[u8], left: LeafId, next: Option<LeafId>) {
    let mut h = CRC_SEED;
    let mut prev_hash = CRC_SEED;                          // 1つ短い接頭辞のハッシュ
    let mut parent_alive = false;                          // 1つ短い接頭辞の item が残ったか
    for plen in 0..=a.len() {
        if plen > 0 { h = crc32c_extend(h, &a[plen - 1..plen]); }
        let p = &a[..plen];
        let it = ht.get_mut(h, p).unwrap();
        if it.lmost == victim && it.rmost == victim {
            // victim だけが使っていた item: 消す。親の item から子のビットを外す
            ht.remove(h, p);
            if parent_alive { ht.get_mut(prev_hash, &a[..plen - 1]).unwrap().clear_child(a[plen - 1]); }
            parent_alive = false;
        } else {
            if it.lmost == victim { it.lmost = next.unwrap(); }   // victim の次 (同じ接頭辞を持つ)
            else if it.rmost == victim { it.rmost = left; }       // victim の前 (同じ接頭辞を持つ)
            parent_alive = true;
        }
        prev_hash = h;
    }
}
```

* item が残る (他の葉も使っている) とき、victim が左端なら新しい左端は next、右端なら新しい右端は left。どちらも p で始まる (範囲が連続しているから)。
* victim の anchor そのものの item が、他の anchor の接頭辞として残ることがある (例: victim の anchor "Jo"、next の anchor "Jos")。その場合 item は残り、lmost が next に変わる。以後 "Jo" は anchor ではない item になる (B2.3 の判定が自動的に false になる)。
* 親のビットを外すのは、子の item を消したときだけ。親も消えたなら不要。
* wh.c は消す item に子がなければ (anchor の末端) ループを抜ける。また split と同じく `lcp(left.anchor, next.anchor)` から始める (`wormmeta_merge`)。
* `max_anchor_len` は減らさない。上限が緩くなるだけで、正しさには影響しない (wh.c も減らさない)。

### B5.8 範囲検索

```rust
fn scan(wh: &mut Wormhole, start: &[u8], cb: ScanCallback) {
    let mut id = Some(search_leaf(&wh.ht, &wh.leaves, start));
    let mut first = true;
    while let Some(l) = id {
        inc_sort(&mut wh.leaves[l]);                      // ソートを遅らせた分をここで払う
        let leaf = &wh.leaves[l];
        let from = if first { leaf.lower_bound_in_order(start) } else { 0 };   // order 上の二分探索
        for i in from..leaf.nr_keys {
            let kv = leaf.kv(leaf.order[i]);
            if !cb(&kv.key, &kv.value) { return; }        // Kv は別確保なので、ここで毎回キャッシュミスしうる
        }
        id = leaf.next; first = false;
    }
}
```

* 読み取り専用に見えるが、inc_sort で葉を書き換える。並行版では葉に別のロック (wh.c の `sortlock`) が要る。

## B6. 並行制御の要点

詳細は [12-concurrency.md](12-concurrency.md) に回す。要点だけ。

* 3種類の操作で必要な排他が違う (Wormhole 論文 2.5)。
  * 点検索・範囲検索: MetaTrieHT も葉も読むだけ。
  * split / merge を伴わない insert / delete: 葉1つの書き込みロックだけ。
  * split / merge: MetaTrieHT の変更が要る。全体で1つの mutex を取る。
* MetaTrieHT は**2つ持つ** (T1, T2)。書き手は T2 を変更し、ポインタを原子的に T2 へ切り替える。QSBR (RCU の一種) で、T1 を読んでいる読み手がいなくなるのを待つ。それから同じ変更を T1 にも当て、次の書き手の作業用にする。
* 葉と MetaTrieHT にバージョン番号を持たせる。読み手は「MetaTrieHT のバージョン ≥ 着いた葉のバージョン」でなければ、古い表で葉を選んだとみなしてやり直す (wh.c `wormhole_jump_leaf_read`)。
* 論文の Section 6.4 の測定は `whunsafe` API (同期なし) を使っている。単一スレッドの最初の版では全部省いてよい。

## B7. 境界条件と落とし穴

* **空の Wormhole**: 葉は最左の1枚 (anchor "") だけ、item は root "" だけ。この葉は merge で消さない。
* **キーが anchor より短い**: 例えば key = "J" で、"J" は item だが anchor ではない。plen == key.len() の分岐 (lpath) で、"J" で始まる最左の葉の左隣へ行く。
* **キーが空**: LPM は "" (長さ 0)。lpath(root) = 最左の葉。
* **0x00 や 0xFF を含むキー**: B3.3 の方式なら特別扱いは要らない。B3.2 (⊥ = 0) の方式で実装すると壊れる。
* **ハッシュの偽陽性**: 二分探索で、ハッシュ一致だけで長い側に進まない (B5.2)。
* **既存 item の bitmap**: split で新しい枝のビットを立て忘れない (B5.6 の論文との違い)。
* **lmost の左隣**: lpath で `prev.unwrap()` するのは、p が anchor でないときだけ。p = "" は常に anchor なので落ちない。
* **anchor が他の anchor の接頭辞**: B3.3 の方式では普通に起きる。item の「anchor かどうか」を固定のフラグで持つと、merge で更新し忘れる。この資料では lmost から毎回判定する。
* **split 直後の挿入先**: 新しいキーが右の anchor 以上なら右、未満なら左 (論文 Algorithm 2 の SET)。
* **merge の条件**: 右隣があれば、自分が空のときは合計に関係なく右を吸収する (wh.c)。右端の葉が空になり、左隣が大きいときは、空のまま残る (B5.5 の `del` も同じ)。範囲検索はそこを素通りするだけで、正しさには影響しない。
* **長い anchor**: anchor の長さはキー長まで伸びうる。wh.c は u16 に収まらない anchor では split をあきらめる (`WH_KPN2` を返す)。

## B8. テスト方針

* **オラクル**: `BTreeMap<Vec<u8>, Vec<u8>>` に同じ操作列を流し、get / set / del / scan を比べる。split / merge が頻繁に起きるよう、テストでは LEAF_CAP を 4〜8 程度に小さくする (MERGE_SIZE も比例させる)。
* **不変条件チェッカー** (毎操作または N 操作ごと):
  * 葉のリストを左からたどり、B4-1, 2, 7, 8 を確認する。prev と next の対応も確認する。
  * 全 anchor の全接頭辞から「あるべき item の集合」を作り、MetaTrieHT と**完全に一致**することを確認する (B4-3)。
  * 各 item について、bitmap を接頭辞集合から計算し直して比べる (B4-4)。lmost / rmost を葉のリストから計算し直して比べる (B4-5)。
  * 各 item の hash が `crc32c_extend(CRC_SEED, prefix)` に等しい。
* **search_leaf の単体テスト**: ランダムな key について、`search_leaf(key)` が「anchor ≤ key の最大の葉」(葉のリストを線形に探した結果) と一致すること。key は既存キー、既存キーの接頭辞、既存 anchor そのもの、anchor の接頭辞、anchor + 1 バイト、空文字列などを混ぜる。
* **CRC32C**: `crc32c_extend(crc32c_extend(s, a), b) == crc32c_extend(s, a ++ b)` を、ランダムな a, b で確認する。ハードウェア命令版をソフトウェア版 (表引き) と比べる。
* **狙い撃ちのケース**:
  * anchor が他の anchor の接頭辞になる配置 (例: キー "Ja", "Jo", "Jo1", "Jos.." を小さい LEAF_CAP で入れる)。その後、間の葉を merge で消す。
  * 0x00 を多く含むキー、末尾が 0x00 の並びだけ違うキー (論文 3.3 の fat node の例)。
  * 長い共通接頭辞 (URL 型) と、短く疎なキー (4 バイト整数) の両方。
  * 全件削除 → 最左の葉と root item だけに戻ること。

## B9. 原典との違い・簡略化

* **⊥ を使わない anchor**: 論文 2.2 の ⊥ 付き方式ではなく、wh.c の方式 (B3.3) を採った。prefix 条件を課さず、lookup の最後で「prefix が anchor か」を見る。
* **item の種類**: 論文の「葉 item / 内部 item」を1種類にまとめ、anchor かどうかは lmost から判定した。wh.c の `lpath` キャッシュは省いた (毎回 `prev` を1回たどる)。
* **bitmap**: 常に 256 ビット (32 B) を持つ。wh.c は子1つなら bitmap を省く (`bitmin == bitmax`)。
* **split の bitmap 更新**: 論文 Algorithm 4 にない「既存 item へのビット設定」を、wh.c に合わせて入れた (B5.6)。
* **LPM**: 照合付きの二分探索1段だけにした。wh.c はタグだけの速い探索 + 照合付きのやり直しの2段 (`wormhole_meta_lcp`)。
* **ハッシュ表**: `hashbrown::HashTable` を使う。wh.c は 8-way のバケット + 16 ビットのタグ + cuckoo 置換の自前の表 (`wormhmap_*`)。
* **葉のタグ配列**: 詰めた配列 + 「tag * n / 65536」から探す、論文の形にした。wh.c は 128 枠に `tag / 512` を起点に置く形。
* **分割位置**: 中央で切る簡単な形を既定にした。wh.c の短い anchor を探す方法は B5.6 に記述のみ。
* **並行制御**: 全部省いた (B6 で要点のみ)。
* 【未検証】B3.3 の方式の正しさ (B5.3 の証明) は、wh.c のコードを読んで自分で導いたもの。wh.c を実行しての確認はしていない。

---

## 参考資料

**Masstree**

* Mao, Kohler, Morris. Cache Craftiness for Fast Multicore Key-Value Storage. EuroSys 2012. https://pdos.csail.mit.edu/papers/masstree:eurosys12.pdf
  * 4.1 (layer の構造), 4.2 (ノードの配置、keylen と suffix), 4.3 (単一スレッドの変更), 4.6 (並行な挿入、新しい layer、split)
* 参照実装: https://github.com/kohler/masstree-beta (コミット `1119842`)
  * `kpermuter.hh`: `kpermuter::make_empty`, `make_sorted`, `insert_from_back`, `remove_to_back`
  * `masstree_struct.hh`: `leaf` (`ksuf_keylenx`, `layer_keylenx`, `keylenx_is_layer`, `keylenx_has_ksuf`, `ksuf_matches`, `assign`)
  * `masstree_key.hh`: `key::compare`
  * `masstree_get.hh`: `unlocked_tcursor::find_unlocked`, `tcursor::find_locked`
  * `masstree_insert.hh`: `tcursor::find_insert`, `tcursor::make_new_layer`
  * `masstree_split.hh`: `leaf::split_into`

**Wormhole**

* Wu, Ni, Jiang. Wormhole: A Fast Ordered Index for In-memory Data Management. EuroSys 2019. https://arxiv.org/abs/1805.02200
  * 2.2 (anchor と ⊥), 2.3〜2.4 (LPM と MetaTrieHT), Algorithm 1〜4, 3.2 (タグ配列と incSort), 3.3 (任意のトークンへの対応と fat node), 2.5 (並行制御)
* 参照実装: https://github.com/wuxb45/wormhole (コミット `9d3d0d0`、GPL-3.0 または MIT)
  * `wh.c`: `struct wormmeta`, `struct wormleaf`, `wormmeta_init`, `wormmeta_lmost_store`, `wormmeta_bm_set_helper`, `wormmeta_bm_clear_helper`, `wormhole_pkey`, `wormhole_meta_lcp`, `wormhole_meta_down`, `wormleaf_match_hs`, `wormhole_split_cut_search1`, `wormhole_split_alloc_anchor`, `wormhole_split_leaf`, `wormmeta_split_touch`, `wormmeta_split`, `wormmeta_lpath_update`, `wormmeta_merge`, `wormhole_split_meta`, `wormhole_meta_merge`, `wormhole_create_leaf0`, `wormhole_jump_leaf_read`
  * `kv.h`: `KV_CRC32C_SEED`
* 論文: Müller, Benson, Leis. B-Trees Are Back: Engineering Fast and Pageable Node Layouts. SIGMOD 2025. Section 6.4
