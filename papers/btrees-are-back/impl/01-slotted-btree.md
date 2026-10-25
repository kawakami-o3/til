# 01. スロット付きページの B+-Tree

論文のベースラインとなる B+-Tree を、自分で書けるように書き下す。
対象は background.md の 1.1〜1.4, 2.2, 2.3, 3.7。
prefix truncation、suffix truncation (短い区切りキー)、heads、hints も含める。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* 正規化済みキーの作り方は [02-key-encoding.md](02-key-encoding.md)、`head()` などの部品は [00-primitives.md](00-primitives.md) を参照。
* 並行制御 (OLC) は [12-concurrency.md](12-concurrency.md)、ページング (vmcache) は [11-buffer-management.md](11-buffer-management.md) で扱う。ここでは単一スレッド・全データがメモリ上、という前提で書く。

参照実装は論文の [btree-cpp](https://github.com/m-mueller678/btree-cpp/tree/sigmod25) (`btree/btree2020.{hpp,cpp}`)。
擬似コードは読みやすさを優先して書き直したもので、コードの直訳ではない。

## 目次

1. [目的と論文との関係](#1-目的と論文との関係)
2. [データ配置](#2-データ配置)
3. [不変条件](#3-不変条件)
4. [ノード単位の操作](#4-ノード単位の操作)
5. [木全体の操作](#5-木全体の操作)
6. [固定長キー版 (TLX 型)](#6-固定長キー版-tlx-型)
7. [一括構築と waves of misery](#7-一括構築と-waves-of-misery)
8. [境界条件と落とし穴](#8-境界条件と落とし穴)
9. [テスト方針](#9-テスト方針)
10. [原典との違い・簡略化](#10-原典との違い簡略化)
11. [参考資料](#11-参考資料)

---

## 1. 目的と論文との関係

* 可変長のキーと値を、**固定サイズ (4 KiB) のページ**に詰めて持つ B+-Tree。
* ページサイズが固定なので、そのままバッファマネージャに載せてディスクに追い出せる (pageable)。
* 論文の Section 2 のベースライン。そこに prefix truncation → heads → hints を足したものが、論文の比較の基準 (「hints 構成」) になる。
* fingerprinting リーフ ([08-fptree-bptree.md](08-fptree-bptree.md)) や dense leaves は、このノードの**別形式のリーフ**として差し替える。

## 2. データ配置

### 2.1 ノード全体

```
0                                                                     4096
+--------+------------------+-------- 空き --------+-------------------+
| header | slot[0..count]   |  →               ←   | heap: kv, fences  |
+--------+------------------+----------------------+-------------------+
          スロット配列は前から伸びる                 ヒープは後ろから伸びる
                                                 ↑ data_offset (ヒープの先頭)
```

* **header**: ノードのメタデータ (下記)。
* **slot 配列**: レコードごとに10バイト。**キー順に**並べる。
* **heap**: キーの本体 (prefix を除いた部分) と値、それに2つの fence キーを置く。順番は問わない。後ろから詰めていく (bump allocator)。

### 2.2 ヘッダ

```rust
#[repr(C)]
struct NodeHeader {            // offset  size
    tag: u8,                   // 0       1    Leaf / Inner (別形式のリーフもここで区別)
    _pad: u8,                  // 1       1
    count: u16,                // 2       2    スロット数
    space_used: u16,           // 4       2    heap 上の「生きている」バイト数 (kv + fences)
    data_offset: u16,          // 6       2    heap の先頭 (ここより後ろが使用中)
    lower_fence: FenceSlot,    // 8       4    下限 (この値は含まない)
    upper_fence: FenceSlot,    // 12      4    上限 (この値を含む)
    prefix_len: u16,           // 16      2    全キー共通の接頭辞の長さ
    _pad2: [u8; 6],            // 18      6
    upper: PageId,             // 24      8    内部ノードのみ: 最大の子
    hints: [u32; HINT_COUNT],  // 32      64   heads のサンプル
}                              // 合計 96 バイト

#[repr(C)]
struct FenceSlot { offset: u16, len: u16 }   // heap 上の位置と長さ。len == 0 は ±∞

const HINT_COUNT: usize = 16;
```

* `space_used` は、削除で使われなくなった heap 領域を数えないための値。compaction の判定に使う。
* 参照実装はフィールドの並びが少し違う (適応型用のカウンタなどがある)。ここでは論文 Figure 2 に合わせて整理した。

### 2.3 スロット

```rust
#[repr(C, packed)]
struct Slot {        // offset size
    offset: u16,     // 0      2   heap 上のキー本体の位置
    key_len: u16,    // 2      2   prefix を除いたキー長
    val_len: u16,    // 4      2   値の長さ
    head: u32,       // 6      4   prefix を除いたキーの先頭4バイト (ビッグエンディアン)
}                    // 10 バイト (アライメントなし)
```

* キー本体と値は heap 上で連続している: `[key (key_len) | value (val_len)]`。値の位置は `offset + key_len`。
* `head` は 4 バイト境界に揃わない (packed)。論文によると、2バイト詰め物を入れてアラインしても性能差は3%未満なので、空間を優先している。
  Rust では `ptr::read_unaligned` で読む ([00-primitives.md](00-primitives.md) の `load_be_u32` 参照)。

### 2.4 内部ノードの意味づけ

内部ノードの値は**子のページ ID (8バイト)**。

```
内部ノード: keys = [k0, k1, k2], children = [c0, c1, c2], upper = c3

  c0: (lower_fence, k0]
  c1: (k0, k1]
  c2: (k1, k2]
  c3: (k2, upper_fence]      ← header.upper
```

* 子 `c_i` が担当するのは「1つ前のキーより大きく、`k_i` 以下」。区切りキー `k_i` は、**子 `c_i` の上限 fence と同じ値**。
* キーより子が1つ多いので、最後の子は `upper` フィールドに持つ。
* 探索は `lower_bound(key)` (key 以上の最初のスロット) で行う。結果が `count` なら `upper` に進む。

### 2.5 fence と prefix

* 各ノードは自分の担当範囲 `(lower_fence, upper_fence]` を持つ。
  * 下限 fence は含まない (exclusive)、上限 fence は含む (inclusive)。
  * 長さ0の fence は「−∞ / +∞」を表す。根と、各レベルの左端・右端のノードがこれを持つ。
* `prefix_len = LCP(lower_fence, upper_fence)`。LCP は最長共通接頭辞の長さ。
  範囲内のキーはすべてこの接頭辞を持つので、キー本体からは省いて格納する。
* fence 自体は切り詰めずに heap に置く。prefix の実体は `lower_fence[..prefix_len]` で取れる。

```
lower_fence = "https://a",  upper_fence = "https://b"
prefix_len  = 8  ("https://")
格納するキー: "amazon.com" → "amazon.com" から "https://" を除いたもの
```

## 3. 不変条件

テストで毎回チェックする性質 (§9 の `check_invariants`)。

1. **スロットはキー順**: `prefix + key(i) < prefix + key(i+1)` (厳密に増加。重複キーなし)。
2. **キーは fence の範囲内**: すべての i で `lower_fence < full_key(i) <= upper_fence`。±∞ の側は検査しない。
3. **prefix の一致**: `prefix_len == LCP(lower_fence, upper_fence)`。全キーが `lower_fence[..prefix_len]` で始まる。
4. **head の一致**: `slot[i].head == head(key_without_prefix(i))`。
5. **hints の一致**: `count > 2*HINT_COUNT` のとき `hints[j] == slot[dist*(j+1)].head` (`dist = count / (HINT_COUNT+1)`)。
6. **領域が重ならない**: `size_of::<NodeHeader>() + count*10 <= data_offset`。
7. **space_used の正しさ**: `space_used == Σ(key_len + val_len) + lower_fence.len + upper_fence.len`。
8. **子の fence が親と一致**: 内部ノードの子 `c_i` について、`c_i.lower_fence == k_{i-1}` (i=0 なら親の lower_fence)、`c_i.upper_fence == k_i` (upper なら親の upper_fence)。
9. **平衡**: 根から全ての葉までの深さが等しい。

## 4. ノード単位の操作

### 4.1 基本の読み出し

```rust
impl Node {
    fn ptr(&self) -> *const u8 { self as *const _ as *const u8 }

    fn slot(&self, i: usize) -> Slot;                 // read_unaligned で i 番目を読む
    fn key(&self, i: usize) -> &[u8] {                // prefix を除いたキー
        let s = self.slot(i);
        &self.bytes()[s.offset as usize..][..s.key_len as usize]
    }
    fn value(&self, i: usize) -> &[u8] {
        let s = self.slot(i);
        &self.bytes()[(s.offset + s.key_len) as usize..][..s.val_len as usize]
    }
    fn prefix(&self) -> &[u8] {                       // lower_fence の先頭 prefix_len バイト
        &self.lower_fence()[..self.prefix_len as usize]
    }
    fn child(&self, i: usize) -> PageId {             // 内部ノード: i == count なら upper
        if i == self.count as usize { self.upper }
        else { u64::from_ne_bytes(self.value(i).try_into().unwrap()) }
    }
}
```

### 4.2 空き容量と compaction

```rust
fn slots_end(&self) -> usize { size_of::<NodeHeader>() + self.count as usize * size_of::<Slot>() }

/// 今すぐ使える空き
fn free_space(&self) -> usize { self.data_offset as usize - self.slots_end() }

/// 削除で生じた heap の穴を詰めた後の空き
fn free_space_after_compaction(&self) -> usize {
    PAGE_SIZE - self.slots_end() - self.space_used as usize
}

/// need バイトを確保できるようにする。必要なら compaction する。
fn request_space(&mut self, need: usize) -> bool {
    if need <= self.free_space() { return true; }
    if need <= self.free_space_after_compaction() { self.compactify(); return true; }
    false
}

/// 一時バッファに作り直してから丸ごとコピーする
fn compactify(&mut self) {
    let mut tmp = Node::new_empty(self.tag);                // スタック上の 4 KiB
    tmp.set_fences(self.lower_fence(), self.upper_fence());
    self.copy_range_to(&mut tmp, 0, 0, self.count as usize);
    tmp.upper = self.upper;
    tmp.make_hints();
    *self = tmp;
}
```

* compaction は insert のときだけ起きる (remove では起きない)。
* compaction するとキーの位置が変わる。**compaction の前に取った `&[u8]` を後で使わない**こと (Rust では借用規則が守ってくれるが、生ポインタで書くときは要注意)。

### 4.3 fence の設定と prefix の計算

```rust
fn set_fences(&mut self, lower: &[u8], upper: &[u8]) {
    self.lower_fence = self.heap_push(lower);   // data_offset を減らしてコピー、space_used += len
    self.upper_fence = self.heap_push(upper);
    self.prefix_len = lcp(lower, upper) as u16;
}

fn lcp(a: &[u8], b: &[u8]) -> usize {
    a.iter().zip(b).take_while(|(x, y)| x == y).count()
}
```

* 片方の fence が長さ0 (±∞) なら、prefix は0になる。

### 4.4 キーと値の格納

```rust
/// スロット i に (full_key, val) を書く。スロット配列のずらしは呼び出し側で済ませておく。
fn store_kv(&mut self, i: usize, full_key: &[u8], val: &[u8]) {
    let k = &full_key[self.prefix_len as usize..];       // prefix を落とす
    let len = k.len() + val.len();
    self.data_offset -= len as u16;
    self.space_used += len as u16;
    let off = self.data_offset as usize;
    self.bytes_mut()[off..][..k.len()].copy_from_slice(k);
    self.bytes_mut()[off + k.len()..][..val.len()].copy_from_slice(val);
    self.set_slot(i, Slot {
        offset: off as u16, key_len: k.len() as u16, val_len: val.len() as u16, head: head(k),
    });
}

/// 新しいレコードに必要なバイト数
fn space_needed(&self, full_key_len: usize, val_len: usize) -> usize {
    size_of::<Slot>() + (full_key_len - self.prefix_len as usize) + val_len
}
```

### 4.5 hints

```rust
fn make_hints(&mut self) {
    let dist = self.count as usize / (HINT_COUNT + 1);
    for j in 0..HINT_COUNT {
        self.hints[j] = self.slot(dist * (j + 1)).head;
    }
}

/// スロット i に挿入した直後に呼ぶ
fn update_hints(&mut self, i: usize) {
    let n = self.count as usize;
    let dist = n / (HINT_COUNT + 1);
    let mut begin = 0;
    // 間隔 dist が挿入前と同じなら、挿入位置より前の hint は変わらない
    if n > 2 * HINT_COUNT + 1 && (n - 1) / (HINT_COUNT + 1) == dist && i / dist > 1 {
        begin = i / dist - 1;
    }
    for j in begin..HINT_COUNT {
        self.hints[j] = self.slot(dist * (j + 1)).head;
    }
}

/// key_head を探す範囲 [lo, hi) を hints で絞る
fn search_hints(&self, key_head: u32, lo: &mut usize, hi: &mut usize) {
    let n = self.count as usize;
    if n <= 2 * HINT_COUNT { return; }              // 小さいノードでは使わない
    let dist = n / (HINT_COUNT + 1);
    let mut p = 0;
    while p < HINT_COUNT && self.hints[p] < key_head { p += 1; }
    let mut p2 = p;
    while p2 < HINT_COUNT && self.hints[p2] == key_head { p2 += 1; }
    *lo = p * dist;
    if p2 < HINT_COUNT { *hi = (p2 + 1) * dist; }
}
```

* `hints[j]` はスロット `dist*(j+1)` の head。`n` 個のスロットを17等分した境目をサンプリングしている。
* **`p2` で等しい hint を読み飛ばす**のは、同じ head が続く場合に備えるため。等しい hint の範囲全体を候補に含めないと、正しい位置を取りこぼす。
* `update_hints` の `i / dist > 1` の条件は「挿入位置が先頭付近でない」こと。先頭付近なら全部作り直す。
* `remove` 後はスロットが前にずれるので、全部作り直す (`make_hints`)。
* 線形走査でよい。16個 × 4バイト = 64バイトで、1キャッシュラインに収まる。SIMD で一度に比較してもよい (`simd` 版は 00-primitives.md の比較を u32 × 16 に広げる)。

### 4.6 ノード内探索 (lower_bound)

```rust
/// full_key 以上の最初のスロット位置を返す。完全一致なら found = true。
fn lower_bound(&self, full_key: &[u8]) -> (usize, bool) {
    debug_assert!(full_key.starts_with(self.prefix()));   // fence の範囲内なら必ず成り立つ
    let k = &full_key[self.prefix_len as usize..];
    let kh = head(k);
    let (mut lo, mut hi) = (0, self.count as usize);
    self.search_hints(kh, &mut lo, &mut hi);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let sh = self.slot(mid).head;
        if kh < sh { hi = mid; continue; }
        if kh > sh { lo = mid + 1; continue; }
        // head が等しいときだけ heap 上のキー本体を見る
        match k.cmp(self.key(mid)) {                  // バイト列の辞書順 (= memcmp + 長さ比較)
            Ordering::Less => hi = mid,
            Ordering::Greater => lo = mid + 1,
            Ordering::Equal => return (mid, true),
        }
    }
    (lo, false)
}
```

* head は「先頭4バイトを big-endian で整数にしたもの」なので、**head の大小 = 先頭4バイトの辞書順**。head が違えばそれだけで大小が決まる。
* head が等しくても、キーが4バイト未満のときは0埋めの影響がある。例: `"ab"` と `"ab\0"` は同じ head。だから head が等しいときは必ず本体を比べる。
* `full_key.starts_with(prefix)` は、親から正しく降りてきていれば必ず成り立つ。scan の開始キーなど外から来るキーは注意 (§8)。

### 4.7 insert (ノード単体)

```rust
/// 成功したら true。容量不足なら false (呼び出し側が split する)。
fn insert(&mut self, full_key: &[u8], val: &[u8]) -> bool {
    let (_, found) = self.lower_bound(full_key);
    if found {
        // 上書き: まず古いレコードを消し、新しいキーとして入れ直す
        self.remove(full_key);
    }
    if !self.request_space(self.space_needed(full_key.len(), val.len())) {
        return false;                                      // 上書きで消した分はそのまま。呼び出し側が split して再試行する
    }
    let (i, _) = self.lower_bound(full_key);               // compaction 後でも位置は同じだが念のため
    self.shift_slots_right(i);                             // slot[i..count] を1つ後ろへ (memmove)
    self.store_kv(i, full_key, val);
    self.count += 1;
    self.update_hints(i);
    true
}
```

* 参照実装は既存キーへの insert を `abort()` している (ベンチマークでは起きないため)。ここでは上書きとして書いた。
* 上書きを「消してから入れ直す」にしているのは、compaction との兼ね合いのため。
  古いレコードを残したまま `space_used` だけ減らして `request_space` を呼ぶと、compaction が古いレコードも一緒にコピーしてしまう。
  すると実際の空きが見積もりより小さくなり、heap がスロット配列に食い込む。
* 容量不足で false を返したとき、古い値はもう消えている。木全体の `insert` (§5.2) は split してから同じキーで入れ直すので、最終的には新しい値が入る。
* 挿入のたびにスロットを平均 `count/2` 個ずらす。論文の言う「insert のコスト = スロットの半分を移動」はこれ。

### 4.8 remove (ノード単体)

```rust
fn remove(&mut self, full_key: &[u8]) -> bool {
    let (i, found) = self.lower_bound(full_key);
    if !found { return false; }
    let s = self.slot(i);
    self.space_used -= s.key_len + s.val_len;              // heap はそのまま (穴になる)
    self.shift_slots_left(i);                              // slot[i+1..count] を1つ前へ
    self.count -= 1;
    self.make_hints();
    true
}
```

### 4.9 レコードの範囲コピー (prefix の付け替え)

split / merge / compaction で、レコードを別ノードに移す。**移動先の prefix_len が違う**ので、キーの付け替えが要る。

```rust
/// self の slot[src..src+n] を dst の slot[dst_i..] にコピーする
fn copy_range_to(&self, dst: &mut Node, dst_i: usize, src: usize, n: usize) {
    let (sp, dp) = (self.prefix_len as usize, dst.prefix_len as usize);
    for j in 0..n {
        let (k, v) = (self.key(src + j), self.value(src + j));
        if sp <= dp {
            // prefix が伸びる (split で範囲が狭くなる): キーの先頭 dp-sp バイトを捨てる
            dst.store_kv_truncated(dst_i + j, &k[dp - sp..], v);
        } else {
            // prefix が縮む (merge で範囲が広がる): 捨てていた prefix を戻す
            let mut full = Vec::with_capacity(sp + k.len());   // 実装では固定長バッファでよい
            full.extend_from_slice(self.prefix());
            full.extend_from_slice(k);
            dst.store_kv(dst_i + j, &full, v);
        }
    }
    dst.count += n as u16;
}
```

* `store_kv_truncated` は、すでに dst の prefix を除いたキーを受け取る版の `store_kv`。
* prefix が伸びる場合、捨てる `dp - sp` バイトはすべてのキーで共通 (新しい fence の範囲内だから)。

### 4.10 区切りキーの選択 (suffix truncation)

葉を split するとき、**左右を分けられる最短の区切りキー**を、中央付近の窓から選ぶ。

```rust
struct SepInfo { len: usize, slot: usize, truncated: bool }
// 左ノードには slot[0..=slot] が入る。区切りキーの実体は §4.11 の get_sep で作る。

fn find_separator(&self) -> SepInfo {
    let n = self.count as usize;
    let p = self.prefix_len as usize;
    if self.is_inner() {
        // 内部ノードは真ん中で分ける。区切りキーは既存のキーそのもの (親に移動する)
        let i = n / 2 - 1;
        return SepInfo { len: p + self.slot(i).key_len as usize, slot: i, truncated: false };
    }
    // 中央付近の n/16 個の窓
    let lo = n / 2 - n / 32;
    let hi = lo + n / 16;
    let c = lcp(self.key(lo), self.key(hi));           // 窓の両端の共通接頭辞 (prefix 抜き)
    if self.key(lo).len() == c {
        // key(lo) 自体が窓全体の共通接頭辞 → key(lo) を区切りキーにして、その直後で分ける
        return SepInfo { len: p + c, slot: lo, truncated: false };
    }
    // c バイト目が key(lo) と違う最初のキー i を探す (窓の中に必ずある)
    let mut i = lo + 1;
    while self.key(i)[c] == self.key(lo)[c] { i += 1; }
    if self.key(i).len() == c + 1 {
        // key(i) がちょうど c+1 バイト → key(i) 自体を区切りに。i は左に入る
        SepInfo { len: p + c + 1, slot: i, truncated: false }
    } else {
        // key(i) の先頭 c+1 バイトを区切りに。i は右に入る
        SepInfo { len: p + c + 1, slot: i - 1, truncated: true }
    }
}
```

なぜ正しいか:
* `key(i)` の先頭 `c+1` バイトを `s` とする。
* 左の最大キー `key(i-1)` は、c バイト目で `key(i)` より小さい。だから `key(i-1) < s`。
* `s` は `key(i)` の接頭辞なので `s <= key(i)`。
  * `key(i)` が `c+1` バイトちょうどなら `s == key(i)`。上限 fence は「含む」なので、`key(i)` は左に入れる (`truncated: false, slot: i`)。
  * それより長ければ `s < key(i)` で、`key(i)` は右に入る (`truncated: true, slot: i-1`)。
* よって「左の全キー ≤ s < 右の全キー」が成り立つ。

窓は全体の 1/16 なので、左右の件数の偏りは最大でも ±1/32 程度。

**論文が触れている代案**: 「短くする」代わりに「隣の区切りキーと接頭辞を共有させる」選び方もありうる。論文は未検討。トレードオフは [deep-dive.md 4](../deep-dive.md#4-区切りキーは短くすべきか接頭辞を共有させるべきか) を参照。

### 4.11 split (ノード単体)

```rust
/// 区切りキーの実体を作る (prefix + 選んだキーの先頭部分)
fn get_sep(&self, info: &SepInfo) -> Vec<u8> {
    let src = info.slot + info.truncated as usize;
    let mut s = self.prefix().to_vec();
    s.extend_from_slice(&self.key(src)[..info.len - self.prefix_len as usize]);
    s
}

/// self を左右に分け、区切りキーと新しい左ノードを parent に登録する。
/// 右ノードは self のページを再利用する (親の既存のポインタがそのまま右を指す)。
fn split(&mut self, parent: &mut Node, alloc: &mut PageAlloc) -> Result<(), NoSpace> {
    let info = self.find_separator();
    let sep = self.get_sep(&info);
    // 親に入らないなら、親を先に split してもらう (§5.3)
    if !parent.request_space(parent.space_needed(sep.len(), size_of::<PageId>())) {
        return Err(NoSpace);
    }
    let left_id = alloc.alloc_page();
    let left = alloc.node_mut(left_id);
    left.init(self.tag);
    left.set_fences(self.lower_fence(), &sep);
    let mut right = Node::new_empty(self.tag);            // 一時バッファ
    right.set_fences(&sep, self.upper_fence());

    if self.is_leaf() {
        self.copy_range_to(left, 0, 0, info.slot + 1);
        self.copy_range_to(&mut right, 0, info.slot + 1, self.count as usize - (info.slot + 1));
    } else {
        // 内部ノード: slot[info.slot] は親に上がるので、どちらにもコピーしない
        self.copy_range_to(left, 0, 0, info.slot);
        self.copy_range_to(&mut right, 0, info.slot + 1, self.count as usize - info.slot - 1);
        left.upper = self.child(info.slot);                 // 上がったキーの子が左の最大の子
        right.upper = self.upper;
    }
    left.make_hints();
    right.make_hints();
    parent.insert(&sep, &left_id.to_ne_bytes());           // 区切り = 左の上限 fence
    *self = right;
    Ok(())
}
```

* 親に入れる区切りキーは「**左ノードの上限 fence**」。§2.4 の約束 (子 `c_i` の範囲は `(k_{i-1}, k_i]`) と合う。
  親の中では、新しい区切りキーが元の区切りキーの手前に入り、その子が `left_id` になる。元のポインタ (self = 右) は元のキーの位置にそのまま残る。
* 右を「元のページ」に残すので、親のポインタを書き換えずに済む。
* 内部ノードの split では、区切りキーは新しく作らない。真ん中のキーがそのまま親に移動する。

### 4.12 merge (ノード単体)

`self` (左) を右隣 `right` に吸収させる。親の `slot[i]` (左を指すスロット) を消す。

```rust
fn merge_into_right(&self, i: usize, parent: &mut Node, right: &mut Node) -> bool {
    let mut tmp = Node::new_empty(self.tag);
    tmp.set_fences(self.lower_fence(), right.upper_fence());
    let np = tmp.prefix_len as usize;
    // prefix が短くなる分、各キーが長くなる
    let grow_l = (self.prefix_len as usize - np) * self.count as usize;
    let grow_r = (right.prefix_len as usize - np) * right.count as usize;
    let mut need = self.space_used as usize + right.space_used as usize + grow_l + grow_r
        + size_of::<NodeHeader>() + (self.count + right.count) as usize * size_of::<Slot>();
    if self.is_inner() {
        // 親の区切りキー k_i が、左の upper を指す新しいスロットとして降りてくる
        need += tmp.space_needed(parent.full_key_len(i), size_of::<PageId>());
    }
    if need > PAGE_SIZE { return false; }

    self.copy_range_to(&mut tmp, 0, 0, self.count as usize);
    if self.is_inner() {
        let k = parent.full_key(i);                         // prefix を戻した区切りキー
        tmp.store_kv(tmp.count as usize, &k, &self.upper.to_ne_bytes());
        tmp.count += 1;
    }
    right.copy_range_to(&mut tmp, tmp.count as usize, 0, right.count as usize);
    tmp.upper = right.upper;
    tmp.make_hints();
    parent.remove_slot(i);                                  // 左を指していたスロットを消す
    *right = tmp;
    true                                                    // 呼び出し側が self のページを解放する
}
```

* 見積もり `need` には、合計した fence の長さ分の余裕が入っていない。参照実装も同じ見積もりで、「左右の space_used に含まれる fence 4本」が、新しい fence 2本より多いので足りる、という理屈。
* `parent.remove_slot(i)` の後、親の `c_{i+1}` = right が `(k_{i-1}, k_{i+1}]` を担当する。これは tmp の fence と一致する。

## 5. 木全体の操作

```rust
struct BTree { root: PageId, alloc: PageAlloc }
```

この節で使う補助関数 (定義は省略):

| 関数 | 中身 |
|---|---|
| `descend(key)` | 根から `lower_bound` で葉まで降り、(葉, 直前の親) を返す。根が葉なら親は `None` |
| `descend_with_pos(key)` | `descend` と同じだが、親の中で降りた位置 `i` も返す |
| `descend_to_leaf(key)` | 葉だけ返す |
| `split_one(node, parent)` | §4.11 の `split`。親に入らなければ `Err(NoSpace)` |
| `node(id)` / `node_mut(id)` | ページ ID からノードへの参照 (メモリ上なら配列の添字、vmcache なら 11 の `to_ptr`) |
| `init_inner_with_upper(child)` | 空の内部ノード (count = 0, fence は ±∞, `upper = child`) にする |
| `full_key(i)` / `full_key_len(i)` | prefix を付け直したキー (とその長さ) |
| `remove_slot(i)` | §4.8 の `remove` のうち、スロット i を消す部分だけ |
| `heap_push(bytes)` | heap の先頭にコピーし、`FenceSlot` を返す (`data_offset` と `space_used` を更新) |
| `set_slot(i, s)` / `shift_slots_right(i)` / `shift_slots_left(i)` | スロット配列の書き込み・memmove |
| `store_kv_truncated(i, k, v)` | `store_kv` の、prefix を除いたキーを受け取る版 |

* 最初は根が空の葉 (fence は両方 ±∞)。
* 根が split するときは、新しい内部ノードを作る。中身は `count = 0`, `upper = 旧根` で、これを根にしてから split する。

### 5.1 lookup

```rust
fn lookup(&self, key: &[u8]) -> Option<&[u8]> {
    let mut node = self.node(self.root);
    while node.is_inner() {
        let (i, _) = node.lower_bound(key);
        node = self.node(node.child(i));                    // i == count なら upper
    }
    match node.lower_bound(key) { (i, true) => Some(node.value(i)), _ => None }
}
```

* 内部ノードで `found == true` (区切りキーと完全一致) のときも、同じ `i` に進めばよい。上限 fence は「含む」なので、その子に入っている。

### 5.2 insert

```rust
fn insert(&mut self, key: &[u8], val: &[u8]) {
    assert!(key.len() + val.len() <= MAX_KV_SIZE);           // §8
    loop {
        // 葉まで降りる。親を覚えておく
        let (leaf_id, parent_id) = self.descend(key);
        if self.node_mut(leaf_id).insert(key, val) { return; }
        // 容量不足: split してやり直す
        self.split_node(leaf_id, parent_id, key);
    }
}

fn split_node(&mut self, node_id: PageId, parent_id: Option<PageId>, key: &[u8]) {
    let parent_id = parent_id.unwrap_or_else(|| {
        let r = self.alloc.alloc_page();
        self.node_mut(r).init_inner_with_upper(node_id);     // count=0, upper=旧根, fence は ±∞
        self.root = r;
        r
    });
    if self.split_one(node_id, parent_id).is_err() {
        // 親に区切りキーが入らない → 親を先に split する (§5.3)。
        // その後、呼び出し元の loop が根から降り直す
        self.ensure_space(parent_id, key);
    }
}
```

* split したら**根から降り直す**。split 後に key がどちらの葉に行くかを、自分で判定しなくて済む。
* 1回の insert で split が何段も起きる場合も、「親に入らなければ親を split → やり直し」の繰り返しで処理できる。

### 5.3 親の split (ensure_space)

```rust
/// to_split を split する。そのために to_split の親を根から探す
fn ensure_space(&mut self, to_split: PageId, key: &[u8]) {
    let mut node = self.root;
    let mut parent = None;
    while self.node(node).is_inner() && node != to_split {
        parent = Some(node);
        let (i, _) = self.node(node).lower_bound(key);
        node = self.node(node).child(i);
    }
    self.split_node(to_split, parent, key);                  // 再帰的に上へ伝わる
}
```

* 参照実装は親ポインタを持たないので、根から同じキーで降りて親を見つける。
  親ポインタを持たない設計は、ページの追い出し (swizzling) や並行制御と相性が良い。

### 5.4 remove と merge

```rust
fn remove(&mut self, key: &[u8]) -> bool {
    let (leaf_id, parent_and_pos) = self.descend_with_pos(key);  // 親と、親の中での位置 i
    if !self.node_mut(leaf_id).remove(key) { return false; }
    if let Some((parent_id, i)) = parent_and_pos {
        let leaf = self.node(leaf_id);
        let parent = self.node(parent_id);
        // 右隣があり、両方とも空きが UNDERFULL 以上なら merge を試す
        if leaf.free_space_after_compaction() >= UNDERFULL
            && i + 1 <= parent.count as usize                      // child(i+1) が存在する (upper を含む)
        {
            let right_id = parent.child(i + 1);
            if self.node(right_id).free_space_after_compaction() >= UNDERFULL
                && self.merge_into_right(leaf_id, i, parent_id, right_id)
            {
                self.alloc.free_page(leaf_id);
            }
        }
    }
    true
}

const UNDERFULL: usize = PAGE_SIZE / 4;
```

* 論文の本文は「隣接する2ノードの空きが 3/4 以上なら merge」と書いているが、参照実装は空き **1/4 以上** で merge を試みる (実際に入るかは `merge_into_right` の見積もりで判定)。ここでは実装に合わせた。
* 参照実装は葉の merge しかしていない (内部ノードが空いても放置)。merge で親が空いたときに親も merge するなら、`ensure_space` と同様に根から親をたどって同じ処理を繰り返す。
* 参照実装は右隣が `child(pos+1)` で `pos + 1 < parentCount` のときだけ merge する。そのため `upper` (最も右の子) とは merge しない。上の擬似コードは upper とも merge できる形で書いた。
  upper と merge したら、親の `upper` が merge 後のページを指すことになるので、`remove_slot(i)` だけで整合する。

### 5.5 範囲検索 (scan)

参照実装は**葉同士のリンクを持たない**。1つの葉を読み終えたら、その葉の上限 fence より大きい最小のキーで**根から降り直す**。

```rust
fn scan(&self, start: &[u8], cb: ScanCallback) {
    let mut k: Vec<u8> = start.to_vec();
    let mut first = true;
    loop {
        let leaf = self.descend_to_leaf(&k);
        let from = if first { leaf.lower_bound(&k).0 } else { 0 };
        let mut full = leaf.prefix().to_vec();
        for i in from..leaf.count as usize {
            full.truncate(leaf.prefix_len as usize);
            full.extend_from_slice(leaf.key(i));             // キーを復元して渡す
            if !cb(&full, leaf.value(i)) { return; }
        }
        let uf = leaf.upper_fence();
        if uf.is_empty() { return; }                          // 右端の葉 (上限 = +∞)
        // 上限 fence の直後のキー = 上限 fence + 0x00
        k.clear();
        k.extend_from_slice(uf);
        k.push(0);
        first = false;
    }
}
```

* `F + 0x00` は「F より大きい最小のバイト列」。上限 fence は「含む」ので、次の葉の最初のキーは必ず `F + 0x00` 以上になる。
* 葉のリンクを持たないと、並行制御 (リンクの更新) やページの追い出しが単純になる。その代わり、葉をまたぐたびに根から降りるコストがかかる。
* 論文の scan は「平均して高々2枚の葉にまたがる」長さ (1〜50件) なので、このコストは小さい。

## 6. 固定長キー版 (TLX 型)

TLX (旧 STX) のような、テンプレートで固定長のキーと値を扱う B+-Tree。論文の比較対象 (background.md 3.7)。

```rust
struct LeafNode<K: Ord + Copy, V: Copy, const N: usize> {
    count: u16,
    keys: [K; N],          // ソート済み
    vals: [V; N],
    prev: Option<NonNull<LeafNode<K, V, N>>>,   // 葉の双方向リンク
    next: Option<NonNull<LeafNode<K, V, N>>>,
}
struct InnerNode<K: Ord + Copy, const M: usize> {
    level: u16,
    count: u16,
    keys: [K; M],
    children: [NodePtr; M + 1],                  // 擬似コードなので const 式は省略
}
// N, M はノードを約 256 バイトにする値: N = max(8, 256 / (size_of::<K>() + size_of::<V>()))
```

* 探索は `keys[..count]` の二分探索。比較は `K` の `Ord` で、ページ内のオフセット計算もない。
* 挿入は配列をずらして入れるだけ。split は真ん中で半分ずつコピーする。scan は `next` リンクで隣の葉へ進む。
* **可変長キーを扱うには `K = Vec<u8>` (24バイトのハンドル) にするしかない**。比較のたびにヒープ上の別の場所を読むので、キャッシュミスが増える。
  論文で TLX が文字列に弱かった理由はこれ。
* ノードを `malloc` で個別に確保するので、そのままではページングできない。

スロット付きページ版との違い:

| | スロット付きページ | 固定長キー版 |
|---|---|---|
| キー | 可変長、ページ内に格納 | 固定長 (可変長はポインタ経由) |
| ノード | 4 KiB 固定、ページング可 | 約 256 B、malloc |
| 探索 | head + hints + 本体比較 | `Ord` で二分探索 |
| 葉の移動 | 根から降り直し | `next` リンク |

## 7. 一括構築と waves of misery

### 7.1 ソート済みデータからの一括構築 (bulk load)

```rust
fn bulk_load(sorted: impl Iterator<Item = (Vec<u8>, Vec<u8>)>, fill: f64) -> BTree {
    // 1. 葉を左から順に、容量の fill 割合まで詰める
    // 2. 葉が埋まったら、次のキーとの間の最短区切りキーを作り、その葉の上限 fence にする
    // 3. 各葉の (区切りキー, ページ ID) を、一段上の内部ノード列に同じ要領で詰める
    // 4. 1ノードになるまで繰り返す (それが根)
    todo!()
}
```

* fence は「左の葉の上限 = 右の葉の下限 = 区切りキー」になるように設定する。
* 区切りキーは §4.10 と同じく `lcp(左の最後, 右の最初) + 1` バイト。

### 7.2 waves of misery を避ける

* すべての葉を同じ割合 (例えば 90%) で詰めると、その後のランダム挿入で多くの葉が同時に満杯になり、split が一斉に起きる (background.md 1.4)。
* Glombiewski らの対策: 葉ごとに**詰める割合をランダムにばらつかせる**。
  例えば、`fill` を `[0.5, 1.0]` から一様に選ぶ。こうすると満杯になる時期が散らばる。
* 論文のベンチマークは bulk load を使わず、ランダム順の挿入で木を作っている。そのため、充填率は自然に揺れる。
  これを均すため、fan-out の計測ではレコード数を `16^-R` 倍 (R は [0,1) の一様乱数) にずらして平均をとっている (論文 4.4節)。

## 8. 境界条件と落とし穴

* **1レコードの最大サイズ**: 1ページに最低3レコード入る大きさに制限する。
  参照実装の値は `MAX_KV_SIZE = (PAGE_SIZE - size_of::<NodeHeader>() - 2*size_of::<Slot>()) / 3`。
  これがないと、split しても入らない巨大レコードで無限ループする。
* **fence も heap に入る**: 長いキーが区切りキーになると、fence 2本が heap を圧迫する。最大サイズの見積もりに含める。
* **u16 の上限**: offset や長さを u16 で持つので、ページサイズは 64 KiB 未満に限る。
* **空のキー**: 長さ0のキーは正当なキー (最小のキー) だが、この設計では「長さ0の fence = ±∞」と衝突する。
  * 下限側は問題ない。下限は「含まない」ので、−∞ を長さ0で表しても空キーは範囲内に入る。
  * 問題は上限側。§4.10 で `key(lo)` が空キーだと、区切りキー (= 左の上限 fence) が長さ0になり、+∞ と区別できなくなる。scan はそこで終わってしまう。
  * 対処は2通り。(a) 空キーを禁止する (正規化キーは NULL マーカーなどで必ず1バイト以上になる)。(b) fence に「無限か」のフラグを別に持つ。
  * 参照実装はこのケースを特別扱いしていない (ベンチマークのキーに空キーがないため)。
* **head の0埋め**: `"a"` と `"a\0"` は同じ head。head の一致は「本体を比べよ」という意味でしかない。
* **prefix_len とキー長**: キーは必ず prefix より長いか等しい (範囲内なら成り立つ)。外から来たキー (scan の開始キーなど) を、範囲外のノードで `lower_bound` しないこと。
* **区切りキーの窓**: `count < 16` だと `n/16 = 0` で `hi == lo` になり、窓が1点になる。
  このとき `c = key(lo).len()` なので §4.10 の最初の分岐に入り、`key(lo)` をそのまま (切り詰めずに) 区切りキーにする。
  `count >= 2` が前提 (`n/2 - 1` や `lo` が範囲内に収まるため)。最大レコードサイズの制限 (上記) で、split するノードは必ず3件以上ある。
* **split 時の親の容量**: 親に区切りキーが入らない場合を忘れやすい。§5.2 の「親を split してから根からやり直す」で処理する。
* **compaction と借用**: compaction の後は、それ以前に取ったキーのスライスが無効になる。
* **上書き insert**: 新しい値が長いと容量不足になりうる。古いレコードを先に削除してから、新しいキーとして容量判定する (§4.7)。

## 9. テスト方針

### 9.1 オラクルとの比較

```rust
#[test]
fn random_ops_against_btreemap() {
    let mut t = BTree::new();
    let mut oracle = std::collections::BTreeMap::<Vec<u8>, Vec<u8>>::new();
    let mut rng = SmallRng::seed_from_u64(seed);
    for _ in 0..1_000_000 {
        let k = gen_key(&mut rng);      // 短い・長い・共通接頭辞が長い・空、を混ぜる
        match rng.gen_range(0..10) {
            0..=5 => { let v = gen_val(&mut rng); t.insert(&k, &v); oracle.insert(k, v); }
            6..=7 => { assert_eq!(t.remove(&k), oracle.remove(&k).is_some()); }
            8     => { assert_eq!(t.lookup(&k), oracle.get(&k).map(|v| &v[..])); }
            _     => { /* scan を n 件取り、oracle.range(k..).take(n) と比べる */ }
        }
        if step % 1000 == 0 { t.check_invariants(); }
    }
}
```

### 9.2 不変条件チェッカー

* §3 の1〜9をすべて検査する。
* 木全体を再帰的にたどり、子の fence が親の区切りキーと一致するか (不変条件8) を確認する。

### 9.3 狙い撃ちのケース

* **キーの分布**: URL のように長い共通接頭辞があるもの、整数 (4バイト)、ランダムなバイト列、長さ0〜最大長。
* **挿入順**: 昇順、降順、ランダム。昇順は右端の葉だけが split し続ける。
* **split の連鎖**: 小さいページサイズ (例: 512 B) で、木の高さが4〜5段になるまで入れる。
* **merge**: 大量に入れたあと、ほとんど削除する。空き 1/4 の境界前後を狙う。
* **head の衝突**: 先頭4バイトがすべて同じキー (`"http..."`)。hints の `p2` の処理が効くか。
* **区切りキー**: 長さがちょうど `c+1` のキーが窓に入るケース (§4.10 の `truncated: false` 側)。

## 10. 原典との違い・簡略化

* **ヘッダの並び**: 論文 Figure 2 に合わせた。参照実装は適応型のカウンタを持ち、並びも違う。
* **上書き insert**: 参照実装は `abort()`。ここでは「削除してから挿入」として書いた。
* **merge**: 参照実装は葉だけ、右隣だけ (upper を除く)。論文本文の閾値 (3/4) と実装 (1/4) が食い違うので、実装に合わせた。
* **ページの確保**: 参照実装は `AnyNode*` を直接持つ。ここでは `PageId` と `PageAlloc` で書いた。vmcache に載せるときはこの形の方が素直 ([11-buffer-management.md](11-buffer-management.md))。
* **一括構築**: 参照実装にはない。§7 は一般的な手順として書いた。

## 11. 参考資料

* 論文: Müller, Benson, Leis. B-Trees Are Back: Engineering Fast and Pageable Node Layouts. SIGMOD 2025. https://doi.org/10.1145/3709664
* 参照実装: https://github.com/m-mueller678/btree-cpp/tree/sigmod25 (コミット `774b9fd`)
  * `btree/btree2020.hpp`: `BTreeNodeHeader`, `BTreeNode::Slot`, `head()`, `maxKVSize`
  * `btree/btree2020.cpp`: `lowerBound`, `searchHint`, `makeHint`, `updateHint`, `insert`, `remove`, `compactify`, `copyKeyValueRange`, `findSeparator`, `getSep`, `splitNode`, `mergeNodes`, `BTree::insertImpl`, `BTree::splitNode`, `BTree::ensureSpace`, `BTree::removeImpl`, `BTree::range_lookupImpl`
* The Evolution of LeanStore (hints の原典): https://dl.gi.de/bitstreams/edd344ab-d765-4454-9dbe-fcfa25c8059c/download
* Bayer & Unterauer. Prefix B-Trees. TODS 1977 (prefix / suffix truncation)
* Graefe & Larson. B-Tree Indexes and CPU Caches. ICDE 2001 (poor man's normalized keys)
* STX B+ Tree: https://panthema.net/2007/stx-btree/
* Glombiewski, Seeger, Graefe. Waves of Misery After Index Creation. BTW 2019: https://dl.gi.de/handle/20.500.12116/21736
