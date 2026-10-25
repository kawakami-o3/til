# 12. 並行制御: ロックカップリング、OLC、Rust での楽観的読み取り、contention split、XMerge

[background.md 5.4, 5.5](../background.md#54-ロックカップリングと楽観的ロックカップリング-olc) と [deep-dive.md 2章](../deep-dive.md#2-olc-と-vmcache-の仕組み) の実装ノート。

## 実装サマリ

| 節 | 作るもの | 前提 |
|---|---|---|
| 1 | ロックカップリング (crabbing) の lookup / insert | ノードごとの RwLock |
| 2 | OLC のロック語と lookup / insert (restart ループ付き) | ノード内探索がゴミを読んでも止まること |
| 3 | Rust での楽観的読み取り (データ競合を起こさない書き方) と回収 | 2 の書き方を UB なしで実現する |
| 4 | contention split | 2 の insert の中に数行足す |
| 5 | XMerge | 11 章 3節の vmcache の追い出し経路から呼ぶ |

* ノード単体の操作 (`lower_bound`, `insert`, `split`, `find_separator`, `merge_into_right`, `free_space_after_compaction`) は [01-slotted-btree.md](01-slotted-btree.md) のものを名前で使う。
* ページの状態語 (vmcache の 8+56 ビット) は [11-buffer-management.md](11-buffer-management.md) 3節。この章の OLC は、その状態語でもそのまま成り立つ。
* **3節が一番大事**。C++ の OLC を素直に Rust へ移すと未定義動作になる。

## 目次

1. [ロックカップリング](#1-ロックカップリング-crabbing)
2. [OLC (Optimistic Lock Coupling)](#2-olc-optimistic-lock-coupling)
3. [Rust での OLC の実現](#3-rust-での-olc-の実現)
4. [Contention split](#4-contention-split)
5. [XMerge](#5-xmerge)
6. [テスト方針 (全体)](#6-テスト方針-全体)
7. [原典との違い・簡略化 (まとめ)](#7-原典との違い簡略化-まとめ)
8. [参考資料](#8-参考資料)

---

## 1. ロックカップリング (crabbing)

### 1.1 目的と論文との関係

* B-Tree を複数スレッドで安全にたどる、最も古典的な方法。
* 「子のロックを取ってから親のロックを外す」。保持するロックは高々2つ (insert では祖先を保持することがある)。
* 論文では使っていない。OLC がなぜ必要かを理解するための比較対象。

### 1.2 lookup

```rust
fn lookup(&self, key: &[u8]) -> Option<Vec<u8>> {
    let mut g = self.root_node().latch.read();         // 根を S ロック
    let mut node = self.root_node();
    while node.is_inner() {
        let child = node.child(node.lower_bound(key).0);
        let cg = child.latch.read();                    // 子を先に取る
        drop(g);                                        // それから親を外す
        g = cg; node = child;
    }
    let (i, found) = node.lower_bound(key);
    found.then(|| node.value(i).to_vec())
}
```

* 根の取り直し: 根の split で根が入れ替わる。根の ID を読む → 根を S ロック → 根の ID が変わっていないか確認、とする。

### 1.3 insert と「安全なノード」の規則

* **安全なノード (safe node)**: この insert で split しないことが確実なノード。
  * 葉: 新しいキー + 値が入る空きがある。
  * 内部: 子が split しても、区切りキー1つ + 子 ID が入る空きがある (可変長キーなら「最大長の区切りキーが入る」で判定)。
* 下りながら X ロックを取り、**安全なノードに着いたら、それより上のロックを全部外す**。

```rust
fn insert(&self, key: &[u8], val: &[u8]) {
    let mut held: Vec<WriteGuard> = vec![self.root_node().latch.write()];
    let mut node = self.root_node();
    loop {
        let safe = if node.is_inner() { node.has_space_for(MAX_SEP_LEN, size_of::<PageId>()) }
                   else { node.has_space_for(key.len(), val.len()) };
        if safe { let last = held.pop().unwrap(); held.clear(); held.push(last); } // 祖先を解放
        if !node.is_inner() { break; }
        let child = node.child(node.lower_bound(key).0);
        held.push(child.latch.write());
        node = child;
    }
    // held に残っているのは「split が波及しうる範囲」だけ。下から順に split して挿入する。
    split_upwards_and_insert(&mut held, key, val);
}

// 01 の関数で書くと:
// has_space_for(k, v) = space_needed(k, v) <= free_space_after_compaction()
```

* 楽観版 (Bayer & Schkolnick): 内部ノードは S で下り、葉だけ X。葉が安全でなければ全部外して、上の悲観版でやり直す。split はまれなので、ほとんどは楽観版で終わる。

### 1.4 根のロックがボトルネックになる理由

* S ロックの取得は、ロック語 (読み手の数) への**書き込み**。
* 全操作が根の S ロックを取るので、根のロック語のキャッシュラインが全コアの間を行き来する。
* 読むだけの lookup でも、コア数を増やすとこのキャッシュライン転送で律速する。OLC 論文の表4では、10 スレッドで lookup がロックカップリング 5.71 M op/s、OLC 14.60 M op/s。

### 1.5 境界条件

* ロックの順序は常に親 → 子。兄弟ポインタを使うスキャンは左 → 右に固定する。逆向きに取るとデッドロック。
* `held` の解放順序は関係ない (取るときの順序だけが重要)。

---

## 2. OLC (Optimistic Lock Coupling)

### 2.1 目的と論文との関係

* 読み手はロックを取らない。バージョンを読み、ノードを読み、バージョンが変わっていないか確かめる。
* 論文 7章: vmcache の同期は OLC。論文のノード内最適化は OLC と直交する (deep-dive 2章)。ただしノード内探索が「ゴミを読んでも止まる」必要がある。

### 2.2 ロック語の配置

OLC 論文自体はビット配置を決めていない (「ロックとバージョンを 64 ビット1語にまとめる」とだけ書く)。ここでは次の配置を使う。

```
 63                                              2    1        0
 ┌─────────────────────────────────────────────────┬────────┬──────────┐
 │ version (62 ビット)                              │ locked │ obsolete │
 └─────────────────────────────────────────────────┴────────┴──────────┘
 初期値: 0b100
 write lock:            +0b10   (locked を立てる。version は変わらない)
 write unlock:          +0b10   (locked が繰り上がって version が +1)
 write unlock obsolete: +0b11   (version +1 し、obsolete を立てる)
```

* この配置は、著者らの公開実装 (BTreeOLC) で筆者が記憶している形 (【未検証】原典のコードとは照合していない)。
* 「ロック中なら version が変わらない、外すと +1」という性質は vmcache の状態語と同じ。vmcache の語を使うなら次の対応になる。

| 本節の操作 | vmcache (11 章 3節) |
|---|---|
| locked ビットが立っている | state == LOCKED (253) |
| obsolete | state == EVICTED を見たら読み込む (ノードの削除は別途空きリスト) |
| write lock | `try_lock_x` |
| write unlock | `unlock_x` (version +1) |
| 共有ロック中 | 楽観的な読みは成功してよい (version が同じなら無視) |

### 2.3 ロック操作

```rust
struct OptLock(AtomicU64);
const LOCKED_BIT: u64 = 0b10;
const OBSOLETE_BIT: u64 = 0b01;
struct Restart;                                     // やり直しの印 (C++ の例外の代わり)

impl OptLock {
    fn is_locked(v: u64) -> bool { v & LOCKED_BIT != 0 }
    fn is_obsolete(v: u64) -> bool { v & OBSOLETE_BIT != 0 }

    /// 楽観的な読み取りの開始。
    fn read_lock_or_restart(&self) -> Result<u64, Restart> {
        let v = self.0.load(Acquire);
        if Self::is_locked(v) || Self::is_obsolete(v) { spin_loop(); return Err(Restart); }
        Ok(v)
    }
    /// 読み取りの検証。データの読み取りの後に呼ぶ。
    fn read_unlock_or_restart(&self, v: u64) -> Result<(), Restart> {
        fence(Acquire);                              // ★ データの読み取りをこの前に閉じ込める (3.3)
        if self.0.load(Relaxed) == v { Ok(()) } else { Err(Restart) }
    }
    /// 中身は read_unlock_or_restart と同じ。「子ポインタを使う前の確認」であることを名前で示す。
    fn check_or_restart(&self, v: u64) -> Result<(), Restart> { self.read_unlock_or_restart(v) }

    /// 読んだ版のまま X ロックへ昇格。間に誰かが書いていたら失敗。
    fn upgrade_to_write_lock_or_restart(&self, v: &mut u64) -> Result<(), Restart> {
        match self.0.compare_exchange(*v, *v + LOCKED_BIT, Acquire, Relaxed) {
            Ok(_) => { *v += LOCKED_BIT; fence(Release); Ok(()) }   // ★ 以後の書き込みより前に lock を見せる (3.3)
            Err(_) => { spin_loop(); Err(Restart) }
        }
    }
    fn write_lock_or_restart(&self) -> Result<(), Restart> {
        let mut v = self.read_lock_or_restart()?;
        self.upgrade_to_write_lock_or_restart(&mut v)
    }
    fn write_unlock(&self) { self.0.fetch_add(LOCKED_BIT, Release); }
    fn write_unlock_obsolete(&self) { self.0.fetch_add(LOCKED_BIT | OBSOLETE_BIT, Release); }
}
```

### 2.4 不変条件

* X ロック中にだけノードを書き換える。書き換えたら必ず unlock で version を進める。
* 楽観的に読んだ値 (子 ID、長さ、オフセット) は、**検証が通るまで信用しない**。特に子 ID をデリファレンスする前に親を検証する。
* obsolete になったノードには、新しく到達する経路がない (親から外した後に obsolete にする)。
* X ロックは常に親 → 子の順に取る (昇格も同じ)。子を持ったまま親を待たない。

### 2.5 lookup

```rust
fn lookup(&self, key: &[u8], out: &mut Vec<u8>) -> bool {
    let mut restarts = 0;
    loop {
        match self.try_lookup(key, out) {
            Ok(found) => return found,
            Err(Restart) => { restarts += 1; if restarts > MAX_RESTARTS { return self.lookup_pessimistic(key, out); } }
        }
    }
}

fn try_lookup(&self, key: &[u8], out: &mut Vec<u8>) -> Result<bool, Restart> {
    let mut node = self.root.load(Acquire);                    // 根の ID / ポインタ
    let mut v = lock_of(node).read_lock_or_restart()?;
    if node != self.root.load(Acquire) { return Err(Restart); } // 読んでいる間に根が替わった

    let mut parent: Option<(NodeRef, u64)> = None;
    while is_inner(node, v)? {                                 // ノード種別も楽観的に読む値
        if let Some((p, pv)) = parent { lock_of(p).read_unlock_or_restart(pv)?; } // (A)
        parent = Some((node, v));

        let child = find_child_optimistic(node, key);          // ゴミかもしれない
        lock_of(node).check_or_restart(v)?;                    // (B) child を使う前に検証
        v = lock_of(child).read_lock_or_restart()?;            // (C)
        node = child;
    }
    let found = find_value_optimistic(node, key, out);         // 値をローカルにコピー
    if let Some((p, pv)) = parent { lock_of(p).read_unlock_or_restart(pv)?; }
    lock_of(node).read_unlock_or_restart(v)?;                  // 葉の検証。通るまで out を使わない
    Ok(found)
}
```

* (B) を省くと、ゴミの子 ID で (C) の読み取りをしてしまう。
* (A) は「(C) で子の版を読んだ時点でも、子がまだ親の子だった」ことの確認。(B) と (C) の間に子が split され、探しているキーが右の兄弟に移ったかもしれない。次の周回の (A) で親の版が変わっていれば検出できる。
* 葉で見つけた値は、検証が通るまで呼び出し側に返さない。

### 2.6 ノード内探索はゴミを読んでも止まること

* 書き換え途中のノードを読むので、`count`、スロットのオフセット、キー長、prefix 長、hints がすべてデタラメでありうる。
* 求められるのは「正しい答え」ではなく、**有限時間で止まり、範囲外を読まないこと**。答えは検証で捨てられる。
* 守ること:
  * `count` を上限 (`MAX_SLOTS = (PAGE_SIZE - HEADER) / SLOT_SIZE`) で切る。
  * スロットのオフセットと長さを `offset + len <= PAGE_SIZE` に切る (`min` で丸める)。
  * prefix 長を `min(prefix_len, lower_fence_len, key.len())` に切る。
  * 二分探索は `[lo, hi)` が毎回必ず縮む形で書く (`mid = lo + (hi - lo) / 2`、比較結果で `lo = mid + 1` か `hi = mid`)。
  * hints で絞った範囲 `[lo, hi)` を `0 <= lo <= hi <= count` に切る。
  * 内部ノードの子 ID は、使う前に `pid < virt_count` (vmcache) / フレーム数未満 (swizzling) を確認する。
* 上の丸めは、ゴミでない入力では何もしない。正しいノードの結果を変えない。

### 2.7 insert (下りながら満杯の内部ノードを先に split する版)

OLC 論文には insert のコードがない。以下は、著者らの公開実装 (BTreeOLC) の方式を筆者が再構成したもの (【未検証】原典との照合はしていない)。

```rust
fn try_insert(&self, key: &[u8], val: &[u8]) -> Result<(), Restart> {
    let mut node = self.root.load(Acquire);
    let mut v = lock_of(node).read_lock_or_restart()?;
    if node != self.root.load(Acquire) { return Err(Restart); }
    let mut parent: Option<(NodeRef, u64)> = None;

    while is_inner(node, v)? {
        if inner_is_full(node) {                         // 先に split しておく (eager split)
            lock_and_split(parent, node, v)?;            // 親と自分を X にして split → 解放
            return Err(Restart);                         // 根からやり直す
        }
        if let Some((p, pv)) = parent { lock_of(p).read_unlock_or_restart(pv)?; }
        parent = Some((node, v));
        let child = find_child_optimistic(node, key);
        lock_of(node).check_or_restart(v)?;
        v = lock_of(child).read_lock_or_restart()?;
        node = child;
    }

    if !leaf_has_space(node, key, val) {
        lock_and_split(parent, node, v)?;
        return Err(Restart);
    }
    let mut v_leaf = v;
    lock_of(node).upgrade_to_write_lock_or_restart(&mut v_leaf)?;    // 葉だけ X
    if let Some((p, pv)) = parent {
        if lock_of(p).read_unlock_or_restart(pv).is_err() {          // 親が変わった = 葉の範囲が変わったかも
            lock_of(node).write_unlock();
            return Err(Restart);
        }
    }
    node_insert(node, key, val);                                     // 01 の Node::insert
    lock_of(node).write_unlock();
    Ok(())
}

/// parent と node を X にして node を split する。どちらかの昇格に失敗したらやり直し。
fn lock_and_split(&self, parent: Option<(NodeRef, u64)>, node: NodeRef, mut v: u64) -> Result<(), Restart> {
    let mut pv_opt = None;
    if let Some((p, mut pv)) = parent {
        lock_of(p).upgrade_to_write_lock_or_restart(&mut pv)?;       // 親 → 子の順
        pv_opt = Some((p, pv));
    }
    if let Err(r) = lock_of(node).upgrade_to_write_lock_or_restart(&mut v) {
        if let Some((p, _)) = pv_opt { lock_of(p).write_unlock(); }
        return Err(r);
    }
    if pv_opt.is_none() && node != self.root.load(Acquire) {         // 親なしなのに根でない = 根が増えた
        lock_of(node).write_unlock();
        return Err(Restart);
    }
    let (sep, new_right) = node_split(node);                         // 01 の find_separator + split
    match pv_opt {
        Some((p, _)) => node_insert_child(p, &sep, new_right),      // 親には必ず空きがある (eager split のおかげ)
        None => self.make_new_root(&sep, node, new_right),           // root.store(new, Release)
    }
    lock_of(node).write_unlock();
    if let Some((p, _)) = pv_opt { lock_of(p).write_unlock(); }
    Ok(())
}
```

* eager split の利点: 親は「下りるときに満杯でなかった」ので、子の split の区切りキーが必ず入る。split が上に波及しない。
* `inner_is_full` は可変長キーでは「最大長の区切りキー + 子 ID が入らない」で判定する。
* vmcache の B-Tree (論文の実装の土台) は別の方式を取る (`vmcache.cpp:BTree::insert / trySplit / ensureSpace`)。
  * 葉が満杯なら、親と葉を X にして葉を split し、根からやり直す。
  * 親に区切りキーが入らなければ、ロックを全部外し、`ensure_space(parent)` で親を split する (根から親まで下り直し、親とその親を X にして split)。その後、根からやり直す。
  * 下りる途中で split しないので、内部ノードを無駄に split しない。可変長キーではこちらが自然。

### 2.8 restart の上限とフォールバック

* `MAX_RESTARTS` (例: 64) を超えたら悲観的な経路に切り替える (OLC 論文 3.4 節の提案)。
* 悲観的な経路 = 1章のロックカップリングを、同じ `OptLock` の X ロックで行う。X ロックを親 → 子の順で取るので、楽観的な書き手とデッドロックしない。
* 悲観的な lookup は「X でたどる」と書き手を止めすぎる。範囲スキャン用に共有ロック (「shared pessimistic」モード) を持つロック語にする手もある (vmcache の状態語は 1〜252 で持つ)。
* restart の間に `spin_loop()` / 指数バックオフを入れる。入れないと、書き手のキャッシュラインを読み手が叩き続ける。
* vmcache 自身は上限なしで再試行する (`_mm_pause` のみ)。

### 2.9 境界条件と落とし穴

* **ABA**: 書き手が lock → 変更 → unlock を2回すると version は +2。読み手が 62 ビットの一周を見逃すことはない。
* **restart storm**: 根の split の直後など、全スレッドが一斉にやり直す。バックオフで散らす。
* **検証前の値で分岐して副作用**: 楽観的に読んだ値で `Vec` を確保する、ログを書く、などをしない。サイズがゴミだと巨大な確保になる。
* **葉の値のコピー**: 値の長さもゴミかもしれない。コピーする長さを `PAGE_SIZE` 以下に切る。
* **obsolete ノード**: merge でノードを外したら `write_unlock_obsolete`。読み手は `read_lock_or_restart` で obsolete を見てやり直す。メモリを解放するのは回収機構 (3.6) に任せる。

---

## 3. Rust での OLC の実現

### 3.1 なぜ素直に書くと UB なのか

* Rust (と C++) のメモリモデルでは、**少なくとも一方が非アトミックな書き込み**である同時アクセスはデータ競合 = 未定義動作。
* OLC の読み手は、書き手が X ロック中に書いているノードを読む。読み手が `&Node` で読み、書き手が `&mut Node` で書けば、まさにデータ競合。
* 「後で検証して捨てるから大丈夫」は通らない。UB は読んだ瞬間に起きる (コンパイラは、競合がないと仮定して読み取りの重複除去や再読み込みをしてよい)。
* `ptr::read_volatile` もアトミックではない。volatile と書き込みの競合も、形式的にはデータ競合 (UB)。

### 3.2 設計判断: ページは「アトミックの配列」として扱う

**楽観的な読み手が触りうるバイトは、読み書きの両方をアトミック操作で行う。** アトミックと非アトミックが混ざってもデータ競合になるため、書き手側も例外にできない。

```rust
#[repr(C, align(4096))]
struct Page { w: [AtomicU64; PAGE_SIZE / 8] }      // 512 語

impl Page {
    // 読み取り (楽観的な読み手用)。すべて Relaxed。順序は 3.3 の fence でつける。
    fn ld_u64(&self, word: usize) -> u64 { self.w[word.min(511)].load(Relaxed) }
    fn ld_u8(&self, off: usize) -> u8 {
        let off = off.min(PAGE_SIZE - 1);
        (self.ld_u64(off / 8) >> ((off % 8) * 8)) as u8     // リトルエンディアン前提
    }
    fn ld_u16(&self, off: usize) -> u16 { self.ld_u8(off) as u16 | (self.ld_u8(off + 1) as u16) << 8 }
    /// 任意範囲をローカルバッファへコピー (「アトミックな memcpy」)。範囲は丸める。
    fn copy_out(&self, off: usize, dst: &mut [u8]) {
        let end = (off + dst.len()).min(PAGE_SIZE);
        for (i, o) in (off..end).enumerate() { dst[i] = self.ld_u8(o); }   // 実装では語単位にまとめる
    }

    // 書き込み (X ロック保持者のみ)。他の書き手はいないので load → 合成 → store でよい。
    fn st_u8(&self, off: usize, b: u8) {
        let w = &self.w[off / 8];
        let sh = (off % 8) * 8;
        w.store((w.load(Relaxed) & !(0xff << sh)) | (b as u64) << sh, Relaxed);
    }
}
```

* 粒度は `AtomicU64` に統一する。同じメモリを `AtomicU8` と `AtomicU64` の両方で触る「サイズ混在アトミック」は、Rust では競合時に許されていない。
* x86-64 では Relaxed のアトミック読み書きは普通の `mov`。コストは「ベクトル化されない」「バイト取り出しのシフトが増える」程度。

**01 のノード操作をそのまま使う方法 (推奨する出発点)**:

```
 読み手 (スナップショット方式)
   v = lock.read_lock_or_restart()
   page.copy_out(0, &mut local[..PAGE_SIZE])   ← 512 回の Relaxed load
   lock.read_unlock_or_restart(v)              ← fence(Acquire) + 版の比較
   以後 local を普通の &[u8] として 01 の lower_bound 等で探索 (検証済みなので一貫している)

 書き手 (書き戻し方式)
   lock.write_lock()
   page.copy_out(0, &mut local)                ← X 中なので一貫している
   01 の Node::insert / split を local (&mut [u8]) に対して実行
   変更した語だけ page.w[i].store(local_w[i], Relaxed)
   lock.write_unlock()                          ← Release で公開
```

* 利点: ゴミ耐性 (2.6) を考えなくてよい。探索は検証済みのコピーで動く。01 のコードをそのまま使える。
* 欠点: 1 ノードごとに 4 KiB のコピー。L1 に乗るので 1 回数十〜百 ns 程度と見込むが、ノード内探索 (数十 ns) より重い (【未検証】測っていない)。
* 速くするには、必要な部分だけ読む**直接方式**に移る: ヘッダ → hints → スロットの head → 必要なキーだけ、を `ld_*` で読みながら探索する。この場合は 2.6 の丸めがすべて必要。
* どちらも【設計判断】(筆者の案)。原典 (C++) は普通のポインタで直接読む。

### 3.3 メモリ順序 (seqlock パターン)

```
 読み手                                書き手
 v1 = ver.load(Acquire)                CAS ver: v → v|LOCKED  (Acquire)
 データ load (Relaxed) ...             fence(Release)
 fence(Acquire)                        データ store (Relaxed) ...
 v2 = ver.load(Relaxed)                ver.fetch_add(LOCKED_BIT, Release)   // unlock, version+1
 v1 == v2 なら成功
```

* 読み手の `fence(Acquire)`: データの load がこれより後ろ (v2 の読みの後) にずれないようにする。
* 書き手の CAS 直後の `fence(Release)`: データの store がロック取得より前に見えないようにする。
  * 読み手のデータ load が書き手の store を1つでも見たなら、fence 同士の同期により、v2 の読みは「ロック中」以降の値を見る。だから v1 != v2 になり、失敗する。
  * CAS を Acquire にするだけでは、後続の Relaxed store が他スレッドから先に見えることを禁じられない。fence が要る。
* unlock の Release: 書いた内容が、次にこの版を Acquire で読んだ読み手に見えるようにする。
* x86-64 では `fence(Acquire)` / `fence(Release)` は命令を出さない (コンパイラの並べ替え禁止だけ)。ARM では `dmb` が出る。
* この順序付けは Boehm の seqlock 論文の推奨と同じ形 (`Can Seqlocks Get Along with Programming Language Memory Models?`, MSPC 2012)。

### 3.4 volatile を使う近道とその扱い

* 実用の Rust の seqlock 実装には、データを `ptr::read_volatile` で読み、競合を「容認」するものがある (`seqlock` クレートがそうだと理解しているが、【未検証】)。
* 生成コードは 3.2 とほぼ同じで、動くことが多い。ただし形式的には UB。Miri はこれをデータ競合として報告する。
* 本ノートの推奨は 3.2 (全部アトミック)。近道を使うなら、Miri のテストから外れることを承知のうえで、その箇所に `// UB: 容認した競合` と書いておく。
* `atomic` クレートの `Atomic<T>` は、任意の `Copy` 型をアトミックに扱う (大きい型はロックで代用)。ページ全体には向かないが、ヘッダの小さい構造体を1語で読むのには使える (【未検証】内部実装は確認していない)。
* バイト単位のアトミック memcpy を提供するクレートとして `atomic-memcpy` (taiki-e) がある。言語として「バイトごとにアトミックな memcpy」を入れる提案 (RFC 3301 `AtomicPerByte`) もある (【未検証】採用状況は確認していない)。

### 3.5 比較 (memcmp) と検索の注意

* ページ上のキーを `&[u8]` として `memcmp` / `<[u8]>::cmp` / `memchr` に渡すと、それは非アトミックな読み取り。競合する書き手がいれば UB。
* 直接方式で比較するときは、キーを `copy_out` でローカルにコピーしてから比較するか、`ld_u64` で 8 バイトずつ読んでビッグエンディアンに直して比較する。
* heads (先頭4バイト) や hints は u32 なので、`ld_u64` からの取り出しで済む。SIMD でまとめて読む場合は、アトミック読みを並べた結果を SIMD レジスタに詰める (アトミックのベクトル load は Rust にない)。
* 「同じ値を2回読んだら同じ」と仮定しない。長さを1回読んで変数に保存し、以後その変数を使う (2回読むと2回目は別の値かもしれない)。

### 3.6 回収 (解放したノードを読まれないために)

**ヒープにノードを確保する OLC 木 (11 章のバッファ管理なし)**: `crossbeam-epoch` を使う。

```rust
fn try_lookup(&self, key: &[u8], out: &mut Vec<u8>) -> Result<bool, Restart> {
    let guard = crossbeam_epoch::pin();              // 操作の間、エポックに入る
    let root = self.root.load(Acquire, &guard);      // crossbeam_epoch::Atomic<Node>
    // ... 2.5 と同じ。子は Shared<'g, Node> として扱う
}

fn remove_node(&self, n: Shared<'_, Node>, guard: &Guard) {
    // 親から外した後、X ロックのまま obsolete にして解放を予約する
    lock_of(n).write_unlock_obsolete();
    unsafe { guard.defer_destroy(n); }               // 全スレッドがこのエポックを抜けたら解放
}
```

* `pin()` は操作 (restart ループの1周) ごとに取り直す。長く持つと回収が止まる。
* ノードの解放は `defer_destroy`。obsolete にしてから予約する。読み手は obsolete を見てやり直す。

**バッファマネージャの上 (vmcache / 2023 年版 LeanStore)**: 回収機構は要らない。

* ページ (仮想アドレス) と状態語の配列は、プロセスの寿命中解放されない。
* ページが追い出されたり別のノードに再利用されたりしても、状態語の版が進むので、古い読み手は検証で失敗する。
* 読み手が読むのは「別の内容かゼロ」であって「解放済みメモリ」ではない。
* 条件は2つ (Evolution of LeanStore 6.1): 版の語を巻き戻さない。メモリを OS に返さない (vmcache は物理ページを返すが仮想アドレスは残すので、読んでもゼロページになるだけ)。

### 3.7 restart の表し方

* C++ 実装は例外で restart する。Rust では `Result<T, Restart>` と `?` で書く。
* 楽観ガード型を作るなら、`Drop` で検証しない (Drop は失敗を返せない)。検証は明示的な `check()?` にする。

```rust
struct OptGuard<'a> { lock: &'a OptLock, v: u64 }
impl OptGuard<'_> {
    fn check(&self) -> Result<(), Restart> { self.lock.read_unlock_or_restart(self.v) }
    fn upgrade(self) -> Result<WriteGuard<'_>, Restart> { /* upgrade_to_write_lock_or_restart */ todo!() }
}
struct WriteGuard<'a> { lock: &'a OptLock }
impl Drop for WriteGuard<'_> { fn drop(&mut self) { self.lock.write_unlock(); } }  // 書き手の解放は Drop でよい
```

* `WriteGuard` の Drop で unlock すれば、`?` で途中から抜けてもロックが漏れない。
* panic の扱い: X ロック中に panic するとノードが壊れたまま unlock される。テストでは panic = 失敗とし、本番では `panic = "abort"` にする (【設計判断】)。

### 3.8 テスト (この節固有)

* **Miri**: スレッド 2〜3、操作 100 程度の小さな多スレッドテストを `cargo miri test` で走らせる。全部アトミック (3.2) ならデータ競合は報告されない。volatile 近道を使った箇所は報告される。
* **loom**: `OptLock` + 2語のデータだけのモデルで、「読み手が成功したなら2語は同じ書き込みの組である」を全インタリーブで検査する。loom は fence をモデル化する (【未検証】`fence(Acquire)` 単独のモデル化の精度は確認していない)。
* **ゴミ耐性の fuzz** (直接方式のとき): ページをランダムバイトで埋めて探索関数を呼び、panic せず、ループ回数が `log2(MAX_SLOTS) + 定数` 以下であることを確認。

---

## 4. Contention split

### 4.1 目的と論文との関係

* ロックはページ単位。別々のホットなキーが同じ葉にあると、無関係な更新同士が同じロックを奪い合う。
* 競合を確率的に検出し、満杯でなくても葉を split して、ホットなキーを別々のページに分ける (Alhomssi & Leis, CIDR 2021)。
* 論文 7.3 節: fingerprinting 葉に実装。「サンプルした書き込みの 1/30 以上が競合したら split」。ページを大きくしても書き込み性能が落ちなくなった。

### 4.2 パラメータ (出典ごと)

| 項目 | CIDR 2021 | 論文 (7.3) | btree24 の `contentionSplit` ブランチ |
|---|---|---|---|
| サンプル確率 | 2^-2 | 記載なし | 1/16 |
| 期間の終わり | 各更新で確率 2^-9 | 記載なし | サンプル 2^15 回 |
| split 条件 | 期間中のサンプルが全部「競合」 | 1/30 以上が競合 | 競合数 ≥ 2^15 / 40 (= 1/40) かつ今回の位置 ≠ 前回の位置 |
| 「競合」の意味 | X ロックをすぐ取れなかった (slow path) | 記載なし | この葉で restart した後の再挑戦 |
| split 位置 | `mid(pos, last_pos)` | 記載なし | `(count/2 + ホットキーの位置) / 2` (ソートしてから) |

* 論文の 1/30 とコードの 1/40 は一致しない。公開ブランチが論文の評価時と別の版である可能性がある (【未検証】)。
* sigmod25 ブランチ (論文の公開版) には contention split が入っていない。`contentionSplit` ブランチにだけある。
* CIDR の Listing 1 は、整数割り算で `ratio == 1` を判定する、変数名が揺れる、など擬似コードとして不正確。以下は筆者が書き直したもの。

### 4.3 データ配置 (葉のヘッダに足す欄)

```rust
#[repr(C)]
struct ContentionCounters {   // 葉ヘッダの末尾に置く。6 バイト
    updates: u16,             // 期間中のサンプル数
    slow: u16,                // そのうち競合したもの
    last_pos: u16,            // 最後にサンプルした更新のスロット位置。u16::MAX = なし
}
```

* X ロック中にだけ書く。楽観的な読み手は読まないが、ページの一部なので 3.2 の規則どおりアトミック store で書く。
* split で新しくできた葉は 0 で初期化する。

### 4.4 擬似コード (CIDR 方式。比率の閾値を引数にする)

```rust
const SAMPLE_PROB_LOG2: u32 = 2;          // 2^-2
const PERIOD_PROB_LOG2: u32 = 9;          // 2^-9
const SPLIT_RATIO: (u16, u16) = (1, 30);  // 論文の 1/30。CIDR 原典なら (1, 1)

/// 葉を X ロックで更新した直後に呼ぶ。pos = 更新したスロット、contended = slow path だったか。
/// split すべきなら Some(split_slot) を返す。
fn after_leaf_update(c: &mut ContentionCounters, pos: u16, contended: bool, rng: &mut impl Rng) -> Option<u16> {
    let r: u32 = rng.gen();                                    // 1つの乱数でサンプルと期間を両方判定
    if r & ((1 << SAMPLE_PROB_LOG2) - 1) == 0 {
        c.updates += 1;
        c.slow += contended as u16;
    }
    let mut ret = None;
    if r & ((1 << PERIOD_PROB_LOG2) - 1) == 0 {                // 期間の終わり (2^-9 ⊂ 2^-2 なので必ずサンプルもされる)
        let enough = c.updates > 0
            && (c.slow as u32) * (SPLIT_RATIO.1 as u32) >= (c.updates as u32) * (SPLIT_RATIO.0 as u32);
        if enough && c.last_pos != u16::MAX && c.last_pos != pos {   // 別のキー同士の競合 = 不要な競合
            ret = Some(mid(pos, c.last_pos));
        }
        *c = ContentionCounters { updates: 0, slow: 0, last_pos: u16::MAX };
        return ret;
    }
    if r & ((1 << SAMPLE_PROB_LOG2) - 1) == 0 { c.last_pos = pos; }
    ret
}

fn mid(a: u16, b: u16) -> u16 { let (lo, hi) = (a.min(b), a.max(b)); lo + (hi - lo + 1) / 2 } // 2つの間 (hi 側に寄せる)
```

* 比較 (`c.last_pos != pos`) は、`last_pos` を今回の `pos` で上書きする**前**に行う。CIDR の Listing 1 は上書きしてから比較しているように読め、期間の終わりは必ずサンプルもされるので常に等しくなってしまう。本文の説明 (「他のスレッドが前に書いた位置と比べる」) に合わせて順序を直した。
* `mid` の結果を split 位置 `k` とし、`[0, k)` と `[k, count)` に分ける。`lo < k <= hi` なので2つのキーは別の葉に行く。
* 位置は「スロットの番号」。fingerprinting 葉のようにスロットが未ソートなら、先にソートしてから位置を求め直す (btree24 はスロットの offset でホットキーを探し直している)。
* `updates` が u16 であふれないこと: 期間の長さは平均 2^9 回の更新、サンプルはその 1/4。まれに長い期間で 65535 を超えうるので、飽和加算にする。

### 4.5 OLC の insert / update への組み込み

```rust
// 2.7 の try_insert の葉の部分を置き換える
// last_restart_leaf: restart ループの外に置いた、この操作だけのローカル変数 (btree24 の insertImpl と同じ)
let contended_here = last_restart_leaf == Some(node);              // 前の周回でこの葉で失敗した
let mut v_leaf = v;
let fast = lock_of(node).upgrade_to_write_lock_or_restart(&mut v_leaf);
if fast.is_err() { *last_restart_leaf = Some(node); return Err(Restart); }
// ... parent の検証、node_insert
let pos = node_insert(node, key, val);
if let Some(k) = after_leaf_update(counters_mut(node), pos, contended_here, rng) {
    if let Some((p, mut pv)) = parent {
        // ★ 親は try だけ。待たない (子を X で持ったまま親を待つと、親→子の順で待つ相手とデッドロック)
        if lock_of(p).upgrade_to_write_lock_or_restart(&mut pv).is_ok() {
            split_leaf_at(node, k, p);                                // 01 の split を位置指定で呼ぶ
            lock_of(p).write_unlock();
        }
    }
}
lock_of(node).write_unlock();
```

* 「競合した」の判定は、ロックの種類で変わる。
  * スピンロック / mutex: 最初の `try_lock` が失敗したら contended。
  * OLC: 昇格に失敗して restart し、次の周回で同じ葉に来たら contended (btree24 の方式)。
* 親が根のメタデータ (vmcache の PID 0) なら split しない。葉が根なら通常の split に任せる。
* split 後、親に区切りキーが入らなければ諦める (contention split は最適化なので、失敗してよい)。
* **落とし穴 (デッドロック)**: btree24 の実装は、葉を X で持ったまま親を `GuardX(GuardO&&)` で取る。このコンストラクタは版が同じでロック中ならスピンして待つ。別スレッドが親 → 葉の順で取ろうとしていると互いに待つ可能性がある、と筆者は読んだ (【未検証】実際に起きるかは試していない)。上の擬似コードは親を try だけにして避けている。

### 4.6 境界条件

* 2つのホットキーが隣同士 (`hi = lo + 1`): `mid = hi`。それでも分けられる。
* 同じキーへの競合 (`pos == last_pos`): split しても無意味。条件で除外。
* 1つのホットキーと多数のコールドキー: 分けても競合は減らない。CIDR の条件 (別の位置同士) である程度除外される。
* split でできた小さい葉は、後で XMerge が拾う。

### 4.7 テスト

* 葉 1 枚に収まる 100 キーを作り、8 スレッドがそれぞれ別のキーを更新し続ける。一定時間後に葉が複数に分かれていること。全キーの最終値が正解 (`Mutex<BTreeMap>`) と一致すること。
* 1 スレッドだけで更新した場合に split が起きないこと (`contended` が常に false)。
* `after_leaf_update` は乱数を注入して単体テスト (期間の終わりでカウンタがリセットされる、比率の境界)。

---

## 5. XMerge

### 5.1 目的と論文との関係

* 可変長キーの B-Tree は、空になるまでノードを merge しないことが多く、充填率が下がる (39% 以下もありうる)。contention split も小さい葉を作る。
* 隣り合う X 個の兄弟の空きを合計して1ノード分以上あれば、右へ詰めて X-1 個にし、左端を解放する (Alhomssi & Leis, CIDR 2021)。
* 論文自体は XMerge を使っていない。contention split と対になる手法として background 5.5 に出てくる。

### 5.2 アルゴリズム

```
 K = 5 (グループの最大サイズ)

 空き:   a 34%   b 34%   c 50%      a+b = 68% < 100% → c も加える → 118% ≥ 100%
         ┌────┐  ┌────┐  ┌────┐
 開始    │ a  │  │ b  │  │ c  │
         └────┘  └────┘  └────┘
 (1) b の末尾のレコードを c の先頭へ、c が満杯になるまで移す
 (2) a の全レコードを b の先頭へ移す (入りきる)
 (3) a を親から外して解放
 結果    (空)     b'       c' (満杯)
```

```rust
const K: usize = 5;

/// parent の子 start から右へグループを作り、1ノード解放できれば詰める。
/// parent と関係する子はすべて X ロック済みで呼ぶ (5.3)。
fn xmerge(parent: &mut Node, start: usize, children: &mut [&mut Node]) -> bool {
    // 1. グループの大きさを決める
    let mut free = children[0].free_space_after_compaction();
    let mut x = 1;
    while x < K && start + x < parent.count_children() && free < NODE_CAPACITY {
        free += children[x].free_space_after_compaction();
        x += 1;
    }
    if free < NODE_CAPACITY { return false; }

    // 2. 右から左へ。src の中身を dst (src より右で、まだ木に残っているノード) へ移す。
    //    ★ 移し先 dst と移し元 src を別々に持つ。全部移せた src は親から外れるので、
    //      次の移し先にしてはいけない (leanstore は fully_merged[] で同じことをしている)。
    let mut freed = [false; K];
    let mut dst = x - 1;                                   // children 内の添字
    let mut src = x - 1;
    while src > 0 {
        src -= 1;
        let (l, r) = two_mut(children, src, dst);
        if r.free_space_after_compaction() >= l.used_space() {
            // 01: l を全部 r へ移し、親から l の区切り (start + src 番) を消す
            if !l.merge_into_right(start + src, parent, r) { break; }
            freed[src] = true;                             // dst はそのまま
        } else {
            match move_tail_to_right(l, r, parent, start + src) {
                Moved::Some | Moved::None => dst = src,    // l は残る。次の移し先は l
                Moved::ParentFull => break,                // 親に区切りが入らない: ここで中断
            }
        }
    }
    // 3. 全部移せたノードを解放する。1つも解放できなければ失敗 (空きは改善しているので害はない)
    let mut any = false;
    for i in 0..x { if freed[i] { free_node(children[i]); any = true; } }
    any
}

enum Moved { Some, None, ParentFull }

/// l の末尾から入るだけ r の先頭へ移す。親の区切りキー (l と r の間) を新しい境界に付け替える。
fn move_tail_to_right(l: &mut Node, r: &mut Node, parent: &mut Node, sep_slot: usize) -> Moved {
    let n = how_many_fit(l, r);                               // r に入る最大件数 (末尾から)
    if n == 0 { return Moved::None; }                         // ★ これがないと下の k-1, k が範囲外
    let k = l.count as usize - n;                             // l に残る件数 (≥ 1。全部入るなら上の merge 側に行く)
    let new_sep = l.separator_between(k - 1, k);              // 01 の find_separator と同じ規則で短く
    if !parent.can_replace_key(sep_slot, &new_sep) { return Moved::ParentFull; }
    let mut tmp = Node::new_leaf();
    tmp.set_fences(&new_sep, r.upper_fence());                // r の新しい範囲: (new_sep, upper]
    l.copy_range_to(&mut tmp, 0, k, n);                       // 01: prefix の付け替え込みでコピー
    r.copy_range_to(&mut tmp, n, 0, r.count as usize);
    tmp.upper = r.upper;                                      // 葉なら無意味だが 01 の compactify と揃える
    tmp.make_hints();
    *r = tmp;
    // l の上限 fence が変わると prefix_len も変わりうるので、l も作り直す
    // (01 の set_fences は既存キーを詰め直さない。truncate + set_fences だけでは壊れる)
    let mut tmp_l = Node::new_leaf();
    tmp_l.set_fences(l.lower_fence(), &new_sep);
    l.copy_range_to(&mut tmp_l, 0, 0, k);
    tmp_l.make_hints();
    *l = tmp_l;
    parent.replace_key(sep_slot, &new_sep);
    Moved::Some
}
```

* 01 にない補助関数の意味:
  * `used_space()`: 移すのに要るバイト数。`space_used - fence の長さ + count * size_of::<Slot>()`。prefix が短くなる分の伸びは `merge_into_right` 側で見積もり直す。
  * `how_many_fit(l, r)`: l の末尾から何件 r に入るか。末尾から1件ずつ `r.space_needed(..)` を足していき、`r.free_space_after_compaction()` を超える手前までの件数。r の fence が変わると prefix も変わるので、厳密には新しい fence で見積もる。
  * `separator_between(a, b)`: スロット a と b の間の最短区切りキー。01 §4.10 の `lcp + 1` バイトの規則を、窓を使わずに a, b の2件に当てはめたもの。
  * `can_replace_key(i, k)` / `replace_key(i, k)`: 親の i 番目の区切りキーを k に差し替えられるか / 差し替える。01 の `remove_slot` と `insert` の組み合わせでよい (子 ID は保つ)。
* fence: 右へ移したレコードは、右のノードの fence (と prefix) に合わせて詰め直す。01 の `copy_range_to` がそれをする。
* 区切りキーの付け替えで親のキーが長くなりうる。親に入らなければその組だけ移動をやめる。leanstore の実装も「部分 merge できなかった」を返り値で区別している (`BTreeGeneric.cpp:XMerge` の `mergeLeftIntoRight` の戻り値 0/1/2)。
* 例: 空き a=10%, b=80%, c=30% (合計 120%)。b は c に全部入るので b が親から外れる。次の a の移し先は b ではなく c。移し先と移し元を分けないと、木から外れた b に a を移してデータを失う。
* 部分移動で止まると、どのノードも空にならないことがある。その場合は解放せずに終わる。

### 5.3 いつ・どこで呼ぶか (追い出し経路から)

* メモリが足りないときだけ動かす。背景スレッドで常に回すと、充填率が高いときに CPU を浪費する。
* 追い出しの直前に、ランダムな resident ページを1つ選び XMerge を試す。1ページ解放できれば、そのページを追い出しの代わりに使う。できなければ通常の追い出しへ。

```rust
// 11 章 3.8 の evict の先頭に足す
fn evict_with_xmerge(&self) {
    if let Some(pid) = self.resident.random_pid() {
        if self.try_xmerge_around(pid) { return; }      // 1ページ空いた
    }
    self.evict();
}

fn try_xmerge_around(&self, pid: PageId) -> bool {
    // 1. 葉だけ対象。充填率が高ければ何もしない (leanstore は 0.9 以上を除外)
    // 2. 親を探す: vmcache には親ポインタがない。葉の lower fence をキーに根から楽観的に下り、
    //    子 ID == pid の内部ノードとその位置 i を得る (LeanStore 2023 年版の findParent と同じ考え)
    // 3. 親を X、子 i..i+K を左から順に X (親 → 子、左 → 右の順を守る)
    //    ★ 兄弟が EVICTED なら読み込まない (I/O を増やさない)。そこでグループを打ち切る
    // 4. xmerge(parent, i, children)
    // 5. 解放したページは、版を +1 してから空き PID リストへ (vmcache 本体は PID を再利用しない)
    todo!()
}
```

* 親の最後の子 (upper 側の子) をグループに含めるかは実装次第。leanstore は親の `count - 1` 番目より右を対象にしない (`max_right + 1 < count`)。upper の子の扱いを避けるためと読める。
* 対象が根のメタデータの直下、または内部ノードなら何もしない (leanstore と同じ。内部ノードの XMerge は省略)。

### 5.4 不変条件

* XMerge の前後で、木に入っているキーと値の集合が変わらない。
* すべての葉で `lower_fence < key <= upper_fence`、親の区切りキーと子の fence が一致。
* 解放したページへの参照 (親の子 ID、兄弟ポインタ) が残っていない。兄弟ポインタを持つ葉なら、左隣の `next` も付け替える (左隣は X ロックの範囲外なので、兄弟ポインタを持たない設計のほうが楽)。

### 5.5 境界条件と落とし穴

* **ホットな葉を詰める**: 書き込みが集中する範囲を1ノードにまとめると、また contention split される。ランダムに選ぶのでまれ (CIDR 4.2)。
* **ロック順**: 親 → 子 (左から右)。昇格に失敗したら全部外して諦める。追い出し経路は「失敗してよい」ので待たない。
* **解放したページを読む楽観的な読み手**: 版 +1 で検出される。解放ページを空きリストから再利用するときも版は巻き戻さない。
* **兄弟が少ない**: 親の子が 1 つなら何もしない。
* **K が大きい**: 親と K 個の子を同時に X で持つので、並行性が落ちる。CIDR は K=5 を推奨。

### 5.6 テスト

* 順に挿入 → 9 割をランダムに削除 → 充填率が低い木を作る。XMerge を全葉で1回ずつ呼び、ノード数が減ること、全キーが `BTreeMap` と一致すること、不変条件チェッカーが通ること。
* 区切りキーが長くなるケース: キーの共通接頭辞が短い組を作り、親がほぼ満杯の状態で XMerge。親に入らないときに何も壊さず諦めること。
* 多スレッド: lookup / insert を回しながら、別スレッドが小さいプール (11 章) で追い出し + XMerge を回す。最後に照合。

---

## 6. テスト方針 (全体)

* **オラクル**: `Mutex<BTreeMap<Vec<u8>, Vec<u8>>>`。各スレッドは「自分のキー範囲」にだけ insert / update / remove し、全範囲を lookup する。書き込みの順序がスレッドごとに決まるので、最後の状態が比較可能になる。
* lookup の途中結果は、「そのキーの過去の値のどれか」または「なし」であることを確かめる (線形化可能性の弱い確認)。
* **停止状態での不変条件チェッカー**: 全スレッドを止めて、木全体を根から検査 (キー順、fence、親の区切りと子の fence の一致、全ノードが unlocked)。
* **ストレス**: スレッド数をコア数の 2 倍にし、ページを小さく (1 KiB 相当に容量を制限) して split と restart を頻発させる。
* **小さいバッファプール** (11 章): 物理ページ 64 枚で、追い出しと楽観的な読み手の競合を起こす。
* **Miri / loom**: 3.8 節。
* **restart 回数の計測**: 1 操作あたりの restart 回数と、`MAX_RESTARTS` を超えた割合を出す。フォールバックが頻発するならバックオフか contention split を疑う。

## 7. 原典との違い・簡略化 (まとめ)

* 【設計判断】 ページを `[AtomicU64; 512]` として全バイトをアトミックに読み書きする (3.2)。スナップショット / 書き戻し方式も筆者の案。原典 (C++) は普通の読み書き。
* 【設計判断】 contention split の親ロックを try だけにした (4.5)。
* 【簡略化】 2.7 の insert は BTreeOLC 方式の再構成 (【未検証】)。可変長キーでは vmcache の trySplit / ensureSpace 方式を勧める。
* 【簡略化】 delete と通常の merge は省いた (01 の 5.4 を X ロックで行えばよい)。
* 【簡略化】 XMerge は葉だけ。兄弟ポインタの付け替えは省いた。
* 【簡略化】 範囲スキャンは扱っていない。葉ごとに楽観的に読み、次の葉へは「最後に読んだキーの次」で根から引き直すのが安全 (vmcache の B-Tree は共有ロックで葉をたどる)。

## 8. 参考資料

* Leis, Haubenschild, Neumann. *Optimistic Lock Coupling: A Scalable and Efficient General-Purpose Synchronization Method*. IEEE Data Eng. Bull. 42(1), 2019. — 図2の lookup、終了性の要求、restart の上限とフォールバック、shared pessimistic モード、回収 (表4、図3)。
* Leis, Scheibner, Kemper, Neumann. *The ART of Practical Synchronization*. DaMoN 2016. — ロック語のビット配置の原典 (【未検証】本ノートでは読んでいない)。
* Alhomssi, Leis. *Contention and Space Management in B-Trees*. CIDR 2021. — contention split (Listing 1、2^-2 / 2^-9)、XMerge (Listing 2、K=5、追い出し経路への組み込み)。
* Müller, Benson, Leis. *B-Trees Are Back*. SIGMOD 2025. 7.3 節 — 1/30。
* Boehm. *Can Seqlocks Get Along with Programming Language Memory Models?* MSPC 2012. — seqlock の fence の置き方。
* Bayer, Schkolnick. *Concurrency of Operations on B-Trees*. Acta Informatica 1977. — 安全なノードとロックカップリング。
* Alhomssi, Haubenschild, Leis. *The Evolution of LeanStore*. BTW 2023. — 回収機構が不要になる条件、findParent。
* crates: `crossbeam-epoch` (回収), `atomic-memcpy`, `seqlock`, `loom`。
* 参照した実装:
  * `viktorleis/vmcache: vmcache.cpp:GuardO / GuardX / GuardS`, `BTree::insert / trySplit / ensureSpace / lookup`
  * `m-mueller678/btree24` (branch `contentionSplit`): `btree/Tag.cpp:TagAndDirty::shouldContentionSplit`, `btree/Tag.hpp:TagAndDirty` (定数), `btree/HashNode.cpp:HashNode::contentionSplit`, `btree/BTree.cpp:BTree::insertImpl`
  * `leanstore/leanstore: backend/leanstore/storage/btree/core/BTreeGeneric.cpp:BTreeGeneric::XMerge / checkSpaceUtilization`
