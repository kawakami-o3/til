# 13. ベンチマーク: Zipf 乱数、YCSB ワークロード、論文の実験手順

background.md の 6.1 (YCSB) と 6.2 (Zipf 分布) に対応する。

* 論文の数値を再現するには、**どのキーをどの頻度で引くか**を同じにする必要がある。
* Zipf 乱数の作り方は 2 通りある。
  * YCSB の方法 (Gray et al. 1994)。速いが、パラメータ θ < 1 でしか使えず、近似。
  * 論文の実装が使った方法 (Rust の `zipf` クレート = rejection-inversion)。任意の α > 0 で正確。
* 論文 6.6 節は α を 0.5〜1.5 で変えるので、**後者が必要**。

| 節 | 内容 |
|---|---|
| 1 | Zipf 分布の定義と、検算用の数値 |
| 2 | YCSB の `ZipfianGenerator` (Gray et al. の方法) |
| 3 | YCSB の `ScrambledZipfianGenerator` (FNV ハッシュで散らす) |
| 4 | rejection-inversion (論文の実装が使った方法) |
| 5 | scan の長さ (一様分布) |
| 6 | YCSB ワークロード A〜F |
| 7 | 論文の実験手順 (ハーネスの擬似コード) |

---

## 1. Zipf 分布

### 定義

n 個の項目に 1〜n の順位を付ける。順位 k が選ばれる確率は

```
P(k) = (1 / k^θ) / ζ(n, θ)          ζ(n, θ) = Σ_{i=1}^{n} 1 / i^θ
```

* θ (論文では α) が大きいほど上位に集中する。θ = 0 なら一様分布。
* YCSB の既定は θ = 0.99。論文も「YCSB にならって」α = 0.99 を使う (論文 4 章)。
* YCSB の生成器は順位を **0 始まり** (0〜n-1) で返す。`zipf` クレートは **1 始まり** (1〜n) で返す。混ぜると 1 ずれる。

### 検算用の数値 (n = 10^6, θ = 0.99。手元で計算)

| 量 | 値 |
|---|---|
| ζ(10^6, 0.99) | 15.39185 |
| 上位 1 件の確率 | 0.06497 |
| 上位 10 件の累積 | 0.19206 |
| 上位 1,000 件の累積 | 0.50215 |
| 上位 100,000 件の累積 | 0.83020 |
| ζ(10^10, 0.99) | 26.46903 (YCSB の定数 `ZETAN` と一致。Euler-Maclaurin 近似で確認) |

background.md 6.2 の表 (6.5% / 19% / 50% / 83%) と一致する。

---

## 2. YCSB の `ZipfianGenerator` (Gray et al. の方法)

### 2.1 目的

* 準備に O(n) (ζ の計算)、1 回の生成に O(1) で Zipf 乱数を作る。表 (累積分布の配列) を持たない。
* 出典は Gray et al. "Quickly Generating Billion-Record Synthetic Databases" (SIGMOD 1994)。
  原論文は読めていない。以下は YCSB の実装 (`ZipfianGenerator.java:nextLong`) から書き起こした。

### 2.2 状態

```rust
struct GrayZipf {
    items: u64,       // n (コンストラクタで決めた値。後述の癖に関係する)
    base: u64,        // 返す値の最小 (min)
    theta: f64,       // 0 < θ < 1
    alpha: f64,       // 1 / (1 - θ)
    zeta2: f64,       // ζ(2, θ) = 1 + 0.5^θ
    zetan: f64,       // ζ(count_for_zeta, θ)
    count_for_zeta: u64,
    eta: f64,
}
```

### 2.3 擬似コード

