# 02. キーの符号化: 正規化、frame-of-reference、差分圧縮

background.md の 2.1、2.2 (符号化の側)、2.4、2.5 に対応する。

* 論文の B-Tree はキーを**ただのバイト列**として扱い、`memcmp` で比較する。型付きの値をそのバイト列に変換するのが**キー正規化**。
* heads (01) と dense leaves (論文 3.5) は、正規化済みのキーを前提にしている。
* 差分圧縮は論文が採用**しなかった**方式。LSM-tree (10) と比較するために書いておく。

| 節 | 内容 | 論文での使われ方 |
|---|---|---|
| 1 | キー正規化 (整数、浮動小数点、文字列、NULL、DESC、複合キー) | キーは正規化済みという前提 |
| 2 | heads との関係 | heads = 正規化キーの先頭 4 バイト |
| 3 | frame-of-reference (FOR) と dense leaves の添字計算 | dense leaves |
| 4 | 差分圧縮 + restart point (LevelDB のブロック形式) | 不採用の理由、LSM での hints |

---

## 1. キー正規化

### 1.1 目的と論文との関係

* 型付きの値の列 (タプル) を、「**バイト列の辞書順 = 元の値の順**」となるバイト列に変換する (Graefe)。
* 変換は挿入時に 1 回。比較は常に `memcmp` 1 種類になり、B-Tree 側は型を知らなくてよい。
* 満たすべき性質は 2 つ。
  * **順序保存**: `a < b ⇔ enc(a) < enc(b)` (バイト列の辞書順で)。
  * **接頭辞フリー** (複合キーのため): 同じ列の 2 つの値について、一方の符号がもう一方の符号の真の接頭辞にならない。
    これが成り立つと、列ごとの符号をつなげたものの辞書順が、タプルの辞書順と一致する。

### 1.2 データ配置: 列ごとの符号

この資料で採用する規則をまとめる (固定長の整数は CockroachDB の `EncodeUint32Ascending` / `EncodeUint64Ascending` と同じ。FoundationDB の整数は長さごとに型コードを分けた可変長なので違う。型マーカーは付けない)。

| 型 | 符号 (昇順) | バイト数 |
|---|---|---|
| `u8/u16/u32/u64` | ビッグエンディアン | 1/2/4/8 |
| `i8/i16/i32/i64` | 符号ビットを反転してからビッグエンディアン | 1/2/4/8 |
| `f32/f64` | 正 (符号ビット 0): 符号ビットだけ反転。負: 全ビット反転。その後ビッグエンディアン | 4/8 |
| バイト列 / 文字列 | `00` → `00 FF` にエスケープし、終端 `00 01` を付ける | 長さ + `00` の個数 + 2 |
| NULL 可能な列 | 値の前にマーカー 1 バイト (1.6 節) | +1 |
| DESC の列 | 昇順の符号を全ビット反転 (マーカーは除く) | 同じ |

* 整数を**可変長**にしない。CockroachDB の `EncodeVarintAscending` のような可変長符号も順序は保存するが、
  dense leaves は「ノード内の全キーが同じ長さで、末尾 4 バイトだけが違う」ことを要求する (論文 3.5)。固定長なら連番の ID が連続した末尾 4 バイトになる。

### 1.3 整数

```
u32  5          → 00 00 00 05
i32  0          → 80 00 00 00        (0x00000000 ^ 0x80000000)
i32  -1         → 7F FF FF FF        (0xFFFFFFFF ^ 0x80000000)
i32  i32::MIN   → 00 00 00 00
i32  i32::MAX   → FF FF FF FF
```

* 2 の補数で符号ビットを反転すると、`i32::MIN..=i32::MAX` が `0..=u32::MAX` に単調に写る。

```rust
fn enc_u32(v: u32, out: &mut Vec<u8>) { out.extend_from_slice(&v.to_be_bytes()); }
fn enc_i32(v: i32, out: &mut Vec<u8>) { enc_u32((v as u32) ^ 0x8000_0000, out); }
fn dec_i32(b: [u8; 4]) -> i32 { (u32::from_be_bytes(b) ^ 0x8000_0000) as i32 }
// u8/u16/u64、i8/i16/i64 も同じ形。符号ビットは 0x80, 0x8000, 0x8000_0000_0000_0000。
```

### 1.4 浮動小数点

IEEE 754 のビット列は「符号 + 絶対値」の形。正の数はビット列を符号なし整数とみなすと順序どおり、負の数は逆順になる。

```
f32      ビット列     変換後
-42.0    C2 28 00 00  3D D7 FF FF   (負: 全ビット反転)
-0.0     80 00 00 00  7F FF FF FF
+0.0     00 00 00 00  80 00 00 00   (正: 符号ビットだけ反転)
 1.0     3F 80 00 00  BF 80 00 00
+inf     7F 80 00 00  FF 80 00 00
```

`-42.0` の行は FoundationDB の tuple layer の試験ケース (`pack(-42f)`) と一致する。

```rust
fn enc_f64(v: f64, out: &mut Vec<u8>) {
    let b = v.to_bits();
    let u = if b >> 63 == 1 { !b } else { b | (1u64 << 63) };
    out.extend_from_slice(&u.to_be_bytes());
}
fn dec_f64(x: [u8; 8]) -> f64 {
    let u = u64::from_be_bytes(x);
    let b = if u >> 63 == 1 { u & !(1u64 << 63) } else { !u };
    f64::from_bits(b)
}
// f32 は u32 で同じ。
```

