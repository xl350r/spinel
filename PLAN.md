# PLAN: Spinel AOT Compiler

Ruby source → Prism AST → whole-program type inference → standalone C executable.
No runtime dependencies (no mruby, no GC library — GC is generated inline).

詳細設計は `ruby_aot_compiler_design.md` を参照。

---

## 現状 (Status)

### コンパイラアーキテクチャ (~6700行のC)

- Prism (libprism) によるRubyパース
- 多パスコード生成:
  1. クラス/モジュール/関数解析 (継承チェーン、mixin解決含む)
  2. 全変数・パラメータ・戻り値の型推論 (関数間解析)
  3. C構造体・メソッド関数の生成 (GCスキャン関数含む)
  4. ラムダ/クロージャのキャプチャ解析・コード生成
  5. yield/ブロックのコールバック関数生成
  6. main()のトップレベルコード生成
- マーク&スイープGC (シャドウスタック、ファイナライザ)
- setjmp/longjmpベース例外処理
- アリーナアロケータ (ラムダ/クロージャ用)

### サポート済み言語機能

| カテゴリ | 機能 |
|---------|------|
| **OOP** | クラス定義、インスタンス変数、メソッド定義 |
| | 継承 (`class Dog < Animal`)、`super` |
| | `include` (mixin) — モジュールのインスタンスメソッド取り込み |
| | `attr_accessor` / `attr_reader` / `attr_writer` |
| | クラスメソッド (`def self.foo`) |
| | getter/setter自動インライン化 |
| | コンストラクタ (`.new`)、型付きオブジェクトへのメソッド呼び出し |
| | モジュール (状態変数 + メソッド) |
| **ブロック/クロージャ** | `yield`、ブロック付きメソッド呼び出し (キャプチャ変数) |
| | `Array#each/map/select` (インライン化) |
| | `Hash#each` (キー/値ペア) |
| | `Integer#times/upto/downto` with block → C forループ |
| | `-> x { body }` ラムダ → Cクロージャ (キャプチャ解析) |
| | sp_Val タグ付きユニオン + アリーナアロケータ |
| **制御** | while, until, if/elsif/else, unless |
| | case/when/else (値、複数値、Range条件) |
| | for..in + Range, loop do |
| | break, next, return |
| | ternary, and/or/not |
| **例外処理** | begin/rescue/ensure/retry |
| | raise "message" (setjmp/longjmp) |
| | rescue => e (メッセージキャプチャ) |
| | volatile変数でlongjmpの値保存 |
| **引数** | 位置引数、デフォルト値 (`def foo(x = 10)`) |
| | キーワード引数 (`def foo(name:, greeting: "Hello")`) |
| | 可変長引数/スプラット (`def sum(*nums)`) |
| **型** | Integer, Float, Boolean, String, Symbol, nil → アンボックスC型 |
| | 値型 (Vec: 3 floats → 値渡し) vs ポインタ型 |
| **コレクション** | sp_IntArray (push/pop/shift/dup/reverse!/each/map/select) |
| | sp_StrIntHash (文字列キー→整数値、each/has_key?/delete) |
| | sp_StrArray (文字列配列、split結果用) |
| | O(1) shift (デキュー方式のstartオフセット) |
| **演算** | 算術 (+, -, *, /, %, **), 比較, ビット演算 |
| | 単項マイナス, 複合代入 (+=, <<=) |
| | Math.sqrt/cos/sin → C math関数 |
| | Integer#abs/even?/odd?/zero? |
| | Float#abs/ceil/floor/round |
| **文字列** | リテラル、補間 → printf |
| | 15+メソッド: length, upcase, downcase, strip, reverse |
| |   gsub, sub, split, capitalize, chomp |
| |   include?, start_with?, end_with?, count |
| |   +, <<, * (連結、追記、繰り返し) |
| |   ==, !=, <, > (strcmp比較) |
| | Integer#to_s, Integer#chr |
| **I/O** | puts, print, printf, putc, p → stdio |
| | puts: Integer, Float, Boolean, String対応 |
| **GC** | マーク&スイープ (非値型オブジェクト・配列・ハッシュ用) |
| | シャドウスタックルート管理, ファイナライザ |
| | GC不要なプログラムではGCコード省略 |