```rust
fn zeta_range(from: u64, to: u64, theta: f64, initial: f64) -> f64 {
    // Σ_{i=from+1}^{to} 1 / i^θ を initial に足す (i は 1 始まり)
    let mut sum = initial;
    for i in from..to { sum += 1.0 / ((i + 1) as f64).powf(theta); }
    sum
}

fn eta(items: u64, theta: f64, zeta2: f64, zetan: f64) -> f64 {
    (1.0 - (2.0 / items as f64).powf(1.0 - theta)) / (1.0 - zeta2 / zetan)
}

impl GrayZipf {
    fn new(min: u64, max: u64, theta: f64) -> Self {
        assert!(0.0 < theta && theta < 1.0);
        let items = max - min + 1;
        let zeta2 = zeta_range(0, 2, theta, 0.0);
        let zetan = zeta_range(0, items, theta, 0.0);           // O(n)
        GrayZipf {
            items, base: min, theta,
            alpha: 1.0 / (1.0 - theta),
            zeta2, zetan, count_for_zeta: items,
            eta: eta(items, theta, zeta2, zetan),
        }
    }

    /// [base, base + item_count) の値を返す。順位 0 が最頻。
    fn next(&mut self, rng: &mut impl Rng, item_count: u64) -> u64 {
        if item_count > self.count_for_zeta {
            // 項目が増えた: ζ を差分だけ足す (2.4 節)
            self.zetan = zeta_range(self.count_for_zeta, item_count, self.theta, self.zetan);
            self.count_for_zeta = item_count;
            // YCSB の実装はここで self.items (古い n) を使う。下の注を参照。
            self.eta = eta(self.items, self.theta, self.zeta2, self.zetan);
        }
        // 項目が減った場合は既定では何もしない (YCSB は allowitemcountdecrease が真のときだけ作り直す)

        let u: f64 = rng.gen();                // [0, 1)
        let uz = u * self.zetan;
        if uz < 1.0 { return self.base; }                              // 順位 0: 確率 1/ζ
        if uz < 1.0 + 0.5f64.powf(self.theta) { return self.base + 1; } // 順位 1: 確率 0.5^θ/ζ
        let r = (item_count as f64 * (self.eta * u - self.eta + 1.0).powf(self.alpha)) as u64;
        self.base + r.min(item_count - 1)      // min は浮動小数点の誤差への保険 (YCSB にはない)
    }
}
```

### 2.4 式の意味

```
u ∈ [0, 1/ζ)                   → 順位 0           (正確)
u ∈ [1/ζ, (1 + 2^-θ)/ζ)        → 順位 1           (正確)
それ以外                        → n · (1 − η(1 − u))^α   (連続近似)
```

* 順位 2 以降は、離散の和 Σ 1/i^θ を積分 ∫ x^-θ dx で近似した累積分布を、逆関数法で引いている。
* η は「u = (1 + 2^-θ)/ζ のとき、ちょうど順位 2 になる」ように決めた定数。n = 10^6, θ = 0.99 で確かめると、境目で `n · (…)^α = 2.000` になる。
* 正確なのは順位 0 と 1 だけ。それより下位では上位寄りに少しずれる (n = 10^6, θ = 0.99 で手元計算):

| 累積 | Gray の近似 | 正確な値 |
|---|---|---|
| P(順位 < 2) | 0.09768 | 0.09768 |
| P(順位 < 3) | 0.12382 | 0.11958 |
| P(順位 < 10) | 0.20208 | 0.19206 |
| P(順位 < 1000) | 0.51027 | 0.50215 |

### 2.5 n が増えたとき (差分で ζ を更新)

* YCSB は挿入でキー数が増えるワークロード (D, E) で `next(item_count)` に新しい n を渡す。
* ζ(n', θ) = ζ(n, θ) + Σ_{i=n+1}^{n'} i^-θ なので、増えた分だけ足せばよい。
* 減ったときは差分で引くこともできるが、YCSB は最初から計算し直す (しかも既定では無効)。

**YCSB の癖** (再現するならそのまま、正しくするなら直す):

* 差分更新の後の η の計算で、新しい `item_count` ではなく**コンストラクタの `items`** を使っている。
  正しくは `eta(item_count, …)`。ずれは `(2/n)^(1-θ)` の項だけなので小さい。
* `count_for_zeta` を更新する場所が `zeta()` の中にあり、読みにくい。上の擬似コードでは明示的に更新した。

### 2.6 境界条件と落とし穴

* **θ ≥ 1 では使えない**。θ = 1 で α = 1/(1-θ) が無限大、θ > 1 で負になり式が壊れる。論文 6.6 節 (α = 0.5〜1.5) には 4 節の方法を使う。
* θ が 1 に近いと α = 100 (θ = 0.99) のように大きく、`powf` の底のわずかな誤差が順位を大きく動かす。f64 で計算する。
* ζ の計算は O(n)。YCSB のコメントによると 1 億項目で 1 分以上かかる。計測区間の外で行う。
* n が大きいと、f64 で 10^10 項を足す誤差が無視できなくなる。小さい項から足す (逆順)、または Kahan 加算にする。
* 戻り値は `[0, n)`。浮動小数点の誤差で n になる可能性に備えて `min(n - 1)` を入れた (YCSB にはない)。

### 2.7 テスト方針

