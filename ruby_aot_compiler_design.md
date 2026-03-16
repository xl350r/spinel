# Ruby AOTコンパイラ設計文書

*mrubyフォーク型 トレーシング+AOTコンパイラ*

最終更新: 2026-03-14（Opus再検討版）

---

## 1. プロジェクト概要

### 1.1 目的

Rubyソースコードを入力として、実行時トレーシング・静的解析・型特化コード生成を経て、
Cソースコード経由で実行可能バイナリを生成するツールを開発する。

### 1.2 基本方針

- **mrubyフォーク型（案B）**: mrubyのランタイム（GC、オブジェクトモデル、C API）を資産として活用し、AOTに必要な拡張だけを加える。ランタイムのコード自体は最小限の変更に留め、**init コードの生成**と **`-ffunction-sections` + `--gc-sections`** によって使用部分だけを選択的にリンクする。
- **トレーシング+AOT**: mrubyのVMにトレースフックを入れて型プロファイルを収集し、RBS型情報と組み合わせてCコードを生成。重い固定点反復の型推論エンジンを初期段階では不要にする。
- **動的ディスパッチ削減が核心**: 性能だけでなくリンクサイズの削減に直結する。トレースの精度と静的解析の精度がバイナリサイズと性能の両方を支配する。

### 1.3 Cソースを経由する理由

- ターゲットプラットフォームのCコンパイラに最適化を委ねられる（ARM Thumb2、RISC-V等）
- クロスコンパイルが既存ツールチェインで完結する
- W^X環境（iOS、ゲームコンソール）でもJIT不要で動作
- デバッグ性が高い（生成Cコードを人間が読める）

---

## 2. アーキテクチャ

### 2.1 全体パイプライン

```
Ruby Source
    │
    ├──────────────────────────────────────┐
    │                                      │
    ▼                                      ▼
┌────────────┐                    ┌──────────────────┐
│   Prism    │                    │ mruby (トレース  │
│ (libprism) │                    │  モード実行)     │
└─────┬──────┘                    └────────┬─────────┘
      │                                    │
      ▼                                    ▼
┌───────────────┐  ┌──────────┐  ┌──────────────────┐
│ 簡易静的解析   │  │ RBS型情報 │  │ 型プロファイル    │
│ ・クラス階層   │  │(ruby/rbs │  │ (トレース結果)   │
│ ・再定義検出   │  │ から抽出) │  │                  │
│ ・制約違反検出 │  └─────┬────┘  └────────┬─────────┘
└───────┬───────┘        │                │
        │                │                │
        └────────────────┼────────────────┘
                         │
                  ┌──────▼──────┐
                  │  統合 + CHA  │
                  │  判定        │
                  └──────┬──────┘
                         │
              ┌──────────▼───────────┐
              │  Cコード生成          │
              │  + initコード生成     │
              └──────────┬───────────┘
                         │
              ┌──────────▼───────────┐
              │  Cコンパイラ + リンク  │
              │  -ffunction-sections  │
              │  -Wl,--gc-sections    │
              │  + libmruby (フォーク) │
              └──────────┬───────────┘
                         │
              ┌──────────▼───────────┐
              │   最終バイナリ        │
              └──────────────────────┘
```

従来の2段PGO（第1段でプロファイル用Cコード生成→ビルド→実行→第2段で最適化Cコード生成）
に比べ、プロファイルはmrubyで直接実行して収集するため、Cコード生成は1回で済む。

### 2.2 ランタイム戦略

`mrb_init_core` を使わず、AOTコンパイラが到達可能解析の結果に基づいて
**使用クラス・使用メソッドだけを登録するinitコードを生成**する。

```c
/* generated_init.c — AOTコンパイラが生成 */
extern mrb_value mrb_str_split(mrb_state*, mrb_value);
extern mrb_value mrb_str_size(mrb_state*, mrb_value);
/* 未使用の mrb_str_center, mrb_str_rjust 等は宣言しない */

void generated_init_string(mrb_state *mrb) {
    struct RClass *str = mrb_define_class(mrb, "String", mrb->object_class);
    mrb_define_method(mrb, str, "split", mrb_str_split, MRB_ARGS_ARG(1,1));
    mrb_define_method(mrb, str, "size", mrb_str_size, MRB_ARGS_NONE());
}

void generated_init_core(mrb_state *mrb) {
    generated_init_string(mrb);
    generated_init_integer(mrb);
    /* Hash未使用なら generated_init_hash は呼ばない */
}
```

`-ffunction-sections` + `--gc-sections` により、未参照のC関数はリンカが除去する。
これにより**クラス単位だけでなくメソッド単位で不要コードが消える**。

### 2.3 フォーク版ランタイムへの変更（最小限）

| 変更 | 内容 | mruby本体への影響 |
|------|------|-------------------|
| トレースフック | OP_SEND前後で型情報を記録。`#ifdef MRB_AOT_TRACE` | なし（ifdef） |
| 型特化ABI | `mrb_aot_fixnum_add` 等のヘルパー群。ヘッダ1つ | なし（追加ファイル） |
| インラインキャッシュ | メソッドキャッシュスロット | オプショナル拡張 |
| deoptエントリ | VMインタプリタへのフォールバック | aot_func機構の延長 |