### テストプログラム (18例)

| プログラム | テスト対象 |
|-----------|-----------|
| bm_so_mandelbrot | while、ビット演算、PBM出力 |
| bm_ao_render | 6クラス、モジュール、GC |
| bm_so_lists | 配列操作 (push/pop/shift)、GC |
| bm_fib | 再帰、関数型推論 |
| bm_app_lc_fizzbuzz | 1201クロージャ、アリーナ |
| bm_mandel_term | 関数間呼び出し、putc |
| bm_yield | yield/ブロック、each/map/select |
| bm_case | case/when、unless、next、デフォルト引数 |
| bm_inherit | 継承、super |
| bm_rescue | rescue/raise/ensure/retry |
| bm_hash | Hash操作 |
| bm_strings | Symbol、基本文字列メソッド |
| bm_strings2 | 高度な文字列メソッド、split、比較 |
| bm_numeric | 数値メソッド、power |
| bm_attr | attr_accessor、for..in、loop、クラスメソッド |
| bm_kwargs | キーワード引数、スプラット |
| bm_mixin | include (mixin) |
| bm_misc | upto/downto、String <<、配列引数 |

### ベンチマーク結果

| ベンチマーク | CRuby | mruby | Spinel AOT | 高速化 | メモリ |
|-------------|-------|-------|------------|--------|--------|
| mandelbrot (600×600) | 1.14s | 3.18s | 0.02s | 57× | <1MB |
| ao_render (64×64 AO) | 3.55s | 13.69s | 0.07s | 51× | 2MB |
| so_lists (300×10K) | 0.44s | 2.01s | 0.02s | 22× | 2MB |
| fib(34) | 0.55s | 2.78s | 0.01s | 55× | <1MB |
| lc_fizzbuzz (Church) | 28.96s | — | 1.55s | 19× | arena |
| mandel_term | 0.05s | 0.05s | ~0s | 50×+ | <1MB |

生成バイナリは完全スタンドアロン (libc + libm のみ、mruby不要)。

---

## 未サポート機能

### 高優先度

| 機能 | 備考 |
|------|------|
| Regexp | パターンマッチ (PCRE or oniguruma連携) |
| 多値Hash (任意型value) | 現在はString→Integerのみ |
| `Comparable`, `Enumerable` | モジュール組み込み |
| `extend` | クラスレベルmixin |
| `Proc.new`, `proc {}` | lambda以外のProc |
| `respond_to?`, `is_a?`, `class` | 型イントロスペクション |
| `alias` | メソッド別名 |

### 中優先度

| 機能 | 備考 |
|------|------|
| 多段継承チェーン | 現在は1段のみテスト済み |
| Exception クラス定義 | 現在は文字列のみ |
| `Struct` / `Data` | 簡易データクラス |
| `**kwargs` (ダブルスプラット) | ハッシュ引数 |
| `Array#reject/reduce/flatten` | 追加配列メソッド |
| `Hash` with non-string keys | 任意キー型 |
| `String#[]`/`String#[]=` | 文字列インデックス |

### 低優先度 (動的機能)

| 機能 | 備考 |
|------|------|
| `eval`, `instance_eval` | 静的解析不可 |
| `send`, `public_send` | 動的ディスパッチ |
| `define_method` | 動的メソッド定義 |
| `method_missing` | フォールバック |
| `require`, `load` | モジュールシステム |
| File I/O | OS依存 |
| グローバル変数 (`$stdout`等) | ランタイム依存 |
| クラス変数 (`@@var`) | 使用頻度低 |
| open class / monkey patching | 静的解析と相性悪 |

---

## アーキテクチャ

