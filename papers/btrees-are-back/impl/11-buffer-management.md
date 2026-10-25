# 11. バッファ管理: 古典的バッファマネージャ、pointer swizzling、vmcache、非同期 I/O

[background.md 5.1〜5.3, 5.6](../background.md#5-ストレージエンジン側の仕組み) と [deep-dive.md 2章](../deep-dive.md#2-olc-と-vmcache-の仕組み) の実装ノート。

## 実装サマリ

| 節 | 作るもの | 木の側に求めること |
|---|---|---|
| 1 | フレーム配列 + ページテーブル (PID → frame) + clock 置換 | 子を PageId で持つ。使う前に `fix`、使い終わったら `unfix` |
| 2 | swip (8バイト、ポインタか PID か) + cooling + 追い出し | swip の列挙コールバック、親の探索 |
| 3 | vmcache: 仮想メモリ予約 + ページ状態語 + resident set | 子を PageId で持つだけ。ノードは固定 4 KiB |
| 4 | NVMe 向け非同期 I/O ループ | なし |

* 論文 (7章) が実際に使ったのは **3 の vmcache**。1 と 2 は比較のための背景。
* 楽観的な読み取りの Rust での書き方 (seqlock パターン、アトミック読み) は [12-concurrency.md](12-concurrency.md) の 3章にまとめる。この章では「どこで検証が必要か」だけを書く。
* ページ単位のメモリ予約 (`mmap` / `madvise`) は 00-primitives.md の領域予約ヘルパを使う想定。この章では `libc::mmap` などを直接書く。

## 目次

1. [古典的バッファマネージャ](#1-古典的バッファマネージャ)
2. [Pointer swizzling (LeanStore)](#2-pointer-swizzling-leanstore)
3. [vmcache](#3-vmcache)
4. [NVMe 向け非同期 I/O ループ](#4-nvme-向け非同期-io-ループ)
5. [参考資料](#5-参考資料)

---

## 1. 古典的バッファマネージャ

### 1.1 目的と論文との関係

* ディスク上のページを、固定個数のメモリ枠 (frame) にキャッシュする。
* 論文では「全データがメモリに載っていても毎回ハッシュ表を引く遅い方式」として引き合いに出される (1章)。
* swizzling と vmcache は、どちらもこの方式の「ハッシュ表を引く」「pin カウンタに書く」を消すための工夫。違いを理解するために、まず素朴な形を作る。

### 1.2 データ配置

```
 page_table (HashMap<PageId, FrameId>)       frames (Vec<Frame>, 個数 = プールサイズ)
 ┌──────────┬────────┐                      ┌─────────────────────────────────┐
 │ pid=17   │ fid=0  │ ───────────────────▶ │ 0: pid=17 pin=2 ref=1 dirty=0   │
 │ pid=4    │ fid=2  │ ──────┐              │ 1: (free)                       │
 └──────────┴────────┘       └────────────▶ │ 2: pid=4  pin=0 ref=0 dirty=1   │
           ↑ Mutex で保護                    └─────────────────────────────────┘
                                             clock_hand: 0..n を巡回
 data: n × 4096 バイトの連続領域 (frame i のページは data + i*4096)
```

```rust
type FrameId = u32;

struct Frame {
    pid: PageId,            // このフレームにあるページ。空きなら INVALID_PID
    pin_count: u32,         // fix 中のスレッド数。>0 なら追い出し禁止
    ref_bit: bool,          // clock 用。fix されたら true
    dirty: bool,            // 書き換えられたら true。追い出し時に書き戻す
    io_in_progress: bool,   // 読み込み中。他スレッドはこれが下りるまで待つ
    latch: RwLock<()>,      // ページ内容のロック (木のロックカップリング用。12 章)
}

struct BufferPool {
    inner: Mutex<Inner>,    // ページテーブルとフレームのメタデータを1本のロックで守る
    io_done: Condvar,       // io_in_progress を待つため
    data: *mut u8,          // n * PAGE_SIZE。O_DIRECT のため 4096 境界にそろえる
    file: File,             // O_DIRECT で開く
}
struct Inner {
    page_table: HashMap<PageId, FrameId>,
    frames: Vec<Frame>,
    free_list: Vec<FrameId>,
    clock_hand: usize,
}
const INVALID_PID: PageId = u64::MAX;
```

* ページ内容 (`data`) と管理情報 (`Frame`) は分ける。ページ内容をそのまま `pwrite` するため。
* `latch` はページ内容を読み書きするためのロック。`inner` の Mutex とは別物。`inner` はページテーブルの一貫性だけを守る。

### 1.3 不変条件

* `page_table[pid] == fid` ⇔ `frames[fid].pid == pid`。
* `pin_count > 0` のフレームは追い出されない。
* `io_in_progress` のフレームは、読み込んだスレッド以外はページ内容に触れない。
* `dirty == true` のページは、ディスク上の内容より新しい。追い出す前に必ず書き戻す。

### 1.4 操作

```rust
impl BufferPool {
    /// ページを使う前に呼ぶ。戻り値のポインタは unfix まで有効。
    fn fix(&self, pid: PageId) -> *mut u8 {
        let mut g = self.inner.lock();
        loop {
            if let Some(&fid) = g.page_table.get(&pid) {
                let f = &mut g.frames[fid as usize];
                if f.io_in_progress {                // 他スレッドが読み込み中
                    g = self.io_done.wait(g);        // ロックを手放して待つ → 最初からやり直し
                    continue;
                }
                f.pin_count += 1;
                f.ref_bit = true;
                return self.frame_ptr(fid);
            }
            // ミス: フレームを確保して読み込む
            let fid = match self.grab_frame(&mut g) {
                Some(fid) => fid,
                None => { g = self.io_done.wait(g); continue; } // 全部 pin 中。待つ (または Err を返す)
            };
            let f = &mut g.frames[fid as usize];
            f.pid = pid; f.pin_count = 1; f.ref_bit = true; f.dirty = false;
            f.io_in_progress = true;
            g.page_table.insert(pid, fid);
            drop(g);                                 // ★ I/O 中はロックを持たない
            self.file.read_exact_at(self.frame_slice_mut(fid), pid * PAGE_SIZE as u64);
            let mut g = self.inner.lock();
            g.frames[fid as usize].io_in_progress = false;
            self.io_done.notify_all();
            return self.frame_ptr(fid);
        }
    }

    fn unfix(&self, pid: PageId, dirtied: bool) {
        let mut g = self.inner.lock();
        let fid = g.page_table[&pid];
        let f = &mut g.frames[fid as usize];
        f.pin_count -= 1;
        f.dirty |= dirtied;
    }

    /// 空きリスト → clock の順で追い出し先を探す。inner のロックを持って呼ぶ。
    fn grab_frame(&self, g: &mut Inner) -> Option<FrameId> {
        if let Some(fid) = g.free_list.pop() { return Some(fid); }
        let n = g.frames.len();
        for _ in 0..2 * n {                          // 2周すれば ref_bit は全部落ちている
            let fid = g.clock_hand;
            g.clock_hand = (g.clock_hand + 1) % n;
            let f = &mut g.frames[fid];
            if f.pin_count > 0 || f.io_in_progress { continue; }
            if f.ref_bit { f.ref_bit = false; continue; }   // second chance
            // 犠牲者決定
            if f.dirty {
                // 簡略化: ロックを持ったまま同期書き込み。本物はロックを外して書き、
                // 書いている間は pin_count を 1 にして他の追い出しから守る。
                self.file.write_all_at(self.frame_slice(fid as FrameId), f.pid * PAGE_SIZE as u64);
                f.dirty = false;
            }
            g.page_table.remove(&f.pid);
            f.pid = INVALID_PID;
            return Some(fid as FrameId);
        }
        None
    }
}
```

* clock は LRU の近似。`ref_bit` が立っていれば落として飛ばし、落ちていれば追い出す。
* 新しいページの割り当て (`alloc_page`) は、ファイル末尾の PID を払い出し、`fix` と同じ流れで読み込みを省いたもの。

### 1.5 境界条件と落とし穴

* **同じページを2スレッドが同時にミスする**: `io_in_progress` を先にテーブルへ登録するので、2本目は待つだけになる。登録を I/O の後にすると、同じページが2つのフレームに載る。
* **全フレームが pin 中**: `grab_frame` が `None`。待つかエラーにする。木の深さ × スレッド数よりプールが小さいと必ず起きる。
* **I/O 中にロックを持たない**: 持つと全スレッドが SSD のレイテンシ (〜100µs) で直列化する。
* **dirty の書き戻し中に再 fix される**: 本物の実装では、書き戻し中フレームを pin して守る。上の擬似コードはロックを持ったまま書くので起きないが遅い。
* **ページ内容の latch と inner の Mutex の順序**: 常に `inner` → `latch` の順でなく、`inner` を持ったまま `latch` を待たないこと。`fix` は `inner` を返す前に外し、`latch` は呼び出し側が取る。

### 1.6 テスト方針

* プールサイズを 3〜8 フレームに絞り、ページ数 1000 程度で `fix` → 書き込み → `unfix` をランダムに繰り返す。正解は `HashMap<PageId, [u8; PAGE_SIZE]>`。
* 各操作後に不変条件 (テーブルとフレームの双方向一致、pin 0 以上) を検査する。
* 複数スレッド: 各スレッドが自分専用の PID 範囲を書き、共通 PID 範囲は読むだけ。最後に全ページを読み直して正解と比べる。

### 1.7 原典との違い・簡略化

* 【簡略化】 ハッシュ表は1本の Mutex。本物はパーティション分割やロックフリーのハッシュ表を使う。
* 【簡略化】 WAL (書き戻し前にログを flush する規則) を省いた。

---

## 2. Pointer swizzling (LeanStore)

### 2.1 目的と論文との関係

* 子への参照 (**swip**) に、メモリ上ならポインタ、ディスク上なら PID を入れる。メモリ上のページはハッシュ表なしでたどれる。
* LeanStore (ICDE 2018) の B-Tree は論文のベースラインの元になった (background 5.2)。論文自体は vmcache を使う。
* 2つの版を書く。
  * **2018 年版**: cooling stage (FIFO + ハッシュ表) を持つ。
  * **2023 年版** ("The Evolution of LeanStore"): cooling stage を捨て、swip の1ビットで second chance を実現する。

### 2.2 データ配置

**swip (8バイト)**。leanstore リポジトリの現行版のビット割り当て (`Swip.hpp`)。

```
 bit 63   bit 62   bit 61 ............................ 0
 ┌──────┬────────┬────────────────────────────────────┐
 │  1   │   -    │ PID (63ビット)                      │  EVICTED (cold)
 │  0   │   1    │ フレームへのポインタ                 │  COOL (2023年版)
 │  0   │   0    │ フレームへのポインタ                 │  HOT
 └──────┴────────┴────────────────────────────────────┘
```

* 2018 年版は COOL を swip に持たない (cooling 中も PID が入る)。bit 63 だけを使う。
* x86-64 のユーザ空間ポインタは上位16ビットが 0 なので、bit 62/63 を借りられる。

**Rust での表現**。2つの選択肢がある。

```rust
// 案A (推奨): ポインタの代わりにフレーム番号を入れる。provenance の問題が消える。
#[repr(transparent)]
struct Swip(AtomicU64);
const EVICTED_BIT: u64 = 1 << 63;
const COOL_BIT: u64 = 1 << 62;
const PAYLOAD_MASK: u64 = !(EVICTED_BIT | COOL_BIT);

enum SwipState { Hot(FrameId), Cool(FrameId), Evicted(PageId) }

impl Swip {
    fn decode(raw: u64) -> SwipState {
        if raw & EVICTED_BIT != 0 { SwipState::Evicted(raw & !EVICTED_BIT) }
        else if raw & COOL_BIT != 0 { SwipState::Cool((raw & PAYLOAD_MASK) as FrameId) }
        else { SwipState::Hot(raw as FrameId) }
    }
}

// 案B: 本物のポインタを入れる。strict provenance の API でタグを付け外しする。
struct SwipPtr(AtomicPtr<BufferFrame>);
fn cool(p: *mut BufferFrame) -> *mut BufferFrame { p.map_addr(|a| a | COOL_BIT as usize) }
fn hot(p: *mut BufferFrame) -> *mut BufferFrame  { p.map_addr(|a| a & PAYLOAD_MASK as usize) }
fn evicted(pid: PageId) -> *mut BufferFrame      { ptr::without_provenance_mut((pid | EVICTED_BIT) as usize) }
```

* 案B で PID を入れたポインタは provenance を持たない。デリファレンスしてはいけない。`without_provenance_mut` で作れば、誤って触ったときに Miri が検出する。
* 案A はフレーム配列の添字計算が1回増えるが、ほぼ無視できる (【未検証】性能差は測っていない)。
* swip はページ内 (内部ノードの子の欄) に置かれる。ページ内容は楽観的に読まれるので、swip の読み書きもアトミックにする (12 章 3節)。

**フレーム**。

```rust
#[repr(C, align(4096))]
struct BufferFrame {
    header: FrameHeader,   // 管理情報。ページ本体とは別の領域に置いてもよい
    page: [u8; PAGE_SIZE],
}
struct FrameHeader {
    state: AtomicU8,        // FREE / HOT / COOL / LOADED (LeanStore の STATE)
    pid: AtomicU64,         // 載っているページの PID
    latch: AtomicU64,       // 楽観ロックのバージョン語 (12 章)。決して 0 に戻さない
    dirty: AtomicBool,
    parent: AtomicU32,      // 2018年版のみ: 親フレーム番号 (永続化しない)
    epoch: AtomicU64,       // 2018年版のみ: cooling に入れたときのグローバルエポック
}
```

* `latch` を再初期化しないことが重要。フレームが別のページに再利用されても、古い読み手が持つバージョンとは一致しない (leanstore: `BufferFrame.hpp` のコメント "NEVER DECREMENT")。

### 2.3 状態遷移

```
             アクセス (swip を書き戻す)
        ┌────────────────────────────────┐
        ▼                                │
     ┌──────┐   ランダムに選ばれる    ┌─────────┐   FIFO の末尾に達する /   ┌──────┐
     │ HOT  │ ─────────────────────▶ │ COOLING │ ─ 2巡目でも COOL のまま ─▶ │ COLD │
     └──────┘    (swip を cool)      └─────────┘   (dirty なら書き戻す)      └──────┘
        ▲                                                                     │
        └──────────────────── ディスクから読み込む ───────────────────────────┘
```

### 2.4 不変条件

* **各ページを指す swip はちょうど1つ**。木なら自然に満たす。葉の兄弟ポインタは swip にしない (PID のまま持つか、持たない)。
* **swizzle された子を持つページは cool にも evict にもしない**。evict するとポインタがディスクに書かれ、再読込後には無効なアドレスになるため。
* HOT の swip が指すフレームは、そのページを保持している。
* (2018年版) cooling 中のページは FIFO とハッシュ表の両方に、ちょうど1回ずつ載っている。

### 2.5 B-Tree が提供するコールバック

```rust
trait BufferManaged {
    /// ページ内のすべての子 swip を列挙する。葉なら何もしない。
    fn iterate_child_swips(page: &Page, f: &mut dyn FnMut(&Swip) -> bool);
    /// ページ frame の親と、親の中で frame を指す swip を返す。
    /// 2018年版は parent 欄を使う。2023年版は根から同じキーで下って探す。
    fn find_parent(frame: FrameId) -> Result<ParentHandle, Restart>;
}
struct ParentHandle { parent: FrameId, parent_version: u64, swip: *const Swip }
```

* ページが自分の種類 (B-Tree 内部 / 葉 など) をヘッダに持つ必要がある。どのコールバックを呼ぶか判別するため。
* 2023年版の `find_parent`: 対象ページの最小キー (lower fence の次) で根から下り、子の swip が対象フレームを指す内部ノードを探す。親ポインタの保守 (split のたびに子の半分を書き換える) が要らなくなる。

### 2.6 2018年版の操作

```rust
struct CoolingStage {                         // 1本のグローバル Mutex で守る
    fifo: VecDeque<FrameId>,                  // 先頭 = 最近 cool にしたもの
    map: HashMap<PageId, FrameId>,            // PID → cooling 中のフレーム
    io_frames: HashMap<PageId, Arc<IoFrame>>, // 読み込み中のページ (同じ Mutex を共用)
}
struct IoFrame { mutex: Mutex<()>, frame: FrameId }
const COOLING_FRACTION: f64 = 0.10;           // プールの約1割を cooling にしておく

/// swip を解決してフレームを返す。parent_guard は swip を含むページの楽観ガード。
fn resolve_swip(parent_guard: &OptGuard, swip: &Swip) -> Result<FrameId, Restart> {
    let raw = swip.0.load(Acquire);
    parent_guard.check()?;                    // ★ swip を読んだ後、使う前に親を検証
    match Swip::decode(raw) {
        SwipState::Hot(fid) => Ok(fid),       // ホットパス: これだけ
        SwipState::Evicted(pid) => {
            let mut cs = COOLING.lock();
            parent_guard.check()?;            // ロック待ちの間に他スレッドが解決したかも
            if let Some(&fid) = cs.map.get(&pid) {            // cooling 中だった
                let pg = parent_guard.upgrade_x()?;           // ★ 先に親を X。失敗しても cooling stage は無傷
                cs.map.remove(&pid);
                cs.fifo.retain(|&x| x != fid);                // 実装では侵入リストで O(1) にする
                swip.0.store(fid as u64, Release);            // 再 swizzle
                frame(fid).header.state.store(HOT, Release);
                maybe_cool_one(&mut cs);                      // cooling の割合を保つ
                return Ok(fid);
            }
            if let Some(io) = cs.io_frames.get(&pid).cloned() { // 他スレッドが読み込み中
                drop(cs);
                let _w = io.mutex.lock();     // 読み込み完了を待つ
                return Err(Restart);          // 最初からやり直す (完了後の swip は HOT)
            }
            let Ok(fid) = pop_free_frame_or_evict(&mut cs) else { drop(cs); backoff(); return Err(Restart); };
            let io = Arc::new(IoFrame { mutex: Mutex::new(()), frame: fid });
            let held = io.mutex.lock();
            cs.io_frames.insert(pid, io.clone());
            drop(cs);                          // ★ I/O 中はグローバル Mutex を持たない
            exit_epoch();                      // ★ I/O 中はエポックも持たない
            read_page(pid, fid);
            let mut cs = COOLING.lock();
            cs.io_frames.remove(&pid);
            // 親を X ロックして swip を書き換える。失敗したらフレームを cooling に入れておく
            install_or_park(pid, fid, swip, parent_guard);
            drop(held);
            Err(Restart)                       // LeanStore は I/O 後に必ずやり直す
        }
        SwipState::Cool(_) => unreachable!(),  // 2018年版では使わない
    }
}

/// ランダムに1ページ選んで cooling に入れる。子が swizzle されていたら子を代わりに選ぶ。
fn maybe_cool_one(cs: &mut CoolingStage) {
    if cs.fifo.len() as f64 >= COOLING_FRACTION * POOL_FRAMES as f64 { return; }
    let mut fid = random_hot_frame();
    loop {
        let mut hot_child = None;
        B::iterate_child_swips(page(fid), &mut |s| {
            if let SwipState::Hot(c) = Swip::decode(s.0.load(Acquire)) { hot_child = Some(c); false } else { true }
        });
        match hot_child { Some(c) => fid = c, None => break } // 子へ降りる (内部ノードが優先的に残る)
    }
    let Ok(ph) = B::find_parent(fid) else { return };   // 失敗したら今回は諦める
    let Ok(_px) = ph.lock_x() else { return };
    let pid = frame(fid).header.pid.load(Relaxed);
    unsafe { &*ph.swip }.0.store(pid | EVICTED_BIT, Release);  // unswizzle
    frame(fid).header.state.store(COOL, Release);
    frame(fid).header.epoch.store(global_epoch(), Release);
    cs.fifo.push_front(fid);
    cs.map.insert(pid, fid);
}

/// FIFO の末尾から1つ取り出して再利用する。
fn pop_free_frame_or_evict(cs: &mut CoolingStage) -> Result<FrameId, NoFreeFrame> {
    if let Some(f) = free_list_pop() { return Ok(f); }
    // 末尾から順に見て、エポック条件を満たす最初のものを使う。
    // ★ 条件を満たすまで待ってはいけない。古いエポックのスレッドが、この Mutex を待って
    //   resolve_swip で止まっているかもしれない (デッドロック)。
    let min_e = min_local_epoch();
    let Some(idx) = cs.fifo.iter().rposition(|&f| frame(f).header.epoch.load(Acquire) < min_e) else {
        advance_global_epoch();
        return Err(NoFreeFrame);                 // 呼び出し側は Mutex を外してから再試行する
    };
    {
        let fid = cs.fifo.remove(idx).unwrap();
        let pid = frame(fid).header.pid.load(Relaxed);
        cs.map.remove(&pid);
        if frame(fid).header.dirty.load(Acquire) { write_page(pid, fid); } // 簡略化: Mutex を持ったまま同期書き。本物は外して書く
        frame(fid).header.latch.fetch_add(VERSION_STEP, Release);         // 古い読み手を失敗させる
        Ok(fid)
    }
}
```

* cooling に入れた瞬間、swip は PID になる。以後このページを新しく見つける読み手はいない。
* ただし swip を書き換える前にポインタを読んだ読み手は残っている。だから FIFO の末尾に来ても、**エポックで全員が抜けたことを確認するまで**再利用しない。
* エポック: スレッドは操作の開始時にグローバルエポックを自分のローカル欄に写し、終了時に ∞ にする。`min_local_epoch()` は全スレッドの最小値。
* グローバルエポックを上げる頻度は、追い出し数に比例させて 1/100 程度に抑える (ICDE 2018 IV-G)。

### 2.7 2023年版 (Second Chance、cooling stage なし)

```rust
const BATCH: usize = 64;

/// 背景スレッド (page provider) がループで呼ぶ。空きフレームが閾値を下回ったら動く。
fn page_provider_round() {
    let mut to_evict = Vec::new();
    for _ in 0..BATCH {
        let fid = random_frame();
        let h = &frame(fid).header;
        match h.state.load(Acquire) {
            HOT => {
                if has_hot_child(fid) { continue; }        // 子を代わりに選んでもよい
                let Ok(ph) = B::find_parent(fid) else { continue };
                let Ok(_px) = ph.lock_x() else { continue };
                let s = unsafe { &*ph.swip };
                s.0.fetch_or(COOL_BIT, Release);           // ポインタは残したまま印だけ付ける
                h.state.store(COOL, Release);
            }
            COOL => to_evict.push(fid),                    // 2巡目でもまだ COOL → 追い出し
            _ => {}
        }
    }
    let (dirty, mut clean): (Vec<_>, Vec<_>) = to_evict.into_iter().partition(|&f| frame(f).header.dirty.load(Acquire));
    // dirty ページは「検証済みのコピー」を書く。ロックなしでページそのものを書くと、
    // 書いている間に HOT に戻されて書き換えられ、(1) 書いた内容が混ざる、(2) 完了時の
    // dirty=false で新しい変更の印を消してしまう。
    let mut written = Vec::new();
    for fid in dirty {
        let Ok(v) = frame(fid).header.latch_read_begin() else { continue };   // 12 章の read_lock_or_restart
        let buf = write_buffer_slot();                     // 4096 境界にそろえた書き込み用バッファ
        copy_page_atomically(&frame(fid).page, buf);       // 12 章 3.2 の copy_out
        if frame(fid).header.latch_check(v).is_err() { continue; }
        written.push((fid, v, buf));
    }
    async_write_batch(&written);                           // 4章のループで書き、全完了を待つ
    for (fid, mut v, _) in written {
        // 書いた版から変更がなければ clean にする。昇格に成功 = 版が v のまま。
        if frame(fid).header.latch_upgrade(&mut v).is_ok() {
            frame(fid).header.dirty.store(false, Relaxed);
            frame(fid).header.latch_unlock();
            clean.push(fid);
        }                                                  // 変更されていたら dirty のまま。次の周回へ
    }
    for fid in clean {
        let Ok(ph) = B::find_parent(fid) else { continue };
        let Ok(_px) = ph.lock_x() else { continue };
        let Ok(_cx) = lock_x_frame(fid) else { continue };
        if frame(fid).header.state.load(Acquire) != COOL || frame(fid).header.dirty.load(Acquire) { continue; }
        let pid = frame(fid).header.pid.load(Relaxed);
        unsafe { &*ph.swip }.0.store(pid | EVICTED_BIT, Release);
        frame(fid).header.state.store(FREE, Release);
        // _cx の解放でバージョンが進む。古い読み手は検証で失敗する。
        free_list_push(fid);
    }
}

/// 読み手側: COOL を見たら HOT に戻す。
fn resolve_swip_2023(parent_guard: &OptGuard, swip: &Swip) -> Result<FrameId, Restart> {
    let raw = swip.0.load(Acquire);
    parent_guard.check()?;
    match Swip::decode(raw) {
        SwipState::Hot(fid) => Ok(fid),
        SwipState::Cool(fid) => {
            let _px = parent_guard.upgrade_x()?;         // 親を X (swip を書くため)
            let _cx = lock_x_frame(fid)?;                // 子も X (state を書くため)
            swip.0.fetch_and(!COOL_BIT, Release);
            frame(fid).header.state.store(HOT, Release);
            Ok(fid)                                      // 呼び出し側はロック解放後にやり直す
        }
        SwipState::Evicted(pid) => load_via_partitioned_io_stage(pid), // PID の下位ビットで分割した io ハッシュ表
    }
}
```

* COOL は「ポインタはそのまま、印だけ」。読み手は印を落とせばよく、ハッシュ表も FIFO も引かない。
* 2023年版はエポック回収をやめた。理由は2つ。フレームの `latch` 語を決して巻き戻さない。フレームのメモリを OS に返さない。古い読み手は再利用後のフレームを読んでもバージョン不一致で失敗するだけ。
* I/O の排他 (同じページの二重読み込み防止) は、PID の下位ビットで分割した複数のハッシュ表 + Mutex で行う (Evolution 6.3)。

### 2.8 境界条件と落とし穴

* **swip を読んだ後に親を検証しない**: swip が書き換え途中のゴミかもしれない。フレーム番号なら範囲外アクセス、ポインタなら不正アドレスになる。必ず `check` してから使う。
* **cool 対象の選び直しが止まらない**: 全ページが子持ちの内部ノードに見えるなど。試行回数に上限を置く (leanstore の PageProviderThread も上限付きで選び直す)。
* **find_parent 中の split**: 根から下る間に木が変わる。楽観ガードで下り、失敗したら諦めて次の候補へ。
* **根ページ**: 根を指す swip はバッファ外 (メタデータ) にある。find_parent は根に対して特別扱いする。
* **dirty ページの書き戻し中にアクセスされる**: 上の擬似コードは、版を検証したコピーを書き、完了後に「版が変わっていなければ clean」とする。leanstore はコピー用のバッファ (`AsyncWriteBuffer`) と `is_being_written_back` 印を使う。ページそのものをロックなしで書き、完了後に無条件で `dirty=false` にすると、書いている間の更新を失う。
* **エポックを持ったまま I/O しない** (2018年版): 1スレッドが I/O で止まると全体の回収が止まる。
* **長いスキャン**: 1ページごとにエポック / ガードを取り直す。

### 2.9 テスト方針

* プールを 16〜64 フレームに絞り、10万キーの B-Tree に挿入 → ランダム lookup。正解は `BTreeMap`。cooling / 追い出し / 再 swizzle が頻発する。
* 不変条件チェッカー (停止状態で実行): 全 swip を根から列挙し、HOT の swip が指すフレームの `pid` が一致すること、同じフレームを2つの swip が指さないこと、子が HOT の親は HOT であること。
* 多スレッド: 8 スレッドで挿入と lookup を混ぜる。共有の `Mutex<BTreeMap>` を正解にし、各スレッドは自分のキー範囲にだけ書く (結果の順序を決定的にするため)。
* swip のエンコード / デコードは proptest で往復を確認。案B は Miri で、PID 入り swip をデリファレンスしたら検出されることを確認する。

### 2.10 原典との違い・簡略化

* 【簡略化】 2018年版の FIFO 内削除を `retain` で書いた。本物は O(1) で外せる構造。
* 【簡略化】 `install_or_park` (読み込み後に親の swip を書き換えられなかった場合の扱い) は中身を省いた。読み込んだフレームを cooling に入れておき、次にアクセスした読み手が見つける、という設計が自然 (【未検証】原典の扱いは確認していない)。
* 【設計判断】 swip にフレーム番号を入れる案A を推奨したのは筆者の判断。原典はポインタを入れる。

---

## 3. vmcache

### 3.1 目的と論文との関係

* ページ ID → アドレスの変換を OS のページテーブルにやらせる。`addr = virt_mem + pid * 4096`。
* 論文の B-Tree は、このバッファマネージャに**構造を変えずに**載った (7章)。マルチスレッド評価とメモリ溢れ評価はこの上で行った。
* swizzling の制約 (swip は1つだけ、子が載っている親は追い出せない、親の探索) がない。B-Tree は子として PID を持つだけ。

### 3.2 データ配置

```
virt_mem (mmap で予約。物理メモリは触ったページだけ)
┌────────┬────────┬────────┬───── ... ─────┬────────┬───────────┐
│ pid 0  │ pid 1  │ pid 2  │               │ pid N-1│ 予備 64KiB │
│ メタ   │        │(未割当)│               │        │ 読み越し用 │
└────────┴────────┴────────┴───── ... ─────┴────────┴───────────┘
  ↑ 0 番はメタデータページ (根の PID を持つ)

page_state: [PageState; N]  (8バイト × N。巨大ページで確保)
resident_set: 開番地法ハッシュ集合 (容量 = 2^ceil(log2(物理ページ数 × 1.5)))
```

**PageState (64ビット)**。

```
 63        56 55                                              0
 ┌───────────┬────────────────────────────────────────────────┐
 │ state (8) │ version (56)                                    │
 └───────────┴────────────────────────────────────────────────┘
  state:   0       Unlocked
           1..252  共有ロック中 (値 = 読み手数)
           253     Locked (排他)
           254     Marked (追い出し候補。clock の参照ビットが落ちた状態)
           255     Evicted (メモリにない)
```

```rust
#[repr(transparent)]
struct PageState(AtomicU64);
const UNLOCKED: u64 = 0;
const MAX_SHARED: u64 = 252;
const LOCKED: u64 = 253;
const MARKED: u64 = 254;
const EVICTED: u64 = 255;

fn state_of(v: u64) -> u64 { v >> 56 }
fn same_version(v: u64, s: u64) -> u64 { (v & ((1 << 56) - 1)) | (s << 56) }
fn next_version(v: u64, s: u64) -> u64 { (((v & ((1 << 56) - 1)) + 1) & ((1 << 56) - 1)) | (s << 56) }

/// ページ本体。楽観的に読まれるので、全バイトを AtomicU64 で読み書きする (12 章 3.2)。
#[repr(C, align(4096))]
struct Page { w: [AtomicU64; PAGE_SIZE / 8] }

struct BufferManager {
    virt_mem: *mut Page,          // virt_count + 16 ページ分 (= 予備 64KiB)
    virt_count: u64,              // 仮想ページ数 (= 扱える最大 PID + 1)
    phys_count: u64,              // 物理メモリに置ける最大ページ数
    phys_used: AtomicU64,
    alloc_count: AtomicU64,       // 次に払い出す PID。1 から (0 はメタ)
    page_state: Box<[PageState]>, // virt_count 個。決して解放しない
    dirty: Box<[AtomicBool]>,     // virt_count 個。ページ本体の外に置く (下の注)
    resident: ResidentSet,
    fd: RawFd,                    // O_DIRECT で開いたブロックデバイス / ファイル
    batch: usize,                 // 1回の追い出しで扱うページ数 (既定 64)
}
```

* 初期状態は全ページ `same_version(0, EVICTED)`。
* dirty フラグ: vmcache (C++) はページ先頭 1 バイトに置く。Rust 版では PID で引く別配列にする。ページ本体を `AtomicU64` だけで扱うため (サイズの違うアトミックの混在を避ける)。再読込したページは定義上 clean になる。
* `virt_mem` の確保: `mmap(NULL, virt_size + 64KiB, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0)` → `madvise(MADV_NOHUGEPAGE)`。巨大ページだと 4 KiB 単位で返せないため。
  * vmcache 本体は `MAP_NORESERVE` を付けていない。overcommit の設定次第で巨大な予約が失敗するので、付けるほうが安全 (【未検証】既定の overcommit 設定で失敗するかは試していない)。
* 末尾の予備 64 KiB: 楽観的な読み手がゴミのオフセットで少し読み越しても SIGSEGV にならないように。

### 3.3 不変条件

* `state == EVICTED` ⇔ ページが resident set にない ⇔ 物理メモリが割り当たっていない (ゼロページかもしれない)。
* ロックを取っても**バージョンは変わらない**。外すときに +1 する (排他ロックの解除と、追い出し)。共有ロックの増減ではバージョンは変わらない。
* `Marked` は「最近アクセスされていない」の意味。誰かが楽観的にでも読めば `Unlocked` に戻る。これが clock の参照ビットの代わり。
* `page_state` 配列とその番地は、プロセスの寿命中変わらない。だからエポック回収が要らない。

### 3.4 状態語の操作

```rust
impl PageState {
    fn load(&self) -> u64 { self.0.load(Acquire) }
    fn try_lock_x(&self, v: u64) -> bool {
        let ok = self.0.compare_exchange(v, same_version(v, LOCKED), Acquire, Relaxed).is_ok();
        if ok { fence(Release); }   // ★ 以後のページへの書き込みより前にロックを見せる (12 章 3.3)
        ok
    }
    fn unlock_x(&self) {                                     // 書き込みの公開
        let v = self.0.load(Relaxed);
        debug_assert_eq!(state_of(v), LOCKED);
        self.0.store(next_version(v, UNLOCKED), Release);
    }
    fn unlock_x_evicted(&self) {
        let v = self.0.load(Relaxed);
        self.0.store(next_version(v, EVICTED), Release);
    }
    fn try_lock_s(&self, v: u64) -> bool {
        let s = state_of(v);
        let new = if s < MAX_SHARED { same_version(v, s + 1) }
                  else if s == MARKED { same_version(v, 1) }    // 読めば mark は消える
                  else { return false };
        self.0.compare_exchange(v, new, Acquire, Relaxed).is_ok()
    }
    fn unlock_s(&self) {
        loop {
            let v = self.0.load(Relaxed);
            let s = state_of(v);
            debug_assert!(s >= 1 && s <= MAX_SHARED);
            if self.0.compare_exchange_weak(v, same_version(v, s - 1), Release, Relaxed).is_ok() { return; }
        }
    }
    fn try_mark(&self, v: u64) -> bool {                      // v の state は UNLOCKED
        self.0.compare_exchange(v, same_version(v, MARKED), Relaxed, Relaxed).is_ok()
    }
}
```

* `unlock_x` は `load` → `store` で書いている。排他中は他の誰も状態語を書かないので CAS は不要。
  * 例外: 楽観的な読み手が `MARKED → UNLOCKED` の CAS をすることがあるが、LOCKED 中は失敗するので衝突しない。

### 3.5 fix 系の操作

```rust
impl BufferManager {
    fn to_ptr(&self, pid: PageId) -> *mut Page { self.virt_mem.wrapping_add(pid as usize) }
    fn to_pid(&self, p: *const Page) -> PageId { (p.addr() - self.virt_mem.addr()) as u64 / PAGE_SIZE as u64 }

    fn fix_x(&self, pid: PageId) -> *mut Page {
        let ps = &self.page_state[pid as usize];
        for spin in 0.. {
            let v = ps.load();
            match state_of(v) {
                EVICTED => if ps.try_lock_x(v) { self.handle_fault(pid); return self.to_ptr(pid); },
                MARKED | UNLOCKED => if ps.try_lock_x(v) { return self.to_ptr(pid); },
                _ => {}
            }
            backoff(spin);
        }
        unreachable!()
    }

    fn fix_s(&self, pid: PageId) -> *mut Page {
        let ps = &self.page_state[pid as usize];
        for spin in 0.. {
            let v = ps.load();
            match state_of(v) {
                LOCKED => {}
                EVICTED => if ps.try_lock_x(v) { self.handle_fault(pid); ps.unlock_x(); }, // 読んだら一度離して取り直す
                _ => if ps.try_lock_s(v) { return self.to_ptr(pid); },
            }
            backoff(spin);
        }
        unreachable!()
    }

    /// 楽観ガードの開始。ロックせずにバージョンを得る。
    fn optimistic_begin(&self, pid: PageId) -> u64 {
        let ps = &self.page_state[pid as usize];
        for spin in 0.. {
            let v = ps.load();
            match state_of(v) {
                MARKED => {                                    // 参照ビットを立て直す
                    let nv = same_version(v, UNLOCKED);
                    if ps.0.compare_exchange_weak(v, nv, Acquire, Relaxed).is_ok() { return nv; }
                }
                LOCKED => {}
                EVICTED => if ps.try_lock_x(v) { self.handle_fault(pid); ps.unlock_x(); },
                _ => return v,                                 // UNLOCKED か共有ロック中
            }
            backoff(spin);
        }
        unreachable!()
    }

    /// 楽観ガードの検証。成功なら Ok。
    fn optimistic_check(&self, pid: PageId, version: u64) -> Result<(), Restart> {
        let ps = &self.page_state[pid as usize];
        let v = ps.0.load(Acquire);       // 呼び出し側でデータ読みの後に fence(Acquire) 済み (12 章)
        if v == version { return Ok(()); }
        if (v << 8) == (version << 8) {   // バージョンが同じ
            let s = state_of(v);
            if s <= MAX_SHARED { return Ok(()); }          // 共有ロックの出入りは無視
            if s == MARKED && ps.0.compare_exchange_weak(v, same_version(v, UNLOCKED), Relaxed, Relaxed).is_ok() {
                return Ok(());
            }
        }
        Err(Restart)
    }
}
```

* 楽観ガードは「ロックせずに読み、後で検証」。12 章の OLC そのもの。vmcache のバージョン語は OLC のロック語を兼ねる。
* `fix_s` / `optimistic_begin` で EVICTED を見たら、自分で X を取って読み込み、離してから取り直す。読み込みは誰か1人だけが行う (CAS に勝った者)。

### 3.6 ページフォルトと割り当て

```rust
impl BufferManager {
    /// pid の X ロックを持った状態で呼ぶ。
    fn handle_fault(&self, pid: PageId) {
        self.phys_used.fetch_add(1, Relaxed);
        self.ensure_free_pages();
        self.read_page(pid);
        self.resident.insert(pid);
    }

    fn read_page(&self, pid: PageId) {
        // O_DIRECT: バッファ・オフセット・長さはすべて 4096 の倍数。virt_mem の各ページはそれを満たす。
        let n = unsafe { libc::pread(self.fd, self.to_ptr(pid).cast(), PAGE_SIZE, (pid * PAGE_SIZE as u64) as i64) };
        assert_eq!(n, PAGE_SIZE as isize);   // 本物はエラー処理と EINTR の再試行
    }

    fn ensure_free_pages(&self) {
        if self.phys_used.load(Relaxed) as f64 >= self.phys_count as f64 * 0.95 { self.evict(); }
    }

    /// 新しいページを X ロック済みで返す。
    fn alloc_page(&self) -> (PageId, *mut Page) {
        self.phys_used.fetch_add(1, Relaxed);
        self.ensure_free_pages();
        let pid = self.alloc_count.fetch_add(1, Relaxed);
        assert!(pid < self.virt_count, "仮想領域が足りない");
        let ps = &self.page_state[pid as usize];
        let ok = ps.try_lock_x(ps.load());   // 新規 PID なので誰も触っていない
        debug_assert!(ok);
        self.resident.insert(pid);
        self.dirty[pid as usize].store(true, Relaxed);
        (pid, self.to_ptr(pid))
    }
}
```

* `pread` はカーネルがページに書き込む。X ロック中なので Rust 側の書き手はいない。楽観的な読み手は `optimistic_begin` で EVICTED / LOCKED を見て待つので、新しく読み始める者もいない。
  * 追い出し前から読んでいた古い読み手は、ゼロページ → 読み込み中の内容というゴミを読むかもしれない。バージョンが進むので検証で失敗する。ゴミを読んでも暴走しないことが前提 (12 章 2.6)。
* `handle_fault` の中で `evict` を呼ぶ。自分の pid は X ロック中で resident set にもまだ入っていないので、自分を追い出すことはない。

### 3.7 resident set (clock の針付きハッシュ集合)

```rust
struct ResidentSet {
    ht: Box<[AtomicU64]>,     // 各要素は PID / EMPTY / TOMBSTONE
    mask: u64,                // 容量 - 1 (容量は 2 の累乗)
    clock_pos: AtomicU64,
}
const EMPTY: u64 = u64::MAX;
const TOMBSTONE: u64 = u64::MAX - 1;

impl ResidentSet {
    fn insert(&self, pid: PageId) {
        let mut pos = hash64(pid) & self.mask;
        loop {
            let cur = self.ht[pos as usize].load(Relaxed);
            debug_assert_ne!(cur, pid);
            if (cur == EMPTY || cur == TOMBSTONE)
                && self.ht[pos as usize].compare_exchange(cur, pid, AcqRel, Relaxed).is_ok() { return; }
            pos = (pos + 1) & self.mask;
        }
    }
    fn remove(&self, pid: PageId) -> bool {
        let mut pos = hash64(pid) & self.mask;
        loop {
            let cur = self.ht[pos as usize].load(Relaxed);
            if cur == EMPTY { return false; }
            if cur == pid && self.ht[pos as usize].compare_exchange(cur, TOMBSTONE, AcqRel, Relaxed).is_ok() { return true; }
            pos = (pos + 1) & self.mask;
        }
    }
    /// 針を batch 個ぶん進め、その範囲の PID に f を適用する。針は CAS で取り合う。
    fn iterate_clock_batch(&self, batch: u64, mut f: impl FnMut(PageId)) {
        let cap = self.mask + 1;
        let mut pos = self.clock_pos.load(Relaxed);
        while let Err(p) = self.clock_pos.compare_exchange_weak(pos, (pos + batch) % cap, Relaxed, Relaxed) { pos = p; }
        for _ in 0..batch {
            let cur = self.ht[pos as usize].load(Relaxed);
            if cur != EMPTY && cur != TOMBSTONE { f(cur); }
            pos = (pos + 1) & self.mask;
        }
    }
}
```

* ハッシュは MurmurHash64A の最終混合 (`vmcache.cpp:ResidentPageSet::hash`)。何でもよいが、連番の PID が偏らないこと。
* 容量を物理ページ数の 1.5 倍以上にするので、満杯にはならない。
* TOMBSTONE は再利用されるが、全体の再構築はしない。挿入と削除が同数なので、TOMBSTONE が増えすぎることはない (【未検証】長時間運転での探索長は測っていない)。

### 3.8 追い出し

```rust
impl BufferManager {
    fn evict(&self) {
        let mut to_evict: Vec<PageId> = Vec::with_capacity(self.batch);
        let mut to_write: Vec<PageId> = Vec::with_capacity(self.batch);

        // 0. 候補集め。UNLOCKED は MARK するだけ (1周目)。MARKED のまま残っていたら候補 (2周目)。
        while to_evict.len() + to_write.len() < self.batch {
            self.resident.iterate_clock_batch(self.batch as u64, |pid| {
                let ps = &self.page_state[pid as usize];
                let v = ps.load();
                match state_of(v) {
                    MARKED => {
                        if self.dirty[pid as usize].load(Relaxed) {
                            if ps.try_lock_s(v) { to_write.push(pid); }   // 書き戻す間、書き手を止める
                        } else {
                            to_evict.push(pid);
                        }
                    }
                    UNLOCKED => { ps.try_mark(v); }
                    _ => {}                                               // ロック中・EVICTED は飛ばす
                }
            });
        }

        // 1. dirty ページをまとめて書く (4章)。書く前に dirty を下ろす。
        for &pid in &to_write { self.dirty[pid as usize].store(false, Relaxed); }
        self.io.write_pages_batch(&to_write);    // 全部の完了を待って戻る

        // 2. clean 候補を X ロック。MARKED のままでなければ (誰かが触った) 諦める。
        to_evict.retain(|&pid| {
            let ps = &self.page_state[pid as usize];
            let v = ps.load();
            state_of(v) == MARKED && ps.try_lock_x(v)
        });

        // 3. 書いたページは S → X に昇格。共有者が自分だけ (state == 1) のときだけ。
        for &pid in &to_write {
            let ps = &self.page_state[pid as usize];
            let v = ps.load();
            if state_of(v) == 1 && ps.0.compare_exchange_weak(v, same_version(v, LOCKED), Acquire, Relaxed).is_ok() {
                to_evict.push(pid);
            } else {
                ps.unlock_s();
            }
        }

        // 4. 物理メモリを返す。仮想アドレスは残る。
        for &pid in &to_evict {
            unsafe { libc::madvise(self.to_ptr(pid).cast(), PAGE_SIZE, libc::MADV_DONTNEED); }
        }
        // (exmap を使う場合は、ここを EXMAP_OP_FREE の ioctl 1回にまとめる)

        // 5. resident set から外し、EVICTED + バージョン +1 で解放する。
        for &pid in &to_evict {
            let ok = self.resident.remove(pid);
            debug_assert!(ok);
            self.page_state[pid as usize].unlock_x_evicted();
        }
        self.phys_used.fetch_sub(to_evict.len() as u64, Relaxed);
    }
}
```

* clock の2段階: 1周目で `MARKED` にする。次に針が来るまでに誰かが読めば `UNLOCKED` に戻る (楽観的な読みでも戻る)。戻っていなければ追い出す。
* dirty ページを S ロックで書くのは、書いている間に書き手が内容を変えるのを防ぐため。読み手は止めない。
* `dirty = false` を書く**前**に下ろす: vmcache ではフラグがページ本体の先頭バイトにあり、ページごとディスクに書かれるため。先に下ろせば再読込したページは clean で始まる。別配列にした場合はどちらでもよいが、S ロック中なので書いている間に他の書き手が dirty を立て直すことはない。
* `MADV_DONTNEED` の後に同じ仮想アドレスを読むと、**ゼロで埋まったページ**が見える (匿名 private マッピングの仕様)。古い楽観的な読み手はゼロを読み、バージョン不一致で失敗する。

### 3.9 楽観的な読み手との関係

| 読み手の位置 | 起きること | 検出方法 |
|---|---|---|
| `optimistic_begin` の前に追い出し済み | EVICTED を見て自分で読み込む | 不要 |
| 読んでいる途中で追い出し | ゼロページか、再読込途中の内容を読む | 追い出しで +1、再読込の X 解除で +1。検証で失敗 |
| 子の PID を読んだ直後に親が書き換え | ゴミの PID | **子の状態語を読む前に親を検証**する。さらに `pid < virt_count` を確認 |
| 書き手が X で変更中 | 途中の内容 | 解除時の +1 で検証が失敗 |

* 子へ進む順序: 親の中で子 PID を読む → 親を検証 → 子の `optimistic_begin`。vmcache の `GuardO(pid, parent)` コンストラクタがこの順 (`vmcache.cpp:GuardO::GuardO`)。
* 検証前の PID は信用しない。`page_state[pid]` の添字にする前に範囲を確認する (Rust では範囲外は panic なので UB にはならないが、panic はやり直しにならない)。
* ページ内容は、追い出しの前後で物理ページが入れ替わっても同じ仮想アドレスにある。読み手がセグメンテーション違反を起こすことはない。
  * exmap を使った場合に解放後のページを読むとどうなるかは確認していない (【未検証】)。
* Rust での読み方: ページの中身は `AtomicU64` / `AtomicU8` で読むか、12 章 3節の seqlock パターンで読む。`&Page` 経由の通常の読み取りはデータ競合 = UB。
  * `pread` (カーネルによる書き込み) と読み手のアトミック読みの競合は、Rust のメモリモデルの外の話。実用上は問題ないとされるが、形式的な保証はない (【未検証】)。

### 3.10 境界条件と落とし穴

* **候補集めが終わらない**: 全ページがロック中だと `while` が回り続ける。1回の `evict` で回る周回数に上限を置き、足りなければ諦めて戻る (vmcache 本体は上限なし)。
* **共有ロック数の上限**: 252 人まで。超えると `try_lock_s` が失敗し続ける。スレッド数が 252 を超えるなら、待ちながら再試行する。
* **バージョンの桁あふれ**: 56 ビット。毎秒 10^9 回更新しても 2 年以上。ABA は実用上起きない。
* **dirty フラグの位置** (vmcache 方式でページ内に置く場合): ページ先頭 1 バイトを B-Tree が上書きしないこと。B-Tree のヘッダは offset 8 から置く。
* **書き戻しと X ロック**: dirty ページは S で書いてから X に昇格する。昇格に失敗したら (他にも読み手がいる) 追い出さずに S を外す。dirty はすでに false なので、次の周回では clean として扱われる。
* **PID 0**: メタデータ (根の PID)。追い出してもよいが、毎回アクセスされるので実際は残る。
* **phys_used の数え方**: 先に +1 してから `ensure_free_pages` を呼ぶ。複数スレッドが同時に 95% を超えると、それぞれが `evict` を呼ぶ (問題ない)。

### 3.11 テスト方針

* **小さすぎるプール**: `phys_count = 64` ページ、データ 10 万ページ。挿入 → ランダム lookup → ランダム update。正解は `BTreeMap`。追い出しと再読込が毎操作のように起きる。
* **多スレッド**: 16 スレッドで lookup / insert / update を混ぜる。正解は `Mutex<BTreeMap>`。insert / update はキー範囲をスレッドごとに分け、lookup は全範囲。最後に全キーを照合する。
* **書き戻しの確認**: 全ページを強制的に追い出す関数 (テスト用) を作る。追い出し → 再読込のあと内容が一致すること。
* **状態語の単体テスト**: `same_version` / `next_version` の境界 (バージョン最大値で 0 に戻る)、共有ロックの 252 上限。
* **ゴミ耐性**: ページをランダムなバイト列で埋め、B-Tree のノード内探索を走らせる。panic せず有限時間で終わることを確認する (fuzz)。
* loom: `PageState` の遷移 (fix_x / fix_s / optimistic / evict) を 2〜3 スレッドでモデル検査する。ページ本体は省き、状態語だけを対象にする。

### 3.12 原典との違い・簡略化

* 【簡略化】 `read_page` は同期 `pread`。vmcache も同期。非同期化は 4 章。
* 【簡略化】 exmap (専用カーネルモジュール) は扱いを省いた。exmap は `pread` の代わりにスレッドごとのインタフェースで読み、`EXMAP_OP_FREE` でまとめて解放する。TLB shootdown の削減が目的。
* 【設計判断】 `MAP_NORESERVE` の追加と、`evict` の周回上限は筆者の追加。
* 【設計判断】 dirty フラグをページ外の配列に移した (vmcache はページ先頭バイト)。
* vmcache の `fix_x` / `fix_s` は無限に再試行する (`_mm_pause` のみ)。上限付き再試行とフォールバックは OLC 論文の提案 (12 章 2.7)。

---

## 4. NVMe 向け非同期 I/O ループ

### 4.1 目的と論文との関係

* NVMe SSD は、同時に多数の要求を投げないと性能が出ない (ランダム読み 〜100µs、PCIe 4.0 で 1 台 100万 IOPS 以上)。
* 論文 7.2 節は 256 スレッドで同期 `pread` を投げ、SSD の読み出し性能の 61〜72% を得た。スレッドを増やす代わりに、少数のスレッドで多数の I/O を投げるのがこの節の方式。
* vmcache 自身は、書き戻しだけ libaio でまとめて投げ、**全部の完了を待って**戻る (`vmcache.cpp:LibaioInterface::writePages`)。「まとめて投げる」だけで、待ちながら別の仕事をするループではない。

### 4.2 データ配置

```rust
struct IoRing {
    ring: io_uring::IoUring,          // SQ (投入キュー) と CQ (完了キュー)。io-uring クレート
    in_flight: Slab<Pending>,         // user_data → 待っている仕事
    to_submit: usize,                 // SQ に積んだが未投入の数
}
struct Pending { pid: PageId, kind: IoKind, waiter: TaskId }
enum IoKind { Read, Write }
```

```
 worker thread (1スレッド = 多数のタスク)
 ┌─────────────────────────────────────────────────────────────┐
 │ loop {                                                      │
 │   1. 実行可能なタスクを1つ走らせる ── ページフォルト ─┐       │
 │   2. SQ に積んだ要求をまとめて投入 (io_uring_enter)   │ SQ に │
 │   3. 空きページが足りなければ追い出し                  │ 積んで│
 │   4. CQ を覗いて完了したタスクを実行可能に戻す         │ 休止  │
 │ }                                                     ◀┘       │
 └─────────────────────────────────────────────────────────────┘
```

### 4.3 擬似コード

```rust
fn worker_loop(ring: &mut IoRing, sched: &mut Scheduler) {
    loop {
        // 1. タスクを1つ走らせる。ページフォルトしたら SQ に積んで Waiting になる。
        if let Some(t) = sched.pop_ready() { sched.run_until_yield(t); }

        // 2. 投入。積んだ分を1回のシステムコールでまとめて送る。
        if ring.to_submit > 0 {
            ring.ring.submit().expect("submit");     // SQPOLL なら不要
            ring.to_submit = 0;
        }

        // 3. 追い出し (3.8 節の evict を、書き込みを SQ に積む形に変えたもの)
        if bm.needs_eviction() { bm.evict_async(ring); }

        // 4. 完了の刈り取り。待たずに覗くだけ。
        for cqe in ring.ring.completion() {
            let p = ring.in_flight.remove(cqe.user_data() as usize);
            assert_eq!(cqe.result(), PAGE_SIZE as i32);   // 本物は短い読み / エラーを処理
            match p.kind {
                IoKind::Read => { bm.finish_fault(p.pid); sched.make_ready(p.waiter); }
                IoKind::Write => { bm.finish_writeback(p.pid); }
            }
        }
    }
}

/// タスク内のページフォルト。X ロックは取ったまま、I/O を積んで休止する。
fn fault_async(ring: &mut IoRing, pid: PageId, me: TaskId) {
    let key = ring.in_flight.insert(Pending { pid, kind: IoKind::Read, waiter: me });
    let sqe = io_uring::opcode::Read::new(io_uring::types::Fd(bm.fd), bm.to_ptr(pid).cast(), PAGE_SIZE as u32)
        .offset(pid * PAGE_SIZE as u64)
        .build()
        .user_data(key as u64);
    unsafe { ring.ring.submission().push(&sqe).expect("SQ full"); }  // 満杯なら先に submit する
    ring.to_submit += 1;
    yield_to_scheduler();                // コルーチン / 手書きの状態機械で実装
}
```

* `finish_fault(pid)`: resident set に入れて `unlock_x` する。
* `finish_writeback(pid)`: S ロックを外す (または X に昇格して追い出す)。
* タスクの切り替えはコルーチン (Haas & Leis はユーザレベルのコンテキスト切り替え)。Rust なら `async` + 自前の executor か、操作を状態機械で書く。

### 4.4 落とし穴

* **I/O 中のバッファ**: カーネルが書き込むメモリは、完了まで動かない・解放されない必要がある。vmcache のページは固定番地なので満たす。X ロックを持ったままにして Rust 側からも触らせない。
* **O_DIRECT の整列**: バッファ・オフセット・長さを 4096 の倍数に。
* **SQ が満杯**: `push` が失敗したら先に `submit` してから積み直す。
* **完了を刈り取らないと CQ があふれる**: 投入数の上限 (in-flight 数) を CQ サイズ以下に抑える。
* **ロックを持ったままタスクを休止する**: 休止中のタスクが X ロックを持つページに、同じスレッドの別タスクが触ると、スピン待ちでスレッドごと止まる (自己デッドロック)。ロック待ちもタスクの休止にする。
* **ポーリングの CPU 消費**: IOPOLL / SQPOLL は割り込みを避けて速いが、CPU を食う。Haas & Leis は IOPOLL 付き io_uring で、少数スレッドで 1250万 IOPS 近くに達したと報告。

### 4.5 テスト方針

* ファイルの代わりに tmpfs や小さいファイルで、4章のループに「全ページを1回ずつ読む」タスク 1000 個を流す。全タスクが完了し、内容が書き込んだものと一致すること。
* in-flight 上限を 1 にしても正しく動くこと (投入と刈り取りの順序の確認)。
* 書き込みの完了を待たずに同じページを再 fix するテスト。S ロックで止まること。

### 4.6 原典との違い・簡略化

* 【簡略化】 SSD 複数台への振り分け、スレッドごとの queue pair (SPDK) は省いた。
* 【簡略化】 libaio の場合は `io_submit` / `io_getevents(min_nr=0)` で同じループになる。

---

## 5. 参考資料

* Leis, Haubenschild, Kemper, Neumann. *LeanStore: In-Memory Data Management beyond Main Memory*. ICDE 2018. — swip、cooling stage (10%)、FIFO + ハッシュ表、子を先に unswizzle する規則、親ポインタ、エポック回収、I/O frame。
* Alhomssi, Haubenschild, Leis. *The Evolution of LeanStore*. BTW 2023. — 64 個のランダムなフレームでの second chance、swip の cool ビット、親ポインタの廃止 (findParent)、エポック回収の廃止、分割 I/O stage。
* Leis, Alhomssi, Ziegler, Loeck, Dietrich. *Virtual-Memory Assisted Buffer Management*. SIGMOD 2023. (vmcache) <https://github.com/viktorleis/vmcache>
* Graefe et al. *In-Memory Performance for Big Data*. VLDB 2015. — swizzling を使うバッファプール。
* Haas, Leis. *What Modern NVMe Storage Can Do, and How to Exploit It*. VLDB 2023. — libaio / io_uring / SPDK の比較、タスクと I/O 投入・刈り取りを交互に回すワーカーループ。
* Harizopoulos, Abadi, Madden, Stonebraker. *OLTP Through the Looking Glass, and What We Found There*. SIGMOD 2008. — バッファ管理が命令数の約3割。
* 参照した実装:
  * `viktorleis/vmcache: vmcache.cpp:PageState` (状態語), `BufferManager::fixX / fixS / handleFault / allocPage / evict`, `ResidentPageSet::insert / remove / iterateClockBatch`, `GuardO::init / checkVersionAndRestart`, `LibaioInterface::writePages`
  * `leanstore/leanstore: backend/leanstore/storage/buffer-manager/Swip.hpp:Swip` (ビット割り当て), `BufferFrame.hpp:BufferFrame::Header`, `BufferManager.cpp:BufferManager::resolveSwip`, `PageProviderThread.cpp` (cool / evict の2段階)