GCやオブジェクトモデルの変更は初期段階では不要。

### 2.4 トレースフックの設計

mrubyのvm.c内のOP_SEND処理にフックを挿入し、コールサイトごとの型情報を記録する。

```c
/* vm.c の OP_SEND 処理内 */
#ifdef MRB_AOT_TRACE
{
    mrb_value recv = regs[a];
    /* コールサイト = irep + pc で一意に識別 */
    aot_trace_record(mrb, irep, pc,
                     mrb_obj_class(mrb, recv),  /* レシーバのクラス */
                     mid,                        /* メソッド名 */
                     argc, &regs[a+1]);          /* 引数の型も記録 */
}
#endif

/* ... OP_SEND の通常処理 ... */

#ifdef MRB_AOT_TRACE
{
    /* 戻り値の型を記録 */
    aot_trace_record_return(mrb, irep, pc,
                           mrb_obj_class(mrb, regs[a]));
}
#endif
```

#### トレースデータの出力フォーマット

```json
{
  "version": 1,
  "source_hash": "sha256:...",
  "call_sites": {
    "app.rb:10:5": {
      "method": "+",
      "receiver_types": {"Integer": 9950, "Float": 50},
      "arg_types": [{"Integer": 9800, "Float": 200}],
      "return_types": {"Integer": 9900, "Float": 100},
      "total_calls": 10000
    },
    "app.rb:15:3": {
      "method": "split",
      "receiver_types": {"String": 1000},
      "arg_types": [{"String": 800, "Regexp": 200}],
      "return_types": {"Array": 1000},
      "total_calls": 1000
    }
  }
}
```

コールサイトの識別は `ソースファイル:行:カラム` で行う。
Prismのソース位置情報と対応付けるため。

#### トレースのオーバーヘッド制御

- 各コールサイトにつき最初のN回（例: 10000回）だけ記録し、打ち切る
- 型がモノモーフィックと判定された時点でそのサイトの記録を停止
- OP_ADD等の特殊化オペコードもトレース対象（Fixnum fast pathの確認）

---

## 3. 到達可能解析

### 3.1 概要

到達可能解析は**動的ディスパッチ削減**と**不要コード除去**の両方の基盤となる。
型推論とCHA（Class Hierarchy Analysis）を組み合わせた固定点反復で、
プログラム全体から到達可能なメソッドの集合を計算する。

### 3.2 動的ディスパッチ削減のレベル

| レベル | 手法 | 効果 | リンクへの影響 |
|--------|------|------|----------------|
| 0 | 現状mruby | 全SEND動的 | ランタイム全体をリンク |
| 1 | 型ガード付きfast path | 高速化（ガード成功時） | フォールバックパス残存 |
| 2 | CHA + devirtualization | ガード不要の直接呼び出し | フォールバック不要、dead code化 |
| 3 | 完全型推論 | 静的解決、unboxed演算 | 最小リンク |

**レベル2（CHA）が費用対効果の主戦場**。実アプリではコアクラスのメソッド再定義はまれであり、
「Integer#+ は再定義されていない」等の事実は静的に検証可能。

### 3.3 型の表現

```
Type = ⊥                     -- 未到達 (unknown)
     | ⊤                     -- 任意型 (any) — 解析断念
     | Single(Class)          -- 特定クラスのインスタンス
     | Union(Set<Class>)      -- 複数クラスの可能性
     | Nil                    -- NilClass
     | True / False           -- TrueClass / FalseClass
     | Symbol(name)           -- 特定シンボル（リテラル）
```

Union のサイズが閾値（4クラス）を超えたら ⊤ に widening。

### 3.4 型情報の取得: トレーシング + RBS + 簡易静的解析

型情報を3つのソースから統合する。重い固定点反復の型推論エンジンは初期段階では不要。

#### (a) トレーシング（主要な型情報源）

mrubyのトレースモードでプログラムを実行し、各コールサイトのレシーバ型・引数型・戻り値型を記録する。
テスト実行やサンプル入力による実行で収集。

**強み**: 実際のプログラムの型分布が正確にわかる。ユーザー定義メソッドの型も自動的に得られる。
**弱み**: 実行されないコードパスの型情報がない。入力データに依存。

#### (b) RBS（組み込みメソッドの型情報）

ruby/rbsのコア型定義から組み込みメソッドの型シグネチャを取得する。
トレースで得られない情報（未実行パスの組み込みメソッド呼び出し等）を補完。
ジェネリクス情報（`Array[Elem]`等）はRBSからのみ得られる。

#### (c) 簡易静的解析（CHA用）

PrismのASTを走査して以下を収集:
- クラス階層の構築
- メソッド再定義・prependの検出
- 言語制約違反の検出（eval, method_missing等）
- リテラルの型（静的に確定、トレース不要）

#### 統合ロジック