```
Ruby Source (.rb)
    |
    v
Prism (libprism)                -- パース → AST
    |
    v
Pass 1: クラス解析              -- クラス (継承チェーン)、メソッド、ivar検出
    |                              モジュール (mixin解決)、attr_accessor展開
    |                              トップレベル関数、yield検出
    v
Pass 2: 型推論                  -- 全変数・ivar・パラメータの型推論
    |                              (Integer/Float/Boolean/String/Object/Array/Hash/Proc)
    |                              関数間型推論、super型伝播、継承ivar伝播
    |                              キーワード引数・スプラットの型解決
    v
Pass 3: 構造体・メソッド生成    -- クラス → C構造体 (親フィールド先頭配置)
    |                              メソッド → C関数 (継承はcast-to-parent)
    |                              getter/setter → インラインフィールドアクセス
    |                              GCスキャン関数、ファイナライザ生成
    |                              ラムダ → キャプチャ解析 + C関数生成
    |                              yield → コールバック関数ポインタ生成
    v
Pass 4: main() コード生成       -- トップレベルコード → main()
    |                              while/for/times/each/upto/downto → Cループ
    |                              yield → _block(_block_env, arg)
    |                              case/when → if/else チェーン
    |                              rescue → setjmp/longjmp
    |                              算術 → C演算子
    |                              puts/print/printf → stdio
    v
スタンドアロンCファイル           -- GC内蔵, 例外処理内蔵
    |
    v
cc -O2 -lm → ネイティブバイナリ  -- mruby不要、libc+libmのみ
```

## ビルドフロー

```bash
# コンパイラのビルド
make deps   # Prismを取得・ビルド
make        # spinelコンパイラをビルド

# Rubyプログラムのコンパイル
./spinel --source=examples/bm_fib.rb --output=fib.c
cc -O2 fib.c -lm -o fib
./fib   # → 5702887

# テスト
make test   # mandelbrotをコンパイル・実行・CRubyと出力比較
```

## プロジェクト構成

```
spinel/
├── src/
│   ├── main.c          # CLI、ファイル読み込み、Prismパース
│   ├── codegen.h       # 型システム、クラス/メソッド/モジュール情報構造体
│   └── codegen.c       # 多パスコード生成器 (~6700行)
├── examples/           # 18テストプログラム
│   ├── bm_so_mandelbrot.rb   # Mandelbrot集合
│   ├── bm_ao_render.rb       # AOレイトレーサー (6クラス、モジュール)
│   ├── bm_so_lists.rb        # 配列操作
│   ├── bm_fib.rb             # 再帰フィボナッチ
│   ├── bm_app_lc_fizzbuzz.rb # λ計算FizzBuzz (1201クロージャ)
│   ├── bm_mandel_term.rb     # ターミナルMandelbrot
│   ├── bm_yield.rb           # yield/ブロック
│   ├── bm_case.rb            # case/when, unless, next
│   ├── bm_inherit.rb         # 継承、super
│   ├── bm_rescue.rb          # rescue/raise/ensure/retry
│   ├── bm_hash.rb            # Hash操作
│   ├── bm_strings.rb         # Symbol、文字列メソッド
│   ├── bm_strings2.rb        # 高度な文字列メソッド
│   ├── bm_numeric.rb         # 数値メソッド
│   ├── bm_attr.rb            # attr_accessor、for..in、loop、クラスメソッド
│   ├── bm_kwargs.rb          # キーワード引数、スプラット
│   ├── bm_mixin.rb           # include (mixin)
│   └── bm_misc.rb            # upto/downto、String <<
├── prototype/
│   └── tools/          # Step 0プロトタイプ (RBS抽出、LumiTrace等)
├── Makefile
├── PLAN.md             # 本文書
└── ruby_aot_compiler_design.md  # 詳細設計文書
```

## 次のステップ

1. **Regexp** — 正規表現 (PCRE or oniguruma連携)
2. **多値Hash** — 任意型のvalue対応
3. **respond_to? / is_a?** — 型イントロスペクション
4. **Proc.new / proc {}** — lambda以外のProc
5. **Struct / Data** — 簡易データクラス
6. **LumiTraceプロファイル統合** — 型推論の精度向上
7. **複数ファイルコンパイル** — require/load対応

## 参考情報

- 詳細設計: `ruby_aot_compiler_design.md`
- プロトタイプツール: `prototype/`