* n = 1000, θ = 0.99 で 10^7 回引き、順位 0 と 1 の頻度が `1/ζ` と `0.5^θ/ζ` に (二項分布の 4σ 以内で) 一致すること。
* 全体はカイ二乗検定で比べるが、**期待値には 2.4 節の近似分布を使う** (正確な Zipf と比べると近似誤差で落ちる)。
  近似分布の期待値は、`P(順位 < k) = ((k/n)^(1/α) − 1 + η) / η` (k ≥ 2) の差分で求まる。
* 差分更新: `new(0, n-1)` の後に `next(n')` を呼んだ状態の `zetan` が、`zeta_range(0, n', …)` と相対誤差 1e-12 以内で一致すること。
* 1 節の表の値 (n = 10^6) を、正確な ζ から計算して一致させる (生成器のテストではなく ζ の計算のテスト)。

---

## 3. `ScrambledZipfianGenerator` (人気の項目を散らす)

### 3.1 目的

* 2 節の生成器は、順位 0, 1, 2, … が人気順。そのままキー番号にすると、**人気のキーがキー空間の端に固まる**。
* B-Tree では人気のキーが同じ葉に集まり、キャッシュに 1 ページ載るだけで済む。実際の負荷より有利になりすぎる。
* そこで、順位をハッシュしてから `% n` し、人気のキーをキー空間全体に散らす。

### 3.2 擬似コード

```rust
const FNV_OFFSET_BASIS_64: u64 = 0xCBF2_9CE4_8422_2325;
const FNV_PRIME_64: u64 = 1_099_511_628_211;

/// YCSB の Utils.fnvhash64: 8 バイトを下位バイトから順に FNV-1a で混ぜる。
fn fnvhash64(mut val: i64) -> i64 {
    let mut h = FNV_OFFSET_BASIS_64;
    for _ in 0..8 {
        let octet = (val & 0xFF) as u64;
        val >>= 8;                       // Java の >> は算術シフト (負なら上位に 1 が入る)
        h ^= octet;
        h = h.wrapping_mul(FNV_PRIME_64);
    }
    (h as i64).wrapping_abs()            // Java の Math.abs と同じ。i64::MIN は負のまま
}

struct ScrambledZipf { inner: GrayZipf, min: u64, item_count: u64 }

const SCRAMBLE_ITEMS: u64 = 10_000_000_000;      // 10^10
const SCRAMBLE_ZETAN_099: f64 = 26.46902820178302; // ζ(10^10, 0.99)。事前計算した定数

impl ScrambledZipf {
    fn new(min: u64, max: u64, theta: f64) -> Self {
        // 内側は 0..=10^10 の Zipf。θ = 0.99 なら ζ を定数で済ませる (10^10 項の和を避ける)
        let inner = if theta == 0.99 {
            GrayZipf::with_zetan(0, SCRAMBLE_ITEMS, theta, SCRAMBLE_ZETAN_099)
        } else {
            GrayZipf::new(0, SCRAMBLE_ITEMS, theta)  // 非常に遅い
        };
        ScrambledZipf { inner, min, item_count: max - min + 1 }
    }

    fn next(&mut self, rng: &mut impl Rng) -> u64 {
        let r = self.inner.next(rng, self.inner.items);
        let h = fnvhash64(r as i64);
        // Java の % は被除数の符号を持つ。h が負 (i64::MIN) なら結果も負。
        (self.min as i64 + h % self.item_count as i64) as u64
    }
}
```

* `GrayZipf::with_zetan` は、ζ を計算せずに渡された値を使うコンストラクタ (YCSB の 4 引数版)。擬似コードは省略。
* YCSB は内側を `ZipfianGenerator(0, ITEM_COUNT)` で作るので、項目数は 10^10 + 1。一方 `ZETAN` は ζ(10^10) の値。差は無視できる。

### 3.3 性質と落とし穴

* **出力は n 項目上の正確な Zipf ではない**。10^10 個の順位を n 個に `%` で畳むので、1 項目には平均 10^10/n 個の順位が集まる。
  上位の順位 (確率が大きい) は別々の項目に行きやすいので、上位の偏りはおおむね保たれる。裾は平らになる。
* なぜ 10^10 か: 内側の n が出力の n より十分大きくないと、人気の順位同士が同じ項目に衝突しやすい。【未検証】YCSB がこの値を選んだ根拠の記述は見つけていない。
* `i64::MIN` のとき結果が負になる (YCSB のバグ)。確率は 2^-64 程度なので実害はないが、Rust で `u64` にするなら `rem_euclid` を使う方が安全。
* YCSB はキー名を作るときにも `fnvhash64` を使う (`CoreWorkload.buildKeyName`、`insertorder=hashed` が既定)。
  キー番号 → `"user" + 10進(fnvhash64(keynum))`。よって挿入順もキー順と無関係になる。