```
各コールサイトについて:
  1. トレースデータがある場合:
     - モノモーフィック (1型のみ) → proven候補
     - ポリモーフィック (2-4型) → likely候補
     - メガモーフィック (5型以上) → unresolved
  2. CHA判定:
     - proven候補 + CHA証明 (メソッド再定義なし) → SEND_PROVEN
     - proven候補 + CHA不成立 → SEND_LIKELY (型ガード付き)
     - likely候補 → SEND_LIKELY
     - unresolved → SEND_UNRESOLVED
  3. トレースデータがない場合（未実行パス）:
     - RBSから型シグネチャが得られれば → SEND_LIKELY
     - それ以外 → SEND_UNRESOLVED
```

#### 到達可能メソッド集合の計算

```
reachable = { entry_point から直接呼ばれるメソッド群 }
worklist = reachable

while worklist is not empty:
    m = worklist.pop()
    for each CALL_NODE in m:
        site = lookup_call_site(call_node)
        case site.resolution:
          SEND_PROVEN:
            add site.resolved_method to reachable
          SEND_LIKELY:
            add all type-guarded methods to reachable
          SEND_UNRESOLVED:
            add all known implementors to reachable
    for each newly added method:
        worklist.add(method)

到達不能なメソッド → initコードから除外 → gc-sectionsで消える
```

### 3.5 フロー感度（flow-sensitivity）

条件分岐での型絞り込みは解析精度に大きく影響する。追跡すべきパターン：

| パターン | then節 | else節 |
|----------|--------|--------|
| `if x` | x から Nil, False を除外 | x : Nil \| False |
| `if x.nil?` | x : Nil | x からNilを除外 |
| `if x.is_a?(Integer)` | x : Integer | x からIntegerを除外 |
| `case x when Integer` | x : Integer | — |
| `x = y \|\| default` | — | x : type(y) - Nil - False \| type(default) |

### 3.6 C定義メソッドの型情報 — RBS活用

#### 方針

ruby/rbs リポジトリのコア型定義をそのまま利用する。自前で型データベースを構築しない。

#### 利点

- コミュニティが継続的にメンテナンスしている
- ジェネリクスがあり、イテレータの型表現が自然にできる:
  ```rbs
  class Array[unchecked out Elem]
    def each: () { (Elem) -> void } -> self
    def map: [U] () { (Elem) -> U } -> Array[U]
    def select: () { (Elem) -> boolish } -> Array[Elem]
  end
  ```
- Steep等の既存ツールとの知見共有が可能

#### mrubyとのギャップ吸収

- **存在しないクラス/メソッドの除外**: mrubyのビルド構成から有効なクラス/メソッドを特定し、RBSからフィルタ
- **C関数との紐づけ**: mrubyの `mrb_define_method` 呼び出しを走査し「Ruby名 → C関数名」マッピングを抽出

#### RBS解析パイプライン

ビルド時にCRubyで前処理し、中間形式を生成:

```bash
# Step 1: RBSからmruby用型情報を抽出
ruby extract_rbs.rb \
  --mruby-config=build_config.rb \
  --rbs-dir=ruby/rbs/core \
  --output=type_db.json

# Step 2: AOTコンパイル
mruby-aot \
  --type-db=type_db.json \
  --source=app.rb \
  --output=app_aot.c
```

### 3.7 言語サブセットの制約

到達可能解析の精度を保証するため、以下の制約を課す。

#### 禁止（コンパイルエラー）

| 機能 | 理由 |
|------|------|
| `eval`, `instance_eval(文字列)`, `class_eval(文字列)` | 静的解析が不可能 |
| `method_missing` / `respond_to_missing?` の定義 | ディスパッチ先が不定 |
| `refinements` (`using`, `refine`) | 解析複雑度に対して得られるものが少ない |

#### 条件付き許容（静的に確定できない場合にコンパイルエラー）

| 機能 | 条件 | 例 |
|------|------|-----|
| `send` / `public_send` | 送られるシンボルが静的に有限集合に絞れること | `send(:foo)` OK, `send(cond ? :a : :b)` OK, `send(var)` NG |
| `define_method` | メソッド名が静的に確定可能なこと | リテラル OK, リテラル配列のイテレーション展開 OK |

#### 許容（制約なし）

| 機能 | 扱い |
|------|------|
| コアクラスの既存メソッド再定義 | 検出し、該当メソッドのCHAを無効化。他のメソッドには影響なし |
| `prepend` | 再定義と同等に扱い、該当メソッドのCHAを無効化 |
| open class（新規メソッド追加） | CHAに影響なし。全ソースがコンパイル時に揃っていれば問題なし |
| `attr_accessor` / `attr_reader` / `attr_writer` | 引数がリテラルなら静的に確定 |
| `require` / `load` | ビルド構成で所在を静的に指定。require文はコード中に残してよい |
| `respond_to?` | フロー感度の型絞り込みパターンとして扱う |
| `Proc` / `lambda` / ブロック | 型推論で追跡可能 |

#### CHA無効化の仕組み

コアクラスの既存メソッド再定義とprependは、禁止ではなく**検出して対応**する:

