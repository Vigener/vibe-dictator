import Cocoa
import Speech
import AVFoundation
import ApplicationServices

private let hotkeyCode: UInt16 = 111
private let defaultModelName = "gemini-2.5-flash-lite"
private let configDirectory = URL(fileURLWithPath: NSHomeDirectory())
	.appendingPathComponent(".config/vibe-dictator", isDirectory: true)
private let vocabularyURL = configDirectory.appendingPathComponent("vocabulary.json")
private let environmentURL = configDirectory.appendingPathComponent(".env")

struct VocabularyFile: Codable {
	struct UserProfile: Codable {
		let name: String
		let reading: String?
	}

	struct PreferredTerm: Codable {
		let from: String
		let to: String
	}

	let userProfile: UserProfile
	let preferredTerms: [PreferredTerm]

	enum CodingKeys: String, CodingKey {
		case userProfile = "user_profile"
		case preferredTerms = "preferred_terms"
	}
}

enum ProcessingMode {
	case normal
	case instruction(selectedText: String)
}

struct CommandLineOptions {
	var testFilePath: String?
	var dryRun: Bool = false
}

@main
struct VibeDictatorApp {
	static func main() {
		let options = parseArguments(CommandLine.arguments)
		let dictator = VibeDictator()

		if let testFilePath = options.testFilePath {
			dictator.runTest(filePath: testFilePath, dryRun: options.dryRun)
			return
		}

		dictator.startDaemon()
	}

	private static func parseArguments(_ arguments: [String]) -> CommandLineOptions {
		var options = CommandLineOptions()
		var index = 1

		while index < arguments.count {
			let argument = arguments[index]
			switch argument {
			case "--test-file":
				if index + 1 < arguments.count {
					options.testFilePath = arguments[index + 1]
					index += 1
				}
			case "--dry-run":
				options.dryRun = true
			case "--help", "-h":
				print(helpText())
				exit(0)
			default:
				break
			}
			index += 1
		}

		return options
	}

	private static func helpText() -> String {
		"""
		Usage:
		  vibe_dictator
		  vibe_dictator --test-file <path> [--dry-run]

		Options:
		  --test-file <path>   Read a fake transcription from a file and process it once.
		  --dry-run            Do not paste; print the rewritten result only.
		"""
	}
}

final class VibeDictator {
	private enum RewriteRoute {
		case gemini
		case local(reason: String)
	}

	private let audioEngine = AVAudioEngine()
	private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
	private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
	private var recognitionTask: SFSpeechRecognitionTask?
	private var globalMonitor: Any?

	private var isRecording = false
	private var recognizedText = ""
	private var currentSelectionText: String?
	private let vocabulary = VocabularyStore.load(from: vocabularyURL)
	private var testDiagnosticsEnabled = false

	init() {
		loadEnvironmentFile()
	}

	func startDaemon() {
		NSApplication.shared.setActivationPolicy(.accessory)
		print("Vibe Dictator を起動中...")
		requestAccessibilityPrompt()
		requestPermissions { [weak self] granted in
			guard let self = self else { return }
			guard granted else { exit(1) }

			self.setupGlobalHotkey()
			print("Vibe Dictator 起動完了 [スタンバイ]")
			print("  - F12キー: 録音の開始/停止 (トグル)")
			print("  - 終了するには Ctrl+C を押してください")
		}
		NSApplication.shared.run()
	}

	func runTest(filePath: String, dryRun: Bool) {
		let url = URL(fileURLWithPath: filePath)
		do {
			testDiagnosticsEnabled = true
			let sampleText = try String(contentsOf: url, encoding: .utf8)
			let cleaned = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
			if cleaned.isEmpty {
				print("テスト入力が空です: \(filePath)")
				return
			}

			print("[test] 入力ファイル: \(filePath)")
			print("[test] 元テキスト:\n\(cleaned)\n")

			rewriteText(cleaned, mode: .normal) { result in
				print("[test] 整形後テキスト:\n\(result)")
				if !dryRun {
					self.copyToClipboard(result)
				}
				exit(0)
			}

			RunLoop.main.run()
		} catch {
			print("テストファイルを読み込めませんでした: \(error)")
		}
	}