### 3.4 テスト方針

* `fnvhash64` を YCSB の Java 実装と同じ入力 (0, 1, -1, i64::MAX) で比べる。期待値は Java で 1 回出しておく。
* n = 1000 で 10^7 回引き、頻度の上位 10 項目の確率が、内側の上位 10 順位の確率とおおむね一致すること (衝突がなければ一致する)。

---

## 4. Rejection-inversion (論文の実装が使った方法)

### 4.1 目的と論文との関係

* 論文の実装 (`btree-cpp: zipfc/src/lib.rs:zipf_generate`) は Rust の `zipf` クレート 7.0 の `ZipfDistribution` を呼んでいる。
* `zipf` クレートは Apache Commons RNG の `RejectionInversionZipfSampler` の移植で、Hörmann & Derflinger (TOMACS 1996) の **rejection-inversion** 法。
* 任意の指数 s > 0 (論文の α) で使え、準備は O(1)、出力は**正確な** Zipf (棄却法なので近似誤差がない)。返す値は **1〜n**。

### 4.2 考え方

```
h(x) = x^-s                         (連続版の重み。h(k) が順位 k の重み)
H(x) = ∫_1^x h(t) dt = (x^(1-s) − 1) / (1 − s)      (s = 1 なら ln x)

[0.5, n + 0.5] の上の「面積」を一様に引き、H の逆関数で x に戻す (逆関数法)。
x を四捨五入した k を候補とし、「k の棒 [k-0.5, k+0.5] の面積のうち、
本当の重み h(k) に当たる部分」に落ちたときだけ採用する (棄却法)。
```

* 採用率は高い (1 に近い) ので、ループはほぼ 1 回で終わる。
* 順位 1 の棒だけ特別扱いして面積を `H(1.5) − 1` に縮め、採用判定を正確にしている (コードの `h_int_x1`)。

### 4.3 擬似コード

```rust
struct RejInvZipf {
    n: u64,
    s: f64,                 // 指数 (> 0)
    h_int_x1: f64,          // H(1.5) - 1
    h_int_n: f64,           // H(n + 0.5)
    r: f64,                 // h_int_x1 - h_int_n (負)
    s_thresh: f64,          // 2 - H_inv(H(2.5) - h(2))
}

impl RejInvZipf {
    fn new(n: u64, s: f64) -> Self {
        assert!(n >= 1 && s > 0.0 && s.is_finite());
        let mut z = RejInvZipf { n, s, h_int_x1: 0.0, h_int_n: 0.0, r: 0.0, s_thresh: 0.0 };
        z.h_int_x1 = z.big_h(1.5) - 1.0;
        z.h_int_n = z.big_h(n as f64 + 0.5);
        z.r = z.h_int_x1 - z.h_int_n;
        z.s_thresh = 2.0 - z.big_h_inv(z.big_h(2.5) - z.h(2.0));
        z
    }

    /// 1..=n を返す。
    fn sample(&self, rng: &mut impl Rng) -> u64 {
        loop {
            let u = self.h_int_n + rng.gen::<f64>() * self.r;   // [H(n+0.5), H(1.5)-1] を一様に
            let x = self.big_h_inv(u);
            let k = ((x + 0.5) as u64).clamp(1, self.n);        // 四捨五入して範囲に収める
            let kf = k as f64;
            if kf - x <= self.s_thresh || u >= self.big_h(kf + 0.5) - self.h(kf) {
                return k;
            }
        }
    }

    fn h(&self, x: f64) -> f64 { (-self.s * x.ln()).exp() }

    /// H(x)。s が 1 に近くても桁落ちしないよう、(e^y - 1)/y を使う。
    fn big_h(&self, x: f64) -> f64 {
        let lx = x.ln();
        expm1_over_x((1.0 - self.s) * lx) * lx
    }

    fn big_h_inv(&self, y: f64) -> f64 {
        let t = (y * (1.0 - self.s)).max(-1.0);   // ln(1+t) の定義域を守る
        (ln1p_over_x(t) * y).exp()
    }
}

/// ln(1+x)/x。|x| が小さいときは Taylor 展開 1 - x/2 + x²/3 - x³/4。
fn ln1p_over_x(x: f64) -> f64 {
    if x.abs() > 1e-8 { x.ln_1p() / x } else { 1.0 - x * (0.5 - x * (1.0 / 3.0 - 0.25 * x)) }
}

/// (e^x - 1)/x。|x| が小さいときは 1 + x/2 (1 + x/3 (1 + x/4))。
fn expm1_over_x(x: f64) -> f64 {
    if x.abs() > 1e-8 { x.exp_m1() / x } else { 1.0 + x * 0.5 * (1.0 + x / 3.0 * (1.0 + 0.25 * x)) }
}
```

