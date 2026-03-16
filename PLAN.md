# PLAN: Spinel AOT Compiler

mrubyフォーク型 トレーシング+AOTコンパイラ。
LumiTraceによるCRuby上の型プロファイリングとRBS型情報を組み合わせ、
Cコード生成経由で実行可能バイナリを生成する。

詳細設計は `ruby_aot_compiler_design.md` を参照。

---

## 第一目標: bm_so_mandelbrot.rb のコンパイル

最初のマイルストーンとして、CRubyベンチマーク `bm_so_mandelbrot.rb`
(Computer Language Benchmarks Game由来) を入力とし、
mrubyランタイムとリンクした実行可能バイナリを生成する。

### ターゲットプログラム

```ruby
# bm_so_mandelbrot.rb — Mandelbrot集合をPBM P4形式で出力
size = 600
puts "P4\n#{size} #{size}"
ITER = 49
LIMIT_SQUARED = 4.0
byte_acc = 0
bit_num = 0
count_size = size - 1
for y in 0..count_size
  for x in 0..count_size
    zr = 0.0; zi = 0.0
    cr = (2.0*x/size)-1.5; ci = (2.0*y/size)-1.0
    escape = false
    for dummy in 0..ITER
      tr = zr*zr - zi*zi + cr
      ti = 2*zr*zi + ci
      zr, zi = tr, ti
      if (zr*zr+zi*zi) > LIMIT_SQUARED
        escape = true; break
      end
    end
    byte_acc = (byte_acc << 1) | (escape ? 0b0 : 0b1)
    bit_num += 1
    if (bit_num == 8)
      print byte_acc.chr; byte_acc = 0; bit_num = 0
    elsif (x == count_size)
      byte_acc <<= (8 - bit_num)
      print byte_acc.chr; byte_acc = 0; bit_num = 0
    end
  end
end
```

### 必要な言語機能

このベンチマークをコンパイルするために、以下の言語機能をサポートする必要がある:

| 機能 | 使用箇所 | 難易度 |
|------|---------|--------|
| ローカル変数 (代入・参照) | `size = 600`, `zr = 0.0` 等 | 低 |
| 定数 | `ITER = 49`, `LIMIT_SQUARED = 4.0` | 低 |
| Integer / Float リテラル | `600`, `4.0`, `0b0`, `0b1` | 低 |
| String リテラル・補間 | `"P4\n#{size} #{size}"` | 中 |
| 算術演算 (`+`, `-`, `*`, `/`) | Float演算が中心 | 低 |
| 比較演算 (`>`, `==`) | `(zr*zr+zi*zi) > LIMIT_SQUARED` | 低 |
| ビット演算 (`<<`, `\|`, `<<=`) | `byte_acc << 1`, `byte_acc \| ...` | 低 |
| `for..in` + Range | `for y in 0..count_size` | 中 |
| 並列代入 | `zr, zi = tr, ti` | 中 |
| 三項演算子 | `escape ? 0b0 : 0b1` | 低 |
| `if` / `elsif` | 条件分岐 | 低 |
| `break` | ループからの脱出 | 中 |
| Boolean (`true`, `false`) | `escape = false` | 低 |
| `Integer#chr` | `byte_acc.chr` | 低 |
| `puts` / `print` | 出力 | 低 |

### 不要な機能（このベンチマークでは）

- クラス定義・メソッド定義
- ブロック・Proc・lambda
- 配列・ハッシュ操作
- 例外処理
- `require` / モジュール
- eval / リフレクション

### 成功基準

1. `./spinel bm_so_mandelbrot.rb -o mandelbrot_aot.c` でCコードを生成
2. `cc mandelbrot_aot.c -lmruby -o mandelbrot` でバイナリを生成
3. `./mandelbrot` の出力が `ruby bm_so_mandelbrot.rb` と一致
4. バイナリサイズがフルリンクのmrubyより小さい

### ベンチマーク比較対象

- `ruby bm_so_mandelbrot.rb` (CRuby)
- `mruby bm_so_mandelbrot.rb` (mrubyインタプリタ)
- `./mandelbrot` (Spinel AOTバイナリ)

---

## パイプライン概要

```
Ruby Source
    |
    +-----------------------------+
    |                             |
    v                             v
 Prism                    CRuby + LumiTrace
 (libprism)               --collect-mode types
    |                             |
    v                             v
 Simple static            lumitrace_recorded.json
 analysis (CHA)                   |
    |                     convert_lumitrace.rb
    |                             |
    |              +--------------+
    |              |
    v              v
 Integration + CHA  <--  RBS type info
    |
    v
 C code generation + init code gen
    |
    v
 cc + libmruby fork (-ffunction-sections, --gc-sections)
    |
    v
 Final binary
```

## 実装ロードマップ

### Step 0: プロトタイプ (完了)

- [x] LumiTrace JSON → Spinel trace format 変換 (`tools/convert_lumitrace.rb`)
- [x] RBS → JSON 型情報抽出 (`tools/extract_rbs.rb`)
- [x] mruby メソッドマッピング (`tools/scan_mruby_methods.rb`)
- [x] RBS カバレッジ測定 (`tools/coverage_report.rb`)
- [x] トレース + RBS 統合デモ (`tools/merge_trace_rbs.rb`)

### Step 1: 簡易静的解析

- libprismのビルドとリンク
- PrismのASTを走査してクラス階層を構築
- メソッド再定義・prependの検出
- 言語制約違反の検出（eval, method_missing, refinements）

### Step 2: 統合 + CHA判定

- トレースデータ（JSON）の読み込み（cJSON）
- RBS型情報（JSON）の読み込み
- コールサイトごとの統合ロジック（トレース + RBS + CHA → 解決レベル判定）
- 到達可能メソッド集合の計算（固定点ワークリスト）

### Step 3: Cコード生成 — bm_so_mandelbrot.rb をターゲット

- bm_so_mandelbrot.rb が使う言語機能のCコード生成を優先実装
- SEND_PROVEN → ガードなし直接呼び出し（Integer/Float算術）
- SEND_LIKELY → 型ガード付き特化コード
- SEND_UNRESOLVED → mrb_funcall ディスパッチ
- initコード生成（到達可能メソッドのみ登録）
- libmruby（フォーク版）とのリンク、`--gc-sections` による不要コード除去

### Step 4: 検証・最適化

- bm_so_mandelbrot.rb の出力一致確認
- バイナリサイズの計測（フルリンク vs AOT）
- 性能比較（CRuby / mrubyインタプリタ / AOTバイナリ）
- エッジケースの洗い出し

---

## ビルドフロー

```bash
# Step 1: LumiTraceで型トレース収集
lumitrace --collect-mode types -j --json trace_raw.json bm_so_mandelbrot.rb

# Step 2: トレースフォーマット変換
ruby tools/convert_lumitrace.rb \
  --input=trace_raw.json \
  --mruby-classes=type_db/method_map.json \
  --output=trace.json

# Step 3: RBS型情報抽出（初回のみ）
ruby tools/extract_rbs.rb \
  --rbs-dir=path/to/ruby/rbs/core \
  --output=type_db/core.json

# Step 4: AOTコンパイル（トレース + RBS + 静的解析 → C）
./spinel \
  --type-db=type_db/core.json \
  --trace=trace.json \
  --source=bm_so_mandelbrot.rb \
  --output=mandelbrot_aot.c

# Step 5: 最終バイナリ
cc -ffunction-sections -Wl,--gc-sections \
  mandelbrot_aot.c -lmruby -o mandelbrot
```

## 参考情報

- 詳細設計: `ruby_aot_compiler_design.md`
- プロトタイプツール: `prototype/`
