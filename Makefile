# sample
install:
	# バイナリのコンパイルと配置
	swiftc main.swift -o vibe_dictator
	mkdir -p ~/.local/bin
	mv vibe_dictator ~/.local/bin/

	# 設定ディレクトリの作成
	mkdir -p ~/.config/vibe-dictator

	# 辞書ファイルがない場合のみサンプルをコピー
	@if [ ! -f ~/.config/vibe-dictator/vocabulary.json ]; then \
		cp vocabulary.sample.json ~/.config/vibe-dictator/vocabulary.json; \
	fi