1. 全ソースを走査し、組み込みメソッドの再定義・prependを検出
2. 該当メソッドのCHAエントリに「再定義あり」フラグを設定
3. SENDの解決時にフラグを確認し、再定義ありならdevirtualizeしない
4. そのサイトは通常のmrubyディスパッチにフォールバック

現実のRubyコードではコアメソッドの再定義はまれであり、
大半のプログラムではCHAがフルに効く。再定義しているプログラムでは
その部分だけ最適化されないという自然な結果になる。

### 3.8 保守的フォールバックのグラデーション

解析が型を確定できない場合、3段階で扱う:

| 解決レベル | 条件 | コード生成 | リンクへの影響 |
|------------|------|------------|----------------|
| proven | CHA証明済み | ガードなし直接呼び出し | 最小 |
| likely | 静的に絞り込み済み、プロファイルで確認 | 軽量型ガード + 直接呼び出し | ガード失敗パス分 |
| unresolved | 型不確定 | mrubyディスパッチ | そのサイトから芋づる式にリンク |

---

## 4. コード生成

### 4.1 解決レベル別コード生成

トレース＋RBS＋簡易静的解析の統合結果に基づき、コールサイトごとに異なるコードを生成する。

```c
/* SEND_PROVEN: CHA証明済み + トレースでモノモーフィック確認 */
/* ガードなし直接呼び出し */
{
    /* Integer#+ は再定義なし、トレースでも100%Integer */
    mrb_int a = mrb_fixnum(regs[1]);
    mrb_int b = mrb_fixnum(regs[2]);
    regs[1] = mrb_fixnum_value(a + b);
}

/* SEND_LIKELY: トレースでモノモーフィックだがCHA証明なし */
/* 型ガード付き直接呼び出し */
{
    mrb_value recv = regs[1];
    if (mrb_fixnum_p(recv) && mrb_fixnum_p(regs[2])) {
        /* fast path: 直接演算 */
        mrb_int a = mrb_fixnum(recv);
        mrb_int b = mrb_fixnum(regs[2]);
        if (!MRB_INT_OVERFLOW_ADD_P(a, b)) {
            regs[1] = mrb_fixnum_value(a + b);
            goto next_inst;
        }
    }
    /* slow path: mrubyディスパッチ */
    regs[1] = mrb_funcall(mrb, recv, "+", 1, regs[2]);
  next_inst:;
}

/* SEND_UNRESOLVED: 型不確定 */
/* 通常のmrubyディスパッチ */
{
    regs[1] = mrb_funcall(mrb, regs[1], "foo", 0);
}
```

### 4.2 initコード生成

到達可能解析の結果から、使用メソッドだけを登録するinitコードを生成:

```c
void generated_init_core(mrb_state *mrb) {
    /* 到達可能なクラスのみ初期化 */
    generated_init_object(mrb);
    generated_init_string(mrb);
    generated_init_integer(mrb);
    generated_init_array(mrb);
    /* Hash未使用 → 呼ばない */
}
```

---

## 5. プロトタイプ（Step 0）

### 5.1 目的

本格実装に先立ち、以下の2つの基盤技術を実証する:
- (a) RBSからの型情報抽出とmrubyへの適用可能性
- (b) mrubyのVMにトレースフックを入れて型プロファイルを収集する仕組み

### 5.2 スコープ

1. **RBS → JSON変換**: ruby/rbs の core/ ディレクトリからmrubyに存在するクラス/メソッドの
   型シグネチャを抽出し、JSON形式で出力する
2. **mrubyメソッドマッピング**: mrubyソースの `mrb_define_method` 呼び出しを走査し、
   「Ruby名 → C関数名」の対応表を生成する
3. **カバレッジ測定**: mrubyのコアメソッドのうち何%がRBSで型情報を持つか計測する
4. **トレースフックのパッチ**: mrubyのvm.cにOP_SEND前後のフックを挿入し、
   型プロファイルをJSON出力する
5. **トレース+RBS統合デモ**: 小さなRubyスクリプトに対して、
   トレースで収集した型情報とRBS型情報を統合し、到達可能メソッド集合の計算を行い、
   フルリンクとの差分を可視化する

### 5.3 成果物

```
prototype/
├── tools/
│   ├── extract_rbs.rb          # RBS→JSON変換スクリプト（CRuby）
│   ├── scan_mruby_methods.rb   # mrubyソースからメソッドマッピング抽出
│   ├── coverage_report.rb      # カバレッジ測定・レポート
│   └── merge_trace_rbs.rb      # トレース結果とRBSの統合デモ
├── trace/
│   ├── aot_trace.h             # トレースAPI定義
│   ├── aot_trace.c             # トレースデータ記録・JSON出力
│   └── vm_patch.diff           # mruby vm.cへのパッチ
├── output/                     # 生成物
│   ├── type_db.json            # RBS由来の型情報
│   ├── method_map.json         # Ruby名→C関数名マッピング
│   └── trace_output.json       # トレース結果（サンプル）
└── README.md
```

### 5.4 extract_rbs.rb の設計