**-0.0 と NaN の方針** (どれかを選んで文書化する):

| 方針 | 並び | 復号 |
|---|---|---|
| A. 全順序 (この資料の既定) | -NaN < -inf < … < -0.0 < +0.0 < … < +inf < +NaN | 可逆 (NaN のペイロードも戻る) |
| B. SQL 的 | 符号化の前に `-0.0 → +0.0`、全 NaN → 1 つの正規 NaN (正の quiet NaN) | 不可逆 (-0.0 と NaN の種類が失われる) |

* A は Rust の `f64::total_cmp` と同じ順序になる。FoundationDB の tuple layer も A ("IEEE total ordering" と同等と書いている)。
* B では `-0.0 == 0.0` が「同じキー」になる。一意索引で `-0.0` と `0.0` を別の行として許したくないなら B を選ぶ。
  正規 NaN は正の符号なので最大になる (PostgreSQL も NaN を最大として扱う)。
* CockroachDB は NaN と 0 を専用のマーカーバイトで表す別方式 (`float.go:EncodeFloatAscending`。NaN が最小、±0 は同じ符号)。

### 1.5 バイト列と文字列

```
"ab"      → 61 62 00 01
""        → 00 01
"a\0b"    → 61 00 FF 62 00 01
"a\0"     → 61 00 FF 00 01
```

**順序が保たれる理由**: 2 つの文字列 x, y を先頭から比べる。

* 最初に違う元のバイトが c < d なら、符号の同じ位置も c < d (`00` だけは `00 FF` になるが、先頭は `00` のまま)。
* x が y の真の接頭辞のとき (x が短い):
  * y の次のバイトが `00` 以外 (≥ `01`): x の終端 `00` < それ。→ x が小さい。
  * y の次のバイトが `00`: x は `00 01`、y は `00 FF`。`01 < FF` → x が小さい。
* どちらも「短い方が小さい」になり、元の辞書順と一致する。
* 終端 `00 01` は符号の中に他の場所では現れないので、接頭辞フリーになる。

**終端がないと壊れる例** (background.md 2.1): `("a","bc")` と `("ab","c")` がどちらも `61 62 63` になる。

```rust
fn enc_bytes(s: &[u8], out: &mut Vec<u8>) {
    for &b in s {
        if b == 0x00 { out.extend_from_slice(&[0x00, 0xFF]); } else { out.push(b); }
    }
    out.extend_from_slice(&[0x00, 0x01]);
}

/// 符号を読んで元のバイト列と消費バイト数を返す。desc なら各バイトを反転して読む。
fn dec_bytes(input: &[u8], desc: bool) -> Result<(Vec<u8>, usize), DecodeError> {
    let un = |b: u8| if desc { !b } else { b };
    let mut out = Vec::new();
    let mut i = 0;
    loop {
        let b = un(*input.get(i).ok_or(DecodeError::Truncated)?);
        if b != 0x00 { out.push(b); i += 1; continue; }
        match un(*input.get(i + 1).ok_or(DecodeError::Truncated)?) {
            0xFF => { out.push(0x00); i += 2; }
            0x01 => return Ok((out, i + 2)),
            _ => return Err(DecodeError::BadEscape),
        }
    }
}
```

* FoundationDB の tuple layer は終端が `00` 1 バイト (`00` → `00 FF` は同じ)。直後に来る型コードがすべて `FF` 未満なので成り立つ (`tuple.md` は `0xff` を「エスケープのため予約、型コードとして使わない」と明記している)。
  型コードを付けない方式では、次の列の先頭が `FF` になりうるので、2 バイト終端 (CockroachDB 方式) にする。
* 文字列は**バイト順**で比べる。UTF-8 のバイト順はコードポイント順と一致する。ロケール依存の照合順序 (collation) が必要なら、
  ICU のソートキーなどで照合キーを作ってから、それをバイト列として符号化する (この資料の範囲外)。

### 1.6 NULL

* NULL 可能な列には、値の前に**マーカー 1 バイト**を付ける。NOT NULL の列には付けない (1 バイト節約、heads も 1 バイト分よく効く)。
* マーカーは **NULLS FIRST / LAST だけで決め、ASC / DESC では反転しない**。

| 指定 | NULL | 非 NULL |
|---|---|---|
| NULLS FIRST | `00` | `01` + 値の符号 |
| NULLS LAST | `01` | `00` + 値の符号 |

* PostgreSQL の既定は「NULL は最大」なので、ASC なら NULLS LAST、DESC なら NULLS FIRST に相当する。
  既定の対応はシステムごとに違うので、SQL 層で明示的に決めてから渡す。
* NULL の後ろには値の符号を置かない。マーカーだけで長さが決まるので、接頭辞フリーは保たれる (`00` と `01 …` は先頭で決着)。

### 1.7 降順 (DESC)

* 昇順の符号を**全ビット反転**する。反転は大小を逆にし、接頭辞フリーも保つ。
* 固定長の型は単純。可変長 (文字列) では**終端も反転しなければならない**。

```
ASC の符号          "a"  = 61 00 01      "ab" = 61 62 00 01
全部反転 (正しい)    "a"  = 9E FF FE      "ab" = 9E 9D FF FE
                     2 バイト目: FF > 9D → "a" > "ab"   ✓ 降順

終端を反転しない (誤り) "a" = 9E 00 01    "ab" = 9E 9D 00 01
                     2 バイト目: 00 < 9D → "a" < "ab"   ✗ 昇順のまま
```