* 参照: `commons-rng: RejectionInversionZipfSampler.java:RejectionInversionZipfSamplerImpl.sample`, `hIntegral`, `hIntegralInverse`, `helper1`, `helper2`。
  `rust-zipf: src/lib.rs:ZipfDistribution` はその移植。

### 4.4 落とし穴

* s = 1 は特異点ではない (`expm1_over_x(0) = 1` で H(x) = ln x になる) が、`(x^(1-s) - 1)/(1-s)` を素直に書くと 0/0 になる。上の補助関数を使う。
* `u` の範囲は `r < 0` なので「大きい方から小さい方へ」。`gen::<f64>()` が 0 なら `u = H(n+0.5)` (順位 n 付近)。
* 1 始まりで返る。0 始まりの添字に使うなら `k - 1`。

### 4.5 テスト方針

* n ∈ {1, 2, 10, 1000}、s ∈ {0.5, 0.99, 1.0, 1.5} で 10^7 回引き、正確な pmf `k^-s / ζ(n, s)` とカイ二乗検定で比べる (近似ではないので正確な値と比べてよい)。
* n = 1 なら常に 1。
* n = 10^6, s = 0.99 で、1 節の表 (上位 1 件 6.5%、上位 1,000 件 50%) を頻度で再現すること (許容 ±0.2 ポイント)。

---

## 5. scan の長さ (一様分布)

* YCSB: `UniformLongGenerator(minscanlength, maxscanlength)`。両端を含む。既定は 1〜1000、workload E の設定ファイルでは `maxscanlength=100`。
  実装は `abs(nextLong()) % interval + lb` で、剰余によるわずかな偏りがある。
* 論文: `std::uniform_int_distribution<unsigned>{1, 50}` (両端を含む)、乱数源は `std::minstd_rand`。
* Rust では `rng.gen_range(1..=max_scan_len)` (偏りなし)。

**scan の意味**: 開始キー以上のレコードを、キー順に**最大 len 件**返す。論文のハーネスはコールバックで件数を数え、len 件目で `false` を返して打ち切る。

```rust
fn do_scan(tree: &Tree, start: &[u8], len: u32) -> u32 {
    let mut found = 0u32;
    tree.scan(start, &mut |_k: &[u8], v: &[u8]| {
        debug_assert_eq!(v.len(), PAYLOAD_SIZE);
        found += 1;
        found < len                 // len 件目で false → 打ち切り
    });
    found                           // 末尾に達したら len 未満になりうる
}
```

---

## 6. YCSB ワークロード A〜F

### 6.1 操作の比率 (`workloads/workload{a..f}` の設定ファイル)

| | read | update | insert | scan | read-modify-write | キーの分布 | 例 |
|---|---|---|---|---|---|---|---|
| A | 0.50 | 0.50 | 0 | 0 | 0 | zipfian | セッションストア |
| B | 0.95 | 0.05 | 0 | 0 | 0 | zipfian | 写真のタグ付け |
| C | 1.00 | 0 | 0 | 0 | 0 | zipfian | ユーザープロフィールのキャッシュ |
| D | 0.95 | 0 | 0.05 | 0 | 0 | latest | ステータス更新 |
| E | 0 | 0 | 0.05 | 0.95 | 0 | zipfian (scan 長は uniform, 最大 100) | スレッド形式の会話 |
| F | 0.50 | 0 | 0 | 0 | 0.50 | zipfian | ユーザーデータベース |

* 例の列は設定ファイルのコメント (Application example) による。
* 設定ファイルの `recordcount=1000` / `operationcount=1000` は雛形で、実際には上書きして使う。

### 6.2 操作の選び方

```rust
enum Op { Read, Update, Insert, Scan, ReadModifyWrite }

/// 比率の表から操作を 1 つ選ぶ (YCSB の DiscreteGenerator と同じ考え方)。
fn choose_op(rng: &mut impl Rng, weights: &[(Op, f64)]) -> Op {
    let total: f64 = weights.iter().map(|w| w.1).sum();
    let mut x = rng.gen::<f64>() * total;
    for (op, w) in weights {
        if x < *w { return *op; }
        x -= w;
    }
    weights.last().unwrap().0     // 誤差の保険
}
```

### 6.3 キーの選び方 (挿入があるワークロード)