```ruby
# 入力: ruby/rbs/core/*.rbs
# 出力: type_db.json
#
# 処理:
#   1. RBS::Parser でパース
#   2. mrubyに存在するクラスでフィルタ
#   3. 各メソッドの型シグネチャを以下の形式で出力:
#
# {
#   "Integer": {
#     "+": {
#       "overloads": [
#         { "params": [{"name": "other", "type": "Integer"}],
#           "return": "Integer" },
#         { "params": [{"name": "other", "type": "Float"}],
#           "return": "Float" }
#       ]
#     },
#     "to_s": {
#       "overloads": [
#         { "params": [], "return": "String" },
#         { "params": [{"name": "base", "type": "Integer"}],
#           "return": "String" }
#       ]
#     }
#   },
#   "Array": {
#     "each": {
#       "overloads": [
#         { "params": [],
#           "block": {"params": ["Elem"], "return": "void"},
#           "return": "self" }
#       ],
#       "type_params": ["Elem"]
#     }
#   }
# }
```

### 5.5 scan_mruby_methods.rb の設計

```ruby
# mrubyのsrc/*.c および mrbgems/*/src/*.c を走査し
# mrb_define_method, mrb_define_class_method 等の呼び出しから
# Ruby名 → C関数名のマッピングを抽出
#
# 出力例:
# {
#   "String": {
#     "instance_methods": {
#       "split": { "c_func": "mrb_str_split", "file": "src/string.c", "line": 1234 },
#       "size":  { "c_func": "mrb_str_size",  "file": "src/string.c", "line": 567 }
#     },
#     "class_methods": {}
#   }
# }
```

### 5.6 トレースフックの設計

```c
/* aot_trace.h */
#ifndef MRB_AOT_TRACE_H
#define MRB_AOT_TRACE_H

#include <mruby.h>

/* トレースの初期化・終了 */
void aot_trace_init(mrb_state *mrb);
void aot_trace_finish(mrb_state *mrb, const char *output_path);

/* OP_SEND 前に呼ぶ: レシーバ・引数の型を記録 */
void aot_trace_record(mrb_state *mrb,
                      const mrb_irep *irep, const mrb_code *pc,
                      struct RClass *recv_class,
                      mrb_sym method_name,
                      int argc, mrb_value *args);

/* OP_SEND 後に呼ぶ: 戻り値の型を記録 */
void aot_trace_record_return(mrb_state *mrb,
                             const mrb_irep *irep, const mrb_code *pc,
                             struct RClass *return_class);

#endif
```

```c
/* aot_trace.c の概要 */

/* コールサイトごとのトレースデータ */
typedef struct {
    const char *source_file;
    int line;
    int column;
    mrb_sym method_name;
    /* 型カウンタ: クラスID → 出現回数 */
    /* khash で管理 */
    khash_t(type_count) *recv_types;
    khash_t(type_count) *return_types;
    int total_calls;
    int max_records;       /* 打ち切り閾値 */
} aot_trace_site;

/* 全コールサイトの管理 */
/* khash: (irep_ptr, pc_offset) → aot_trace_site */

void aot_trace_finish(mrb_state *mrb, const char *output_path) {
    /* 全サイトのデータをJSON形式で出力 */
    /* cJSON を使用 */
}
```

### 5.7 統合デモ (merge_trace_rbs.rb)

小さなテストプログラムに対して、トレース結果とRBS型情報を統合し、
到達可能メソッドの集合を計算する。

```ruby
# テスト対象のRubyコード:
# def greet(name)
#   "Hello, " + name.to_s
# end
# puts greet("world")
#
# 手順:
# 1. mruby (トレースモード) で実行 → trace_output.json
# 2. RBS型情報 (type_db.json) と統合
# 3. 各コールサイトの解決結果を表示:
#      app.rb:2 String#+ → PROVEN (trace: 100% String, CHA: 再定義なし)
#      app.rb:2 Object#to_s → LIKELY (trace: 100% String, CHA: 再定義あり)
#      app.rb:4 Kernel#puts → PROVEN (trace: 100% Object, CHA: 再定義なし)
# 4. 到達可能メソッド集合 vs 全メソッド の差分を表示
```

### 5.8 検証項目

- [ ] RBSのジェネリクス（Array[Elem]等）が正しくJSON化されるか
- [ ] mrubyに存在しないメソッド（IO系等）が正しく除外されるか
- [ ] overload（Integer#+ の Integer版/Float版）が区別されるか
- [ ] ブロック付きメソッド（each, map等）の型情報が取れるか
- [ ] mrubyのコアメソッドのRBSカバレッジ率はどの程度か
- [ ] トレースフックがmrubyの全テストスイートを壊さないか
- [ ] トレース出力のJSON形式が正しく、期待される型カウントを含むか
- [ ] トレースのオーバーヘッド（通常実行比でN倍程度か）
- [ ] トレース+RBS統合で、明らかに不要なクラスが到達不能と判定されるか

---

## 6. 実装技術

### 6.1 実装言語: C（klib使用）

AOTコンパイラ本体はCで実装する。RBS型情報の前処理のみCRubyスクリプト。