* 反転しない終端は「短い方が常に小さい」性質を持ち込むので、DESC の列で接頭辞関係にある値の順が逆にならない。
* 復号側は、DESC の列ではエスケープ `FF 00`、終端 `FF FE` を探す (`dec_bytes(.., desc=true)`)。
* CockroachDB の `EncodeBytesDescending` も「昇順で符号化してから反転」。

### 1.8 複合キー: エンコーダとデコーダ

```rust
enum ColType { U32, U64, I32, I64, F64, Bytes /* 他の幅も同様 */ }

struct ColSpec {
    ty: ColType,
    nullable: bool,
    desc: bool,
    nulls_first: bool,   // nullable のときだけ意味がある
}

enum Value { Null, U32(u32), U64(u64), I32(i32), I64(i64), F64(f64), Bytes(Vec<u8>) }

fn encode_key(vals: &[Value], schema: &[ColSpec], out: &mut Vec<u8>) {
    assert_eq!(vals.len(), schema.len());
    for (v, c) in vals.iter().zip(schema) {
        if c.nullable {
            let (null_mark, val_mark) = if c.nulls_first { (0x00, 0x01) } else { (0x01, 0x00) };
            if let Value::Null = v { out.push(null_mark); continue; }
            out.push(val_mark);
        } else if let Value::Null = v {
            panic!("NULL in NOT NULL column");
        }
        let start = out.len();
        match (v, &c.ty) {
            (Value::U32(x), ColType::U32) => enc_u32(*x, out),
            (Value::U64(x), ColType::U64) => out.extend_from_slice(&x.to_be_bytes()),
            (Value::I32(x), ColType::I32) => enc_i32(*x, out),
            (Value::I64(x), ColType::I64) => out.extend_from_slice(&((*x as u64) ^ (1 << 63)).to_be_bytes()),
            (Value::F64(x), ColType::F64) => enc_f64(*x, out),
            (Value::Bytes(s), ColType::Bytes) => enc_bytes(s, out),
            _ => panic!("type mismatch"),
        }
        if c.desc {
            for b in &mut out[start..] { *b = !*b; }   // マーカーは start より前なので反転されない
        }
    }
}

fn decode_key(mut k: &[u8], schema: &[ColSpec]) -> Result<Vec<Value>, DecodeError> {
    let mut vals = Vec::with_capacity(schema.len());
    for c in schema {
        if c.nullable {
            let null_mark = if c.nulls_first { 0x00 } else { 0x01 };
            let m = *k.first().ok_or(DecodeError::Truncated)?;
            k = &k[1..];
            if m == null_mark { vals.push(Value::Null); continue; }
            // m が val_mark でなければ DecodeError::BadMarker
        }
        // 固定長: 幅だけ切り出し、desc なら反転してから dec_*。
        // Bytes: dec_bytes(k, c.desc) が消費バイト数を返す。
        let (v, used) = decode_one(k, &c.ty, c.desc)?;   // 型ごとの分岐は省略
        vals.push(v);
        k = &k[used..];
    }
    if !k.is_empty() { return Err(DecodeError::TrailingBytes); }
    Ok(vals)
}
```

* 型マーカーを付けないので、**スキーマがないと復号できない**。FoundationDB / CockroachDB は型コードを付けてスキーマなしで復号できるようにしている (1 列あたり 1 バイト多い)。
* 復号できないのは方針 B の浮動小数点 (情報が落ちる) だけ。

### 1.9 バイト単位の例

background.md の例。`a INT NOT NULL, s TEXT (NULL 可, NULLS FIRST), id INT NOT NULL DESC`。

```
(-1, "ab", 5)
a  = -1          → 7F FF FF FF                  (マーカーなし: NOT NULL)
s  = "ab"        → 01 | 61 62 00 01             (非NULL マーカー 01, 本体, 終端)
id = 5 DESC      → ~(80 00 00 05) = 7F FF FF FA
key = 7F FF FF FF 01 61 62 00 01 7F FF FF FA     (13 バイト)

(-1, NULL, 5)
key = 7F FF FF FF 00 7F FF FF FA                  (9 バイト)
      先頭 4 バイトが同じで、5 バイト目 00 < 01 → NULL が先   ✓ NULLS FIRST

(-1, "ab", 6)
key = 7F FF FF FF 01 61 62 00 01 7F FF FF F9
      最後のバイト F9 < FA → id=6 が先                       ✓ DESC
```

### 1.10 境界条件と落とし穴

* キー長が伸びる: 文字列は最悪 `2n + 2` バイト。ページに入る最大キー長 (01) の検査は**符号化後**の長さで行う。
* `00` を多く含むバイナリ列 (例: 整数をそのまま文字列列に入れたもの) は膨らむ。
* 方針 A で NaN を受け入れると、NaN 同士が別キーになる (ペイロード違い)。等値検索の意味を決めておく。
* DESC の列を後から ASC に変える、NULLS の指定を変える、はキーの全面的な再符号化になる。

### 1.11 テスト方針

* **順序保存** (性質テスト): ランダムな値の組 (a, b) について `a.cmp(&b) == enc(a).cmp(&enc(b))`。
  * 整数は `Ord`、浮動小数点 (方針 A) は `total_cmp`、文字列は `[u8]` の `Ord` をオラクルにする。
  * 複合キーは、列ごとに「NULL の位置、DESC」を反映した比較関数をオラクルとして手で書く。
