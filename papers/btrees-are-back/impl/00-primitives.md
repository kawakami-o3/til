# 00. 共通の部品

他のファイルから名前で参照する小さな部品をまとめる。background.md の 0.1〜0.5 に対応する。

* どれも数行〜数十行で書ける。ただし、**未定義動作 (UB) と境界条件**で失敗しやすい。
* 各部品について「目的 → データ配置 → 不変条件 → 擬似コード → 落とし穴 → テスト」の順に、短く書く。
* x86_64 を前提にする。SIMD 部品には必ずスカラ版を併記する (テストのオラクルにもなる)。

| 部品 | 使う場所 | background.md |
|---|---|---|
| `load_be_u32` / `load_be_u64` | heads, 正規化キー, dense leaves | 2.1, 2.2 |
| `head` | 01 (heads, hints) | 2.2 |
| `simd_eq_mask_u8x16` / `_u8x32` | 08 (fingerprint), 04 (ART Node16) | 0.2 |
| `simd_eq_mask_u16x16` | 16ビットタグの線形探索 | 0.2 |
| `for_each_set_bit` | SIMD マスク、FDL のビットマップ | 0.2 |
| `lower_bound_u32` (分岐なし) | 01 (heads 上の探索), 03 (CSS-Tree) | 0.3 |
| `prefetch_read` | 05 (HOT), 走査の次の葉 | 0.1 |
| `alloc_aligned` | ノード, ハッシュ表 | 0.1 |
| `PageAllocator` | 01 (全ノード) | 0.5 |
| `VirtRegion` (mmap / madvise) | 11 (vmcache) | 0.4 |

---

## 1. ビッグエンディアン読み込み: `load_be_u32` / `load_be_u64`

### 目的と論文との関係

* 正規化キーは「上位バイトが先」のバイト列。先頭 4 / 8 バイトを**ビッグエンディアンの整数**として読むと、整数比較 = `memcmp` の結果になる。
* x86 はリトルエンディアンなので、普通に読むと順序が壊れる。読んだ後にバイトを反転する (`bswap` / `movbe` 命令1つ)。
* 論文のスロットは 10 バイト (offset, key_len, val_len の `u16` ×3 + head の `u32`) で、**パディングなしの詰め込み**にしている。
  そのため head は 4 バイト境界に揃っておらず、**非整列読み込み**が必要になる (論文 3.2 "Slot Alignment"。速度差は 3% 未満)。

### データ配置

```
メモリ:   [0x61][0x62][0x63][0x64]       key = "abcd"
LE で読む: 0x64636261   ← 比較に使えない
BE で読む: 0x61626364   ← memcmp と同じ順
```

### 擬似コード

```rust
/// p[off..off+4] をビッグエンディアンで読む。境界は呼び出し側が保証する。
#[inline(always)]
fn load_be_u32(p: &[u8], off: usize) -> u32 {
    // try_into で [u8; 4] にコピーしてから変換する。
    // LLVM はこれを 1 命令の非整列ロード + bswap (または movbe) にする。
    u32::from_be_bytes(p[off..off + 4].try_into().unwrap())
}

#[inline(always)]
fn load_be_u64(p: &[u8], off: usize) -> u64 {
    u64::from_be_bytes(p[off..off + 8].try_into().unwrap())
}

/// 生ポインタ版 (ページ内のオフセット計算をした後に使う)。
/// unsafe: p から 4 バイトが同じ割り当ての中にあり、初期化済みであること。
#[inline(always)]
unsafe fn load_be_u32_ptr(p: *const u8) -> u32 {
    u32::from_be(core::ptr::read_unaligned(p as *const u32))
}

#[inline(always)]
fn store_be_u32(p: &mut [u8], off: usize, v: u32) {
    p[off..off + 4].copy_from_slice(&v.to_be_bytes());
}
```

### 詰め込んだスロットの読み書き