**選定理由**:
- mrubyのランタイムと同じ言語であり、irep構造体やシンボルテーブルを直接利用可能
- C++のtemplateを多用したコードは可読性・保守性に問題がある
- klibがSTL相当のデータ構造をマクロベースで提供（mruby自体がkhashを使用）
- Claude Codeによる実装との相性も良い

### 6.2 依存ライブラリ

| ライブラリ | 用途 | 備考 |
|-----------|------|------|
| klib (khash) | ハッシュマップ — 型環境、メソッドテーブル | mrubyと同じ |
| klib (kvec) | 動的配列 — ワークリスト、union型要素、AST子ノード | ヘッダのみ |
| klib (kstring) | 文字列操作 — メソッド名、クラス名 | ヘッダのみ |
| cJSON | JSON解析 — RBS型情報の読み込み | .h + .c 各1つ |
| Prism (libprism) | Rubyパーサ — AST生成 | C99、依存なし |
| mruby headers | シンボル定義、値表現 | フォーク版ランタイムのリンク用 |

### 6.3 ディレクトリ構成

```
mruby-aot/
├── src/
│   ├── main.c                 # エントリポイント、CLI
│   ├── type.h / type.c        # 型の表現（aot_type構造体）、サイドテーブル定義
│   ├── type_db.h / type_db.c  # RBS由来のJSON型情報読み込み
│   ├── analyzer.h / analyzer.c  # 型推論 + 固定点反復
│   ├── cha.h / cha.c          # Class Hierarchy Analysis
│   ├── reachability.h / reachability.c  # 到達可能解析
│   ├── codegen.h / codegen.c  # Cコード生成
│   └── profile.h / profile.c  # プロファイルデータ読み書き
├── lib/
│   ├── klib/                  # khash.h, kvec.h, kstring.h
│   ├── cjson/                 # cJSON.h, cJSON.c
│   └── prism/                 # libprism（C99、依存なし）
├── include/
│   └── mruby/                 # mrubyヘッダ（フォーク版）
├── tools/
│   ├── extract_rbs.rb         # RBS→JSON変換（CRuby）
│   └── scan_mruby_methods.rb  # mrubyメソッドマッピング抽出
├── type_db/
│   └── core.json              # 生成された型情報
├── test/
│   ├── test_analyzer.c
│   ├── test_cha.c
│   └── fixtures/              # テスト用Rubyソース
├── Makefile
└── README.md
```

※ パーサにPrismを使うため、パース段階ではmrb_state不要。
※ libmruby（フォーク版）は生成コードのリンク時に使用。AOTコンパイラ自体はlibprismのみに依存。

### 6.4 パーサとAST設計

#### パーサ: Prism (libprism)

PrismのC APIを使用してRubyソースをパースし、`pm_node_t`ツリーを直接解析する。
独自ASTへの変換は行わない。

**選択理由**:
- C99、依存なし — AOTコンパイラの他の依存（klib, cJSON）と同じ精神
- AST構造が `config.yml` で宣言的に定義・文書化されている
- mrb_state不要 — パーサのためにmrubyランタイムを初期化する必要がない
- mruby-compiler2 (picoruby) で Prism → mruby irep の変換実績あり
- MRubyCS でも採用されている
- CRuby, JRuby, TruffleRuby, Sorbet で広く使われている

**mrubyの文法はCRubyと完全互換**（pattern matchingを除く）なので、
Prismがパースする構文範囲に問題はない。
mrubyに存在しないのはメソッドや機能であり、文法ではない。

#### パイプライン

```
Ruby Source
    │
    ▼
Prism (libprism)          ← C99、依存なし、mrb_state不要
    │
    ▼
pm_node_t tree             ← Prismの公開AST（文書化済み）
    │
    ├─── サイドテーブル: pm_node_t* → aot_type（推論型）
    ├─── サイドテーブル: pm_node_t* → send_resolution（SEND解決結果）
    │
    ▼
型推論 / CHA / 到達可能解析  ← pm_node_tを直接走査、結果はサイドテーブルに記録
    │
    ▼
Cコード生成                 ← pm_node_t + サイドテーブルから出力
```

独自ASTへの変換を行わない理由:
- 型情報やSEND解決結果はサイドテーブル（khash: `pm_node_t*` → 値）で管理できる
- `pm_parser_t` を解析完了まで保持すれば、メモリ管理の問題は生じない
- PrismのAST構造は安定しており文書化されている。隔離層の必要性が低い
- ast_convert.c と aot_node 定義が丸ごと不要になり、コード量が大幅に減る

#### 基本的な使い方

```c
#include <prism.h>

/* パース */
pm_parser_t parser;
pm_parser_init(&parser, source, length, NULL);
pm_node_t *root = pm_parse(&parser);

/* サイドテーブル初期化 */
khash_t(node_types) *types = kh_init(node_types);
khash_t(node_resolutions) *resolutions = kh_init(node_resolutions);

/* pm_node_tを直接走査して型推論 */
type_env env;
type_env_init(&env);
infer(root, &env, types, resolutions);

/* コード生成（pm_node_t + サイドテーブルから） */
codegen(root, types, resolutions, output_file);

/* 解放 */
kh_destroy(node_types, types);
kh_destroy(node_resolutions, resolutions);
pm_node_destroy(&parser, root);
pm_parser_free(&parser);
```