	private func requestPermissions(completion: @escaping (Bool) -> Void) {
		SFSpeechRecognizer.requestAuthorization { status in
			if status != .authorized {
				print("エラー: 音声認識へのアクセスが許可されていません。")
				completion(false)
				return
			}
			self.requestMicrophoneAccess(completion: completion)
		}
	}

	private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized:
			completion(true)
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				if !granted {
					print("エラー: マイクへのアクセスが許可されていません。")
				}
				completion(granted)
			}
		default:
			print("エラー: マイクへのアクセスが拒否されています。")
			completion(false)
		}
	}

	private func requestAccessibilityPrompt() {
		let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
		let accessEnabled = AXIsProcessTrustedWithOptions(options)
		if !accessEnabled {
			print("警告: アクセシビリティ権限が必要です。選択テキストの検出は無効になります。")
		}
	}

	private func setupGlobalHotkey() {
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self = self else { return }
			guard event.keyCode == hotkeyCode else { return }

			if self.isRecording {
				self.stopRecordingAndProcess()
			} else {
				self.startRecording()
			}
		}
	}

	private func startRecording() {
		if recognitionTask != nil {
			recognitionTask?.cancel()
			recognitionTask = nil
		}

		currentSelectionText = captureSelectedText()
		recognizedText = ""

		recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
		guard let recognitionRequest = recognitionRequest else {
			print("SFSpeechAudioBufferRecognitionRequest の作成に失敗しました")
			return
		}

		recognitionRequest.shouldReportPartialResults = true
		if #available(macOS 13.0, *) {
			recognitionRequest.requiresOnDeviceRecognition = true
		}

		let inputNode = audioEngine.inputNode
		let recordingFormat = inputNode.outputFormat(forBus: 0)

		inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
			self?.recognitionRequest?.append(buffer)
		}

		audioEngine.prepare()

		do {
			try audioEngine.start()
			isRecording = true
			print("🎤 録音開始...")
			notify(title: "Vibe Dictator", message: "録音開始")
		} catch {
			print("オーディオエンジンの起動に失敗しました: \(error)")
			cleanupRecordingState()
			return
		}

		recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
			guard let self = self else { return }

			if let result = result {
				self.recognizedText = result.bestTranscription.formattedString
			}

			if error != nil {
				self.cleanupRecordingState()
			}
		}
	}

	private func stopRecordingAndProcess() {
		print("停止処理中...")
		audioEngine.stop()
		audioEngine.inputNode.removeTap(onBus: 0)
		recognitionRequest?.endAudio()
		isRecording = false

		let transcript = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
		let mode: ProcessingMode
		if let selection = currentSelectionText, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			mode = .instruction(selectedText: selection)
		} else {
			mode = .normal
		}

		// 元テキストが短すぎる場合は Gemini へ送らずローカル処理で対応
		if transcript.count <= 10 {
			print("元テキストが短いため Gemini へ送信せずローカル処理を実行します: \(transcript)")
			let localResult = self.localRewrite(transcript, mode: mode)
			print("整形後テキスト: \(localResult)")
			self.pasteToActiveWindow(text: localResult)
			self.notify(title: "Vibe Dictator", message: "入力完了")
			self.cleanupRecordingState()
			return
		}

		notify(title: "Vibe Dictator", message: "AIによる整形中...")
		print("元のテキスト: \(transcript)")

		rewriteText(transcript, mode: mode) { [weak self] rewrittenText in
			guard let self = self else { return }
			print("整形後テキスト: \(rewrittenText)")
			self.pasteToActiveWindow(text: rewrittenText)
			self.notify(title: "Vibe Dictator", message: "入力完了")
			self.cleanupRecordingState()
		}
	}

	private func cleanupRecordingState() {
		audioEngine.stop()
		audioEngine.inputNode.removeTap(onBus: 0)
		recognitionRequest = nil
		recognitionTask = nil
		isRecording = false
	}

	private func rewriteText(_ text: String, mode: ProcessingMode, completion: @escaping (String) -> Void) {
		func finishWithLocal(reason: String) {
			reportRewriteRoute(.local(reason: reason))
			completion(localRewrite(text, mode: mode))
		}

		let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
		if apiKey.isEmpty {
			finishWithLocal(reason: "GEMINI_API_KEY が未設定")
			return
		}

		let prompt = buildPrompt(text: text, mode: mode)
		let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(defaultModelName):generateContent?key=\(apiKey)"
		guard let url = URL(string: urlString) else {
			finishWithLocal(reason: "Gemini API URL の生成に失敗")
			return
		}

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")

		let body: [String: Any] = [
			"contents": [
				["parts": [["text": prompt]]]
			],
			"generationConfig": [
				"temperature": 0.2,
				"maxOutputTokens": 512
			]
		]

		request.httpBody = try? JSONSerialization.data(withJSONObject: body)

		let task = URLSession.shared.dataTask(with: request) { data, _, error in
			guard let data = data, error == nil else {
				print("APIリクエストエラー: \(String(describing: error))")
				finishWithLocal(reason: "API リクエストエラー")
				return
			}

			do {
				guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
					finishWithLocal(reason: "レスポンス JSON の型が不正")
					return
				}

				if let errorObject = json["error"] as? [String: Any],
				   let message = errorObject["message"] as? String {
					print("Gemini API error: \(message)")
					finishWithLocal(reason: "Gemini API error: \(message)")
					return
				}

                if let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let raw = firstPart["text"] as? String {
				// Try to safely extract JSON {"text":"..."} if model returned it,
				// otherwise attempt some common fallbacks (JSON substring, code fence),
				// finally fall back to raw trimmed text.
				var finalOutput: String? = nil
				if let data = raw.data(using: .utf8) {
					if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
						let textField = parsed["text"] as? String {
						finalOutput = textField
					}
				}

				if finalOutput == nil, let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end {
					let jsonCandidate = String(raw[start...end])
					if let data = jsonCandidate.data(using: .utf8),
						let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
						let textField = parsed["text"] as? String {
						finalOutput = textField
					}
				}

				if finalOutput == nil, raw.contains("```") {
					let parts = raw.components(separatedBy: "```")
					if parts.count >= 3 {
						finalOutput = parts[1]
					}
				}

				let output = (finalOutput ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
				self.reportRewriteRoute(.gemini)
				completion(output)
			} else {
				finishWithLocal(reason: "Gemini 応答に text が含まれない")
			}
			} catch {
				print("JSONパースエラー: \(error)")
				finishWithLocal(reason: "JSON パースエラー")
			}
		}
		task.resume()
	}

	private func reportRewriteRoute(_ route: RewriteRoute) {
		guard testDiagnosticsEnabled else { return }

		switch route {
		case .gemini:
			print("[test] AI整形経路: Gemini API 成功 (model=\(defaultModelName))")
		case .local(let reason):
			print("[test] AI整形経路: ローカル整形にフォールバック (理由: \(reason))")
		}
	}

	private func buildPrompt(text: String, mode: ProcessingMode) -> String {
		let terms = vocabulary.preferredTerms
			.map { "- \($0.from): \($0.to)" }
			.joined(separator: "\n")
		let displayName = vocabulary.userProfile.name
		let glossarySection = terms.isEmpty ? "(なし)" : terms

		switch mode {
		case .normal:
			return """
			あなたは優秀なエンジニア向け編集アシスタントです。
			以下の音声文字起こしテキストを、元の話し言葉の雰囲気を保ちながら、必要最小限の修正で自然に読みやすく整形してください。

			重要なルール:
			- 出力は整形後の本文のみ。必ず JSON 形式の単一オブジェクトで、キーは `text` のみを返してください。例: {"text": "整形後の本文"}
			- 話し口調（例: 「〜だよね」「〜的な感じ」）は残すこと。
			- 勝手に意訳・過度な言い換えをしないこと。原文に忠実であることを最優先とする。
			- フィラー表現（例: 「えーと」「あの」「その」など）は除去すること。
			- 余計な前置き、挨拶、理由説明、注釈を一切含めないこと。
			- 用語は以下を優先すること。
			- 執筆者名は \(displayName) です。

			用語集:
			\(glossarySection)

			音声文字起こしテキスト:
			\(text)
			"""
		case .instruction(let selectedText):
			return """
			あなたは優秀なエンジニア向け編集アシスタントです。
			以下の選択中テキストに対して、音声指示を反映してください。

			重要なルール:
			- 出力は変換後のテキストのみ。必ず JSON 形式の単一オブジェクトで、キーは `text` のみを返してください。例: {"text": "変換後の本文"}
			- 話し口調（例: 「〜だよね」「〜的な感じ」）は残すこと。
			- 勝手に意訳・過度な言い換えをしないこと。可能な限り原文に忠実に編集すること。
			- フィラー表現（例: 「えーと」「あの」「その」など）は除去すること。
			- 余計な前置き、挨拶、理由説明、注釈を一切含めないこと。
			- 元の選択内容を文脈として保持し、指示どおりに編集すること。
			- 用語は以下を優先すること。

			用語集:
			\(glossarySection)

			選択中テキスト:
			\(selectedText)

			音声指示:
			\(text)
			"""
		}
	}

	private func localRewrite(_ text: String, mode: ProcessingMode) -> String {
		let rewritten = vocabulary.preferredTerms.reduce(text) { partialResult, term in
			partialResult.replacingOccurrences(of: term.from, with: term.to)
		}

		switch mode {
		case .normal:
			return rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
		case .instruction(let selectedText):
			let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
			if instruction.isEmpty {
				return selectedText
			}
			return "\(selectedText)\n\(instruction)"
		}
	}

	private func captureSelectedText() -> String? {
		guard AXIsProcessTrusted() else { return nil }

		let systemWide = AXUIElementCreateSystemWide()
		var focusedApplicationValue: CFTypeRef?
		let focusedApplicationStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApplicationValue)
		guard focusedApplicationStatus == .success,
			  let focusedApplicationValue = focusedApplicationValue,
			  CFGetTypeID(focusedApplicationValue) == AXUIElementGetTypeID() else {
			return nil
		}

		let focusedApplication = focusedApplicationValue as! AXUIElement
		var focusedElementValue: CFTypeRef?
		let focusedElementStatus = AXUIElementCopyAttributeValue(focusedApplication, kAXFocusedUIElementAttribute as CFString, &focusedElementValue)
		guard focusedElementStatus == .success,
			  let focusedElementValue = focusedElementValue,
			  CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
			return nil
		}

		let focusedElement = focusedElementValue as! AXUIElement
		var selectedTextValue: CFTypeRef?
		let selectedTextStatus = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
		guard selectedTextStatus == .success,
			  let selectedText = selectedTextValue as? String,
			  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return nil
		}

		return selectedText
	}

	private func pasteToActiveWindow(text: String) {
		DispatchQueue.main.async {
			let pasteboard = NSPasteboard.general
			// 現在のクリップボード内容を保存（文字列のみ）。復元可能であれば復元する。
			let previousString = pasteboard.string(forType: .string)

			self.copyToClipboard(text)

			let script = "tell application \"System Events\" to keystroke \"v\" using command down"
			var error: NSDictionary?
			if let appleScript = NSAppleScript(source: script) {
				appleScript.executeAndReturnError(&error)
				if let error = error {
					print("AppleScriptエラー: \(error)")
				}
			}

			// 少し待ってからクリップボードを復元する（履歴アプリが過去の貼付を記録する場合は除去できません）
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				if let prev = previousString {
					pasteboard.clearContents()
					pasteboard.setString(prev, forType: .string)
				} else {
					pasteboard.clearContents()
				}
			}
		}
	}

	private func copyToClipboard(_ text: String) {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
	}

	private func notify(title: String, message: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", "display notification \"\(message)\" with title \"\(title)\""]
		try? process.run()
	}

	private func loadEnvironmentFile() {
		guard let data = try? String(contentsOf: environmentURL, encoding: .utf8) else { return }

		for rawLine in data.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !line.isEmpty, !line.hasPrefix("#") else { continue }

			let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard pieces.count == 2 else { continue }

			let key = String(pieces[0]).trimmingCharacters(in: .whitespaces)
			var value = String(pieces[1]).trimmingCharacters(in: .whitespaces)
			if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
				value.removeFirst()
				value.removeLast()
			}

			if ProcessInfo.processInfo.environment[key] == nil {
				setenv(key, value, 1)
			}
		}
	}
}

enum VocabularyStore {
	static func load(from url: URL) -> VocabularyFile {
		guard let data = try? Data(contentsOf: url) else {
			return VocabularyFile(userProfile: .init(name: "User", reading: nil), preferredTerms: [])
		}

		let decoder = JSONDecoder()
		if let vocabulary = try? decoder.decode(VocabularyFile.self, from: data) {
			return vocabulary
		}

		return VocabularyFile(userProfile: .init(name: "User", reading: nil), preferredTerms: [])
	}
}