* **往復**: `decode_key(encode_key(v)) == v` (方針 A。NaN はビット列で比べる)。
* **接頭辞フリー**: 同じ列の符号 x, y について `!(x != y && y.starts_with(&x))`。
* 生成器は境界値に偏らせる: 0, -1, MIN, MAX, ±0.0, ±inf, NaN, 空文字列, `"\0"`, `"\0\x01"`, `"\xFF"`, 長い共通接頭辞を持つ文字列。
* 符号化したキーで `BTreeMap<Vec<u8>, _>` を作り、元の値で作った `BTreeMap<Tuple, _>` と走査順が一致するかを比べる。

---

## 2. heads との関係 (poor man's normalized keys)

* head (00 の `head`) は、**prefix truncation の後の**正規化キーの先頭 4 バイト。
* 正規化キーの作り方で、head の効き方が変わる。

| キー | head に入るもの | 効き方 |
|---|---|---|
| `u32` / `i32` 1 列 | 値全体 | head だけで比較が決着する (論文の dense / sparse) |
| `u64` 1 列 | 上位 4 バイト | 接頭辞を削った後なら、ノード内で違う部分が先頭に来る |
| 文字列 | 先頭 4 文字 (エスケープ後) | URL のように共通接頭辞が長いと、削らないと全部同じ (論文: urls で 38%、wiki で 61% の隣接ペアが head で区別できる) |
| NULL 可能列が先頭 | マーカー 1 バイト + 3 バイト | 1 バイト無駄になる。NOT NULL ならマーカーなし |

* キーの列順は「区別しやすい列を先に」とはいかない (並び順は SQL の索引定義で決まる)。prefix truncation で共通部分を削るのが現実的な対策。
* heads はバイト列の先頭を見るだけなので、**正規化していないキー** (例: リトルエンディアンの整数) では順序が壊れ、使えない。

---

## 3. Frame-of-reference (FOR)

### 3.1 目的と論文との関係

* 値の集まりを「**基準値 (reference) からの差**」で持つ。差が小さければ少ないビットで表せる (Goldstein et al., ICDE 1998)。
* 論文の dense leaves は、その差を**配列の添字**として使う。キー比較なしで `slots[key - reference]` と引ける。

### 3.2 一般の FOR: データ配置

```
値:        1005 1009 1002 1015
reference: 1002 (= 最小値)
差:           3    7    0   13        最大 13 → 4 ビット
ビット詰め: |0011|0111|0000|1101| ...  (u64 の下位ビットから詰める)
```

```rust
struct ForBlock {
    reference: u64,  // 最小値
    width: u32,      // 1 値あたりのビット数 (0..=64)
    n: usize,
    words: Vec<u64>, // 末尾に 1 語の余白を置き、2 語にまたがる読み込みで範囲外にしない
}
```

### 3.3 FOR の擬似コード

```rust
fn bit_width(x: u64) -> u32 { 64 - x.leading_zeros() }   // 0 → 0, 1 → 1, 13 → 4

fn for_encode(vals: &[u64]) -> ForBlock {
    let min = vals.iter().copied().min().unwrap_or(0);
    let max = vals.iter().copied().max().unwrap_or(0);
    let width = bit_width(max - min);
    let mut words = vec![0u64; (vals.len() * width as usize + 63) / 64 + 1];
    for (i, &v) in vals.iter().enumerate() {
        let d = v - min;
        let bit = i * width as usize;
        let (w, s) = (bit / 64, (bit % 64) as u32);
        if width == 0 { break; }
        words[w] |= d << s;
        if s + width > 64 { words[w + 1] |= d >> (64 - s); } // s > 0 が保証される
    }
    ForBlock { reference: min, width, n: vals.len(), words }
}

fn for_get(b: &ForBlock, i: usize) -> u64 {
    if b.width == 0 { return b.reference; }
    let bit = i * b.width as usize;
    let (w, s) = (bit / 64, (bit % 64) as u32);
    let lo = b.words[w] >> s;
    let hi = if s + b.width > 64 { b.words[w + 1] << (64 - s) } else { 0 };
    let mask = if b.width == 64 { u64::MAX } else { (1u64 << b.width) - 1 };
    b.reference + ((lo | hi) & mask)
}
```

* **reference = 最小値**にすると、差がすべて非負になり、ビット幅が最小になる。
  先頭の値や下限 fence を reference にすると、差が負になりうる (符号付きの差が必要になる)。
* ソート済みの値なら、検索は `x - reference` を差の列の上で二分探索するだけ。`x < reference` なら位置 0。
* 挿入で `v < reference` か `v - reference` が幅に収まらない値が来たら、ブロック全体を作り直す (`for_encode` をやり直す)。

### 3.4 dense leaves での使い方: キーから添字へ

論文 3.5 の規則 (参照実装 `btree-cpp: btree/dense.cpp`):

* ノード内の全キーは**同じ長さ** `full_len` で、**末尾 4 バイト (数値部分) だけが違う**。それ以外の部分 (非数値部分) は下限 fence と同じ。
* **数値部分**: キーの末尾 4 バイトを BE の u32 として読む。
  * キーが 4 バイト未満なら、**先頭側**に 0 があるとみなす (head は末尾側を 0 埋めする。向きが逆)。
* **reference (`array_start`)**: 「下限 fence より大きい、長さ `full_len` の最小のキー」の数値部分。
  * fence が `full_len` と同じ長さ: fence の数値部分 + 1。
  * fence が短い: fence の後ろに 0 を足して `full_len` にしたもの (これは fence より真に大きい)。+1 はしない。
