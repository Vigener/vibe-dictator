# Vibe Dictator

Vibe Dictator は、macOSネイティブの音声認識機能（Apple Speech）と、軽量・高速な LLM (Gemini 2.0 Flash-Lite) を組み合わせた、エンジニア向けのヘッドレス音声入力・整形デーモンです。

グローバルホットキーで録音を開始し、音声を爆速でテキスト化。その後、パーソナライズされた用語集とコンテキスト（テキスト選択状況）に応じて AI が自然な文章やコマンドに整形し、アクティブなウィンドウへ自動ペーストします。

## 🎯 主な機能と要件

### 1. アーキテクチャと採用技術
* **音声認識エンジン:** macOSネイティブ `SFSpeechRecognizer` (Apple Speech Framework)
  * 完全オフライン、遅延ゼロ、Neural Engine (Apple Silicon) 駆動。
* **LLMモデル:** `gemini-2.0-flash-lite`
  * 高速・低コストでの推論・テキスト整形処理を担当。
* **開発言語:** Swift (macOS ネイティブ API へのダイレクトアクセス)

### 2. トリガー（グローバルホットキー）
* デフォルトでは **`F12` (キーコード: 111)** を監視します。
* ※Macの標準設定では `[Fn] + [音量UP]` キーの同時押しに相当します。Karabiner-Elements 等で任意のキーを F12 にリマップしての使用を推奨します。

### 3. 用語集（Vocabulary）機能
特定のエディタ名（Cursor, Zed）、コマンド（.zshrc）、または自身の名前等の誤変換を防ぐため、JSON形式のユーザー辞書を読み込み、プロンプトへ動的に注入します。
* **ファイルパス:** `~/.config/vibe-dictator/vocabulary.json`
* ターミナルから簡単に単語を登録できるカスタムコマンド `vibe-add` の併用を推奨します。（設定方法は後述）

### 4. コンテキスト・アウェア機能（テキスト選択時の挙動）
現在のアクティブウィンドウでテキストが選択されているかどうかを検知し、Geminiに送るプロンプトを動的に変更します。
* **非選択時（通常モード）:** 音声を自然な文章に整形し、カーソル位置に入力。
* **選択時（指示モード）:** 音声を「指示」として解釈し、選択中のテキストに対して処理（例：「箇条書きにして」）を行い、結果で上書き（置換）。

## 📂 ディレクトリとファイル構成

開発・運用において、GNU Stow等を用いた dotfiles 管理との親和性を考慮した配置です。

* **ソースコード (本リポジトリ):** `~/dev/vibe-dictator/`
* **設定ファイル (ユーザー個別):** `~/.config/vibe-dictator/vocabulary.json`
  * ※本リポジトリには `vocabulary.sample.json` を同梱しています。コピーしてご利用ください。
* **実行バイナリ:** `~/.local/bin/vibe_dictator`
* **APIキー管理:** `~/.config/vibe-dictator/.env` 等の環境変数 (`GEMINI_API_KEY`)

## 🚀 推奨ツール: `vibe-add` コマンド
辞書ファイルへのアクセスを自動化するため、お使いのシェル設定ファイル（`.zshrc` 等）に以下のエイリアス/関数を追加することを推奨します。（実行には `jq` コマンドが必要です）
```bash
function vibe-add() {
  if [ "$#" -ne 2 ]; then
    echo "Usage: vibe-add <from> <to>"
    echo "Example: vibe-add カラビナ Karabiner-Elements"
    return 1
  fi
  
  local vocab_file="$HOME/.config/vibe-dictator/vocabulary.json"
  jq --arg f "$1" --arg t "$2" '.preferred_terms += [{"from": $f, "to": $t}]' "$vocab_file" > "${vocab_file}.tmp" && mv "${vocab_file}.tmp" "$vocab_file"
  echo "✅ 辞書に追加しました: $1 -> $2"
}
```
使用例: `vibe-add カラビナ Karabiner-Elements

## メモ

### 1. 手動でのセットアップフロー
新しいMacでこのアプリを使える状態にするには、以下のステップを踏みます。

1. **クローン:** `git clone [https://github.com/yourname/vibe-dictator.git](https://github.com/yourname/vibe-dictator.git) ~/dev/vibe-dictator`
2. **コンパイル:** `swiftc main.swift -o vibe_dictator`
3. **バイナリ配置:** `mkdir -p ~/.local/bin && mv vibe_dictator ~/.local/bin/`
4. **辞書配置:** `mkdir -p ~/.config/vibe-dictator && cp vocabulary.sample.json ~/.config/vibe-dictator/vocabulary.json`
5. **常駐化:** `~/Library/LaunchAgents/com.mikoto.vibedictator.plist` を作成して配置。
6. **起動:** `launchctl load ~/Library/LaunchAgents/com.mikoto.vibedictator.plist`

### 2. 自動化の方法（シェルスクリプトに頼らない美しいアプローチ）

`.sh`（シェルスクリプト）はエラーハンドリングが面倒で、状態を持たないため（既にインストールされているかの判定などが書きづらい）、美しくありません。エンジニア界隈で好まれるアプローチは以下の2つです。

**アプローチA：`Makefile` の導入（最もスタンダード）**
リポジトリ直下に `Makefile` という設定ファイルを置きます。これは「どうやってビルドして、どこに配置するか」を定義する伝統的かつ強力なツールです。利用者は、リポジトリ内で以下のコマンドを打つだけで全自動セットアップが完了します。

```bash
make install
```