```rust
struct Workload {
    record_count: u64,               // 事前ロードした件数
    insert_seq: u64,                 // 次に挿入するキー番号 (最初は record_count)
    chooser: KeyChooser,
}

enum KeyChooser {
    Zipfian(ScrambledZipf),          // A, B, C, E, F
    Latest(GrayZipf),                // D
}

impl Workload {
    fn new_zipfian(record_count: u64, op_count: u64, insert_prop: f64) -> Self {
        // 挿入で増える分を見込んで、項目数を固定のまま多めに作る。
        // YCSB: expectednewkeys = opcount * insertproportion * 2.0 ("2 is fudge factor")
        let expected_new = (op_count as f64 * insert_prop * 2.0) as u64;
        let z = ScrambledZipf::new(0, record_count + expected_new, 0.99);
        Workload { record_count, insert_seq: record_count, chooser: KeyChooser::Zipfian(z) }
    }

    /// 既存のキー番号を 1 つ選ぶ。
    fn next_keynum(&mut self, rng: &mut impl Rng) -> u64 {
        let last = self.insert_seq - 1;       // 挿入済みの最大番号
        match &mut self.chooser {
            KeyChooser::Zipfian(z) => loop {
                let k = z.next(rng);
                if k <= last { return k; }     // まだ挿入していない番号は引き直す
            },
            KeyChooser::Latest(z) => {
                // D: 最近挿入したものほど人気。max - zipf(max)
                let max = last;
                max - z.next(rng, max)         // SkewedLatestGenerator.nextValue
            }
        }
    }

    fn next_insert_keynum(&mut self) -> u64 {
        let k = self.insert_seq;
        self.insert_seq += 1;
        k
    }
}

fn key_name(keynum: u64) -> String {
    format!("user{}", fnvhash64(keynum as i64))   // insertorder=hashed (既定), zeropadding=1
}
```

* **scrambled の項目数を固定する理由**: n を変えると `% n` の結果が全部変わり、人気のキーが入れ替わってしまう。
  そこで最初から多めの n で作り、範囲外 (未挿入) は引き直す。
* **latest** は `GrayZipf::next(max)` を毎回新しい `max` で呼ぶ。n が増えるたびに 2.5 節の差分更新が走る。
  YCSB では `max` は「確認済みの最後の挿入」(`AcknowledgedCounterGenerator`)。並行に挿入しているとき、まだ終わっていない挿入のキーを読まないための仕組み。
  単一スレッドなら単なるカウンタでよい (この資料の簡略化)。
* F の read-modify-write は、同じキーを read してから update する。
* `Latest` の `z.next(rng, max)` は順位 0 で `max` そのもの (最新) を返す。`max - 0 = max`。

### 6.4 テスト方針

* `choose_op` を 10^6 回呼び、各操作の頻度が比率 ± 0.5 ポイントに入ること。
* `next_keynum` が常に `< insert_seq` であること (挿入済みのキーしか読まない)。
* D で、直近 1% の挿入キーへのアクセスが全体のかなりの割合を占めること (目安の確認)。

---

## 7. 論文の実験手順

### 7.1 論文の記述 (4 章 Experimental Setup)

* キー集合: urls (平均 62 バイト)、wiki (平均 23 バイト)、dense (`[0, N)` の 32 ビット整数)、sparse (ランダムな 32 ビット整数)。値は 8 バイト (タプル ID を想定)。
* レコード数は、データ全体が 300 MB になるように選ぶ。
* 手順: レコードの 90% を挿入 → **残り 10% の挿入を計測** → **5M 回の lookup** と **5M 回の scan** を計測。挿入順はランダム。
* lookup / scan の開始キーは Zipf (α = 0.99) で選ぶ。scan の件数は `[1, 50]` の一様分布。
* 各構成を 5 回実行し、中央値を示す。

### 7.2 参照実装での対応 (確認したこと)

* 実験スクリプト (`R/eval-2/re-eval.py`) の引数: `YCSB_VARIANT=6 SCAN_LENGTH=50 OP_COUNT=5e6 PAYLOAD_SIZE=8 ZIPF=0.99`。
* `YCSB_VARIANT=6` は `ycsb2.cpp:runMulti` を呼ぶ (`main` の switch)。
* Zipf 乱数は `ycsb2.cpp:zipf_next` → `zipfc/src/lib.rs:zipf_generate` → `zipf` クレート (4 節)。
  * 2^18 個ずつまとめて生成し、その間は性能カウンタを止めている (生成コストを計測に含めない)。
  * `zipf` クレートは 1〜N を返し、`zipf_next` は `N` 以上を捨てる。結果として**添字 0 は選ばれず、最頻の添字は 1**。
    キー列は事前にシャッフルしてあるので、実質的な影響はない (どのキーが人気になるかがずれるだけ)。