* **添字** = 数値部分 − `array_start`。`slot_count` 未満なら、その位置のスロットを使う。

```rust
/// key を長さ target_len に揃えたときの、末尾 4 バイトの値。
/// key が短ければ末尾に 0 を足す (fence 用)。target_len < 4 なら先頭側を 0 とみなす。
fn numeric_part(key: &[u8], target_len: usize) -> u32 {
    let len = key.len().min(target_len);
    if len + 4 <= target_len { return 0; }          // 末尾 4 バイトがすべて足した 0
    let take = len.min(4);
    let mut x: u32 = 0;
    for &b in &key[len - take..len] { x = (x << 8) | b as u32; }  // 最後の take バイトを BE で
    // target_len - len バイト分だけ 0 を末尾に足したことにする (溢れた上位は捨てる)
    x.checked_shl(8 * (target_len - len) as u32).unwrap_or(0)
}

fn array_start(lower_fence: &[u8], full_len: usize) -> Option<u32> {
    let a = numeric_part(lower_fence, full_len);
    if lower_fence.len() >= full_len {
        a.checked_add(1)   // u32::MAX なら dense にできない (None)
    } else {
        Some(a)
    }
}

enum KeyIndex { Slot(usize), WrongLen, NotNumericRange, TooLarge }

fn key_to_index(key: &[u8], lower_fence: &[u8], full_len: usize,
                array_start: u32, slot_count: usize) -> KeyIndex {
    if key.len() != full_len { return KeyIndex::WrongLen; }
    let non_numeric = full_len.saturating_sub(4);
    // 非数値部分が下限 fence と一致するか (prefix truncation 済みなら接頭辞の後ろだけ比べる)
    if key[..non_numeric] != lower_fence[..non_numeric] { return KeyIndex::NotNumericRange; }
    let np = numeric_part(key, full_len);
    debug_assert!(np >= array_start);    // fence による振り分けで保証される
    let idx = (np - array_start) as usize;
    if idx < slot_count { KeyIndex::Slot(idx) } else { KeyIndex::TooLarge }
}

/// 添字からキーを復元する (走査のとき)。
fn restore_key(lower_fence: &[u8], full_len: usize, array_start: u32, idx: usize, out: &mut Vec<u8>) {
    let np_len = full_len.min(4);
    out.clear();
    out.extend_from_slice(&lower_fence[..full_len - np_len]);
    let np = (array_start + idx as u32).to_be_bytes();
    out.extend_from_slice(&np[4 - np_len..]);
}
```

* 参照実装の対応: `dense.cpp:getNumericPart`, `leastGreaterKey`, `keyToIndex`, `restoreKey`。
  参照実装は `TooLarge` を `SlightlyTooLarge` (添字 < 1.5 × slot_count) と `FarTooLarge` に分け、split の作り方を変えている (論文 3.5 "Dense Leaf Split")。
* 前提条件「非数値部分の全体が下限 fence に含まれる」(`full_len - 4 <= fence.len()`) が成り立たないノードは dense にしない。

### 3.5 バイト単位の例 (論文の例)

キー = (文字列 `'wiki'`, `u32`)。1.5 節の規則で `'wiki'` → `77 69 6B 69 00 01`、整数は 4 バイト BE。

```
('wiki', 12)   = 77 69 6B 69 00 01 | 00 00 00 0C     full_len = 10
                 └ 非数値部分 (6) ┘   └ 数値部分 ┘

下限 fence = ('wiki', 12) (長さ 10 = full_len)  → array_start = 12 + 1 = 13
slot_count = 400                               → スロット 0..399 = ('wiki', 13) .. ('wiki', 412)

key ('wiki', 100): 数値部分 100 → 添字 87
key ('wiki', 500): 数値部分 500 → 487 ≥ 400 → TooLarge → split (論文: 新しい空の葉を作る)

下限 fence = 'wiki' だけ (77 69 6B 69 00 01, 長さ 6)
  → 0 を足して 77 69 6B 69 00 01 00 00 00 00 → array_start = 0
```

論文の整数キー (dense / sparse) は `u32` 1 列 (4 バイト BE)。非数値部分は空で、キー全体が数値部分になる。

### 3.6 不変条件

* FOR: `for_get(encode(v), i) == v[i]` (全 i)。`width == bit_width(max - min)`。
* dense: 存在するスロット i について `restore_key(i)` は下限 fence より大きく、上限 fence 以下。`key_to_index(restore_key(i)) == Slot(i)`。

### 3.7 境界条件と落とし穴

* `width == 64` で `1 << 64` は桁あふれ。マスクを場合分けする。
* `width == 0` (全値が同じ) を特別扱いしないと、`d << s` などの式は動いても `words` が空になりうる。
* `array_start + idx` は u32 の加算。`array_start` の計算で `u32::MAX + 1` を検出して dense を諦める (参照実装は assert だけ)。
* `u64` の ID 列では、数値部分 (下位 4 バイト) が `0xFFFF_FFFF → 0` と桁上がりする境目で、非数値部分も変わる。そこをまたぐノードは dense にできない。
* 符号付き整数でも、符号ビット反転後に連番なら数値部分も連番 (−1 → `7FFFFFFF`, 0 → `80000000`)。

### 3.8 テスト方針

