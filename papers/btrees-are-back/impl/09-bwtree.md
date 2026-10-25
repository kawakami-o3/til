# 09. Bw-Tree (と OpenBw-Tree の改良)

background.md 4.2 の Bw-Tree を、自分で書けるように書き下す。
SMO (split / merge) の手順は、原典 (Levandoski et al. 2013) と OpenBw-Tree の実装 (wangziqi2013/BwTree) を突き合わせて書いた。**両者が違う箇所はコードに合わせ、違いを明記する**。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* README の「Rust 特有の注意点 / メモリ回収」に従い、回収は `crossbeam-epoch` で書く。
* 比較対象の「OLC の普通の B+-Tree」は [12-concurrency.md](12-concurrency.md)。

## 目次

1. [目的と論文との関係](#1-目的と論文との関係)
2. [データ配置](#2-データ配置)
3. [不変条件](#3-不変条件)
4. [走査 (traverse) と help-along](#4-走査-traverse-と-help-along)
5. [lookup](#5-lookup)
6. [insert / delete / update](#6-insert--delete--update)
7. [consolidation](#7-consolidation)
8. [split](#8-split)
9. [merge](#9-merge)
10. [メモリ回収 (epoch)](#10-メモリ回収-epoch)
11. [OpenBw-Tree の改良](#11-openbw-tree-の改良)
12. [範囲走査](#12-範囲走査)
13. [境界条件と落とし穴](#13-境界条件と落とし穴)
14. [テスト方針](#14-テスト方針)
15. [原典との違い・簡略化](#15-原典との違い簡略化)
16. [参考資料](#16-参考資料)

---

## 1. 目的と論文との関係

* Levandoski, Lomet, Sengupta (ICDE 2013)。**ラッチを一切使わない B+-Tree**。
* 3つの仕組み。
  * **mapping table**: 論理ページ ID (PID) → 物理ポインタ。ノード間のリンクはすべて PID。ノードの差し替えは mapping table の1エントリへの CAS 1回。
  * **delta chain**: ノードをその場で書き換えず、変更を表す delta record を先頭に付け足す。古い状態は不変。
  * **SMO を delta で表す**: split / merge も delta record の付け足しの列で行う。途中の状態を見たスレッドは、先にその SMO を完了させる (help-along)。
* OpenBw-Tree の検証 (Wang et al., SIGMOD 2018): 改良しても**ロックを使う他の並行索引 (比較対象は OLC の B+-Tree, OLC の ART, Masstree) に及ばない** (同論文の abstract)。mapping table の参照と delta chain の辿りでキャッシュミスが増えるため。
* 論文 (B-Trees Are Back) 8章: Bw-Tree の技法は論文の最適化とは独立 (直交) だが、メモリ上では OLC の B-Tree に劣ると後の研究が示した、とだけ触れる。**論文が OLC + 4 KiB ページを選ぶ根拠**。

## 2. データ配置

### 2.1 mapping table

```rust
type Pid = u64;
const INVALID_PID: Pid = 0;

struct MappingTable {
    slots: Box<[crossbeam_epoch::Atomic<Node>]>,   // 添字 = PID。巨大な仮想領域を予約して遅延確保 (11.4)
    next_pid: AtomicU64,
    free_pids: crossbeam_queue::SegQueue<Pid>,     // 回収済み PID (epoch を経てから戻す)
}
struct BwTree { map: MappingTable, root: AtomicU64 /* 根の PID */ }
```

* 根の PID は mapping table の外に別の原子変数で持つ (根の split で差し替えるため)。OpenBw-Tree の `root_id`。

### 2.2 ノード (base node と delta record)

1つの PID が指すのは「delta record の連結リスト + 末尾の base node」。これを**論理ノード**と呼ぶ。

```rust
/// 各要素 (base / delta) が持つ、その時点の論理ノードの属性 (OpenBw-Tree Table 1)。
/// delta を作るときに直前の要素から引き継ぎ、変わる項目だけ更新する。
#[derive(Clone)]
struct Meta {
    low_key: Bound<Vec<u8>>,     // この論理ノードのキーの下限 (含む)。左端は -∞
    high_key: Bound<Vec<u8>>,    // 上限 (含まない) = 右隣の low_key。右端は +∞
    right: Pid,                  // 右隣の PID (B-link の side link)。右端は INVALID
    depth: u16,                  // delta chain の長さ (base は 0)
    item_count: u32,             // 論理ノードの要素数
}

enum Node {
    // ---- base node (不変) ----
    LeafBase  { meta: Meta, items: Box<[(Vec<u8>, Vec<u8>)]> },   // キー昇順
    InnerBase { meta: Meta, items: Box<[(Vec<u8>, Pid)]> },       // items[0].0 = low_key (番兵)
    // ---- leaf delta ----
    LeafInsert { meta: Meta, key: Vec<u8>, val: Vec<u8>, offset: u32, next: *const Node },
    LeafDelete { meta: Meta, key: Vec<u8>, offset: u32, next: *const Node },
    // ---- inner delta ----
    InnerInsert { meta: Meta, item: (Vec<u8>, Pid), next_item: (Bound<Vec<u8>>, Pid),
                  offset: u32, next: *const Node },               // 「index entry delta」
    InnerDelete { meta: Meta, item: (Vec<u8>, Pid), prev_item: (Bound<Vec<u8>>, Pid),
                  next_item: (Bound<Vec<u8>>, Pid), offset: u32, next: *const Node },
    // ---- SMO delta (leaf / inner 共通) ----
    Split  { meta: Meta, split_item: (Vec<u8>, Pid), next: *const Node },   // meta.high_key = 分割キー
    Remove { removed: *const Node },                                       // この PID は消える
    Merge  { meta: Meta, merge_key: Vec<u8>, right_branch: *const Node,
             deleted: (Vec<u8>, Pid), next: *const Node },
    Abort  { next: *const Node },                                          // OpenBw-Tree: 親を一時的に塞ぐ
}
```

* `next` は**物理ポインタ** (同じ論理ノード内のリンク)。ノード間は必ず PID。
* `offset` (OpenBw-Tree): そのキーが base node のどの位置に入る/あるか。11.2, 11.3 で使う。
* 内部ノードの意味: `items[i] = (k_i, child_i)` で、`child_i` は `[k_i, k_{i+1})` を受け持つ。`items[0].0` は low_key で、比較には使わない。
  (03 の CSB+ とは逆の「左端キー」方式。OpenBw-Tree に合わせた。)

```
mapping table                      論理ノード P
 PID ─┬─ ...
      ├─ P ──► [Insert k=7] ──► [Delete k=3] ──► [Split sep=20, →Q] ──► [LeafBase 1 3 5 20 25]
      │          meta(depth=3)     meta(depth=2)    meta(high=20,right=Q)   meta(high=+∞)
      └─ Q ──► [LeafBase 20 25]    (Split の時点で Q はもう mapping table にある)
```

* 原典は Rust の enum ではなく、型タグ付きの C++ クラス階層。Rust では enum + `Box` で十分 (11.1 の事前確保をしない場合)。

## 3. 不変条件

* base node と、mapping table に一度載った delta record は**二度と書き換えない**。
* 各要素の `meta` は、その要素を先頭とした論理ノードの属性と一致する。
* 同じレベルの論理ノードを `right` で辿ると、`[low_key, high_key)` が隙間も重なりもなく並ぶ (`n.high_key == right(n).low_key`)。
* キー k を受け持つ葉は常に1つ。親の index entry がまだ無くても、左の兄弟から `right` で辿れる (B-link の性質)。
* delta chain の長さは `depth` と一致し、consolidation でいずれ 0 に戻る。
* epoch に pin しているスレッドが見たポインタは、そのスレッドが unpin するまで解放されない。

## 4. 走査 (traverse) と help-along

OpenBw-Tree の `Traverse` / `LoadNodeID` / `JumpToNodeID` / `NavigateSiblingChain` を整理したもの。
**ノードを1つ読み込むたびに「未完了の SMO を助ける → consolidation を試す → 大きさを調整 (split / merge を始める)」を行う**。どこかで CAS に失敗したら、**根からやり直す** (abort)。

```rust
struct Snapshot { pid: Pid, ptr: *const Node }
struct Ctx { key: Vec<u8>, path: Vec<Snapshot>, abort: bool }   // path の末尾 = 今のノード、その手前 = 親

/// key を含む葉までの経路を作る。abort なら Err。
fn traverse(t: &BwTree, ctx: &mut Ctx, g: &Guard) -> Result<(), Abort> {
    ctx.path.clear();
    load(t, ctx, t.root.load(Acquire), g)?;
    loop {
        move_right(t, ctx, g)?;                         // key >= high_key なら右へ
        let top = ctx.path.last().unwrap();
        if is_leaf(top.ptr) { return Ok(()); }
        let child = navigate_inner(top.ptr, &ctx.key);  // 5.2
        load(t, ctx, child, g)?;
    }
}

fn load(t: &BwTree, ctx: &mut Ctx, pid: Pid, g: &Guard) -> Result<(), Abort> {
    ctx.path.push(Snapshot { pid, ptr: t.map.get(pid, g) });   // Acquire で読む
    finish_partial_smo(t, ctx, g)?;                     // 4.1
    try_consolidate(t, ctx, g);                         // 7. 失敗しても abort しない
    adjust_node_size(t, ctx, g)?;                       // 8, 9. SMO を始めたら abort して根から
    Ok(())
}

fn move_right(t: &BwTree, ctx: &mut Ctx, g: &Guard) -> Result<(), Abort> {
    loop {
        let m = meta_of(ctx.path.last().unwrap().ptr);
        if m.right != INVALID_PID && ctx.key.as_slice() >= m.high_key.as_ref() {
            let pid = m.right;
            ctx.path.pop();                              // 同じ段の別ノードに置き換える
            load(t, ctx, pid, g)?;                        // ここでも help-along が走る
        } else { return Ok(()); }
    }
}
```

* 右へ移るのは、split の後に親の index entry がまだ無いとき。B-link の右移動。
* 移った先の Split delta が未完了なら、その場で 4.1 が親への index entry を代わりに投稿する。

### 4.1 help-along (FinishPartialSMO)

論理ノードの**先頭の要素**だけを見て、未完了の SMO を完了させる。

```rust
fn finish_partial_smo(t: &BwTree, ctx: &mut Ctx, g: &Guard) -> Result<(), Abort> {
    let mut top = ctx.path.last_mut().unwrap();
    let mut head = top.ptr;
    if let Node::Abort { next } = deref(head) {
        top.ptr = *next;                 // Abort の下を「今の状態」として扱う。
        head = *next;                    // ptr が mapping table と食い違うので、この上への CAS は必ず失敗する
    }
    match deref(head) {
        Node::Remove { removed } => {
            // (merge 1/2) 削除中の R を見た → 左隣 L に Merge delta を付ける
            let r_pid = top.pid;
            let right_branch = *removed;
            jump_to_left_sibling(t, ctx, g)?;            // 親から L を探す。L.right == R でなければ abort
            let l = ctx.path.last().unwrap();
            let merge = Node::Merge {
                meta: meta_merged(l.ptr, right_branch),  // high_key, right, item_count を R のものに
                merge_key: meta_of(l.ptr).high_key.clone().unwrap(),   // = R.low_key
                right_branch,
                deleted: (meta_of(right_branch).low_key.clone().unwrap(), r_pid),
                next: l.ptr,
            };
            let new = cas_install(t, l.pid, l.ptr, merge, g).map_err(|_| Abort)?;
            ctx.path.last_mut().unwrap().ptr = new;
            post_parent_delete(t, ctx, g)                // そのまま (merge 2/2) へ
        }
        Node::Merge { .. } => post_parent_delete(t, ctx, g),
        Node::Split { split_item, .. } => {
            if ctx.path.len() == 1 { return split_root(t, ctx, g); }   // 根の split
            let parent = &ctx.path[ctx.path.len() - 2];
            if parent.ptr != t.map.get(parent.pid, g) { return Err(Abort); }   // 親が変わった
            let pm = meta_of(parent.ptr);
            // 分割キーが親の範囲外なら、親も既に split されていて担当は右の親。何もしない
            if pm.right != INVALID_PID && split_item.0.as_slice() >= pm.high_key.as_ref() { return Ok(()); }
            match find_in_inner(parent.ptr, &split_item.0) {
                Some(pid) if pid == split_item.1 => Ok(()),        // もう投稿済み
                Some(_) => Err(Abort),                             // 同じキーで別 PID: 古い経路を見ている
                None => post_inner_insert(t, parent, split_item.clone(),
                                          /* next_item = */ high_key_pair_of(head), g)
                            .map_err(|_| Abort),          // CAS 負けは abort (下の注を参照)
            }
        }
        _ => Ok(()),
    }
}
```

* 親への投稿 (`post_inner_insert`, `post_parent_delete`) の CAS に負けたら **abort して根からやり直す** (OpenBw-Tree の `PostInnerInsertNode` / `PostInnerDeleteNode` も失敗時に `abort_flag` を立てる)。
  abort せずに進むと、直後の `try_consolidate` や自分の insert の delta が Split / Merge delta を覆ってしまい、親への手順が永久に抜け落ちる。
  * Split の場合: 親に Q の entry が入らない。side link で検索はできるが、親と子の対応が崩れ、後の Q の merge が誤った親を見る。
  * Merge の場合: 親に R の entry が残り続け、R を訪れたスレッドが「Remove を見る → L へ → `L.right != R` で abort」を無限に繰り返す (livelock)。
* 原典 2013 も「未完了の SMO を見たスレッドは、自分の操作の前にそれを完了させる」と書く。どの delta をどの順で助けるかの具体は OpenBw-Tree のコードに従った。

## 5. lookup

### 5.1 葉の delta chain を辿る (キー一意の場合)

```rust
// deref(p: *const Node) -> &Node は生ポインタの参照外し (unsafe)。
// epoch に pin している間だけ有効な参照なので、guard より長く持たないこと。
fn leaf_search(mut n: *const Node, key: &[u8]) -> Option<Vec<u8>> {
    loop {
        match deref(n) {
            Node::LeafInsert { key: k, val, next, .. } => { if k == key { return Some(val.clone()); } n = *next; }
            Node::LeafDelete { key: k, next, .. }      => { if k == key { return None; } n = *next; }
            Node::Split { next, .. }                   => n = *next,   // 範囲は move_right で確認済み
            Node::Merge { merge_key, right_branch, next, .. } =>
                n = if key >= merge_key.as_slice() { *right_branch } else { *next },   // 木として辿る
            Node::LeafBase { items, .. } =>
                return items.binary_search_by(|e| e.0.as_slice().cmp(key)).ok().map(|i| items[i].1.clone()),
            Node::Abort { next } => n = *next,
            Node::Remove { .. } => unreachable!("traverse で help-along 済み"),
            _ => unreachable!(),
        }
    }
}
```

* **最初に見つかった delta が答え** (新しい順に並んでいるため)。Delete なら「なし」。
* Merge delta から先は**連結リストではなく木**になる (左の旧状態と、右から吸収した R の旧状態)。

### 5.2 内部ノードの delta chain を辿る

```rust
fn navigate_inner(mut n: *const Node, key: &[u8]) -> Pid {
    loop {
        match deref(n) {
            Node::InnerInsert { item, next_item, next, .. } => {
                // item.0 <= key < next_item.0 なら即決 (原典の「KP < v <= KQ で即座に下りる」)
                if key >= item.0.as_slice() && below(key, &next_item.0) { return item.1; }
                n = *next;
            }
            Node::InnerDelete { prev_item, next_item, next, .. } => {
                // 消えた区間は左隣 (prev) に吸収された: prev.0 <= key < next.0 なら prev へ
                if above_or_eq(key, &prev_item.0) && below(key, &next_item.0) { return prev_item.1; }
                n = *next;
            }
            Node::Merge { merge_key, right_branch, next, .. } =>
                n = if key >= merge_key.as_slice() { *right_branch } else { *next },
            Node::Split { next, .. } | Node::Abort { next } => n = *next,
            Node::InnerBase { items, .. } => {
                // key 以下で最大の items[i].0 (i >= 1)。なければ items[0]
                let i = items[1..].partition_point(|e| e.0.as_slice() <= key);
                return items[i].1;
            }
            _ => unreachable!(),
        }
    }
}
```

* `prev_item.0` が `-∞` (論理ノードの low_key 側の番兵) のときは常に条件を満たす。OpenBw-Tree は「`prev_item` の PID が論理ノードの最左の子か」で判定している。

### 5.3 木全体

```rust
fn lookup(t: &BwTree, key: &[u8]) -> Option<Vec<u8>> {
    let g = crossbeam_epoch::pin();
    loop {
        let mut ctx = Ctx::new(key);
        if traverse(t, &mut ctx, &g).is_err() { continue; }       // abort: 根から
        return leaf_search(ctx.path.last().unwrap().ptr, key);
    }
}
```

* 読み取りは CAS をしないので、help-along と consolidation を除けば失敗しない。OpenBw-Tree には SMO を助けない読み取り専用の経路 (`TraverseReadOptimized`) もある。

## 6. insert / delete / update

```rust
fn insert(t: &BwTree, key: &[u8], val: &[u8]) -> bool {
    let g = crossbeam_epoch::pin();
    loop {
        let mut ctx = Ctx::new(key);
        if traverse(t, &mut ctx, &g).is_err() { continue; }
        let leaf = ctx.path.last().unwrap();
        if leaf_search(leaf.ptr, key).is_some() { return false; }   // 一意キー: 既にある
        let m = meta_of(leaf.ptr);
        let d = Node::LeafInsert {
            meta: Meta { depth: m.depth + 1, item_count: m.item_count + 1, ..m.clone() },
            key: key.to_vec(), val: val.to_vec(),
            offset: offset_in_base(leaf.ptr, key), next: leaf.ptr,
        };
        match cas_install(t, leaf.pid, leaf.ptr, d, &g) {
            Ok(_) => return true,
            Err(_) => continue,          // 他スレッドが先に付け足した: 根からやり直し
        }
    }
}

/// mapping table の CAS。成功したら新しい先頭を返す。失敗したら作った delta は捨てる (誰にも見えていない)。
fn cas_install(t: &BwTree, pid: Pid, expected: *const Node, new: Node, g: &Guard) -> Result<*const Node, ()> {
    let new = Owned::new(new);
    t.map.slots[pid as usize]
        .compare_exchange(Shared::from(expected), new, AcqRel, Acquire, g)
        .map(|s| s.as_raw()).map_err(|_| ())
}
```

* delete は `LeafDelete` (キーがなければ false)。update は「Delete + Insert」として扱うか、値だけ持つ update delta を足す。OpenBw-Tree は update を「古い値の delete + 新しい値の insert」として解釈する。
* **CAS の expected は traverse で読んだポインタ**。その間に誰かが delta を足していれば CAS は失敗する。キーの存在確認と CAS の間に割り込まれても、失敗して根からやり直すので正しい。
* 原典は CAS 失敗時の再試行の範囲を操作ごとに決めるとしている。OpenBw-Tree は**常に根から**やり直す (実装が単純で、辿ったノードはキャッシュに残っているため)。

## 7. consolidation

```rust
fn try_consolidate(t: &BwTree, ctx: &mut Ctx, g: &Guard) {
    let top = ctx.path.last_mut().unwrap();
    if !is_delta(top.ptr) { return; }
    let thr = if is_leaf(top.ptr) { 8 } else { 8 };              // OpenBw-Tree の既定 (葉・内部とも 8)
    if (meta_of(top.ptr).depth as usize) < thr { return; }
    let base = replay(top.ptr);                                   // 新しい base node を作る
    if let Ok(new) = cas_install(t, top.pid, top.ptr, base, g) {
        unsafe { g.defer_unchecked(move || free_chain(top.ptr)) };  // 古い chain 全体を回収待ちに
        top.ptr = new;
    }                                                             // 失敗: 作った base を捨てて何もしない
}
```

`replay` (葉の場合):

1. chain を先頭から辿り、Insert / Delete を `HashMap<key, Option<val>>` に**最初に見た方だけ**記録する (新しい順なので、最初が最新)。
2. Split delta があれば、その `high_key` 以上のキーは捨てる (右の兄弟に移っている)。最初に見た Split の `high_key` が有効。
3. Merge delta があれば、`right_branch` 側も再帰的に replay して結合する。
4. base node の要素のうち、1 で記録されていないキーを残す。1 の Insert を加える。ソートする。
5. `meta` は先頭の要素のものをそのまま使い、`depth = 0`。

* 内部ノードも同じ (InnerInsert / InnerDelete を適用)。
* **consolidation は Split / Merge を「畳み込む」**。Split の後の consolidation で、左のノードは分割キー未満だけになる (原典)。
* CAS に失敗したら**再試行しない**。後で誰かがまた consolidation する (原典)。
* 解放するのは「古い先頭から base までの chain」。Merge delta の `right_branch` (R の旧状態) も、この時点で L の chain の一部として一緒に解放する (原典「R の状態は L の consolidation で回収される」)。
  **R の PID と Remove delta の回収も、この同じ回収予約で行う** (OpenBw-Tree は Merge delta に R の PID を記録し、Merge delta の回収時に PID も回収する)。
  理由: L が consolidation されるまでは、L の Merge delta を見たスレッドが親で `(merge_key, R の PID)` を探しに行く。それより先に R の PID を再利用すると、同じキー・同じ PID の別の entry (例: L がそのキーで再び split した) を誤って消しうる。
* **親への手順が済んでいない Split / Merge delta を consolidation で畳み込まない**。4.1 で abort を徹底すれば、consolidation の時点で先頭の SMO delta は必ず親への投稿が済んでいる (help-along は consolidation より先に走り、失敗すれば abort するため)。

## 8. split

### 8.1 開始 (AdjustNodeSize)

OpenBw-Tree では、`load` のたびに**base node (delta のない状態) のときだけ**大きさを見る。delta が付いていれば何もしない (先に consolidation される)。

```rust
fn start_split(t: &BwTree, ctx: &mut Ctx, g: &Guard) -> Result<(), Abort> {
    let top = ctx.path.last().unwrap();
    let base = top.ptr;                                  // delta なしの base node
    // 1) 右半分の新しい base node Q を作る (low_key = 分割キー, high_key / right = P のもの)
    let (sep, q_node) = make_split_sibling(base)?;       // 分割点が見つからなければ何もしない
    // 内部ノード: Q の最左の子が Remove 中なら split しない (merge と競合するため)
    let q_pid = t.map.alloc_pid();
    t.map.store(q_pid, q_node);                          // 2) CAS なしで mapping table に置く (まだ誰からも見えない)
    let split = Node::Split {
        meta: Meta { high_key: Excluded(sep.clone()), right: q_pid,
                     item_count: left_count, depth: 1, ..meta_of(base).clone() },
        split_item: (sep, q_pid), next: base,
    };
    match cas_install(t, top.pid, base, split, g) {      // 3) P に Split delta を CAS (半分の split = 完了点)
        Ok(_) => Err(Abort),                             //    成功しても abort して根から (help-along に任せる)
        Err(_) => { retire_pid_and_node(q_pid, g); Err(Abort) }   // 失敗: Q の PID とノードを回収
    }
}
```

* 閾値 (OpenBw-Tree 既定): 要素数 128 以上で split、32 以下で merge (葉・内部とも)。
* 葉の分割点は、同じキーが左右にまたがらないように選ぶ (非一意キー対応のため)。一意キーなら中央でよい。

### 8.2 親への index entry (4.1 の Split 分岐)

* 次に P (または右移動で Q) を通ったスレッドが、親 O に `InnerInsert { item: (sep, Q), next_item: P の旧 high_key と right }` を CAS で付ける。
* `next_item` は**Split delta の下にある base の high_key** (= 分割前の P の high_key)。これで `sep <= key < 旧 high_key` の検索は親の delta だけで Q に直行できる。
* 投稿前に「親にもう同じ (sep, Q) があるか」「sep が親の範囲内か」を確かめる (4.1)。二重投稿を避けるため。

### 8.3 根の split

```rust
fn split_root(t: &BwTree, ctx: &mut Ctx, g: &Guard) -> Result<(), Abort> {
    let top = ctx.path.last().unwrap();
    let Node::Split { split_item, .. } = deref(top.ptr) else { unreachable!() };
    let new_root = Node::InnerBase {
        meta: Meta { low_key: Unbounded, high_key: Unbounded, right: INVALID_PID, depth: 0, item_count: 2 },
        items: vec![(Vec::new() /* -∞ 番兵 */, top.pid), split_item.clone()].into(),
    };
    let pid = t.map.alloc_pid();
    t.map.store(pid, new_root);
    match t.root.compare_exchange(top.pid, pid, AcqRel, Acquire) {
        Ok(_) => Err(Abort),                             // 新しい根から辿り直す
        Err(_) => { retire_pid_and_node(pid, g); Err(Abort) }
    }
}
```

### 8.4 順序の確認 (原典との対応)

| 手順 | 原典 2013 | OpenBw-Tree コード |
|---|---|---|
| Q を作り mapping table へ | CAS なしで設置 | `InstallNewNode` (同じ) |
| P に Split delta | CAS (half split) | `InstallNodeToReplace` (同じ) |
| 親に index entry delta | split したスレッドがすぐ投稿 (経路を覚えている) | split したスレッドは **abort して根から**。次に通ったスレッド (自分を含む) が `FinishPartialSMO` で投稿 |
| 親が消えていたら | 祖父母から辿り直す | 親の snapshot が mapping table と違えば abort → 根から |

## 9. merge

原典の3手順 (Remove → Merge → 親の Delete) に、OpenBw-Tree は**親を一時的に塞ぐ Abort delta** を加えている。

### 9.1 開始 (AdjustNodeSize の merge 側)

```rust
fn start_remove(t: &BwTree, ctx: &mut Ctx, g: &Guard) -> Result<(), Abort> {
    // R = 今のノード (base node, 要素数 <= 32)。根と「親の最左の子」は消さない
    if ctx.path.len() == 1 || is_leftmost_child(ctx) { return Ok(()); }
    let r = ctx.path.last().unwrap();
    let parent = &ctx.path[ctx.path.len() - 2];
    // 1) 親に Abort delta を CAS。親への他の CAS (index entry の投稿など) を一時的に全部失敗させる
    let abort = cas_install(t, parent.pid, parent.ptr, Node::Abort { next: parent.ptr }, g)
        .map_err(|_| Abort)?;
    // 2) R に Remove delta を CAS。以後 R は使われない
    let ok = cas_install(t, r.pid, r.ptr, Node::Remove { removed: r.ptr }, g).is_ok();
    // 3) 親の Abort を外す (自分しか外さないので必ず成功する)。Abort ノードは epoch 経由で回収
    t.map.store_cas_must_succeed(parent.pid, abort, parent.ptr);
    unsafe { g.defer_destroy_single(abort) };
    let _ = ok;
    Err(Abort)                                           // 成否によらず根からやり直す
}
```

* Abort を置く理由 (コードのコメントからの解釈): Remove を置く判断 (最左の子でない、親が split 途中でない) を下した時点の親の状態を、Remove の設置まで固定するため。親が同時に「R の位置で split」されると、Merge の相手 (左隣) が別の親の下に行ってしまう。【未検証】原典 2013 には Abort delta はない。
* Abort が付いている間、他のスレッドは 4.1 で Abort の下を「今の状態」として読む。そのポインタは mapping table と一致しないので、親への CAS は必ず失敗し、abort → 根から再試行になる。

### 9.2 Merge delta と親の Delete (help-along)

4.1 の `Remove` / `Merge` 分岐がこれを担う。誰でも完了させられる。

1. R の Remove を見たスレッドは、親の中で R の low_key の左隣の子 L を探す (`jump_to_left_sibling`)。`L.right != R` なら abort。
2. L に `Merge { merge_key = L.high_key (= R.low_key), right_branch = R の旧状態, deleted = (R.low_key, R) }` を CAS。L の `meta` の high_key と right を R のものに広げる。
3. L の Merge を見たスレッドは、親の最新状態を確認し (mapping table と一致しなければ abort)、親にまだ `(R.low_key, R)` があれば `InnerDelete { item: (R.low_key, R), prev_item: (L.low_key, L), next_item: (R.high_key, R.right) }` を CAS。
4. R の PID と Remove delta は、親の InnerDelete の直後ではなく、**L の chain (Merge delta を含む) を回収するときに一緒に**回収する (7 の注、OpenBw-Tree と同じ)。

* 原典 2013: 「L 自体が削除中なら、先に L の削除を完了させてから R の削除を進める」。SMO が積み重なることがあるが稀。OpenBw-Tree では、L が Remove 中なら L の help-along が先に走り、R 側は abort して根からやり直す形になる。
* 内部ノードの merge も同じ手順。merge 後の L の子の範囲が広がるだけ。

## 10. メモリ回収 (epoch)

### 10.1 何を、いつ回収するか

| 対象 | 回収を予約する時点 |
|---|---|
| 古い delta chain + base | consolidation の CAS 成功後 |
| CAS に失敗した delta | すぐ解放してよい (誰にも見えていない) |
| split に失敗した Q と PID | Split の CAS 失敗後 (Q は mapping table に置いたので、誰かが PID を読んだ可能性がある) |
| R の旧状態 | L の consolidation のとき (L の chain の一部として) |
| R の Remove delta と PID | L の chain (Merge delta を含む) の回収と同時 |
| 親に置いた Abort delta | 外した直後 (他スレッドが snapshot に持っているかもしれない) |

### 10.2 crossbeam-epoch での書き方

```rust
use crossbeam_epoch::{self as epoch, Atomic, Owned, Shared, Guard};

// 操作の最初に pin し、操作が終わるまで guard を持つ
let g = epoch::pin();
// ... traverse, CAS ...
// 古い chain を回収予約。chain を辿って Box を全部落とすクロージャを渡す
unsafe { g.defer_unchecked(move || free_chain(old_head)); }
// PID の再利用も epoch の後にする (古い PID を読んだスレッドがいなくなってから)
unsafe { g.defer_unchecked(move || tree.map.free_pids.push(pid)); }
```

* `free_chain` は先頭から `next` を辿って各要素を解放する。Merge delta に出会ったら `right_branch` 側も辿り、さらに Merge delta に記録した R の PID を free リストへ戻し、R の Remove delta も解放する。
* **ABA がない理由**: mapping table の CAS はポインタを比べる。epoch のおかげで、誰かが古いポインタを持っている間はそのメモリが再利用されないので、同じアドレスの別ノードと取り違えない。
* 長時間 pin し続けると回収が止まる。範囲走査は「1件ごと」や「1ノードごと」に pin し直す (原典も「次の1件」を1単位にしている)。

### 10.3 原典と OpenBw-Tree の GC

* 原典 2013: 中央集権の epoch。スレッドは現在の epoch に参加 (カウンタを増やす) し、抜けるときに減らす。カウンタが 0 になった epoch のゴミを回収する。
* OpenBw-Tree: **分散型**。グローバル epoch を背景スレッドが定期的に1増やす。各スレッドは操作の開始時にグローバル値を自分の `e_local` に写し、ゴミには作った時点のグローバル値を付けて自分のリストに積む。回収時は全スレッドの `e_local` の最小より古いゴミを解放する。共有メモリへの書き込みがないのでスケールする。
* `crossbeam-epoch` は後者に近い (スレッドごとの局所 epoch とゴミ袋、グローバル epoch は条件がそろえば進める)。**ここでは OpenBw-Tree 独自の GC を crossbeam-epoch で置き換えた**。

## 11. OpenBw-Tree の改良

### 11.1 delta record の事前確保

* base node を作るときに、**delta 数個分の領域を同じチャンクに確保**しておく。base node はチャンクの高位アドレス側に置き、delta は高位から低位へ詰める。
* 空きの管理は「チャンク先頭のマーカーを原子的に減算 (`fetch_sub`) して領域を取る」。
* delta chain を新しい順に辿ると、アドレスが低位 → 高位に進むことが多い。ハードウェアのプリフェッチが効く。ただし CAS の順と確保の順が入れ替わることがあるので、辿るときは必ず `next` ポインタに従う。
* 論文は「領域が満杯なら consolidation を起こす」と書いている。参照実装 (`AllocationMeta::TryAllocate, GrowChunk`) は、満杯なら**追加のチャンクを連結して**確保を続ける (チャンクは delta 8個分)。どちらで書いてもよい。
* チャンク単位で解放するので、10.1 の「chain の各要素を個別に解放」が「base のチャンク (+ 追加チャンク) を解放」に変わる。

### 11.2 fast consolidation

7 の replay の「全部集めてソート」を、base node の**区間の切り出し + 2-way マージ**に置き換える。

1. chain を辿って、有効な Insert の集合 `S_present` と Delete の集合 `S_deleted` を作る (新しい方が優先)。
2. base node の要素配列を、`offset` で区間に切る。最初は `[0, n)` の1区間。
   * Insert (offset o): 区間 `[s, e)` を `[s, o)` と `[o, e)` に割る。
   * Delete (offset o): `[s, e)` を `[s, o)` と `[o+1, e)` に割る (o の要素を飛ばす)。
   * base にない要素の Delete (前の Insert を取り消すもの) は無視する。
3. `S_present` を (offset, キー) でソートし、区間の列と2-way マージして新しい base を作る。

* `offset` は「その delta を base node に直接適用したらどこか」。delta を作るときに base を二分探索したならその結果、していなければ直前の delta の offset をコピーする (OpenBw-Tree の記述)。
* ソートするのは delta の数 (高々十数) だけなので速い。

### 11.3 node search shortcuts (micro-indexing)

* 葉や内部ノードを辿るとき、base node の二分探索の範囲 `[min, max)` を、chain 中の delta の `offset` で狭める。
  * delta のキー `K'` と探すキー `K` が等しい → 範囲は `[offset, offset]` で確定。
  * `K > K'` かつ `offset > min` → `min = offset`。
  * `K < K'` かつ `offset < max` → `max = offset`。
* 5.2 の `InnerInsert` / `InnerDelete` の分岐で `start_p` / `end_p` を狭めているのがこれ (`NavigateInnerNode`)。
* 大きな base node (128 要素) の二分探索の最初の数回のキャッシュミスを減らす。

### 11.4 mapping table の拡張

* 巨大な仮想領域を `mmap` で予約し、物理ページは OS に遅延確保させる。配列のままで伸ばせる (縮める方法はない)。00-primitives.md のページ単位確保を参照。

### 11.5 その他 (OpenBw-Tree が足した部品)

* **非一意キー**: 葉の chain を辿るとき、キー K について `S_present` と `S_deleted` (値の集合) を作り、`S_present ∪ (S_base − S_deleted)` を返す。最初の一致で止まらない。
* **iterator**: 葉の論理ノードを consolidation した**私的なコピー**を持って走査する (12節)。

## 12. 範囲走査

* 原典: 葉に着いたら、範囲内のレコードのベクタを作る。「次の1件」を返す前に、まだ返していない範囲に更新が入っていないか確かめ、入っていればベクタを作り直す。走査全体は原子的でない。
* OpenBw-Tree: 葉の論理ノードを replay した**読み取り専用のコピー**を持ち、その中を進む。使い切ったら、コピーの high_key を検索キーにして根から辿り直し、次の葉のコピーを作る (逆向きは low_key で)。
* Rust では、コピーを作る間だけ pin し、コピーを返したら unpin してよい (コピーは私有なので epoch の保護は要らない)。

## 13. 境界条件と落とし穴

* **Abort delta を consolidation しない**: Abort を先頭に持つノードを replay すると、型の取り違えで壊れる。4.1 で Abort の下に降りてから扱う。OpenBw-Tree もこのために Abort の回収を epoch に回している。
* **右移動の後の親**: `move_right` で右に移ると、`path` の親は「左の兄弟の親」のまま。split の index entry を投稿するときに範囲外になりうるので、4.1 の範囲チェックが要る。
* **split と merge の競合**: 内部ノードの split で、右半分の最左の子が Remove 中なら split しない (OpenBw-Tree)。Remove 中の子を親の境界に置くと、Merge の相手 (左隣) が別の親になる。
* **最左の子は merge しない**: 左隣が別の親にいるため。
* **item_count の更新**: Insert で +1、Delete で −1、Split で左の数に、Merge で左右の和に。重複キーの Insert (一意キーで既にある) を delta にしないこと。
* **CAS の expected**: 必ず「辿ったときに読んだポインタ」を使う。mapping table を読み直した値を使うと、その間の更新を上書きしてしまう。
* **メモリ順序**: mapping table の読みは `Acquire`、CAS は `AcqRel`。delta の中身は CAS の前に書き終えている (Owned を作った時点で確定) ので、Acquire で読めば見える。
* **PID の再利用**: epoch を経ずに PID を再利用すると、古い親の index entry 経由で無関係なノードに着く。
* **根の split と traverse**: 根の PID は `t.root` から毎回読み直す。abort 後に古い根の PID を使い続けない。
* **delta chain が長すぎる**: consolidation の CAS が負け続けると chain が伸びる。閾値は目安で、上限ではない。

## 14. テスト方針

* **単一スレッドのオラクル**: `BTreeMap` と比べるランダムテスト。閾値を極端に小さくする (split 4 要素、merge 1 要素、consolidation 2 delta) と、すべての SMO 経路を通る。
* **不変条件チェッカー** (静止状態で実行):
  * 各レベルを最左のノードから `right` で辿り、`high_key == 次の low_key`、各ノードのキーが範囲内、レベル全体でキーが昇順。
  * 親の index entry (replay 後) の各 `(k_i, child_i)` について `child_i.low_key == k_i`。
  * 各論理ノードの `meta.depth` が実際の chain 長、`item_count` が replay 後の要素数と一致。
  * mapping table から到達できない PID がすべて free リストか回収待ちにある (PID の漏れがない)。
* **並行ストレス (線形化可能性の近似)**:
  * スレッドごとにキー範囲を分けて insert / delete / lookup を流し、スレッドごとのオラクルと比べる。SMO は範囲の境界で他スレッドと干渉する。
  * 全スレッドで同じ小さいキー集合 (例: 64 キー) を奪い合う。一意キーの insert の成否 (true / false) と delete の成否を記録し、最後に「各キーについて成功した insert − 成功した delete ∈ {0, 1}」かつ最終状態と一致することを確かめる。
  * 読み取りスレッドは「単調に増えるキー列」を書くスレッドを見て、見えたキーが後で消えないこと (削除がない場合) を確かめる。
  * 履歴を記録して小規模に線形化可能性を検査するなら、[porcupine](https://github.com/anishathalye/porcupine) 相当の検査器を書く (オペレーション数百程度)。
* **メモリ安全性**: 単一スレッドのテストを Miri で走らせる (生ポインタと `defer` の誤用を検出)。並行テストは ThreadSanitizer (`-Zsanitizer=thread`) で。
* **故障注入**: `cas_install` に「確率 p で失敗したことにする」フックを入れ、abort 経路と help-along 経路を強制的に通す。

## 15. 原典との違い・簡略化

* SMO の手順は OpenBw-Tree のコードに合わせた。原典との主な違いは、(1) split したスレッドが親への投稿をせず abort すること、(2) merge の前に親へ Abort delta を置くこと、(3) 内部ノードの split で Remove 中の子を避けること。
* GC は OpenBw-Tree の分散型 epoch を `crossbeam-epoch` で置き換えた。
* 原典の LLAMA (キャッシュ層、log structured store、flush delta) と、トランザクションの LSN は扱わない。
* キーは一意とした。非一意キーは 11.5 の要約のみ。
* 事前確保 (11.1) を使わない書き方 (enum + Box) を基本にした。事前確保を入れると、回収の単位がチャンクになる。
* 閾値は OpenBw-Tree の既定値 (split 128 / merge 32 / chain 8)。原典は chain 長 8 がよいと報告している。

## 16. 参考資料

* Justin J. Levandoski, David B. Lomet, Sudipta Sengupta. *The Bw-Tree: A B-tree for New Hardware Platforms*. ICDE 2013. https://cse.buffalo.edu/~zzhao35/teaching/cse707_fall21/bwtree.pdf
  * III (delta, consolidation, range scan, epoch), IV-A (split), IV-B (merge), IV-C (SMO の直列化と help-along)。
* Ziqi Wang, Andrew Pavlo, Hyeontaek Lim, Viktor Leis, Huanchen Zhang, Michael Kaminsky, David G. Andersen. *Building a Bw-Tree Takes More Than Just Buzz Words*. SIGMOD 2018. https://db.cs.cmu.edu/papers/2018/mod342-wangA.pdf
  * 2 (Table 1 の属性、mapping table、SMO の概要), 3 (非一意キー, iterator, mapping table の拡張), 4 (事前確保, GC, fast consolidation, node search shortcuts)。
* Marcus Müller, Lawrence Benson, Viktor Leis. *B-Trees Are Back*. SIGMOD 2025. Section 8 (Bw-Tree)。
* 参照実装 [wangziqi2013/BwTree](https://github.com/wangziqi2013/BwTree) (OpenBw-Tree)
  * `src/bwtree.h:NodeType, NodeMetaData, LeafMergeNode, InnerInsertNode, InnerDeleteNode, InnerSplitNode`
  * `src/bwtree.h:LoadNodeID, JumpToNodeID, NavigateSiblingChain, NavigateInnerNode, JumpToLeftSibling`
  * `src/bwtree.h:FinishPartialSMO` (help-along: Remove → Merge → 親の Delete、Split → 親の Insert / 根の split)
  * `src/bwtree.h:AdjustNodeSize, PostAbortOnParent, RemoveAbortOnParent` (split / remove の開始)
  * `src/bwtree.h:TryConsolidateNode, ConsolidateNode, Insert`
  * `src/bwtree.h:AllocationMeta::TryAllocate, GrowChunk` (事前確保)
  * `src/bwtree.h:GCMetaData, EpochManager` (GC)
  * 閾値: `src/bwtree.h` 冒頭の `*_THRESHOLD` マクロ。