#### 型推論の動作例

```c
/* analyzer.c — PrismのASTを直接走査して型推論 */

/* サイドテーブルに記録するヘルパー */
static aot_type record_type(khash_t(node_types) *types,
                            pm_node_t *node, aot_type type) {
    int ret;
    khint_t k = kh_put(node_types, types, (uintptr_t)node, &ret);
    kh_val(types, k) = type;
    return type;
}

aot_type infer(pm_node_t *node, type_env *env,
               khash_t(node_types) *types,
               khash_t(node_resolutions) *resolutions) {
    switch (PM_NODE_TYPE(node)) {
    case PM_INTEGER_NODE:
        return record_type(types, node, TYPE_SINGLE(Integer));

    case PM_FLOAT_NODE:
        return record_type(types, node, TYPE_SINGLE(Float));

    case PM_STRING_NODE:
        return record_type(types, node, TYPE_SINGLE(String));

    case PM_NIL_NODE:
        return record_type(types, node, TYPE_NIL);

    case PM_TRUE_NODE:
        return record_type(types, node, TYPE_TRUE);

    case PM_FALSE_NODE:
        return record_type(types, node, TYPE_FALSE);

    case PM_LOCAL_VARIABLE_READ_NODE: {
        pm_local_variable_read_node_t *lvar =
            (pm_local_variable_read_node_t *)node;
        return record_type(types, node,
                          type_env_get(env, lvar->name));
    }

    case PM_LOCAL_VARIABLE_WRITE_NODE: {
        pm_local_variable_write_node_t *lvar =
            (pm_local_variable_write_node_t *)node;
        aot_type rhs = infer(lvar->value, env, types, resolutions);
        type_env_set(env, lvar->name, rhs);
        return record_type(types, node, rhs);
    }

    case PM_IF_NODE: {
        pm_if_node_t *if_n = (pm_if_node_t *)node;
        type_env then_env = type_env_clone(env);
        type_env else_env = type_env_clone(env);
        narrow_by_condition(if_n->predicate, &then_env, &else_env);
        aot_type t = infer((pm_node_t *)if_n->statements,
                          &then_env, types, resolutions);
        aot_type e = if_n->subsequent
            ? infer((pm_node_t *)if_n->subsequent,
                   &else_env, types, resolutions)
            : TYPE_NIL;
        return record_type(types, node, type_union(t, e));
    }

    case PM_CALL_NODE:
        return infer_call((pm_call_node_t *)node,
                         env, types, resolutions);

    /* ... */
    }
}
```

### 6.5 核心データ構造

```c
/* type.h — 型の表現 */

enum aot_type_kind {
    TYPE_BOTTOM,       /* 未到達 (unknown) */
    TYPE_TOP,          /* 任意型 (any) — 解析断念 */
    TYPE_SINGLE,       /* 特定クラスのインスタンス */
    TYPE_UNION,        /* 複数クラスの可能性 */
    TYPE_NIL,
    TYPE_TRUE,
    TYPE_FALSE,
};

#define AOT_UNION_MAX 4  /* これを超えたら TOP に widening */

typedef struct {
    enum aot_type_kind kind;
    union {
        mrb_sym class_id;                          /* SINGLE */
        struct { mrb_sym classes[AOT_UNION_MAX]; int n; } uni;  /* UNION */
    };
} aot_type;

/* SEND解決結果 */
enum send_resolution {
    SEND_PROVEN,       /* CHA証明済み — ガードなし直接呼び出し */
    SEND_LIKELY,       /* 型絞り込み済み — プロファイルで補強 */
    SEND_UNRESOLVED,   /* 型不確定 — mrubyディスパッチ */
};

typedef struct {
    enum send_resolution resolution;
    mrb_sym resolved_class;   /* proven時の解決先クラス */
} aot_send_info;

/* --- サイドテーブル（PrismのASTノードに紐づく解析結果） --- */

/* pm_node_t* → 推論型 */
KHASH_MAP_INIT_INT64(node_types, aot_type)

/* pm_node_t* → SEND解決結果（PM_CALL_NODEに対してのみ） */
KHASH_MAP_INIT_INT64(node_sends, aot_send_info)

/* --- 型推論の内部データ構造 --- */

/* 変数名 → 型 */
KHASH_MAP_INIT_INT(type_env, aot_type)

/* 到達可能メソッド集合 */
KHASH_SET_INIT_INT(method_set, char)

/* ワークリスト */
typedef kvec_t(int) worklist_t;
```

### 6.6 ビルドの流れ