* FOR: 幅 0〜64 のそれぞれについて、ランダムな値で往復を確かめる。2 語にまたがる位置 (例: 幅 7 で i = 9) を必ず含める。
* `numeric_part`: 「key を `full_len` まで 0 で延ばし、末尾 4 バイトを (足りなければ先頭を 0 で埋めて) BE で読む」素朴版と比べる。長さ 0〜12、`full_len` 0〜12 の全組み合わせ。
* dense: ランダムな fence と slot_count で、`restore_key` と `key_to_index` の往復を確かめる。
  さらに `BTreeMap` のオラクルで、`slots` 配列経由の lookup が一致するかを確かめる。

---

## 4. 差分圧縮と restart point (LevelDB / RocksDB のブロック形式)

### 4.1 目的と論文との関係

* ソート済みのキー列で、**直前のキーと共通する接頭辞の長さ**だけを記録し、残りを格納する。
* そのままでは途中から復元できない。K 件ごとに接頭辞を共有しない完全なキー (**restart point**) を置き、その位置を末尾の配列に持つ。
* 論文はこの方式を採らない (展開が遅い。background.md 2.5)。LSM-tree への応用では「hints は restart point からサンプリングするとよい」と提案している。

### 4.2 データ配置

```
ブロック (バイト列)
+------------------------------------------------------------+
| entry 0 | entry 1 | ... | entry n-1 |                       |
+------------------------------------------------------------+
| restarts[0] (u32 LE) | restarts[1] | ... | num_restarts (u32 LE) |
+------------------------------------------------------------+

entry:
  shared      : varint32   直前のキーと共通する接頭辞の長さ (restart なら 0)
  non_shared  : varint32   残りの長さ
  value_len   : varint32
  key_delta   : [u8; non_shared]
  value       : [u8; value_len]
```

* **整数の向きに注意**: 末尾の `restarts` と `num_restarts` は**リトルエンディアン**の固定 4 バイト (LevelDB の `Fixed32`)。キーの正規化 (BE) とは逆。
* restart の間隔 K は LevelDB の既定で 16 (`options.h:block_restart_interval`)。

```
K = 2 の例。キー: apple, applesauce, banana, band
off 0  : [0][5][1] "apple"      "v"      ← restart 0
off 9  : [5][5][1] "sauce"      "v"      → "applesauce"
off 18 : [0][6][1] "banana"     "v"      ← restart 1
off 28 : [3][1][1] "d"          "v"      → "band"
off 33 : 00 00 00 00 | 12 00 00 00 | 02 00 00 00
         restarts[0]=0  restarts[1]=18  num_restarts=2
```

### 4.3 varint32 (LEB128)

```
値は 7 ビットずつ下位から並べ、続きがあるバイトは最上位ビットを 1 にする。
1      → 01
127    → 7F
128    → 80 01
300    → AC 02     (300 = 0b10_0101100 → 1_0101100, 0_0000010)
```

```rust
fn put_varint32(out: &mut Vec<u8>, mut v: u32) {
    while v >= 0x80 { out.push((v as u8) | 0x80); v >>= 7; }
    out.push(v as u8);
}

/// 戻り値: (値, 次の位置)。limit を越えるか 5 バイトを超えたら None。
fn get_varint32(buf: &[u8], mut p: usize, limit: usize) -> Option<(u32, usize)> {
    let mut result = 0u32;
    let mut shift = 0;
    while shift <= 28 && p < limit {
        let b = buf[p] as u32; p += 1;
        result |= (b & 0x7F) << shift;
        if b & 0x80 == 0 { return Some((result, p)); }
        shift += 7;
    }
    None
}
```

### 4.4 ブロックビルダー

```rust
struct BlockBuilder {
    buf: Vec<u8>,
    restarts: Vec<u32>,  // 最初は [0]
    counter: usize,      // 直近の restart からのエントリ数
    last_key: Vec<u8>,
    interval: usize,     // K (>= 1)
}

impl BlockBuilder {
    fn new(interval: usize) -> Self {
        BlockBuilder { buf: vec![], restarts: vec![0], counter: 0, last_key: vec![], interval }
    }

    /// キーは厳密に増加する順に渡す。
    fn add(&mut self, key: &[u8], value: &[u8]) {
        debug_assert!(self.buf.is_empty() || key > self.last_key.as_slice());
        let mut shared = 0;
        if self.counter < self.interval {
            let m = self.last_key.len().min(key.len());
            while shared < m && self.last_key[shared] == key[shared] { shared += 1; }
        } else {
            self.restarts.push(self.buf.len() as u32);  // ここから新しい restart
            self.counter = 0;                           // shared = 0 のまま
        }
        put_varint32(&mut self.buf, shared as u32);
        put_varint32(&mut self.buf, (key.len() - shared) as u32);
        put_varint32(&mut self.buf, value.len() as u32);
        self.buf.extend_from_slice(&key[shared..]);
        self.buf.extend_from_slice(value);
        self.last_key.truncate(shared);
        self.last_key.extend_from_slice(&key[shared..]);
        self.counter += 1;
    }

    fn size_estimate(&self) -> usize { self.buf.len() + 4 * self.restarts.len() + 4 }

    fn finish(mut self) -> Vec<u8> {
        for &r in &self.restarts { self.buf.extend_from_slice(&r.to_le_bytes()); }
        self.buf.extend_from_slice(&(self.restarts.len() as u32).to_le_bytes());
        self.buf
    }
}
```

