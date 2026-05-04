SWIFT_FLAGS = -framework Cocoa -framework Speech -framework AVFoundation -framework ApplicationServices
BIN = vibe_dictator

install:
	# バイナリのコンパイルと配置
	swiftc -parse-as-library main.swift $(SWIFT_FLAGS) -o $(BIN)
	mkdir -p ~/.local/bin
	mv $(BIN) ~/.local/bin/

	# 設定ディレクトリの作成
	mkdir -p ~/.config/vibe-dictator

	# 辞書ファイルがない場合のみサンプルをコピー
	@if [ ! -f ~/.config/vibe-dictator/vocabulary.json ]; then \
		cp vocabulary.sample.json ~/.config/vibe-dictator/vocabulary.json; \
	fi

test:
	swiftc -parse-as-library main.swift $(SWIFT_FLAGS) -o $(BIN)
	./$(BIN) --test-file sample_transcript.txt --dry-run