* 人気のキーを散らす方法は YCSB と違う。ハッシュではなく、**キー列 `data` 自体を最初にシャッフル**し、Zipf の添字 i を `data[i]` に対応させる。
  同じシャッフルが挿入順も決めるので、「人気のキー」と「先に挿入されたキー」は相関する (添字の小さいキーが 90% 側に入る)。

### 7.3 ハーネスの擬似コード

```rust
const PAYLOAD_SIZE: usize = 8;
const OP_COUNT: usize = 5_000_000;
const MAX_SCAN_LEN: u32 = 50;
const ALPHA: f64 = 0.99;

fn run_multi(mut data: Vec<Vec<u8>>, key_count: usize, seed: u64) -> Results {
    let mut rng = SmallRng::seed_from_u64(seed);
    data.shuffle(&mut rng);                    // 挿入順と人気の割り当てを同時にランダム化
    data.truncate(key_count);
    let payload = [42u8; PAYLOAD_SIZE];
    let mut tree = Tree::new();

    // 1. 事前ロード 90% (計測しない)
    let pre = key_count - key_count / 10;
    for k in &data[..pre] { tree.insert(k, &payload); }

    // 2. 残り 10% の挿入を計測
    let t_insert = time(|| {
        for k in &data[pre..] { tree.insert(k, &payload); }
    });

    // Zipf の添字は計測前にまとめて作る (参照実装は 2^18 個ずつ、計測を止めて作る)
    let zipf = RejInvZipf::new(key_count as u64, ALPHA);
    let lookups: Vec<usize> = (0..OP_COUNT).map(|_| (zipf.sample(&mut rng) - 1) as usize).collect();
    let scans: Vec<(usize, u32)> = (0..OP_COUNT)
        .map(|_| ((zipf.sample(&mut rng) - 1) as usize, rng.gen_range(1..=MAX_SCAN_LEN)))
        .collect();

    // 3. lookup 5M 回 (値を検証する)
    let t_lookup = time(|| {
        for &i in &lookups {
            let v = tree.lookup(&data[i]).expect("key must exist");
            assert!(v.len() == PAYLOAD_SIZE && v[0] == 42);
        }
    });

    // 4. scan 5M 回
    let t_scan = time(|| {
        for &(i, len) in &scans { do_scan(&tree, &data[i], len); }
    });

    Results {
        insert_ops_per_s: (key_count - pre) as f64 / t_insert,
        lookup_ops_per_s: OP_COUNT as f64 / t_lookup,
        scan_ops_per_s: OP_COUNT as f64 / t_scan,
    }
}

// 5 回実行して、操作ごとに中央値を取る。
```

* `(sample - 1)` で 0 始まりにしている。参照実装 (添字 0 を使わない) との**意図的な違い**。
* 添字を事前に全部作ると 5M × 8 バイト = 40 MB のメモリを使い、キャッシュを汚す。参照実装のように小さなバッファ (2^18 個) で作り直す方が計測への影響が小さい。
* `assert!` は計測区間の中にある。参照実装も値を検証している (`*payload != 42` なら例外)。

### 7.4 YCSB-E (fingerprinting リーフの評価)

論文 4.5 節は fingerprinting リーフを YCSB-E (scan 95% / insert 5%) で評価している。参照実装は `ycsb2.cpp:runYcsbE` (`YCSB_VARIANT=5`)。

```rust
fn run_ycsb_e(mut data: Vec<Vec<u8>>, avg_key_count: usize, op_count: usize, rng: &mut SmallRng) {
    // 実行中の平均キー数が avg_key_count になるように初期件数を決める
    // (挿入は op の 5% = op/20 件、平均するとその半分 op/40 件増える)
    let initial = avg_key_count - op_count / 40;
    let max_keys = initial + 2 * (op_count / 20);   // 挿入に使う分の 2 倍を用意
    data.shuffle(rng);
    let mut tree = Tree::new();
    for k in &data[..initial] { tree.insert(k, &PAYLOAD); }   // 計測しない

    // 操作列: ちょうど 5% が insert になるよう、真偽値の配列をシャッフルして使う
    let mut inserted = initial;
    let zipf = ScrambledByHash::new(max_keys, 0.99);  // 下の注
    for _ in 0..op_count {                            // ここから計測
        if next_is_insert(rng) {
            tree.insert(&data[inserted], &PAYLOAD);
            inserted += 1;
        } else {
            let len = rng.gen_range(1..=MAX_SCAN_LEN);
            let i = loop {                            // 未挿入の添字は引き直す
                let i = zipf.sample(rng);
                if i < inserted { break i; }
            };
            do_scan(&tree, &data[i], len);
        }
    }
}
```