```bash
# Step 1: RBS型情報の抽出（CRuby、一度だけ）
ruby tools/extract_rbs.rb \
  --mruby-config=build_config.rb \
  --rbs-dir=path/to/ruby/rbs/core \
  --output=type_db/core.json

# Step 2: AOTコンパイラのビルド
make

# Step 3: トレースモードでプログラムを実行
# (mruby フォーク版、MRB_AOT_TRACE=1 でビルド済み)
./mruby-trace app.rb --trace-output=trace.json

# Step 4: AOTコンパイル（トレース + RBS + 静的解析 → Cコード生成）
./mruby-aot \
  --type-db=type_db/core.json \
  --trace=trace.json \
  --source=app.rb \
  --output=app_aot.c

# Step 5: 最終バイナリのビルド
cc -ffunction-sections -Wl,--gc-sections \
  app_aot.c -lmruby -o app
```

---

## 7. 実装ロードマップ

### Step 0: プロトタイプ（上記セクション5）

- RBS → JSON抽出
- mrubyメソッドマッピング
- トレースフックのmrubyパッチ（vm.cに数十行）
- トレースデータ出力機構（aot_trace.c）
- トレース + RBS 統合デモ
- **判断ポイント**: RBSのカバレッジ、トレースの精度・オーバーヘッドの確認

### Step 1: 簡易静的解析

- libprismのビルドとリンク
- PrismのASTを走査してクラス階層を構築
- メソッド再定義・prependの検出
- 言語制約違反の検出（eval, method_missing, refinements）
- テスト: 小さなRubyスニペットで制約チェックの正しさ検証

### Step 2: 統合 + CHA判定

- トレースデータ（JSON）の読み込み
- RBS型情報（JSON）の読み込み
- コールサイトごとの統合ロジック（トレース + RBS + CHA → 解決レベル判定）
- 到達可能メソッド集合の計算
- サイドテーブル（khash: pm_node_t* → aot_send_info）への記録

### Step 3: Cコード生成

- proven サイトのガードなし直接呼び出しコード生成
- likely サイトの型ガード付き特化コード生成
- unresolved サイトのmrubyディスパッチコード生成
- initコード生成（到達可能メソッドのみ登録）
- libmruby（フォーク版）とのリンク、`--gc-sections` による不要コード除去

### Step 4: 検証・最適化

- ベンチマークスイート構築
- バイナリサイズの計測・フルリンクとの比較
- 性能計測（mrubyインタプリタ比）
- エッジケースの洗い出し

### 将来の拡張（必要に応じて）

- 固定点反復の型推論エンジン（トレースで未カバーのパスの型推論）
- UC2（MCU組み込み）対応
- プロファイル反復（AOTバイナリで再トレース→再コンパイル）

---

## 8. 未解決事項

### アーキテクチャ

- [x] ~~パーサの選択~~ → Prism (libprism) を使用。pm_node_tを直接走査し、サイドテーブルで型情報を管理
- [x] ~~AOTコンパイラ自体の実装言語~~ → C（klib使用）に決定
- [x] ~~型情報の取得方法~~ → mrubyトレーシング + RBS + 簡易静的解析の3源統合
- [ ] UC2（MCU組み込み）対応は将来の拡張として後回し

### トレーシング

- [ ] トレースのサンプリング戦略の詳細（全数 vs サンプリング、打ち切り閾値）
- [ ] コールサイト識別のirep+pc→ソース位置のマッピング精度
- [ ] テストカバレッジが低い場合の未到達パスの扱い

### 型推論（将来の拡張）

- [ ] 固定点反復の型推論エンジン（トレースで未カバーのパスの型推論）
- [ ] ジェネリクスのインスタンス化戦略（Array[Integer] vs Array[⊤]）
- [ ] Procオブジェクトの型追跡

### ランタイム

- [ ] Fiberを使うプログラムへの対応（deoptとの相互作用）
- [ ] 例外処理のAOTコードでの表現（setjmp/longjmpとの協調）
- [ ] GC safe point の挿入位置

### ビルドシステム

- [x] ~~CMake / Meson / Rake~~ → Makefile に決定
- [x] ~~CRuby依存（RBS解析）の扱い~~ → ビルド時のみの依存として許容

---

## 9. 参考実装・先行研究

| 参照 | 参照ポイント |
|------|-------------|
| **mruby / mrbc** | IRep構造、C生成の基礎、Value表現 |
| **Prism** | Rubyパーサ、C API、AST構造 |
| **mruby-compiler2** | Prism→mruby irep変換の実装例 |
| **ruby/rbs** | コア型定義、ジェネリクス表現 |
| **Steep** | RBS活用の型検査実装 |
| **TypeProf** | Rubyのデータフロー型推論 |
| **lumitrace** | Rubyの実行時トレーシング手法 |
| **Crystal** | RubyライクなASTから静的コンパイル |
| **TruffleRuby** | Speculative最適化とdeoptimization |
| **V8 TurboFan** | 型フィードバック、PGO |
| **LuaJIT** | トレースJITのプロファイル活用 |
| **Sorbet** | 高速なRuby型検査 |
| **klib** | マクロベースのCデータ構造（khash, kvec） |
| **cJSON** | 軽量JSONパーサ |

---

*本文書は設計の現時点のスナップショットです。実装の進行に伴い随時更新してください。*
