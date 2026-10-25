# 10. LSM-tree

background.md 4.4 の LSM-tree を、自分で書けるように書き下す。
具体的な形式は LevelDB に合わせる (RocksDB もほぼ同じ形式を引き継いでいる)。

* 擬似コードの約束事と共通定義は [README.md](README.md) を参照。
* SSTable のデータブロックの中身 (差分圧縮 + restart point) は [02-key-encoding.md](02-key-encoding.md) の差分圧縮ブロックをそのまま使う。ここでは再説明しない。
* 単一プロセス・単一書き込みスレッドで書く。バックグラウンドの compaction スレッドとの同期は要約にとどめる。

## 目次

1. [目的と論文との関係](#1-目的と論文との関係)
2. [全体の構成](#2-全体の構成)
3. [内部キーと順序](#3-内部キーと順序)
4. [不変条件](#4-不変条件)
5. [書き込み経路: WAL と memtable](#5-書き込み経路-wal-と-memtable)
6. [SSTable の形式](#6-sstable-の形式)
7. [bloom filter](#7-bloom-filter)
8. [flush](#8-flush)
9. [点検索](#9-点検索)
10. [範囲走査 (k-way マージ)](#10-範囲走査-k-way-マージ)
11. [leveled compaction](#11-leveled-compaction)
12. [tiered compaction (対比)](#12-tiered-compaction-対比)
13. [論文の最適化を LSM に移す](#13-論文の最適化を-lsm-に移す)
14. [境界条件と落とし穴](#14-境界条件と落とし穴)
15. [テスト方針](#15-テスト方針)
16. [原典との違い・簡略化](#16-原典との違い簡略化)
17. [参考資料](#17-参考資料)

---

## 1. 目的と論文との関係

* O'Neil et al. (1996)。書き込みをメモリに溜め、**変更しないソート済みファイル (SSTable)** としてまとめて書き出す。ファイル同士は裏でマージ (compaction) する。
* B-Tree はその場で書き換える。LSM は追記だけ。書き込みは速いが、読み出しは複数のファイルを見る必要がある。
* 論文 8章は「論文の最適化の多くは、差分圧縮を使う LSM にもよく移る」と述べ、項目ごとに見積もりを書いている (13節)。
* 論文自身は LSM を実装していない。13節の LSM への応用は**論文の見通しであって、実測ではない**。

## 2. 全体の構成

```
 put/delete
    │
    ├──► WAL (追記のみのログファイル)            ← クラッシュ時の復元用
    │
    ▼
 memtable (可変、ソート済み)  ──満杯──►  immutable memtable  ──flush──►  L0 の SSTable
                                                                          │
 L0:  [sst][sst][sst][sst]      ← ファイル同士の範囲が重なってよい         │
 L1:  [sst|sst|sst|sst]         ← 範囲は重ならない、合計 10 MiB 目安     ◄──┘ compaction
 L2:  [sst|sst|...........]     ← 合計 100 MiB 目安
 ...  (各段 10 倍)
```

* **memtable**: 書き込みを受けるメモリ上のソート済み構造。LevelDB はスキップリスト。Rust で書くなら `BTreeMap<InternalKey, Value>` で十分 (並行読み出しが要るなら `crossbeam-skiplist`)。
* **immutable memtable**: 満杯になった memtable。新しい memtable に切り替えたあと、裏で SSTable に書き出す。書き出しが終わるまで読み出しの対象に含める。
* **段 (level)**: LevelDB は 7 段 (L0〜L6)。
* **manifest**: どの段にどのファイルがあるかの記録。compaction のたびに差分 (VersionEdit) を追記する。ここでは「ファイル一覧をアトミックに差し替える」とだけ扱う。

## 3. 内部キーと順序

同じユーザーキーの複数の版を区別するため、ユーザーキーに**シーケンス番号**と**種類**を付ける。

```
internal_key = user_key ++ fixed64_le( (seq << 8) | type )
                           └ 8 B: 上位 56 ビットが seq、下位 8 ビットが type
type: 0 = Deletion (tombstone), 1 = Value
```

```rust
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ValueType { Deletion = 0, Value = 1 }

const MAX_SEQ: u64 = (1 << 56) - 1;

/// 内部キーの順序: ユーザーキー昇順 → seq 降順 (新しい版が先)。
fn cmp_internal(a: &[u8], b: &[u8]) -> Ordering {
    let (ua, ta) = a.split_at(a.len() - 8);
    let (ub, tb) = b.split_at(b.len() - 8);
    ua.cmp(ub).then_with(|| {
        let (na, nb) = (u64::from_le_bytes(ta.try_into().unwrap()),
                        u64::from_le_bytes(tb.try_into().unwrap()));
        nb.cmp(&na)                       // 大きい (新しい) 方が先
    })
}
```

* ユーザーキーは 02 の正規化済みバイト列を想定する (memcmp の順 = 論理的な順)。
* 検索用のキーは `user_key ++ pack(snapshot_seq, Value)`。`Value (1) > Deletion (0)` なので、同じ seq なら Value を先に並べる (= 検索キーはその seq の全版より前に来る)。LevelDB の `kValueTypeForSeek`。
* seq は書き込みごとに1つ増える。バッチは連番を連続して割り当てる。

## 4. 不変条件

* memtable と各 SSTable の中は内部キー順 (`cmp_internal`) で、重複なし。
* L1 以降の各段で、ファイルは `largest` 昇順に並び、範囲が重ならない (ユーザーキーで見ても重ならない。境界の扱いのため)。
* 上の段 (と L0 では新しいファイル) にある版ほど seq が大きい。同じユーザーキーについて、段を下るほど古い。
* 各ファイルの `smallest` / `largest` は実際の最小・最大の内部キー。
* bloom filter に偽陰性はない (入れたキーは必ず `key_may_match == true`)。
* `last_seq` は WAL に書かれた最大の seq 以上。

## 5. 書き込み経路: WAL と memtable

### 5.1 put / delete

```rust
fn write(db: &mut Db, batch: &[(ValueType, &[u8], &[u8])]) -> io::Result<()> {
    let first_seq = db.last_seq + 1;
    db.wal.add_record(&encode_batch(first_seq, batch))?;   // 1) WAL に追記
    if db.opts.sync { db.wal.sync()?; }                     //    fsync するかは設定次第
    for (i, &(t, k, v)) in batch.iter().enumerate() {
        db.mem.insert(make_internal_key(k, first_seq + i as u64, t), v.to_vec());   // 2) memtable
    }
    db.last_seq += batch.len() as u64;                      // 3) 読み出しに見えるようにする
    if db.mem.approx_bytes() >= db.opts.write_buffer_size { // 既定 4 MiB
        db.imm = Some(mem::take(&mut db.mem));              // 切り替え
        db.wal = Wal::create_new()?;                        // 新しい WAL
        schedule_flush(db);
    }
    Ok(())
}
```

* delete は `ValueType::Deletion` と空の値で memtable に入れる (**tombstone**)。キーを消すのではなく、「消した」という版を足す。
* バッチの形式 (LevelDB `write_batch.cc`): `seq: fixed64 | count: fixed32 | 各レコード (type: u8, key: varint 長 + バイト, value: varint 長 + バイト。Deletion は value なし)`。

### 5.2 WAL のレコード形式

```
ファイルは 32 KiB のブロックの列。各ブロックにレコード断片を詰める。
断片 = [crc32c: 4][len: 2][type: 1][payload: len]      ヘッダ 7 B
type: FULL=1, FIRST=2, MIDDLE=3, LAST=4
```

* 1つのレコードがブロックをまたぐときは FIRST / MIDDLE / LAST に分割する。
* ブロックの残りが 7 B 未満なら 0 で埋めて次のブロックへ。
* crc は type と payload にかかる (マスク付き。6.4 参照)。
* 再起動時は WAL を先頭から読み、壊れた断片 (crc 不一致、長さ超過) で読むのをやめる。読めたバッチを memtable に再適用し、`last_seq` を復元する。

## 6. SSTable の形式

### 6.1 全体

```
[data block 0][trailer] [data block 1][trailer] ... [filter block][trailer]
[metaindex block][trailer] [index block][trailer] [footer 48 B]
```

* **data block**: 内部キーと値のソート済みの列。02 の差分圧縮ブロック (restart 間隔 16 件)。目標サイズ 4 KiB (非圧縮で数える)。
* **filter block**: bloom filter (7節)。
* **metaindex block**: `"filter.<名前>" → filter block の BlockHandle`。
* **index block**: data block ごとに1エントリ。`区切りキー → BlockHandle`。index block も差分圧縮ブロック (LevelDB は restart 間隔 1)。
* **BlockHandle** = `(offset: varint64, size: varint64)`。最大 20 B。

### 6.2 data block の書き方 (TableBuilder)

```rust
struct TableBuilder {
    data: BlockBuilder,                 // 02 の差分圧縮ブロック
    index: BlockBuilder,
    filter: FilterBlockBuilder,
    last_key: Vec<u8>,
    pending_index: Option<BlockHandle>, // 直前に閉じた data block (区切りキー待ち)
    offset: u64,
}

fn add(tb: &mut TableBuilder, ikey: &[u8], val: &[u8]) {
    debug_assert!(tb.last_key.is_empty() || cmp_internal(ikey, &tb.last_key).is_gt());
    if let Some(h) = tb.pending_index.take() {
        // 区切りキー: last_key <= sep < ikey を満たす短いキー
        let sep = shortest_separator(&tb.last_key, ikey);
        tb.index.add(&sep, &h.encode());
    }
    tb.filter.add_key(user_key(ikey));               // filter にはユーザーキーを入れる
    tb.last_key = ikey.to_vec();
    tb.data.add(ikey, val);
    if tb.data.estimated_size() >= BLOCK_SIZE { flush_data_block(tb); }
}

fn flush_data_block(tb: &mut TableBuilder) {
    let h = write_block(tb, tb.data.finish());        // 6.4 の trailer 付きで書く
    tb.pending_index = Some(h);
    tb.filter.start_block(tb.offset);                 // 次の block の開始位置を filter に伝える
}
```

* **区切りキーを次の block の先頭キーを見てから決める**のがポイント。`shortest_separator(a, b)` は「a のユーザーキーと b のユーザーキーの最初に異なるバイトを1増やして、そこで切る」。切れなければ a のまま。
  ユーザーキーが短くなったら、末尾に `pack(MAX_SEQ, Value)` を付けて内部キーに戻す (同じユーザーキーの全版より前に来るように)。
* 最後の block は次のキーがないので `short_successor(last_key)` (最初の 0xff でないバイトを1増やして切る) を使う。
* これは 01 の suffix truncation と同じ発想。

### 6.3 footer

```
offset  size
0       ≤20   metaindex の BlockHandle (varint)
..      ≤20   index の BlockHandle (varint)
..            0 埋めで 40 B に揃える
40      8     magic = 0xdb4775248b80fb57 (fixed64 little endian)
合計 48 B
```

* 読み出しはファイル末尾 48 B を読む → magic を確認 → index block と metaindex block を読む → filter block を読む。index と filter はメモリに置いておく (table cache)。

### 6.4 block trailer

```
[block の中身][type: 1 B][crc: 4 B]           5 B
type: 0 = 無圧縮, 1 = Snappy
crc  = mask(crc32c(中身 ++ type))
mask(c) = ((c >> 15) | (c << 17)).wrapping_add(0xa282ead8)
```

* マスクするのは、crc を含むデータの crc を取ったときに偶然の一致が起きやすいのを避けるため。
* 現行の LevelDB は type 2 = Zstd も持つ。
* 圧縮結果が元の 7/8 未満 (12.5% 以上縮む) でなければ無圧縮で書く (LevelDB `table_builder.cc:WriteBlock`)。filter block は常に無圧縮。

## 7. bloom filter

### 7.1 理論

* m ビット、n 個のキー、k 個のハッシュ関数。偽陽性率 `p ≈ (1 - e^(-k n / m))^k`。
* 最適な k は `k = (m/n) · ln 2`。そのとき `p ≈ 0.6185^(m/n)`。
* 欲しい p から1キーあたりのビット数を逆算すると `m/n = -log2(p) / ln 2 ≈ 1.44 · log2(1/p)`。
  * 10 ビット/キー → k ≈ 7, p ≈ 0.8%。

### 7.2 構築と問い合わせ (LevelDB の方式)

```rust
fn k_from_bits(bits_per_key: usize) -> usize {
    ((bits_per_key as f64 * 0.69) as usize).clamp(1, 30)   // ln2 ≈ 0.69, 切り捨て
}

fn create_filter(keys: &[&[u8]], bits_per_key: usize, out: &mut Vec<u8>) {
    let k = k_from_bits(bits_per_key);
    let bits = (keys.len() * bits_per_key).max(64);          // 少数のキーで偽陽性が跳ねるのを防ぐ
    let bytes = (bits + 7) / 8;
    let bits = bytes * 8;
    let base = out.len();
    out.resize(base + bytes, 0);
    out.push(k as u8);                                       // 末尾 1 B に k を記録
    for key in keys {
        let mut h = hash32(key, 0xbc9f1d34);
        let delta = h.rotate_right(17);                      // double hashing の2本目
        for _ in 0..k {
            let pos = (h as usize) % bits;
            out[base + pos / 8] |= 1 << (pos % 8);
            h = h.wrapping_add(delta);
        }
    }
}

fn key_may_match(key: &[u8], filter: &[u8]) -> bool {
    if filter.len() < 2 { return false; }
    let bits = (filter.len() - 1) * 8;
    let k = filter[filter.len() - 1] as usize;
    if k > 30 { return true; }                               // 将来の形式のために予約。一致扱い
    let mut h = hash32(key, 0xbc9f1d34);
    let delta = h.rotate_right(17);
    for _ in 0..k {
        let pos = (h as usize) % bits;
        if filter[pos / 8] & (1 << (pos % 8)) == 0 { return false; }
        h = h.wrapping_add(delta);
    }
    true
}
```

* **double hashing** (Kirsch & Mitzenmacher): `h_i = h1 + i · h2`。ハッシュを1回計算するだけで k 本ぶんの位置が作れる。偽陽性率は独立な k 本とほぼ同じ。
* `hash32` は LevelDB 独自の murmur 風ハッシュ (`util/hash.cc:Hash`)。互換性が要らなければ何でもよい。
* k をフィルタ自身に記録するので、設定を変えても古いファイルを読める。

### 7.3 filter block の構造

```
[filter 0][filter 1]...[filter n-1][offset 0: u32]...[offset n-1: u32][offset 配列の開始: u32][base_lg: u8 = 11]
```

* data block の**ファイル内オフセット 2 KiB ごと**に1つのフィルタを作る。`filter_index = block_offset >> 11`。
* data block が 4 KiB なら、ほぼ「data block 1つにフィルタ1つ」になる。間の番号は空のフィルタ (オフセットだけ) で埋める。
* RocksDB は SSTable 全体で1つのフィルタ (full filter) が既定。【未検証】RocksDB のコードは読んでいない。

## 8. flush

```rust
fn flush(db: &mut Db) -> io::Result<()> {
    let imm = db.imm.as_ref().unwrap();
    let mut tb = TableBuilder::new(new_file_number(db));
    for (ikey, val) in imm.iter() { add(&mut tb, ikey, val); }   // 内部キー順。版も tombstone もそのまま
    let meta = tb.finish()?;                                       // smallest / largest 内部キーを記録
    fsync(meta.file)?;
    let level = pick_level_for_memtable_output(db, &meta);         // 通常 0
    db.versions.apply(edit_add_file(level, meta).set_log_number(db.wal.number))?;  // manifest に記録
    db.imm = None;
    delete_obsolete_wal(db);                                       // 古い WAL を消す
    Ok(())
}
```

* flush では版を捨てない (どのスナップショットが見ているか分からないので、捨てるのは compaction)。
  LevelDB は flush 時にも同じユーザーキーの古い版を残す。
* **L0 以外に直接置く最適化**: 新しいファイルが L0 と重ならず、L1 とも重ならず、L2 との重なりが小さければ、L1 や L2 に直接置く (`kMaxMemCompactLevel = 2`)。省略してもよい。
* 順序: SSTable を fsync → manifest に記録 → WAL を消す。逆にすると、クラッシュでデータが消える。

## 9. 点検索

```rust
fn get(db: &Db, user_key: &[u8], snapshot: u64) -> Option<Vec<u8>> {
    let lk = make_internal_key(user_key, snapshot, ValueType::Value);   // 検索キー
    // 1) memtable → 2) immutable memtable
    for m in [Some(&db.mem), db.imm.as_ref()].into_iter().flatten() {
        match m.seek_first_ge(&lk) {
            Some((ik, v)) if user_key_of(ik) == user_key => return found_or_deleted(ik, v),
            _ => {}
        }
    }
    // 3) L0: 範囲に user_key を含むファイルを新しい順に全部
    let mut l0: Vec<_> = db.version.files[0].iter()
        .filter(|f| f.smallest_user() <= user_key && user_key <= f.largest_user()).collect();
    l0.sort_by_key(|f| Reverse(f.number));                 // ファイル番号が大きい = 新しい
    for f in l0 {
        if let Some(r) = table_get(f, &lk, user_key) { return r; }
    }
    // 4) L1 以降: 各段で高々1ファイル (二分探索)
    for level in 1..NUM_LEVELS {
        let files = &db.version.files[level];
        let i = files.partition_point(|f| cmp_internal(&f.largest, &lk).is_lt());
        if i < files.len() && files[i].smallest_user() <= user_key {
            if let Some(r) = table_get(&files[i], &lk, user_key) { return r; }
        }
    }
    None
}

/// Some(Some(v)) = 見つかった, Some(None) = 削除済み (以降の段は見ない), None = このファイルにない
fn table_get(f: &FileMeta, lk: &[u8], user_key: &[u8]) -> Option<Option<Vec<u8>>> {
    let t = table_cache_open(f);
    let h = t.index.seek_first_ge(lk)?;                   // 区切りキー >= lk の最初の block
    if !t.filter_for_block(h.offset).key_may_match(user_key) { return None; }   // bloom で読み飛ばし
    let blk = t.read_block(h);                            // ここで初めて data block を読む (I/O)
    let (ik, v) = blk.seek_first_ge(lk)?;                 // 02 の restart 二分探索 + 前方へ展開
    (user_key_of(ik) == user_key).then(|| found_or_deleted(ik, v))
}
```

* **最初に見つかった版で止まる**。上の段ほど新しいので、それが答え。tombstone なら「なし」で止まる (下の段の古い値を返してはいけない)。
* bloom filter の問い合わせはメモリ上だけで済む。偽陽性のときだけ無駄な data block の読み出しが起きる。
* 検索キーの seq に `snapshot` を入れることで、それより新しい版を飛ばせる (`seek_first_ge` が自然に飛ばす)。

## 10. 範囲走査 (k-way マージ)

### 10.1 構成

```
DbIter (ユーザーに見せる: 版と tombstone を畳む)
  └ MergingIter (k-way マージ: 内部キー順)
       ├ memtable の iter
       ├ immutable memtable の iter
       ├ L0 の各ファイルの iter (ファイルごとに1本)
       └ L1.. の段ごとの iter (段の中はファイルを順につなぐ "concatenating iter")
             └ TwoLevelIter: index block の iter → data block の iter
```

### 10.2 MergingIter

```rust
struct MergingIter { children: Vec<Box<dyn InternalIter>>, heap: BinaryHeap<Reverse<HeapEntry>> }
// HeapEntry は (現在の内部キー, 子の番号)。cmp_internal で比較する。

fn seek(mi: &mut MergingIter, target: &[u8]) {
    mi.heap.clear();
    for (i, c) in mi.children.iter_mut().enumerate() {
        c.seek(target);
        if c.valid() { mi.heap.push(Reverse(HeapEntry::new(c.key(), i))); }
    }
}

fn next(mi: &mut MergingIter) {
    let Reverse(top) = mi.heap.pop().unwrap();
    let c = &mut mi.children[top.child];
    c.next();
    if c.valid() { mi.heap.push(Reverse(HeapEntry::new(c.key(), top.child))); }
}
```

* 子の数は高々十数本 (L0 のファイル数 + 段数 + 2) なので、LevelDB は二分ヒープではなく**線形に最小を探している** (`table/merger.cc`)。どちらでもよい。
* 同じ内部キーは2つの子に同時に現れない (seq が一意なので)。

### 10.3 DbIter (版と tombstone を畳む)

```rust
/// 内部キー順の列から、snapshot 時点で見えるユーザーキーごとの最新版だけを返す。
fn find_next_user_entry(it: &mut DbIter, mut skipping: bool, skip: &mut Vec<u8>) {
    while it.inner.valid() {
        let (uk, seq, t) = parse_internal_key(it.inner.key());
        if seq <= it.snapshot {
            match t {
                ValueType::Deletion => { skip.clear(); skip.extend_from_slice(uk); skipping = true; }
                ValueType::Value => {
                    if !(skipping && uk <= skip.as_slice()) { it.valid = true; return; }  // 見せる
                }
            }
        }
        it.inner.next();
    }
    it.valid = false;
}

fn db_next(it: &mut DbIter) {
    let mut skip = user_key_of(it.inner.key()).to_vec();   // 今返したキーの古い版は飛ばす
    it.inner.next();
    find_next_user_entry(it, true, &mut skip);
}
```

* 同じユーザーキーの版は seq 降順に並ぶので、**最初に出会った (snapshot 以下の) 版**が答え。それが tombstone なら、そのユーザーキーの残りの版を全部飛ばす。
* 逆向き (Prev) は LevelDB でも別の手順が要る (同じユーザーキーの版を全部読んでから最新を決める)。ここでは省略する。

## 11. leveled compaction

### 11.1 どの段を compaction するか (スコア)

```rust
fn compute_score(v: &Version) -> (usize, f64) {
    let mut best = (0, -1.0);
    for level in 0..NUM_LEVELS - 1 {
        let score = if level == 0 {
            v.files[0].len() as f64 / L0_COMPACTION_TRIGGER as f64   // 4 ファイル
        } else {
            total_bytes(&v.files[level]) as f64 / max_bytes_for_level(level)
        };
        if score > best.1 { best = (level, score); }
    }
    best                                     // score >= 1 なら compaction する
}

fn max_bytes_for_level(level: usize) -> f64 { 10.0 * 1048576.0 * 10f64.powi(level as i32 - 1) }  // L1 = 10 MiB, 以降 10 倍
```

* L0 はファイル数で判定する。L0 のファイルは互いに重なるので、点検索で全部を見る必要があり、数が効くため。
* LevelDB は L0 が 8 ファイルで書き込みを 1ms 遅らせ、12 ファイルで止める (`kL0_SlowdownWritesTrigger`, `kL0_StopWritesTrigger`)。
* 読み出しで「無駄に見たファイル」が多いファイルを compaction する seek compaction もある。省略してよい。

### 11.2 入力ファイルの選び方

```rust
fn pick_compaction(vs: &mut VersionSet) -> Option<Compaction> {
    let (level, score) = compute_score(&vs.current);
    if score < 1.0 { return None; }
    let files = &vs.current.files[level];
    // 1) compact_pointer[level] (前回の終わり) より後ろの最初のファイル。なければ先頭に戻る
    let f = files.iter().find(|f| vs.compact_pointer[level].is_empty()
                                  || cmp_internal(&f.largest, &vs.compact_pointer[level]).is_gt())
                 .unwrap_or(&files[0]);
    let mut in0 = vec![f.clone()];
    // 2) L0 は重なり合うので、範囲が重なるファイルを全部入れる (範囲を広げながら繰り返す)
    if level == 0 { in0 = overlapping_inputs(&vs.current, 0, range_of(&in0)); }
    // 3) 境界のユーザーキーが隣のファイルにまたがっていたら、そのファイルも入れる
    add_boundary_inputs(&vs.current.files[level], &mut in0);
    // 4) 下の段で範囲が重なるファイル
    let mut in1 = overlapping_inputs(&vs.current, level + 1, range_of(&in0));
    add_boundary_inputs(&vs.current.files[level + 1], &mut in1);
    // 5) in1 を増やさずに in0 を広げられるなら広げる (合計 25 × 2 MiB 以内)
    try_expand(&vs.current, level, &mut in0, &mut in1);
    // 6) 次回の開始位置を記録 (ラウンドロビン)
    vs.compact_pointer[level] = range_of(&in0).1;
    Some(Compaction { level, inputs: [in0, in1],
                      grandparents: overlapping_inputs(&vs.current, level + 2, range_of2(..)) })
}
```

* **境界の扱い (3)**: 同じユーザーキーの版が2つのファイルにまたがることがある (ファイルを途中で切ったため)。新しい版のファイルだけを下へ動かすと、古い版の方が上の段に残り、検索で古い値が見えてしまう。LevelDB の `AddBoundaryInputs`。
* **compact_pointer**: 段の中を左から右へ順に compaction していく。同じ範囲ばかりが選ばれるのを防ぐ。

### 11.3 マージと版の破棄

```rust
fn do_compaction(c: &Compaction, smallest_snapshot: u64) -> Vec<FileMeta> {
    let mut it = MergingIter::new(c.inputs.iter().flatten().map(table_iter));
    it.seek_to_first();
    let mut out = Vec::new();
    let mut cur_user_key: Option<Vec<u8>> = None;
    let mut last_seq_for_key = MAX_SEQ;
    while it.valid() {
        let ik = it.key();
        if should_stop_before(c, ik) { finish_output(&mut out); }   // 11.4
        let (uk, seq, t) = parse_internal_key(ik);
        if cur_user_key.as_deref() != Some(uk) {                    // 新しいユーザーキー
            cur_user_key = Some(uk.to_vec());
            last_seq_for_key = MAX_SEQ;
        }
        let drop = if last_seq_for_key <= smallest_snapshot {
            true                    // (A) もっと新しい版があり、それがどのスナップショットからも見える
        } else if t == ValueType::Deletion && seq <= smallest_snapshot
                  && is_base_level_for_key(c, uk) {
            true                    // (B) tombstone 自体が不要: これより下の段にこのキーがない
        } else { false };
        last_seq_for_key = seq;
        if !drop { add_to_output(&mut out, ik, it.value()); }
        it.next();
    }
    finish_output(&mut out);
    out
}
```

* **(A) 古い版の破棄**: ユーザーキーの版は新しい順に来る。直前に見た (より新しい) 版の seq が `smallest_snapshot` 以下なら、今の版は誰からも見えない。
  `smallest_snapshot` = 生きている最古のスナップショットの seq。スナップショットがなければ `last_seq`。
* **(B) tombstone の破棄**: 次の3つがそろえば消せる。
  1. tombstone 自体がすべてのスナップショットから見える (`seq <= smallest_snapshot`)。
  2. `level + 2` 以降の段に、このユーザーキーを範囲に含むファイルがない (`is_base_level_for_key`)。
  3. 入力内の同じキーの古い版は、このあと (A) で全部捨てられる。
  条件 2 を確かめずに消すと、下の段の古い値が「復活」する。**最下段に着くまで tombstone は消せない**、の正確な形がこれ。
* `is_base_level_for_key` は段ごとにファイルのポインタを進めながら線形に探す (キーは昇順に来るので戻らない)。

### 11.4 出力ファイルの切り方

* 出力ファイルが目標サイズ (2 MiB) に達したら切る。
* さらに、**祖父母の段 (level + 2) と重なるバイト数が 10 × 2 MiB を超えたら**切る (`ShouldStopBefore`)。次の compaction で1ファイルが巻き込む下の段の量を抑えるため。
* 切る位置で同じユーザーキーの版が分かれることがある。11.2 の境界の扱いはそのために要る。

### 11.5 インストール

1. 出力ファイルを fsync。
2. manifest に「入力ファイルを削除、出力ファイルを level + 1 に追加、compact_pointer」を1つの VersionEdit として追記 → fsync。
3. 新しい Version に切り替える。古い Version を参照している読み出しが終わってから、入力ファイルを消す (参照カウント)。

### 11.6 trivial move

* 入力が上の段の1ファイルだけで、下の段に重なるファイルがなく、祖父母との重なりも小さいなら、**書き直さずに段だけ変える** (manifest の書き換えのみ)。昇順挿入で効く。

## 12. tiered compaction (対比)

* leveled: 各段 (L1 以降) は**範囲が重ならない1本のソート済み列**。段が溢れると、1ファイルを下の段の重なるファイルとマージする。
  * 読み出し: 段ごとに高々1ファイル。空間の無駄が少ない。
  * 書き込み増幅: 1つのデータが各段で約 10 回 (段の大きさの比) 書き直される。
* tiered (size-tiered): 各段に**範囲が重なってよいソート済み列 (run) を複数**置く。段に run が T 個溜まったら、全部をマージして次の段の1本にする。
  * 書き込み増幅: 各段で1回だけ書き直す。小さい。
  * 読み出し: 段ごとに最大 T 本を見る。bloom filter が効かない範囲走査で特に遅い。空間増幅も大きい。
* 擬似コードの差分: `pick_compaction` が「段の run 数 >= T なら、その段の全 run を入力にして、出力を次の段の新しい run として追加する」になる。下の段の既存 run とはマージしない。
* Cassandra の STCS (SizeTieredCompactionStrategy) は「大きさが近い SSTable を束ね、束が閾値個に達したらマージ」。【未検証】閾値の既定値などは原典を確認していない。

## 13. 論文の最適化を LSM に移す

論文 8章 (LSM-Trees) の見通しを項目ごとに整理する。**以下の「論文」は論文の記述、「実装案」は筆者の解釈**。

| 最適化 | 論文の見通し | 理由 |
|---|---|---|
| dense leaves | 合う (空間もアクセス時間も減る) | 連番キーの data block を配列として持てる (筆者の解釈) |
| fully dense leaves | **値の圧縮と両立しない** | 値を固定位置の配列に置くので、ブロック単位の圧縮をかけられない (筆者の解釈) |
| hints | 副作用が少なく、アクセス時間を改善しそう | restart point からサンプリングするのがよさそう |
| fingerprinting | **2 バイト**の fingerprint にすべき | 誤一致のたびに高価なキーの展開 (差分の復元) が起きる |
| heads | 割に合わない | 空間コストがかかり、ブロックはもともとソート済み |
| 汎用圧縮 (Cassandra) | 適用できるが | 冷たいブロックのアクセス時間は展開に支配される |

### 13.1 実装案: restart point からの hints

* data block の restart point のキーは**差分圧縮されていない完全なキー** (02 参照)。その先頭 4 バイト (`head()`) を小さな配列に抜き出して、block の末尾 (restart 配列の隣) に置く。
* 検索は 01 の hints と同じ: hints 配列を SIMD で比べて restart の範囲を絞る → その範囲だけ restart を二分探索 → 前方に展開。
* restart 間隔 16、4 KiB block なら restart は十数個。hints が効くのは block が大きい (16〜64 KiB) 設定のとき (筆者の見積もり)。

### 13.2 実装案: 2 バイト fingerprint

* data block にエントリごとの 2 バイトハッシュの配列を足し、点検索ではまずその配列を SIMD で探す。
* 一致した位置のキーを得るには、その位置の手前の restart から差分を復元する必要がある (平均で restart 間隔の半分のエントリ)。1 バイトでは 256 件に1件の割で誤一致が起き、そのたびにこの復元が走る。2 バイトなら 65536 件に1件。
* 範囲走査は block がソート済みなので fingerprint は使わない。

### 13.3 B-Tree と LSM の差 (実装上)

* LSM の block は**書いた後は変わらない**。01 のように挿入のたびに hints / fingerprint を保守する必要がなく、block を作るときに1回計算すればよい。
* 一方、block は圧縮されていることがあり、読むたびに展開する。展開済み block のキャッシュ (block cache) に hints を一緒に置く設計も考えられる。

## 14. 境界条件と落とし穴

* **tombstone を早く消しすぎる**: 11.3 の (B) の条件を1つでも欠くと、削除したキーが復活する。最も起きやすい不具合。
* **境界のユーザーキー**: 11.2 の (3) を忘れると、古い版が上の段に残って見える。
* **L0 の順序**: L0 はファイル番号 (新しさ) の順に見る。範囲の順に見ると古い値を返す。
* **flush と compaction の同時実行**: 新しい L0 ファイルを compaction の入力に混ぜないよう、入力の選択は Version のスナップショットに対して行う。
* **空のキー**: ユーザーキーが空でも内部キーは 8 B ある。`split_at(len - 8)` はそれを前提にしている。
* **seq のあふれ**: 56 ビット。現実には溢れないが、`MAX_SEQ` を検索キーで使うので、実データでは使わない。
* **filter のキー**: filter にはユーザーキーを入れる。内部キーを入れると seq が違うだけで不一致になり、偽陰性になる。
* **区切りキーの短縮**: `shortest_separator` の結果が `last_key` より小さくなってはいけない。ユーザーキーが変わらなかったときは元のキーのまま。
* **WAL の削除時期**: 対応する memtable の flush が manifest に記録されるまで消さない。

## 15. テスト方針

* オラクル: `BTreeMap<Vec<u8>, Vec<u8>>`。put / delete / get / scan をランダムに流し、**memtable を小さく** (数 KiB)、`L0_COMPACTION_TRIGGER` や段のサイズも小さくして、flush と compaction を頻繁に起こす。
* 各ステップで不変条件チェッカー: 4節の項目を Version と全ファイルについて確かめる (ファイルを全部読み直してよい)。
* スナップショット: ランダムな時点で `(snapshot, オラクルの複製)` を保存し、後でそのスナップショットで get / scan した結果が複製と一致するか。compaction の (A)(B) の誤りはここで出る。
* tombstone の復活: 「put → 多数の put で下の段へ押し出す → delete → compaction を繰り返す」で、削除したキーが見えないこと。
* クラッシュ: WAL / SSTable / manifest への書き込みをフックし、任意の位置で以降の書き込みを捨てて再起動する。sync した書き込みまでは必ず残っていること。
* bloom filter 単体: 入れたキーが全部一致すること (偽陰性ゼロ)。入れていない 10 万キーで偽陽性率を測り、理論値 (7.1) と同程度か。
* SSTable 単体: ランダムなキー集合を書いて読み、seek_first_ge の結果が配列の二分探索と一致するか。block の境界、空の SSTable、1件だけの SSTable を含める。

## 16. 原典との違い・簡略化

* LevelDB の形式に合わせた。O'Neil の原論文の LSM (2段のコンポーネントを rolling merge する) とは構成が違う。
* 並行性: 書き込みのグループ化、バックグラウンドスレッドとのロック、Version の参照カウントの詳細は省いた。
* manifest (VersionEdit の形式)、table cache、block cache、seek compaction、逆向きの走査は省略または要約。
* RocksDB の full filter、Cassandra の STCS の詳細は確認していない (【未検証】と明記した箇所)。
* 13節の実装案は論文の見通しをもとにした筆者の設計で、論文にも LevelDB にも実装はない。

## 17. 参考資料

* Patrick O'Neil, Edward Cheng, Dieter Gawlick, Elizabeth O'Neil. *The Log-Structured Merge-Tree (LSM-Tree)*. Acta Informatica 33(4), 1996。
* Adam Kirsch, Michael Mitzenmacher. *Less Hashing, Same Performance: Building a Better Bloom Filter*. ESA 2006 (double hashing)。
* Marcus Müller, Lawrence Benson, Viktor Leis. *B-Trees Are Back*. SIGMOD 2025. Section 8 (Compression Alternatives, LSM-Trees)。
* 参照実装 [google/leveldb](https://github.com/google/leveldb)
  * `db/dbformat.h:ValueType, kMaxSequenceNumber, kValueTypeForSeek, config::kL0_*`、`db/dbformat.cc:PackSequenceAndType, InternalKeyComparator::Compare, InternalFilterPolicy::CreateFilter`
  * `db/memtable.cc:MemTable::Add`、`db/log_format.h` (WAL のブロックとヘッダ)
  * `table/table_builder.cc:TableBuilder::Add, Flush, WriteRawBlock, Finish`
  * `table/format.h:BlockHandle, Footer, kTableMagicNumber, kBlockTrailerSize`、`util/crc32c.h:Mask`
  * `table/filter_block.cc:FilterBlockBuilder` (`kFilterBaseLg = 11`)
  * `util/bloom.cc:BloomFilterPolicy::CreateFilter, KeyMayMatch`
  * `db/version_set.cc:MaxBytesForLevel, VersionSet::Finalize, PickCompaction, SetupOtherInputs, AddBoundaryInputs, Compaction::IsBaseLevelForKey, ShouldStopBefore, Version::ForEachOverlapping`
  * `db/db_impl.cc:DBImpl::DoCompactionWork` (版と tombstone の破棄)
  * `db/db_iter.cc:DBIter::FindNextUserEntry`、`table/merger.cc:MergingIterator`