* 最初のエントリは `restarts = [0]` の restart になる (`counter = 0 < K` だが `last_key` が空なので shared = 0)。
* 空のブロックでも `restarts = [0]`, `num_restarts = 1` を書く (8 バイト)。
* 参照: `leveldb: table/block_builder.cc:BlockBuilder::Add`, `Finish`。

### 4.5 ブロックリーダー

```rust
struct Block<'a> { data: &'a [u8], restart_off: usize, num_restarts: u32 }

fn open_block(data: &[u8]) -> Result<Block, Corrupt> {
    if data.len() < 4 { return Err(Corrupt); }
    let n = u32::from_le_bytes(data[data.len() - 4..].try_into().unwrap());
    let max = (data.len() - 4) / 4;
    if n == 0 || n as usize > max { return Err(Corrupt); }
    Ok(Block { data, restart_off: data.len() - 4 * (1 + n as usize), num_restarts: n })
}

impl Block<'_> {
    fn restart_point(&self, i: u32) -> usize {
        let o = self.restart_off + 4 * i as usize;
        u32::from_le_bytes(self.data[o..o + 4].try_into().unwrap()) as usize
    }

    /// p のエントリを読む。戻り値: (shared, non_shared, value_len, key_delta の位置)
    fn decode_entry(&self, p: usize) -> Option<(usize, usize, usize, usize)> {
        let lim = self.restart_off;
        let (s, p) = get_varint32(self.data, p, lim)?;
        let (ns, p) = get_varint32(self.data, p, lim)?;
        let (vl, p) = get_varint32(self.data, p, lim)?;
        if lim - p < ns as usize + vl as usize { return None; }  // 範囲外を読ませない
        Some((s as usize, ns as usize, vl as usize, p))
    }
}

struct BlockIter<'a> {
    b: &'a Block<'a>,
    current: usize,      // 今のエントリの位置。>= restart_off なら無効
    next: usize,         // 次のエントリの位置
    key: Vec<u8>,
    value: (usize, usize), // data 内の範囲
}

impl BlockIter<'_> {
    fn valid(&self) -> bool { self.current < self.b.restart_off }

    fn seek_to_restart(&mut self, i: u32) {
        self.key.clear();
        self.next = self.b.restart_point(i);
    }

    /// 次のエントリへ進む。終わりなら false。
    fn parse_next(&mut self) -> bool {
        self.current = self.next;
        if self.current >= self.b.restart_off { return false; }
        let (s, ns, vl, p) = self.b.decode_entry(self.current).expect("corrupt");
        assert!(s <= self.key.len(), "corrupt: shared > 前のキー長");
        self.key.truncate(s);
        self.key.extend_from_slice(&self.b.data[p..p + ns]);
        self.value = (p + ns, p + ns + vl);
        self.next = p + ns + vl;
        true
    }

    /// key >= target となる最初のエントリに位置づける (lower_bound)。
    fn seek(&mut self, target: &[u8]) {
        // 1. restart の上の二分探索: 「キー < target」となる最後の restart を探す
        let (mut left, mut right) = (0u32, self.b.num_restarts - 1);
        while left < right {
            let mid = (left + right + 1) / 2;          // 上に丸める (left = mid で止まらないように)
            let off = self.b.restart_point(mid);
            let (s, ns, _, p) = self.b.decode_entry(off).expect("corrupt");
            assert!(s == 0, "corrupt: restart のエントリは shared = 0");
            let mid_key = &self.b.data[p..p + ns];
            if mid_key < target { left = mid; } else { right = mid - 1; }
        }
        // 2. その restart から前向きに線形探索
        self.seek_to_restart(left);
        loop {
            if !self.parse_next() { return; }           // 末尾まで来た: 無効 (全キー < target)
            if self.key.as_slice() >= target { return; }
        }
    }

    fn seek_to_first(&mut self) { self.seek_to_restart(0); self.parse_next(); }

    fn seek_to_last(&mut self) {
        self.seek_to_restart(self.b.num_restarts - 1);
        while self.parse_next() && self.next < self.b.restart_off {}
    }
}

/// 点検索: seek してから等しいかを見る。
fn block_get<'a>(b: &'a Block, key: &[u8]) -> Option<&'a [u8]> {
    let mut it = BlockIter { b, current: b.restart_off, next: b.restart_off, key: vec![], value: (0, 0) };
    it.seek(key);
    if it.valid() && it.key == key { Some(&b.data[it.value.0..it.value.1]) } else { None }
}
```

* **seek の意味**: `key >= target` の最初のエントリ。無効になったら「このブロックの全キーが target より小さい」(次のブロックへ進む)。
* `prev` は restart 配列を逆にたどって「現在位置より前の restart」に戻り、そこから前向きに読み直す。コストは最大 K エントリの再デコード。
* 参照: `leveldb: table/block.cc:Block::Iter::Seek`, `ParseNextKey`, `Prev`, `DecodeEntry`。
  LevelDB の `DecodeEntry` は「3 つとも 128 未満なら 1 バイトずつ」の速い経路を持つ。上の擬似コードでは省いた。

### 4.6 不変条件

* キーはブロック内で厳密に増加。
* `restarts[0] == 0`、`restarts` は厳密に増加、各 restart のエントリは `shared == 0`。
* restart の間のエントリ数は K 以下 (最後の区間だけ短くてよい)。
* 各エントリの `shared` は直前のキーの長さ以下。

### 4.7 コストと論文の主張との関係

```
lookup のコスト ≈ log2(n / K) 回の restart キー比較 (それぞれ別のキャッシュラインへのランダムアクセス)
              + 最大 K 回のエントリ復元 (前のキーへの依存があるので逐次的)
```