* 参照実装の Zipf はここでは「散らす」版: 項目数 `N × 2^20` の Zipf を引き、Rust 標準の `DefaultHasher` でハッシュして `% N`。YCSB の Scrambled と同じ考え方 (コメントに "described in the ycsb paper" とある)。
* 項目数 N (`max_keys`) を途中で変えない。YCSB と同じ理由 (変えると人気のキーが入れ替わる)。
* 参照実装は Zipf の範囲をさらに少し広げ (`+ 2^18/10`)、範囲外を捨てている。擬似コードでは省いた。

### 7.5 落とし穴

* **乱数の生成を計測に含めない**。Zipf の 1 回の生成は B-Tree の lookup (数百 ns) と同じ桁になりうる。
* 事前ロードと計測の間で、キャッシュの状態が変わる (挿入の直後はホットなページがキャッシュにある)。参照実装は特に何もしていない。
* scan の開始キーが末尾に近いと、len 件に満たずに終わる。スループットの分母は「操作回数」なので、そのまま数える。
* α を 1 以上にするなら、2 節の方法は使えない (4 節を使う)。

### 7.6 テスト方針 (ハーネス自体の検証)

* 木の代わりに `BTreeMap<Vec<u8>, [u8; 8]>` を使ってハーネスを動かし、lookup がすべて成功すること、scan が返す件数が `min(len, 開始キー以上の件数)` と一致することを確かめる。
* 同じ seed で 2 回実行したとき、操作列 (添字と scan 長) が一致すること (再現性)。
* lookup の添字の頻度上位が、1 節の表の割合 (上位 1 件 ≈ 6.5% など、key_count によって変わる) と合うこと。

---

## 8. 原典との違い・簡略化

* Gray et al. の原論文は読めていない。2 節は YCSB の実装を元にした。
* YCSB の `AcknowledgedCounterGenerator` (並行挿入のための窓付きカウンタ) は単なるカウンタにした。
* YCSB の他の分布 (hotspot, exponential, sequential) とフィールド長の分布、`readallfields` などのレコード形式の設定は省いた。
* 7.3 節のハーネスは、0 始まりの添字にした点、Zipf 添字を事前に全部作る点が参照実装と違う。
* 論文 7 章のマルチスレッド (30 秒間実行) と out-of-memory の実験 (vmcache、256 スレッド) の手順は書いていない。

## 参考資料

* 本論文: Müller, Benson, Leis. B-Trees Are Back. SIGMOD 2025. https://doi.org/10.1145/3709664
* 論文の参照実装 (`ycsb2.cpp:runMulti`, `runYcsbE`, `zipf_next`, `computeInitialKeyCount`; `zipfc/src/lib.rs:zipf_generate`; `R/eval-2/re-eval.py`): https://github.com/m-mueller678/btree-cpp/tree/sigmod25
* Cooper et al. Benchmarking Cloud Serving Systems with YCSB. SoCC 2010: https://doi.org/10.1145/1807128.1807152
* YCSB (`core/src/main/java/site/ycsb/generator/ZipfianGenerator.java:nextLong`, `ScrambledZipfianGenerator.java:nextValue`, `SkewedLatestGenerator.java:nextValue`, `AcknowledgedCounterGenerator.java`, `UniformLongGenerator.java`; `Utils.java:fnvhash64`; `workloads/CoreWorkload.java:init`, `nextKeynum`, `buildKeyName`; `workloads/workloada`〜`workloadf`): https://github.com/brianfrankcooper/YCSB
* Gray, Sundaresan, Englert, Baclawski, Weinberger. Quickly Generating Billion-Record Synthetic Databases. SIGMOD 1994: https://doi.org/10.1145/191839.191886
* Hörmann, Derflinger. Rejection-inversion to generate variates from monotone discrete distributions. TOMACS 6(3), 1996: https://doi.org/10.1145/235025.235029
* Apache Commons RNG (`RejectionInversionZipfSampler.java`): https://github.com/apache/commons-rng
* Rust `zipf` クレート: https://github.com/jonhoo/rust-zipf
* FNV ハッシュ: http://www.isthe.com/chongo/tech/comp/fnv/index.html