```rust
#[repr(C, packed)]
#[derive(Clone, Copy)]
struct Slot {          // offset
    offset: u16,       // 0
    key_len: u16,      // 2
    val_len: u16,      // 4
    head: u32,         // 6   ← 4 の倍数でない
}                      // size = 10

// NG: &slot.head は packed フィールドへの参照なのでコンパイルエラー (E0793)。
// OK: 値としてコピーする。
let h: u32 = { slot.head };                       // ブロックで囲むとコピーになる
let h: u32 = unsafe { core::ptr::addr_of!(slot.head).read_unaligned() };
```

* `head` は「ホストのエンディアンの u32」としてスロットに入れる (比較のたびに bswap しないため)。
  ページを別アーキテクチャに持ち出さない前提の簡略化。

### 落とし穴

* `*(p as *const u32)` は**整列していないと UB**。必ず `read_unaligned` か `from_be_bytes` を使う。
* 範囲外 (`off + 4 > len`) はスライス版なら panic、ポインタ版なら UB。キー長が 4 未満のときは `head` のように場合分けする。

---

## 2. `head(key) -> u32`

### 目的と論文との関係

* 論文の **heads** (poor man's normalized keys)。キーの先頭 4 バイトを u32 にしてスロットにコピーする。
* 二分探索の比較の大半を、スロット配列 (= 少数のキャッシュライン) の中の整数比較で済ませる。
* README の共通定義の実体。足りない分は**末尾側を 0 で埋める**。

### 擬似コード

```rust
/// キーの先頭 4 バイトを BE の u32 で返す。4 バイト未満は末尾を 0 埋め。
fn head(key: &[u8]) -> u32 {
    match key.len() {
        0 => 0,
        1 => (key[0] as u32) << 24,
        2 => (u16::from_be_bytes([key[0], key[1]]) as u32) << 16,
        3 => ((u16::from_be_bytes([key[0], key[1]]) as u32) << 16)
            | ((key[2] as u32) << 8),
        _ => load_be_u32(key, 0),
    }
}
```

```
key = "ab"       → 61 62 00 00 → 0x61620000
key = "ab\0"     → 61 62 00 00 → 0x61620000   ← "ab" と同じ head
key = "abcdef"   → 61 62 63 64 → 0x61626364
```

### 不変条件 (性質)

* **単調性**: `a <= b` (memcmp 順) ならば `head(a) <= head(b)`。
* 逆は成り立たない。`head(a) < head(b)` なら `a < b` と確定するが、`head(a) == head(b)` のときは**本体の比較が必要**。
* 上の例のとおり、長さが違っても head が等しいことがある。等しいときの比較は「共通部分の memcmp → 長さ比較」の両方を行う。

### head を使った比較

```rust
use core::cmp::Ordering;

/// スロットの head と本体を使って、探索キーとスロットのキーを比べる。
fn cmp_with_head(key: &[u8], key_head: u32, slot_head: u32, slot_key: &[u8]) -> Ordering {
    match key_head.cmp(&slot_head) {
        Ordering::Equal => key.cmp(slot_key), // [u8] の Ord は memcmp + 長さ比較
        o => o,
    }
}
```

### 落とし穴

* prefix truncation を使う場合、head は**切り詰めた後のキー**から作る。fence が変わって接頭辞長が変わったら、全スロットの head を作り直す。
* 参照実装には、最後のバイトに長さを入れる別変種 (`makeSepHead` / `makeNeedleHead`) もある。README の `head` はそれではない。混ぜないこと。
* dense leaves の「数値部分」(02 参照) は**先頭側**を 0 で埋める。head は**末尾側**を 0 で埋める。向きが逆。

### テスト方針

* ランダムなバイト列の組 (長さ 0〜8、アルファベット {00, 01, 7F, 80, FF} に偏らせる) で単調性を確かめる。
* `head(a) != head(b)` のとき `head(a).cmp(&head(b)) == a.cmp(b)` を確かめる。
* 長さ 0〜3 の全パターンを、`[key, 0, 0, 0][..4]` を BE で読む素朴版と比べる。

---

## 3. SIMD の等値比較マスク

### 目的と論文との関係

* 16 個 (または 32 個) の値を 1 命令で「needle と等しいか」比較し、結果を 1 ビットずつのマスクにする。
* fingerprinting リーフ (08) は 1 バイトのハッシュ配列をこれで線形探索する。ART の Node16 (04) も同じ。

### データ配置と命令の流れ (SSE2, 16 バイト)

```
bytes : [3a][07][3a][ff] ... [10]      16 バイト
needle: [3a][3a][3a][3a] ... [3a]      _mm_set1_epi8
cmpeq : [ff][00][ff][00] ... [00]      _mm_cmpeq_epi8 (等しいレーンは全ビット 1)
movemask: 各バイトの最上位ビットを集める → 0b...0101 (u16)
          ビット i = レーン i
```

### 擬似コード

```rust
use core::arch::x86_64::*;

/// SSE2 は x86_64 の必須機能なので、実行時の判定はいらない。
#[inline]
fn simd_eq_mask_u8x16(needle: u8, bytes: &[u8; 16]) -> u16 {
    unsafe {
        let v = _mm_loadu_si128(bytes.as_ptr() as *const __m128i); // 非整列ロード
        let n = _mm_set1_epi8(needle as i8);
        let eq = _mm_cmpeq_epi8(v, n);
        _mm_movemask_epi8(eq) as u16 // 上位 16 ビットは 0
    }
}

/// スカラ版。テストのオラクル、および x86 以外での実装。
fn simd_eq_mask_u8x16_scalar(needle: u8, bytes: &[u8; 16]) -> u16 {
    let mut m = 0u16;
    for i in 0..16 {
        m |= ((bytes[i] == needle) as u16) << i;
    }
    m
}

/// AVX2 版 (32 レーン)。AVX2 は必須機能ではないので target_feature + 実行時判定。
#[target_feature(enable = "avx2")]
unsafe fn simd_eq_mask_u8x32(needle: u8, bytes: &[u8; 32]) -> u32 {
    let v = _mm256_loadu_si256(bytes.as_ptr() as *const __m256i);
    let n = _mm256_set1_epi8(needle as i8);
    _mm256_movemask_epi8(_mm256_cmpeq_epi8(v, n)) as u32
}

fn eq_mask_u8x32(needle: u8, bytes: &[u8; 32]) -> u32 {
    if is_x86_feature_detected!("avx2") {          // 結果はキャッシュされるが、
        unsafe { simd_eq_mask_u8x32(needle, bytes) } // ホットループの外で1回判定して
    } else {                                         // 関数ポインタを選ぶ方がよい
        let lo = simd_eq_mask_u8x16(needle, bytes[..16].try_into().unwrap()) as u32;
        let hi = simd_eq_mask_u8x16(needle, bytes[16..].try_into().unwrap()) as u32;
        lo | (hi << 16)
    }
}
```

### 16 ビットタグ版: `simd_eq_mask_u16x16`

* `_mm_cmpeq_epi16` の結果は 1 レーン 2 バイト。そのまま `movemask_epi8` すると**1 レーン 2 ビット**になる。
* 2 本の比較結果を `_mm_packs_epi16` (符号付き飽和で 16→8 ビット) で 1 本にまとめると、1 レーン 1 ビットになる。
  `0xFFFF` (= -1) は `0xFF`、`0x0000` は `0x00` に飽和するので、値が壊れない。

```
tags[0..8]  → cmpeq_epi16 → eq0 (8 レーン × 16 ビット)
tags[8..16] → cmpeq_epi16 → eq1
packs_epi16(eq0, eq1) → 16 レーン × 8 ビット (eq0 が下位 8 レーン)
movemask_epi8 → u16
```

```rust
fn simd_eq_mask_u16x16(needle: u16, tags: &[u16; 16]) -> u16 {
    unsafe {
        let p = tags.as_ptr() as *const __m128i;
        let n = _mm_set1_epi16(needle as i16);
        let eq0 = _mm_cmpeq_epi16(_mm_loadu_si128(p), n);
        let eq1 = _mm_cmpeq_epi16(_mm_loadu_si128(p.add(1)), n);
        _mm_movemask_epi8(_mm_packs_epi16(eq0, eq1)) as u16
    }
}
```

* AVX2 で 1 本 (`_mm256_cmpeq_epi16`) にすると、`_mm256_packs_epi16` は 128 ビットのレーンごとに働くので順序が入れ替わる。
  `_mm256_permute4x64_epi64` で並べ直すか、2 ビットずつのマスクから偶数ビットだけ取り出す (BMI2 の `_pext_u32(m, 0x5555_5555)`) 必要がある。
  簡単なのは上の SSE2 版。

### 不変条件

* 戻り値のビット i が 1 ⇔ `bytes[i] == needle`。i が大きいほど上位ビット。

### 落とし穴

* **末尾のマスク**: 有効な要素が `count < 16` 個のとき、残りのレーンはゴミ。`m & ((1u32 << count) - 1) as u16` で落とす。
  `1u16 << 16` は桁あふれで panic (debug) / 0 (release) になるので、u32 で計算する。
* **読みすぎ**: 配列の末尾を越えて 16 バイト読むと、Rust では割り当て外の読み込み = UB。
  ページ (4 KiB の 1 つの割り当て) の内側に収まり、かつ**初期化済み**なら問題ない。ページは確保時にゼロ埋めしておく。
* `#[target_feature]` 関数を、CPU が対応していないのに呼ぶと UB。必ず `is_x86_feature_detected!` の後で呼ぶ。
* `_mm_set1_epi8` は `i8` を取る。`needle as i8` で 0x80 以上も正しくビットが渡る (値の解釈が変わるだけ)。

### テスト方針

* ランダムな配列と needle (配列中の値を半分の確率で選ぶ) で、SIMD 版とスカラ版の一致を確かめる。
* 全レーン一致、0 レーン一致、needle = 0x00 / 0x80 / 0xFF を固定ケースに入れる。

---

## 4. ビットマスクの反復: `for_each_set_bit`

### 目的

* SIMD の結果マスクや、FDL (fully dense leaf) の「スロットが埋まっているか」のビットマップを、立っているビットだけ順に訪ねる。
* `trailing_zeros` (x86 の `tzcnt`、C++ の `countr_zero`) で最下位の 1 の位置を得て、`m & (m - 1)` でそのビットを消す。

### 擬似コード

```rust
/// 立っているビットを、小さい添字から順に訪ねる。f が false を返したら打ち切る。
#[inline]
fn for_each_set_bit_u32(mut m: u32, mut f: impl FnMut(u32) -> bool) {
    while m != 0 {
        let i = m.trailing_zeros();   // m != 0 なので 0..=31
        if !f(i) { return; }
        m &= m - 1;                   // 最下位の 1 を消す
    }
}

/// 複数ワードのビットマップ (FDL の存在ビット)。start 以上の最初のビットから。
fn for_each_set_bit_words(words: &[u64], start: usize, mut f: impl FnMut(usize) -> bool) {
    let mut w = start / 64;
    if w >= words.len() { return; }
    let mut m = words[w] & (!0u64 << (start % 64)); // start より前を落とす
    loop {
        while m != 0 {
            let i = w * 64 + m.trailing_zeros() as usize;
            if !f(i) { return; }
            m &= m - 1;
        }
        w += 1;
        if w == words.len() { return; }
        m = words[w];
    }
}
```

### 落とし穴

* `0u32.trailing_zeros()` は 32 を返す (C の `__builtin_ctz(0)` は未定義だが Rust は定義済み)。それでもループ条件で 0 を除くこと。
* ビットマップの最後のワードで、スロット数を超えたビットは常に 0 にしておく (不変条件)。そうしないと存在しないスロットを訪ねる。
* 論文の SDL の scan が遅い理由は、スロットごとの `if` が分岐ミスを起こすこと。ビット反復なら空きスロットを飛ばせる (deep-dive.md 5 節)。

### テスト方針

* ランダムな u64 列で、`(0..64*n).filter(|i| bit(i))` と同じ添字列になるかを確かめる。`start` もランダムに選ぶ。

---

## 5. 分岐なし二分探索: `lower_bound_u32`

### 目的と論文との関係

* 二分探索の `if (a[mid] < x)` は結果がランダムなので、分岐予測が半分外れる (background.md 0.3)。
* 比較結果で「次の範囲の先頭」を**条件付き移動** (x86 の `cmov`) で選べば、分岐がなくなる。
  ループ回数はデータに依らず `ceil(log2(n))` 回で固定になる。
* 論文の `lowerBound` (参照実装) は分岐ありで、hint で範囲を狭めてから head で比較する。
  分岐なし版は、固定長キー (03 の CSS-Tree、01 の TLX 型) や hint 配列の探索に使える。

### 擬似コード

```rust
/// a はソート済み。a[i] >= x となる最小の i を返す (なければ a.len())。
fn lower_bound_u32(a: &[u32], x: u32) -> usize {
    let mut n = a.len();
    if n == 0 { return 0; }
    let mut base = 0usize;
    // 不変条件: 答えは [base, base + n] の中にある
    while n > 1 {
        let half = n / 2;
        // 前半 [base, base+half) がすべて x 未満なら、後半に進む。
        // ここを if 文で書かず、値の選択として書く (cmov を期待)。
        let go_right = a[base + half - 1] < x;
        base = if go_right { base + half } else { base };
        n -= half;
    }
    base + (a[base] < x) as usize
}
```

```
a = [1 3 5 7 9 11], x = 6
n=6 half=3: a[2]=5 < 6 → base=3, n=3
n=3 half=1: a[3]=7 < 6 ? no → base=3, n=2
n=2 half=1: a[3]=7 < 6 ? no → base=3, n=1
return 3 + (a[3]=7 < 6) = 3
```

### cmov を出させるには

* Rust (LLVM) は `if c { a } else { b }` を cmov にすることが多いが、**保証はない**。
* 確実にしたいときの手段:
  * 算術で書く: `base += half * (go_right as usize);` (乗算 1 回)。
  * `core::hint::select_unpredictable(go_right, base + half, base)` を使う。【未検証】安定化された Rust のバージョンは確認していない。
  * 生成コードを `cargo asm` などで見て、ループ内に条件分岐 (`jb` など) がないことを確かめる。
* 境界チェックがループ内に残ると分岐が増える。`a[base + half - 1]` は常に範囲内なので、`get_unchecked` に置き換えてよい (unsafe)。

### heads 上の探索への応用

* head が等しいスロットは本体の比較が要る。分岐なし探索で「head >= h の最初」と「head > h の最初」を求め、その間だけ本体を比べる。
* 論文の評価では、整数キー (4 バイトに収まる) なら head だけで決着する。

### 落とし穴

* `n` が大きいと、毎回キャッシュミスする位置を読む。分岐なし版は「投機実行で先読みが進む」効果がなくなるので、**大きな配列ではプリフェッチと組み合わせる** (両側の候補 `a[base + half/2 - 1]` と `a[base + half + half/2 - 1]` を prefetch する)。
* 4 KiB ノード内 (数百要素) なら、プリフェッチなしで十分。

### テスト方針

* ランダムなソート済み配列 (重複あり、長さ 0〜600) とランダムな x で、`a.partition_point(|&v| v < x)` と一致するかを確かめる。
* x = 0, u32::MAX, 配列の最小値・最大値・重複値を必ず含める。

---

## 6. プリフェッチ: `prefetch_read`

### 目的と論文との関係

* 「もうすぐ読むアドレス」を CPU に先に伝え、DRAM からの転送を計算と重ねる。
* HOT はプリフェッチに頼っているので、Zipf の α を上げてもキャッシュの恩恵が小さい (論文 6.6 節)。
* B-Tree では、走査中に次の葉、または降下中に子ノードの先頭キャッシュラインを先読みする用途がある。

### 擬似コード

```rust
#[inline(always)]
fn prefetch_read<T>(p: *const T) {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        use core::arch::x86_64::{_mm_prefetch, _MM_HINT_T0};
        _mm_prefetch::<_MM_HINT_T0>(p as *const i8); // L1 まで持ってくる
    }
    // 他のアーキテクチャでは何もしない (正しさには影響しない)
}

/// ノード全体 (複数のキャッシュライン) を先読みする。
fn prefetch_node(p: *const u8, bytes: usize) {
    let mut off = 0;
    while off < bytes {
        prefetch_read(p.wrapping_add(off)); // wrapping_add: 範囲外でも UB にしない
        off += CACHE_LINE;
    }
}
```

### 落とし穴

* プリフェッチ命令は無効なアドレスでも例外を起こさない。ただし Rust 側で `p.add(off)` を範囲外に作ると UB なので `wrapping_add` を使う。
* 4 KiB ノード全体 (64 ライン) を毎回先読みすると、メモリ帯域を食って逆に遅くなる。先頭の数ライン (ヘッダ + hint) に限る。
* 効果は測定でしか分からない。プリフェッチの有無を切り替えられるようにしておく。

---

## 7. キャッシュライン整列の確保: `alloc_aligned`

### 目的

* 構造体がキャッシュラインをまたぐと、1 回の読み込みで 2 ラインに触る。
* 複数スレッドが書く変数が同じラインにあると、偽共有 (false sharing) でラインが行き来する。
* ページ (4 KiB) は 4096 境界に置く。`PageId` とアドレスの変換が単純になり、ページがキャッシュライン境界からずれない。

### 擬似コード

```rust
use std::alloc::{alloc_zeroed, dealloc, handle_alloc_error, Layout};

/// align の倍数のアドレスに、ゼロ埋めした size バイトを確保する。
fn alloc_aligned(size: usize, align: usize) -> (*mut u8, Layout) {
    // align は 2 のべき乗、size は 0 より大きいこと。違えば Err。
    let layout = Layout::from_size_align(size, align).expect("bad layout");
    let p = unsafe { alloc_zeroed(layout) };
    if p.is_null() { handle_alloc_error(layout); }
    (p, layout)
}

/// 解放には確保時と同じ Layout を渡す (違うと UB)。
unsafe fn free_aligned(p: *mut u8, layout: Layout) {
    dealloc(p, layout);
}

// 型で揃える方法もある。
#[repr(C, align(64))]
struct PaddedCounter { value: std::sync::atomic::AtomicU64 } // 1 つで 1 ライン
```

### 落とし穴

* `size == 0` の `Layout` で `alloc` を呼ぶと UB。
* `Vec<u8>` の要素は 1 バイト整列しか保証されない。ページを `Vec<u8>` で持つと 4096 境界にならない。
* `Box<[u8; 4096]>` も同じ。`#[repr(align(4096))] struct Page([u8; 4096]);` なら揃う。

---

## 8. ページ単位のアロケータ: `PageAllocator`

### 目的と論文との関係

* B-Tree のノードはすべて 4 KiB。大きな領域から 4 KiB ずつ切り出し、解放されたページは**フリーリスト**に戻して再利用する。
* `malloc` を 1 ノードずつ呼ばない理由 (background.md 0.5):
  * 汎用アロケータは各ブロックに管理情報を付ける。4096 バイト要求でも 4096 より少し大きいチャンクになり、**4096 境界に揃わない**。【未検証】ヘッダの大きさは glibc の実装依存。
  * 揃っていないページは OS のページ 2 枚にまたがり、`madvise` や I/O の単位と合わない。
  * 確保・解放が O(1) で、ロックやサイズクラスの探索がいらない。
  * ページを `PageId` (= 領域先頭からの番号) で呼べる。vmcache (11) はこの番号をそのまま使う。
* 論文の比較では、Wormhole のプロセス使用量の約 1/3 がアロケータのオーバーヘッドだった。

### データ配置

```
base (4096 境界)
 │
 ▼
 [page 0][page 1][page 2][page 3][page 4] ...........[page cap-1]
   使用中   free     使用中   free   ← next_unused (ここから先は未使用)
            │                 ▲
            └─ 先頭8バイト = 3 ┘   free_head = 1
               page 3 の先頭8バイト = NONE

フリーリストは「空きページ自身の先頭 8 バイト」に次の PageId を書く (侵入型リスト)。
```

### 擬似コード

```rust
const NONE: PageId = u64::MAX;

struct PageAllocator {
    base: *mut u8,        // 4096 境界。VirtRegion か alloc_aligned で確保
    capacity: u64,        // ページ数
    next_unused: u64,     // まだ一度も渡していない最初のページ
    free_head: PageId,    // フリーリストの先頭 (NONE なら空)
    free_count: u64,
}

impl PageAllocator {
    fn page_ptr(&self, pid: PageId) -> *mut u8 {
        debug_assert!(pid < self.next_unused);
        // base から add するので provenance (ポインタの出自) が保たれる
        unsafe { self.base.add(pid as usize * PAGE_SIZE) }
    }

    fn page_id(&self, p: *const u8) -> PageId {
        ((p.addr() - self.base.addr()) / PAGE_SIZE) as PageId
    }

    fn alloc(&mut self) -> Option<PageId> {
        if self.free_head != NONE {
            let pid = self.free_head;
            let p = self.page_ptr(pid);
            self.free_head = unsafe { (p as *const u64).read() }; // 4096 境界なので整列済み
            self.free_count -= 1;
            unsafe { p.write_bytes(0, PAGE_SIZE) }; // 前の内容を消す (ゼロ埋め前提の部品のため)
            return Some(pid);
        }
        if self.next_unused == self.capacity {
            return None;                           // 領域が尽きた。呼び出し側で拡張か失敗
        }
        let pid = self.next_unused;
        self.next_unused += 1;                     // mmap の新しいページは最初から 0
        Some(pid)
    }

    fn free(&mut self, pid: PageId) {
        let p = self.page_ptr(pid);
        unsafe { (p as *mut u64).write(self.free_head) };
        self.free_head = pid;
        self.free_count += 1;
    }
}
```

### 不変条件

* 各ページは「使用中」「フリーリスト上 (ちょうど 1 回)」「`next_unused` 以降」のどれか 1 つ。
* `free_count` = フリーリストの長さ。
* フリーリストをたどると `NONE` で終わる (循環しない)。

### 落とし穴

* **二重解放**でリストが循環する。デバッグビルドでは「使用中かどうか」のビットマップを別に持って検査する。
* 並行版では、他スレッドが楽観的に読んでいる最中のページを再利用してはいけない (12 のエポック回収)。
* ページを OS に返すなら、フリーリストに入れるときに `madvise(MADV_DONTNEED)` を呼ぶ (次節)。その場合は先頭 8 バイトも消えるので、フリーリストを**ページの外** (`Vec<PageId>`) に持つ。

### テスト方針

* ランダムな alloc / free の列を流し、`HashSet<PageId>` で使用中集合を管理するオラクルと比べる。
  * alloc の結果が使用中集合に含まれていないこと。
  * 各操作の後に不変条件チェッカー (全ページの状態を数える) を走らせる。
* alloc 直後のページが全バイト 0 であることを確かめる。

---

## 9. 仮想領域の予約: `VirtRegion` (mmap / madvise)

### 目的と論文との関係

* 物理メモリより大きな**仮想アドレス範囲**を一度に予約し、触ったページにだけ物理メモリが割り当てられるようにする。
* vmcache (11) は、全ページ分の仮想領域を予約し、`PageId * 4096` をそのままアドレスにする。追い出したページは `madvise(MADV_DONTNEED)` で物理メモリを返す。
* 参照: `vmcache: vmcache.cpp:BufferManager::BufferManager` (mmap) と `evict` (madvise)。

### 擬似コード (Linux, `libc` クレート)

```rust
struct VirtRegion { base: *mut u8, len: usize }

impl VirtRegion {
    fn reserve(len: usize) -> std::io::Result<VirtRegion> {
        assert!(len % PAGE_SIZE == 0);
        let p = unsafe {
            libc::mmap(
                core::ptr::null_mut(), len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE,
                -1, 0,
            )
        };
        if p == libc::MAP_FAILED {            // 失敗は null ではなく MAP_FAILED (= -1)
            return Err(std::io::Error::last_os_error());
        }
        // 大きなページ (THP) を避けたいとき。4 KiB 単位で追い出すため。
        unsafe { libc::madvise(p, len, libc::MADV_NOHUGEPAGE) };
        Ok(VirtRegion { base: p as *mut u8, len })
    }

    /// ページの物理メモリを OS に返す。
    fn discard(&self, pid: PageId) {
        let p = unsafe { self.base.add(pid as usize * PAGE_SIZE) };
        let r = unsafe { libc::madvise(p as *mut libc::c_void, PAGE_SIZE, libc::MADV_DONTNEED) };
        assert_eq!(r, 0);
    }
}

impl Drop for VirtRegion {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.base as *mut libc::c_void, self.len) };
    }
}
```

### 振る舞い

```
reserve(64 GiB)      : 仮想アドレスだけ確保。RSS はほぼ 0
page 5 に初めて書く   : ページフォルト → 0 埋めの物理ページが割り当てられる
discard(5)           : 物理ページを返す。RSS が 4 KiB 減る
page 5 を次に読む     : 再び 0 埋めのページが見える (Linux, 匿名・private の場合)
```

### 落とし穴

* `MADV_DONTNEED` の後に 0 が見えるのは **Linux の匿名 private マッピング**の振る舞い。
  macOS など他の OS では意味が違う。【未検証】macOS での挙動は確認していない。
* 初回アクセスのページフォルトは数マイクロ秒かかる。ベンチマークでは事前に触っておくか、計測区間外で確保する。
* `MAP_NORESERVE` がないと、overcommit の設定によっては大きな予約が失敗する。
* `discard` したページを、他スレッドが楽観的に読んでいる可能性がある。0 が見えても壊れないように、読み手は版数 (version) で検証する (12)。
* Rust の参照 (`&[u8]`) を保持したまま `discard` すると、参照先の内容が変わる。参照ではなく生ポインタで扱う。

### テスト方針

* reserve → 書く → discard → 読むと 0、を確かめる (Linux のみ。`#[cfg(target_os = "linux")]`)。
* `/proc/self/statm` の RSS が discard で減ることを確かめる (目安なので緩い閾値で)。

---

## 10. 原典との違い・簡略化

* `head` は参照実装 (`btree-cpp: btree/btree2020.hpp:head`) と同じ場合分け。長さを埋め込む変種は扱わない。
* 参照実装の二分探索は分岐あり。分岐なし版は一般的な技法として載せた (論文の手法ではない)。
* `PageAllocator` は単一スレッド版。並行版のフリーリスト (ロック、スレッドごとのキャッシュ) は 12 で扱う。
* vmcache は exmap (独自のカーネルモジュール) も使えるが、ここでは `mmap` + `madvise` の経路だけを書いた。
* x86_64 以外 (aarch64 の NEON) の SIMD は載せていない。スカラ版で代用できる。

## 参考資料

* 本論文: Müller, Benson, Leis. B-Trees Are Back. SIGMOD 2025. https://doi.org/10.1145/3709664
* 論文の参照実装 (`btree/btree2020.hpp:head`, `btree/btree2020.cpp:BTreeNode::lowerBound`): https://github.com/m-mueller678/btree-cpp/tree/sigmod25
* vmcache (`vmcache.cpp:BufferManager::BufferManager`, `allocHuge`, `evict`): https://github.com/viktorleis/vmcache
* Intel Intrinsics Guide (`_mm_cmpeq_epi8`, `_mm_movemask_epi8`, `_mm_packs_epi16`): https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html
* Rust `core::arch::x86_64`: https://doc.rust-lang.org/core/arch/x86_64/index.html
* Rust `std::alloc::Layout`: https://doc.rust-lang.org/std/alloc/struct.Layout.html
* Rust `is_x86_feature_detected!`: https://doc.rust-lang.org/std/macro.is_x86_feature_detected.html
* Linux `madvise(2)`: https://man7.org/linux/man-pages/man2/madvise.2.html
* Linux `mmap(2)`: https://man7.org/linux/man-pages/man2/mmap.2.html
* 分岐なし二分探索の解説 (Khuong & Morin, Array Layouts for Comparison-Based Searching): https://arxiv.org/abs/1509.05053