* 比較の前にキーを**復元 (コピー)** する必要がある。slotted page + heads なら、スロットの head と本体を直接比べられる。
* 論文が引く比較研究 (Gao et al. SIGMOD 2024) の結論は「Head+Tail (prefix + suffix truncation) が総合的に最良」。差分圧縮は展開のコストで遅い。
* LSM-tree (10) の SSTable はこの形式。そこに hints を足すなら、restart キーの先頭 4 バイトを固定長の配列に抜き出しておく (論文の提案)。

### 4.8 境界条件と落とし穴

* 空ブロックの seek は、`restarts[0] = 0 = restart_off` なので最初の `parse_next` で無効になる。
* `num_restarts` が壊れていると `restart_off` が負になる。`open_block` で `n <= (len - 4) / 4` を必ず検査する。
* 壊れたデータで `shared > key.len()` になる。ここで panic せず `Corrupt` を返す設計にするなら、`parse_next` を `Result` にする。
* 同じキーの二重追加は `add` の debug_assert で止める。LevelDB の SSTable は内部キー (ユーザーキー + 8 バイトのシーケンス番号と種別) で重複を避けている。
* restart の間隔 K を大きくすると圧縮率が上がるが、seek の線形部分が伸びる。K = 1 なら差分圧縮なし (RocksDB の index block の既定は 1)。【未検証】RocksDB の既定値は確認していない。

### 4.9 テスト方針

* ランダムなキー集合 (共通接頭辞が長いもの、空キー、`00`/`FF` を含むもの) をソートし、K ∈ {1, 2, 16, 1000} でブロックを作る。
* **seek のオラクル**: ソート済みの `Vec<(key, value)>` の `partition_point(|(k, _)| k < target)`。
  target は「存在するキー」「存在しないキー」「全キーより小さい / 大きい」「restart キーちょうど」を混ぜる。
* **全走査**: `seek_to_first` から `parse_next` で全件取り出し、入力と一致すること。
* `seek_to_last` が最後のキーを指すこと。
* `size_estimate()` が `finish()` の長さと一致すること。
* 壊れた入力 (ランダムなバイト列、末尾を切ったブロック) を `open_block` / `seek` に渡しても、範囲外読み込みで panic しない (`Corrupt` を返す) ことをファジングで確かめる。

---

## 5. 原典との違い・簡略化

* キー正規化の規則は複数のシステムの考え方を組み合わせた**この資料の方式**。型マーカーを付けない (スキーマ必須)、NOT NULL 列にはマーカーなし、整数は固定長。
  FoundationDB / CockroachDB / PostgreSQL のどれとも**バイト単位では互換でない**。
* 文字列のエスケープと 2 バイト終端は CockroachDB (`encoding.go:EncodeBytesAscending`) と同じ。CockroachDB はさらに型マーカー (`0x12`) を前に付ける。
* 浮動小数点は FoundationDB の tuple layer と同じ変換 (型コードなし)。
* 照合順序 (collation)、DECIMAL、日付時刻、可変長整数は扱っていない。
* dense leaves の擬似コードは参照実装の `getNumericPart` / `leastGreaterKey` / `keyToIndex` を、prefix truncation を外した形に書き直した。
  参照実装はキーを接頭辞を削った形で受け取り、`prefixLength` 分ずらして比較する。
* LevelDB の形式から、内部キー、ブロックの圧縮 (Snappy) と CRC、フィルタ、RocksDB の拡張 (値の差分符号化、ブロック内ハッシュ索引) を省いた。

## 参考資料

* 本論文: Müller, Benson, Leis. B-Trees Are Back. SIGMOD 2025. https://doi.org/10.1145/3709664
* 論文の参照実装 (`btree/dense.cpp:getNumericPart`, `leastGreaterKey`, `keyToIndex`, `restoreKey`): https://github.com/m-mueller678/btree-cpp/tree/sigmod25
* FoundationDB tuple layer (`design/tuple.md`): https://github.com/apple/foundationdb/blob/main/design/tuple.md
* CockroachDB (`pkg/util/encoding/encoding.go:EncodeBytesAscending`, `EncodeBytesDescending`; `float.go:EncodeFloatAscending`): https://github.com/cockroachdb/cockroach/blob/master/pkg/util/encoding/encoding.go
* PostgreSQL wiki, Key normalization: https://wiki.postgresql.org/wiki/Key_normalization
* PostgreSQL のソート順 (NULLS FIRST / LAST の既定): https://www.postgresql.org/docs/current/queries-order.html
* Goldstein, Ramakrishnan, Shaft. Compressing Relations and Indexes. ICDE 1998: https://doi.org/10.1109/ICDE.1998.655800
* LevelDB (`table/block_builder.cc:BlockBuilder::Add`, `Finish`; `table/block.cc:Block::Iter::Seek`, `ParseNextKey`; `util/coding.cc:EncodeVarint32`): https://github.com/google/leveldb
* LevelDB の SSTable 形式の説明: https://github.com/google/leveldb/blob/main/doc/table_format.md
* RocksDB block builder: https://github.com/facebook/rocksdb/blob/main/table/block_based/block_builder.cc
* Gao, Ballijepalli, Wang. Revisiting B-tree Compression (VLDBJ 拡張版): https://cs.purdue.edu/homes/csjgwang/pubs/VLDBJ26_BtreeCompression.pdf
