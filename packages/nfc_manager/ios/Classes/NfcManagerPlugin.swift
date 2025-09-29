import CoreNFC
import Flutter

public class NfcManagerPlugin: NSObject, FlutterPlugin, HostApiPigeon {
	private let flutterApi: FlutterApiPigeon
	private var shouldInvalidateSessionAfterFirstRead: Bool = true
	private var tagSession: NFCTagReaderSession? = nil
	private var vasSession: NFCVASReaderSession? = nil
	private var cachedTags: [String: NFCNDEFTag] = [:]

	public static func register(with registrar: FlutterPluginRegistrar) {
		print("[NfcManagerPlugin] Registering plugin.")
		HostApiPigeonSetup.setUp(
			binaryMessenger: registrar.messenger(),
			api: NfcManagerPlugin(binaryMessenger: registrar.messenger()))
	}

	private init(binaryMessenger: FlutterBinaryMessenger) {
		print("[NfcManagerPlugin] Initializing NfcManagerPlugin.")
		flutterApi = FlutterApiPigeon(binaryMessenger: binaryMessenger)
	}

	func tagSessionReadingAvailable() throws -> Bool {
		print("[NfcManagerPlugin] tagSessionReadingAvailable called.")
		return NFCTagReaderSession.readingAvailable
	}

	func tagSessionBegin(
		pollingOptions: [PollingOptionPigeon], alertMessage: String?, invalidateAfterFirstRead: Bool
	) throws {
		print(
			"[NfcManagerPlugin] tagSessionBegin called with pollingOptions: \(pollingOptions). and invalidateAfterFirstRead \(invalidateAfterFirstRead)"
		)
		if tagSession != nil || vasSession != nil {
			print("[NfcManagerPlugin] Error: Session already exists.")
			throw FlutterError(
				code: "session_already_exists",
				message: "Multiple sessions cannot be active at the same time.", details: nil)
		}

		tagSession = NFCTagReaderSession(pollingOption: convert(pollingOptions), delegate: self)
		if let alertMessage = alertMessage { tagSession?.alertMessage = alertMessage }
		shouldInvalidateSessionAfterFirstRead = invalidateAfterFirstRead
		print("[NfcManagerPlugin] Starting new NFC session.")
		tagSession?.begin()
	}

	func tagSessionInvalidate(alertMessage: String?, errorMessage: String?) throws {
    // CoreNFC work should be on the main thread
    if !Thread.isMainThread {
        DispatchQueue.main.async { [weak self] in
            try? self?.tagSessionInvalidate(alertMessage: alertMessage, errorMessage: errorMessage)
        }
        return
    }

    print("[NfcManagerPlugin] tagSessionInvalidate called.")

    // If there is no active session, just no-op (don't throw -> no Flutter error)
    guard let tagSession = self.tagSession else {
        print("[NfcManagerPlugin] No active sessions to invalidate. (no-op)")
        return
    }

    // Ensure local cleanup even if anything below changes
    defer {
        self.tagSession = nil
        self.cachedTags.removeAll()
        print("[NfcManagerPlugin] Session invalidated (local cleanup).")
    }

    if let alertMessage = alertMessage {
        tagSession.alertMessage = alertMessage
    }

    if let errorMessage = errorMessage, !errorMessage.isEmpty {
        print("[NfcManagerPlugin] Invalidating session with error message: \(errorMessage).")
        tagSession.invalidate(errorMessage: errorMessage)
    } else {
        print("[NfcManagerPlugin] Invalidating session.")
        tagSession.invalidate()
    }
}


	func tagSessionRestartPolling() throws {
		print("[NfcManagerPlugin] tagSessionRestartPolling called.")
		guard let tagSession = tagSession else {
			print("[NfcManagerPlugin] Error: No active sessions to restart polling.")
			throw FlutterError(
				code: "no_active_sessions", message: "Session is not active.", details: nil)
		}
		print("[NfcManagerPlugin] Restarting polling.")
		tagSession.restartPolling()
	}

	func tagSessionSetAlertMessage(alertMessage: String) throws {
		print("[NfcManagerPlugin] tagSessionSetAlertMessage called.")
		guard let tagSession = tagSession else {
			print("[NfcManagerPlugin] Error: No active sessions to set alert message.")
			throw FlutterError(
				code: "no_active_sessions", message: "Session is not active.", details: nil)
		}
		print("[NfcManagerPlugin] Setting alert message: \(alertMessage).")
		tagSession.alertMessage = alertMessage
	}

	func vasSessionReadingAvailable() throws -> Bool {
		print("[NfcManagerPlugin] vasSessionReadingAvailable called.")
		return NFCVASReaderSession.readingAvailable
	}

	func vasSessionBegin(configurations: [NfcVasCommandConfigurationPigeon], alertMessage: String?)
		throws
	{
		print("[NfcManagerPlugin] vasSessionBegin called.")
		if vasSession != nil || tagSession != nil {
			print("[NfcManagerPlugin] Error: Session already exists.")
			throw FlutterError(
				code: "session_already_exists",
				message: "Multiple sessions cannot be active at the same time.", details: nil)
		}
		vasSession = NFCVASReaderSession(
			vasCommandConfigurations: configurations.map { convert($0) }, delegate: self, queue: nil
		)
		if let alertMessage = alertMessage { vasSession?.alertMessage = alertMessage }
		print("[NfcManagerPlugin] Starting new VAS session.")
		vasSession?.begin()
	}

	func vasSessionInvalidate(alertMessage: String?, errorMessage: String?) throws {
		print("[NfcManagerPlugin] vasSessionInvalidate called.")
		guard let vasSession = vasSession else {
			print("[NfcManagerPlugin] Error: No active VAS sessions to invalidate.")
			throw FlutterError(
				code: "no_active_sessions", message: "Session is not active.", details: nil)
		}
		if let alertMessage = alertMessage { vasSession.alertMessage = alertMessage }
		if let errorMessage = errorMessage {
			print(
				"[NfcManagerPlugin] Invalidating VAS session with error message: \(errorMessage).")
			vasSession.invalidate(errorMessage: errorMessage)
		} else {
			print("[NfcManagerPlugin] Invalidating VAS session.")
			vasSession.invalidate()
		}
		self.vasSession = nil
		print("[NfcManagerPlugin] VAS session invalidated.")
	}

	func vasSessionSetAlertMessage(alertMessage: String) throws {
		print("[NfcManagerPlugin] vasSessionSetAlertMessage called.")
		guard let vasSession = vasSession else {
			print("[NfcManagerPlugin] Error: No active VAS sessions to set alert message.")
			throw FlutterError(
				code: "no_active_sessions", message: "Session is not active.", details: nil)
		}
		print("[NfcManagerPlugin] Setting VAS alert message: \(alertMessage).")
		vasSession.alertMessage = alertMessage
	}

	func ndefQueryNdefStatus(
		handle: String, completion: @escaping (Result<NdefQueryStatusPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] ndefQueryNdefStatus called for handle: \(handle).")
		guard let tag = cachedTags[handle] else {
			print("[NfcManagerPlugin] ndefQueryNdefStatus: Tag not found.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.queryNDEFStatus { status, capacity, error in
			print("[NfcManagerPlugin] ndefQueryNdefStatus completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] ndefQueryNdefStatus error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print(
				"[NfcManagerPlugin] ndefQueryNdefStatus success. Status: \(status), Capacity: \(capacity)."
			)
			completion(
				.success(
					NdefQueryStatusPigeon(
						status: convert(status),
						capacity: Int64(capacity)
					)
				))
		}
	}

	func ndefReadNdef(
		handle: String, completion: @escaping (Result<NdefMessagePigeon?, Error>) -> Void
	) {
		print("[NfcManagerPlugin] ndefReadNdef called for handle: \(handle).")
		guard let tag = cachedTags[handle] else {
			print("[NfcManagerPlugin] ndefReadNdef: Tag not found.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.readNDEF { message, error in
			if let nfcError = error as? NFCReaderError,
				nfcError.code == .ndefReaderSessionErrorZeroLengthMessage
			{
				print(
					"[NfcManagerPlugin] ndefReadNdef: Detected NFCReaderError.Code.ndefReaderSessionErrorZeroLengthMessage. Passing back as success with no message."
				)
				completion(.success(nil))
				return
			}
			if let error = error {
				print(
					"[NfcManagerPlugin] ndefReadNdef: Found error: \(error.localizedDescription).")
				// NEW: close or repoll so the UI doesn't get "stuck"
				if self.shouldInvalidateSessionAfterFirstRead {
					print("[NfcManagerPlugin] ndefReadNdef: Invalidating session after read.")
					self.tagSession?.invalidate(errorMessage: error.localizedDescription)
					self.tagSession = nil
					self.cachedTags.removeAll()
				} else {
					print("[NfcManagerPlugin] ndefReadNdef: Restarting polling after read.")
					self.tagSession?.alertMessage = error.localizedDescription
					self.tagSession?.restartPolling()
				}
				completion(.failure(error))
				return
			}

			guard let message = message else {
				print("[NfcManagerPlugin] ndefReadNdef: No message returned.")
				// No message returned (shouldn’t normally happen without error) – treat as empty
				completion(.success(nil))
				return
			}
			print("[NfcManagerPlugin] ndefReadNdef: Read NDEF message successfully.")
			completion(.success(convert(message)))
		}
	}

	func ndefWriteNdef(
		handle: String, message: NdefMessagePigeon,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] ndefWriteNdef called for handle: \(handle).")
		guard let tag = cachedTags[handle] else {
			print("[NfcManagerPlugin] ndefWriteNdef: Tag not found.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.writeNDEF(convert(message)) { error in
			print("[NfcManagerPlugin] ndefWriteNdef completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] ndefWriteNdef error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] ndefWriteNdef success.")
			completion(.success(()))
		}
	}

	func ndefWriteLock(handle: String, completion: @escaping (Result<Void, Error>) -> Void) {
		print("[NfcManagerPlugin] ndefWriteLock called for handle: \(handle).")
		guard let tag = cachedTags[handle] else {
			print("[NfcManagerPlugin] ndefWriteLock: Tag not found.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.writeLock { error in
			print("[NfcManagerPlugin] ndefWriteLock completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] ndefWriteLock error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] ndefWriteLock success.")
			completion(.success(()))
		}
	}

	func feliCaPolling(
		handle: String, systemCode: FlutterStandardTypedData,
		requestCode: FeliCaPollingRequestCodePigeon, timeSlot: FeliCaPollingTimeSlotPigeon,
		completion: @escaping (Result<FeliCaPollingResponsePigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaPolling called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print("[NfcManagerPlugin] feliCaPolling: Tag not found or is not a FeliCa tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.polling(
			systemCode: systemCode.data, requestCode: convert(requestCode),
			timeSlot: convert(timeSlot)
		) { manufacturerParameter, requestData, error in
			print("[NfcManagerPlugin] feliCaPolling completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] feliCaPolling error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaPolling success.")
			completion(
				.success(
					FeliCaPollingResponsePigeon(
						manufacturerParameter: FlutterStandardTypedData(
							bytes: manufacturerParameter),
						requestData: FlutterStandardTypedData(bytes: requestData)
					)))
		}
	}

	func feliCaRequestService(
		handle: String, nodeCodeList: [FlutterStandardTypedData],
		completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaRequestService called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print("[NfcManagerPlugin] feliCaRequestService: Tag not found or is not a FeliCa tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.requestService(nodeCodeList: nodeCodeList.map { $0.data }) { nodeCodeList, error in
			print("[NfcManagerPlugin] feliCaRequestService completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaRequestService error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaRequestService success.")
			completion(.success(nodeCodeList.map { FlutterStandardTypedData(bytes: $0) }))
		}
	}

	func feliCaRequestResponse(handle: String, completion: @escaping (Result<Int64, Error>) -> Void)
	{
		print("[NfcManagerPlugin] feliCaRequestResponse called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print("[NfcManagerPlugin] feliCaRequestResponse: Tag not found or is not a FeliCa tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.requestResponse { mode, error in
			print("[NfcManagerPlugin] feliCaRequestResponse completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaRequestResponse error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaRequestResponse success.")
			completion(.success(Int64(mode)))
		}
	}

	func feliCaReadWithoutEncryption(
		handle: String, serviceCodeList: [FlutterStandardTypedData],
		blockList: [FlutterStandardTypedData],
		completion: @escaping (Result<FeliCaReadWithoutEncryptionResponsePigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaReadWithoutEncryption called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print(
				"[NfcManagerPlugin] feliCaReadWithoutEncryption: Tag not found or is not a FeliCa tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.readWithoutEncryption(
			serviceCodeList: serviceCodeList.map { $0.data }, blockList: blockList.map { $0.data }
		) { statusFlag1, statusFlag2, blockData, error in
			print("[NfcManagerPlugin] feliCaReadWithoutEncryption completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaReadWithoutEncryption error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaReadWithoutEncryption success.")
			completion(
				.success(
					FeliCaReadWithoutEncryptionResponsePigeon(
						statusFlag1: Int64(statusFlag1),
						statusFlag2: Int64(statusFlag2),
						blockData: blockData.map { FlutterStandardTypedData(bytes: $0) }
					)))
		}
	}

	func feliCaWriteWithoutEncryption(
		handle: String, serviceCodeList: [FlutterStandardTypedData],
		blockList: [FlutterStandardTypedData], blockData: [FlutterStandardTypedData],
		completion: @escaping (Result<FeliCaStatusFlagPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaWriteWithoutEncryption called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print(
				"[NfcManagerPlugin] feliCaWriteWithoutEncryption: Tag not found or is not a FeliCa tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.writeWithoutEncryption(
			serviceCodeList: serviceCodeList.map { $0.data }, blockList: blockList.map { $0.data },
			blockData: blockData.map { $0.data }
		) { statusFlag1, statusFlag2, error in
			print("[NfcManagerPlugin] feliCaWriteWithoutEncryption completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaWriteWithoutEncryption error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaWriteWithoutEncryption success.")
			completion(
				.success(
					FeliCaStatusFlagPigeon(
						statusFlag1: Int64(statusFlag1),
						statusFlag2: Int64(statusFlag2)
					)))
		}
	}

	func feliCaRequestSystemCode(
		handle: String, completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaRequestSystemCode called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print(
				"[NfcManagerPlugin] feliCaRequestSystemCode: Tag not found or is not a FeliCa tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.requestSystemCode { systemCodeList, error in
			print("[NfcManagerPlugin] feliCaRequestSystemCode completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaRequestSystemCode error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaRequestSystemCode success.")
			completion(.success(systemCodeList.map { FlutterStandardTypedData(bytes: $0) }))
		}
	}

	func feliCaRequestServiceV2(
		handle: String, nodeCodeList: [FlutterStandardTypedData],
		completion: @escaping (Result<FeliCaRequestServiceV2ResponsePigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaRequestServiceV2 called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print(
				"[NfcManagerPlugin] feliCaRequestServiceV2: Tag not found or is not a FeliCa tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.requestServiceV2(nodeCodeList: nodeCodeList.map { $0.data }) {
			statusFlag1, statusFlag2, encryptionIdentifier, nodeKeyVersionListAes,
			nodeKeyVersionListDes, error in
			print("[NfcManagerPlugin] feliCaRequestServiceV2 completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaRequestServiceV2 error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaRequestServiceV2 success.")
			completion(
				.success(
					FeliCaRequestServiceV2ResponsePigeon(
						statusFlag1: Int64(statusFlag1),
						statusFlag2: Int64(statusFlag2),
						encryptionIdentifier: Int64(encryptionIdentifier.rawValue),
						nodeKeyVersionListAES: nodeKeyVersionListAes.map {
							FlutterStandardTypedData(bytes: $0)
						},
						nodeKeyVersionListDES: nodeKeyVersionListDes.map {
							FlutterStandardTypedData(bytes: $0)
						}
					)))
		}
	}

	func feliCaRequestSpecificationVersion(
		handle: String,
		completion: @escaping (Result<FeliCaRequestSpecificationVersionResponsePigeon, Error>) ->
			Void
	) {
		print("[NfcManagerPlugin] feliCaRequestSpecificationVersion called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print(
				"[NfcManagerPlugin] feliCaRequestSpecificationVersion: Tag not found or is not a FeliCa tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.requestSpecificationVersion {
			statusFlag1, statusFlag2, basicVersion, optionVersion, error in
			print("[NfcManagerPlugin] feliCaRequestSpecificationVersion completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaRequestSpecificationVersion error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaRequestSpecificationVersion success.")
			completion(
				.success(
					FeliCaRequestSpecificationVersionResponsePigeon(
						statusFlag1: Int64(statusFlag1),
						statusFlag2: Int64(statusFlag2),
						basicVersion: FlutterStandardTypedData(bytes: basicVersion),
						optionVersion: FlutterStandardTypedData(bytes: optionVersion)
					)))
		}
	}

	func feliCaResetMode(
		handle: String, completion: @escaping (Result<FeliCaStatusFlagPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaResetMode called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print("[NfcManagerPlugin] feliCaResetMode: Tag not found or is not a FeliCa tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.resetMode { statusFlag1, statusFlag2, error in
			print("[NfcManagerPlugin] feliCaResetMode completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] feliCaResetMode error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaResetMode success.")
			completion(
				.success(
					FeliCaStatusFlagPigeon(
						statusFlag1: Int64(statusFlag1),
						statusFlag2: Int64(statusFlag2)
					)))
		}
	}

	func feliCaSendFeliCaCommand(
		handle: String, commandPacket: FlutterStandardTypedData,
		completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
	) {
		print("[NfcManagerPlugin] feliCaSendFeliCaCommand called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCFeliCaTag else {
			print(
				"[NfcManagerPlugin] feliCaSendFeliCaCommand: Tag not found or is not a FeliCa tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.sendFeliCaCommand(commandPacket: commandPacket.data) { data, error in
			print("[NfcManagerPlugin] feliCaSendFeliCaCommand completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] feliCaSendFeliCaCommand error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] feliCaSendFeliCaCommand success.")
			completion(.success(FlutterStandardTypedData(bytes: data)))
		}
	}

	func miFareSendMiFareCommand(
		handle: String, commandPacket: FlutterStandardTypedData,
		completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
	) {
		print("[NfcManagerPlugin] miFareSendMiFareCommand called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCMiFareTag else {
			print(
				"[NfcManagerPlugin] miFareSendMiFareCommand: Tag not found or is not a MiFare tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.sendMiFareCommand(commandPacket: commandPacket.data) { data, error in
			print("[NfcManagerPlugin] miFareSendMiFareCommand completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] miFareSendMiFareCommand error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] miFareSendMiFareCommand success.")
			completion(.success(FlutterStandardTypedData(bytes: data)))
		}
	}

	func miFareSendMiFareISO7816Command(
		handle: String, apdu: Iso7816ApduPigeon,
		completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] miFareSendMiFareISO7816Command called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCMiFareTag else {
			print(
				"[NfcManagerPlugin] miFareSendMiFareISO7816Command: Tag not found or is not a MiFare tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.sendMiFareISO7816Command(convert(apdu)) { payload, statusWord1, statusWord2, error in
			print("[NfcManagerPlugin] miFareSendMiFareISO7816Command completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] miFareSendMiFareISO7816Command error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] miFareSendMiFareISO7816Command success.")
			completion(
				.success(
					Iso7816ResponseApduPigeon(
						payload: FlutterStandardTypedData(bytes: payload),
						statusWord1: Int64(statusWord1),
						statusWord2: Int64(statusWord2)
					)))
		}
	}

	func miFareSendMiFareISO7816CommandRaw(
		handle: String, data: FlutterStandardTypedData,
		completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] miFareSendMiFareISO7816CommandRaw called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCMiFareTag else {
			print(
				"[NfcManagerPlugin] miFareSendMiFareISO7816CommandRaw: Tag not found or is not a MiFare tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.sendMiFareISO7816Command(NFCISO7816APDU(data: data.data)!) {
			payload, statusWord1, statusWord2, error in
			print("[NfcManagerPlugin] miFareSendMiFareISO7816CommandRaw completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] miFareSendMiFareISO7816CommandRaw error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] miFareSendMiFareISO7816CommandRaw success.")
			completion(
				.success(
					Iso7816ResponseApduPigeon(
						payload: FlutterStandardTypedData(bytes: payload),
						statusWord1: Int64(statusWord1),
						statusWord2: Int64(statusWord2)
					)))
		}
	}

	func iso7816SendCommand(
		handle: String, apdu: Iso7816ApduPigeon,
		completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso7816SendCommand called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO7816Tag else {
			print("[NfcManagerPlugin] iso7816SendCommand: Tag not found or is not an ISO7816 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.sendCommand(apdu: convert(apdu)) { payload, statusWord1, statusWord2, error in
			print("[NfcManagerPlugin] iso7816SendCommand completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso7816SendCommand error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso7816SendCommand success.")
			completion(
				.success(
					Iso7816ResponseApduPigeon(
						payload: FlutterStandardTypedData(bytes: payload),
						statusWord1: Int64(statusWord1),
						statusWord2: Int64(statusWord2)
					)))
		}
	}

	func iso7816SendCommandRaw(
		handle: String, data: FlutterStandardTypedData,
		completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso7816SendCommandRaw called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO7816Tag else {
			print(
				"[NfcManagerPlugin] iso7816SendCommandRaw: Tag not found or is not an ISO7816 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.sendCommand(apdu: NFCISO7816APDU(data: data.data)!) {
			payload, statusWord1, statusWord2, error in
			print("[NfcManagerPlugin] iso7816SendCommandRaw completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso7816SendCommandRaw error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso7816SendCommandRaw success.")
			completion(
				.success(
					Iso7816ResponseApduPigeon(
						payload: FlutterStandardTypedData(bytes: payload),
						statusWord1: Int64(statusWord1),
						statusWord2: Int64(statusWord2)
					)))
		}
	}

	func iso15693StayQuiet(handle: String, completion: @escaping (Result<Void, Error>) -> Void) {
		print("[NfcManagerPlugin] iso15693StayQuiet called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print("[NfcManagerPlugin] iso15693StayQuiet: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.stayQuiet { error in
			print("[NfcManagerPlugin] iso15693StayQuiet completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso15693StayQuiet error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693StayQuiet success.")
			completion(.success(()))
		}
	}

	func iso15693ReadSingleBlock(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], blockNumber: Int64,
		completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693ReadSingleBlock called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693ReadSingleBlock: Tag not found or is not an ISO15693 tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.readSingleBlock(requestFlags: convert(requestFlags), blockNumber: UInt8(blockNumber)) {
			dataBlock, error in
			print("[NfcManagerPlugin] iso15693ReadSingleBlock completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693ReadSingleBlock error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693ReadSingleBlock success.")
			completion(.success(FlutterStandardTypedData(bytes: dataBlock)))
		}
	}

	func iso15693WriteSingleBlock(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], blockNumber: Int64,
		dataBlock: FlutterStandardTypedData, completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693WriteSingleBlock called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693WriteSingleBlock: Tag not found or is not an ISO15693 tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.writeSingleBlock(
			requestFlags: convert(requestFlags), blockNumber: UInt8(blockNumber),
			dataBlock: dataBlock.data
		) { error in
			print("[NfcManagerPlugin] iso15693WriteSingleBlock completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693WriteSingleBlock error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693WriteSingleBlock success.")
			completion(.success(()))
		}
	}

	func iso15693LockBlock(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], blockNumber: Int64,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693LockBlock called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print("[NfcManagerPlugin] iso15693LockBlock: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.lockBlock(requestFlags: convert(requestFlags), blockNumber: UInt8(blockNumber)) {
			error in
			print("[NfcManagerPlugin] iso15693LockBlock completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso15693LockBlock error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693LockBlock success.")
			completion(.success(()))
		}
	}

	func iso15693ReadMultipleBlocks(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], blockNumber: Int64,
		numberOfBlocks: Int64,
		completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693ReadMultipleBlocks called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693ReadMultipleBlocks: Tag not found or is not an ISO15693 tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.readMultipleBlocks(
			requestFlags: convert(requestFlags), blockRange: convert(blockNumber, numberOfBlocks)
		) { dataBlocks, error in
			print("[NfcManagerPlugin] iso15693ReadMultipleBlocks completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693ReadMultipleBlocks error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693ReadMultipleBlocks success.")
			completion(.success(dataBlocks.map { FlutterStandardTypedData(bytes: $0) }))
		}
	}

	func iso15693WriteMultipleBlocks(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], blockNumber: Int64,
		numberOfBlocks: Int64, dataBlocks: [FlutterStandardTypedData],
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693WriteMultipleBlocks called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693WriteMultipleBlocks: Tag not found or is not an ISO15693 tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.writeMultipleBlocks(
			requestFlags: convert(requestFlags), blockRange: convert(blockNumber, numberOfBlocks),
			dataBlocks: dataBlocks.map { $0.data }
		) { error in
			print("[NfcManagerPlugin] iso15693WriteMultipleBlocks completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693WriteMultipleBlocks error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693WriteMultipleBlocks success.")
			completion(.success(()))
		}
	}

	func iso15693Select(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon],
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693Select called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print("[NfcManagerPlugin] iso15693Select: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.select(requestFlags: convert(requestFlags)) { error in
			print("[NfcManagerPlugin] iso15693Select completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso15693Select error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693Select success.")
			completion(.success(()))
		}
	}

	func iso15693ResetToReady(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon],
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693ResetToReady called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693ResetToReady: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.resetToReady(requestFlags: convert(requestFlags)) { error in
			print("[NfcManagerPlugin] iso15693ResetToReady completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693ResetToReady error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693ResetToReady success.")
			completion(.success(()))
		}
	}

	func iso15693WriteAfi(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], afi: Int64,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693WriteAfi called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print("[NfcManagerPlugin] iso15693WriteAfi: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.writeAFI(requestFlags: convert(requestFlags), afi: UInt8(afi)) { error in
			print("[NfcManagerPlugin] iso15693WriteAfi completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso15693WriteAfi error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693WriteAfi success.")
			completion(.success(()))
		}
	}

	func iso15693LockAfi(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon],
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693LockAfi called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print("[NfcManagerPlugin] iso15693LockAfi: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.lockAFI(requestFlags: convert(requestFlags)) { error in
			print("[NfcManagerPlugin] iso15693LockAfi completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso15693LockAfi error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693LockAfi success.")
			completion(.success(()))
		}
	}

	func iso15693WriteDsfId(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], dsfId: Int64,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693WriteDsfId called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print("[NfcManagerPlugin] iso15693WriteDsfId: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.writeDSFID(requestFlags: convert(requestFlags), dsfid: UInt8(dsfId)) { error in
			print("[NfcManagerPlugin] iso15693WriteDsfId completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso15693WriteDsfId error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693WriteDsfId success.")
			completion(.success(()))
		}
	}

	func iso15693LockDsfId(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon],
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693LockDsfId called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print("[NfcManagerPlugin] iso15693LockDsfId: Tag not found or is not an ISO15693 tag.")
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.lockDFSID(requestFlags: convert(requestFlags)) { error in
			print("[NfcManagerPlugin] iso15693LockDsfId completion handler called.")
			if let error = error {
				print("[NfcManagerPlugin] iso15693LockDsfId error: \(error.localizedDescription).")
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693LockDsfId success.")
			completion(.success(()))
		}
	}

	func iso15693GetSystemInfo(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon],
		completion: @escaping (Result<Iso15693SystemInfoPigeon, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693GetSystemInfo called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693GetSystemInfo: Tag not found or is not an ISO15693 tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.getSystemInfo(requestFlags: convert(requestFlags)) {
			dataStorageFormatIdentifier, applicationFamilyIdentifier, blockSize, totalBlocks,
			icReference, error in
			print("[NfcManagerPlugin] iso15693GetSystemInfo completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693GetSystemInfo error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693GetSystemInfo success.")
			completion(
				.success(
					Iso15693SystemInfoPigeon(
						dataStorageFormatIdentifier: Int64(dataStorageFormatIdentifier),
						applicationFamilyIdentifier: Int64(applicationFamilyIdentifier),
						blockSize: Int64(blockSize),
						totalBlocks: Int64(totalBlocks),
						icReference: Int64(icReference)
					)))
		}
	}

	func iso15693GetMultipleBlockSecurityStatus(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], blockNumber: Int64,
		numberOfBlocks: Int64, completion: @escaping (Result<[Int64], Error>) -> Void
	) {
		print(
			"[NfcManagerPlugin] iso15693GetMultipleBlockSecurityStatus called for handle: \(handle)."
		)
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693GetMultipleBlockSecurityStatus: Tag not found or is not an ISO15693 tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.getMultipleBlockSecurityStatus(
			requestFlags: convert(requestFlags), blockRange: convert(blockNumber, numberOfBlocks)
		) { status, error in
			print(
				"[NfcManagerPlugin] iso15693GetMultipleBlockSecurityStatus completion handler called."
			)
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693GetMultipleBlockSecurityStatus error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693GetMultipleBlockSecurityStatus success.")
			completion(.success(status.map { Int64(truncating: $0) }))
		}
	}

	func iso15693CustomCommand(
		handle: String, requestFlags: [Iso15693RequestFlagPigeon], customCommandCode: Int64,
		customRequestParameters: FlutterStandardTypedData,
		completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
	) {
		print("[NfcManagerPlugin] iso15693CustomCommand called for handle: \(handle).")
		guard let tag = cachedTags[handle] as? NFCISO15693Tag else {
			print(
				"[NfcManagerPlugin] iso15693CustomCommand: Tag not found or is not an ISO15693 tag."
			)
			completion(
				.failure(
					FlutterError(
						code: "tag_not_found", message: "You may have disable the session.",
						details: nil)))
			return
		}
		tag.customCommand(
			requestFlags: convert(requestFlags), customCommandCode: Int(customCommandCode),
			customRequestParameters: customRequestParameters.data
		) { data, error in
			print("[NfcManagerPlugin] iso15693CustomCommand completion handler called.")
			if let error = error {
				print(
					"[NfcManagerPlugin] iso15693CustomCommand error: \(error.localizedDescription)."
				)
				completion(.failure(error))
				return
			}
			print("[NfcManagerPlugin] iso15693CustomCommand success.")
			completion(.success(FlutterStandardTypedData(bytes: data)))
		}
	}
}

extension NfcManagerPlugin: NFCTagReaderSessionDelegate {
	public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
		print("[NfcManagerPlugin] tagReaderSessionDidBecomeActive: Session is active.")
		flutterApi.tagSessionDidBecomeActive { _ in /* no op */ }
	}

	public func tagReaderSession(
		_ session: NFCTagReaderSession, didInvalidateWithError error: Error
	) {
		print("[NfcManagerPlugin] didInvalidateWithError: \(error.localizedDescription)")

		guard let nfcError = error as? NFCReaderError else {
			flutterApi.tagSessionDidInvalidateWithError(
				error: NfcReaderSessionErrorPigeon(
					code: .readerErrorUnsupportedFeature,
					message: error.localizedDescription)
			) { _ in }
			return
		}

		// Map special cases
		switch nfcError.code {
		case .readerTransceiveErrorTagConnectionLost:
			flutterApi.tagSessionDidInvalidateWithError(
				error: NfcReaderSessionErrorPigeon(
					code: .readerTransceiveErrorTagConnectionLost,
					message: "Tag connection lost"
				)
			) { _ in }

		case .ndefReaderSessionErrorTagNotWritable:
			flutterApi.tagSessionDidInvalidateWithError(
				error: NfcReaderSessionErrorPigeon(
					code: .ndefReaderSessionErrorTagNotWritable,
					message: "Tag not NDEF formatted / writable"
				)
			) { _ in }

		default:
			let pigeonError = NfcReaderSessionErrorPigeon(
				code: convert(nfcError.code),
				message: nfcError.localizedDescription
			)
			flutterApi.tagSessionDidInvalidateWithError(error: pigeonError) { _ in }
		}

		self.tagSession = nil
		self.cachedTags.removeAll()
	}

	private func shouldRepoll(for error: Error) -> Bool {
		guard let e = error as? NFCReaderError else { return false }
		switch e.code {
		case .readerTransceiveErrorTagConnectionLost,
			.readerTransceiveErrorTagNotConnected,
			.readerTransceiveErrorRetryExceeded,
			.readerTransceiveErrorTagResponseError:
			return true  // transient RF/connection issues → repoll
		default:
			return false  // everything else: use your normal logic
		}
	}

	public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
		print("[NfcManagerPlugin] tagReaderSessionDidDetect: Tag detected.")
		guard let first = tags.first else {
			print(
				"[NfcManagerPlugin] tagReaderSessionDidDetect: No tag in detected tags array. Invalidating session."
			)
			if self.shouldInvalidateSessionAfterFirstRead {
				session.invalidate(errorMessage: "No tag detected.")
			} else {
				session.restartPolling()
			}
			return
		}

		print("[NfcManagerPlugin] tagReaderSessionDidDetect: Connecting to tag.")
		session.connect(to: tags.first!) { error in
			if let error = error {
				print(
					"[NfcManagerPlugin] tagReaderSessionDidDetect: Error connecting to tag: \(error.localizedDescription)."
				)
				if self.shouldInvalidateSessionAfterFirstRead {
					print(
						"[NfcManagerPlugin] tagReaderSessionDidDetect: Invalidating session due to connection error."
					)
					session.invalidate(errorMessage: error.localizedDescription)
				} else {
					print(
						"[NfcManagerPlugin] tagReaderSessionDidDetect: Restarting polling due to connection error."
					)
					session.restartPolling()
				}
				return
			}
			print("[NfcManagerPlugin] tagReaderSessionDidDetect: Converting tag for NDEF status.")
			convert(first) { tag, pigeon, error in
				if let error = error {
					print(
						"[NfcManagerPlugin] V2 tagReaderSessionDidDetect: Error during tag conversion: \(self.shouldInvalidateSessionAfterFirstRead)"
					)
					//Override restartPolling
					if self.shouldRepoll(for: error) {
						print("[NfcManagerPlugin] safe repolling")
						session.restartPolling()
					} else {
						if self.shouldInvalidateSessionAfterFirstRead {
							session.invalidate(errorMessage: error.localizedDescription)
						} else {

							session.restartPolling()
						}
					}

					return
				}

				guard let pigeon = pigeon else {
					print(
						"[NfcManagerPlugin] tagReaderSessionDidDetect: Converted pigeon is nil. Invalidating."
					)
					if self.shouldInvalidateSessionAfterFirstRead {
						session.invalidate(errorMessage: "Unsupported or unreadable tag.")
					} else {
						session.restartPolling()
					}
					return
				}

				self.cachedTags[pigeon.handle] = tag
				print(
					"[NfcManagerPlugin] tagReaderSessionDidDetect: Tag converted successfully. Notifying Flutter."
				)
				self.flutterApi.tagSessionDidDetect(tag: pigeon) { _ in /* no op */ }
				if !self.shouldInvalidateSessionAfterFirstRead {
					print(
						"[NfcManagerPlugin] tagReaderSessionDidDetect: multi-read mode. Restarting polling."
					)
					session.restartPolling()
				}
			}
		}
	}
}

extension NfcManagerPlugin: NFCVASReaderSessionDelegate {
	public func readerSessionDidBecomeActive(_ session: NFCVASReaderSession) {
		print("[NfcManagerPlugin] readerSessionDidBecomeActive: VAS Session is active.")
		flutterApi.vasSessionDidBecomeActive { _ in /* no op */ }
	}

	public func readerSession(_ session: NFCVASReaderSession, didInvalidateWithError error: Error) {
		print(
			"[NfcManagerPlugin] readerSessionDidInvalidateWithError: VAS Session invalidated with error: \(error.localizedDescription)."
		)
		guard let nfcError = error as? NFCReaderError else {
			print(
				"[NfcManagerPlugin] readerSessionDidInvalidateWithError: Received non-NFCReaderError."
			)
			let pigeonError = NfcReaderSessionErrorPigeon(
				code: .readerErrorUnsupportedFeature,
				message: error.localizedDescription
			)
			flutterApi.vasSessionDidInvalidateWithError(error: pigeonError) { _ in /* no op */ }
			return
		}

		let pigeonError = NfcReaderSessionErrorPigeon(
			code: convert(nfcError.code),
			message: nfcError.localizedDescription
		)
		flutterApi.vasSessionDidInvalidateWithError(error: pigeonError) { _ in /* no op */ }
	}

	public func readerSession(
		_ session: NFCVASReaderSession, didReceive responses: [NFCVASResponse]
	) {
		print("[NfcManagerPlugin] readerSessionDidReceive: VAS responses received.")
		flutterApi.vasSessionDidReceive(responses: responses.map { convert($0) }) {
			_ in /* no op */
		}
	}
}

private func convert(
	_ value: NFCTag, _ completionHandler: @escaping (NFCNDEFTag, TagPigeon?, Error?) -> Void
) {
	print("[NfcManagerPlugin] convert(NFCTag) called.")
	switch value {
	case .feliCa(let tag):
		print("[NfcManagerPlugin] convert: converting FeliCa tag.")
		convert(tag) { pigeon, error in completionHandler(tag, pigeon, error) }
	case .iso15693(let tag):
		print("[NfcManagerPlugin] convert: converting ISO15693 tag.")
		convert(tag) { pigeon, error in completionHandler(tag, pigeon, error) }
	case .iso7816(let tag):
		print("[NfcManagerPlugin] convert: converting ISO7816 tag.")
		convert(tag) { pigeon, error in completionHandler(tag, pigeon, error) }
	case .miFare(let tag):
		print("[NfcManagerPlugin] convert: converting MiFare tag.")
		convert(tag) { pigeon, error in completionHandler(tag, pigeon, error) }
	@unknown default:
		print("[NfcManagerPlugin] convert: Unknown tag cannot be serialized.")
	}
}

private func convert(
	_ value: NFCNDEFTag, _ completionHandler: @escaping (TagPigeon?, Error?) -> Void
) {
	print("[NfcManagerPlugin] convert(NFCNDEFTag) called.")
	var pigeon = TagPigeon(handle: NSUUID().uuidString)

	if let value = value as? NFCFeliCaTag {
		print("[NfcManagerPlugin] convert: NFCFeliCaTag detected.")
		pigeon.feliCa = FeliCaPigeon(
			currentSystemCode: FlutterStandardTypedData(bytes: value.currentSystemCode),
			currentIDm: FlutterStandardTypedData(bytes: value.currentIDm)
		)
	} else if let value = value as? NFCISO15693Tag {
		print("[NfcManagerPlugin] convert: NFCISO15693Tag detected.")
		pigeon.iso15693 = Iso15693Pigeon(
			icManufacturerCode: Int64(value.icManufacturerCode),
			icSerialNumber: FlutterStandardTypedData(bytes: value.icSerialNumber),
			identifier: FlutterStandardTypedData(bytes: value.identifier)
		)
	} else if let value = value as? NFCISO7816Tag {
		print("[NfcManagerPlugin] convert: NFCISO7816Tag detected.")
		pigeon.iso7816 = Iso7816Pigeon(
			initialSelectedAID: value.initialSelectedAID,
			identifier: FlutterStandardTypedData(bytes: value.identifier),
			historicalBytes: value.historicalBytes != nil
				? FlutterStandardTypedData(bytes: value.historicalBytes!) : nil,
			applicationData: value.applicationData != nil
				? FlutterStandardTypedData(bytes: value.applicationData!) : nil,
			proprietaryApplicationDataCoding: value.proprietaryApplicationDataCoding
		)
	} else if let value = value as? NFCMiFareTag {
		print("[NfcManagerPlugin] convert: NFCMiFareTag detected.")
		pigeon.miFare = MiFarePigeon(
			mifareFamily: convert(value.mifareFamily),
			identifier: FlutterStandardTypedData(bytes: value.identifier),
			historicalBytes: value.historicalBytes != nil
				? FlutterStandardTypedData(bytes: value.historicalBytes!) : nil
		)
	}

	value.queryNDEFStatus { status, capacity, error in
		print("[NfcManagerPlugin] convert: queryNDEFStatus completion handler called.")
		if let error = error {
			print(
				"[NfcManagerPlugin] convert: queryNDEFStatus error: \(error.localizedDescription).")
			completionHandler(nil, error)
			return
		}
		pigeon.ndef = NdefPigeon(
			status: convert(status),
			capacity: Int64(capacity)
		)
		print("[NfcManagerPlugin] convert: NDEF Status: \(status), Capacity: \(capacity).")
		if status == .notSupported {
			print("[NfcManagerPlugin] convert: NDEF not supported. Returning tag with no NDEF.")
			completionHandler(pigeon, nil)
			return
		}
		value.readNDEF { message, error in
			print("[NfcManagerPlugin] convert: readNDEF completion handler called.")
			if let nfcError = error as? NFCReaderError,
				nfcError.code == .ndefReaderSessionErrorZeroLengthMessage
			{
				print(
					"[NfcManagerPlugin] convert: readNDEF detected NFCReaderError.Code.ndefReaderSessionErrorZeroLengthMessage. This is valid."
				)
				completionHandler(pigeon, nil)
				return
			}
			if let error = error {
				print(
					"[NfcManagerPlugin] V2 convert: readNDEF error: \(error.localizedDescription).")
				completionHandler(nil, error)
				return
			}
			if let message = message {
				print("[NfcManagerPlugin] convert: readNDEF success. Caching message.")
				pigeon.ndef?.cachedNdefMessage = convert(message)
			}
			print("[NfcManagerPlugin] convert: Returning tag info to didDetect.")
			completionHandler(pigeon, nil)
		}
	}
}

private func convert(_ value: NdefMessagePigeon) -> NFCNDEFMessage {
	print("[NfcManagerPlugin] convert(NdefMessagePigeon) called.")
	return NFCNDEFMessage(
		records: value.records.map {
			NFCNDEFPayload(
				format: convert($0.typeNameFormat),
				type: $0.type.data,
				identifier: $0.identifier.data,
				payload: $0.payload.data
			)
		}
	)
}

private func convert(_ value: NFCNDEFMessage) -> NdefMessagePigeon {
	print("[NfcManagerPlugin] convert(NFCNDEFMessage) called.")
	return NdefMessagePigeon(records: value.records.map { convert($0) })
}

private func convert(_ value: NFCNDEFPayload) -> NdefPayloadPigeon {
	print("[NfcManagerPlugin] convert(NFCNDEFPayload) called.")
	return NdefPayloadPigeon(
		typeNameFormat: convert(value.typeNameFormat),
		type: FlutterStandardTypedData(bytes: value.type),
		identifier: FlutterStandardTypedData(bytes: value.identifier),
		payload: FlutterStandardTypedData(bytes: value.payload)
	)
}

private func convert(_ value: [PollingOptionPigeon]) -> NFCTagReaderSession.PollingOption {
	print("[NfcManagerPlugin] convert([PollingOptionPigeon]) called.")
	var option = NFCTagReaderSession.PollingOption()
	value.forEach { option.insert(convert($0)) }
	return option
}

private func convert(_ value: PollingOptionPigeon) -> NFCTagReaderSession.PollingOption {
	print("[NfcManagerPlugin] convert(PollingOptionPigeon) called.")
	switch value {
	case .iso14443: return .iso14443
	case .iso15693: return .iso15693
	case .iso18092: return .iso18092
	}
}

private func convert(_ value: NFCNDEFStatus) -> NdefStatusPigeon {
	print("[NfcManagerPlugin] convert(NFCNDEFStatus) called.")
	switch value {
	case .notSupported: return .notSupported
	case .readWrite: return .readWrite
	case .readOnly: return .readOnly
	default: fatalError()
	}
}

private func convert(_ value: FeliCaPollingRequestCodePigeon) -> PollingRequestCode {
	print("[NfcManagerPlugin] convert(FeliCaPollingRequestCodePigeon) called.")
	switch value {
	case .noRequest: return .noRequest
	case .systemCode: return .systemCode
	case .communicationPerformance: return .communicationPerformance
	}
}

private func convert(_ value: FeliCaPollingTimeSlotPigeon) -> PollingTimeSlot {
	print("[NfcManagerPlugin] convert(FeliCaPollingTimeSlotPigeon) called.")
	switch value {
	case .max1: return .max1
	case .max2: return .max2
	case .max4: return .max4
	case .max8: return .max8
	case .max16: return .max16
	}
}

private func convert(_ value: Iso7816ApduPigeon) -> NFCISO7816APDU {
	print("[NfcManagerPlugin] convert(Iso7816ApduPigeon) called.")
	return NFCISO7816APDU(
		instructionClass: UInt8(value.instructionClass),
		instructionCode: UInt8(value.instructionCode),
		p1Parameter: UInt8(value.p1Parameter),
		p2Parameter: UInt8(value.p2Parameter),
		data: value.data.data,
		expectedResponseLength: Int(value.expectedResponseLength)
	)
}

private func convert(_ value: [Iso15693RequestFlagPigeon]) -> RequestFlag {
	print("[NfcManagerPlugin] convert([Iso15693RequestFlagPigeon]) called.")
	var flag = RequestFlag()
	value.forEach { flag.insert(convert($0)) }
	return flag
}

private func convert(_ value: NfcVasCommandConfigurationPigeon) -> NFCVASCommandConfiguration {
	print("[NfcManagerPlugin] convert(NfcVasCommandConfigurationPigeon) called.")
	return NFCVASCommandConfiguration(
		vasMode: convert(value.mode),
		passTypeIdentifier: value.passIdentifier,
		url: (value.url == nil) ? nil : URL(string: value.url!)
	)
}

private func convert(_ value: NFCVASResponse) -> NfcVasResponsePigeon {
	print("[NfcManagerPlugin] convert(NFCVASResponse) called.")
	return NfcVasResponsePigeon(
		status: convert(value.status),
		vasData: FlutterStandardTypedData(bytes: value.vasData),
		mobileToken: FlutterStandardTypedData(bytes: value.mobileToken)
	)
}

private func convert(_ value: Iso15693RequestFlagPigeon) -> RequestFlag {
	print("[NfcManagerPlugin] convert(Iso15693RequestFlagPigeon) called.")
	switch value {
	case .address: return .address
	case .dualSubCarriers: return .dualSubCarriers
	case .highDataRate: return .highDataRate
	case .option: return .option
	case .protocolExtension: return .protocolExtension
	case .select: return .select
	}
}

private func convert(_ value: NFCMiFareFamily) -> MiFareFamilyPigeon {
	print("[NfcManagerPlugin] convert(NFCMiFareFamily) called.")
	switch value {
	case .unknown: return .unknown
	case .ultralight: return .ultralight
	case .plus: return .plus
	case .desfire: return .desfire
	default: fatalError()
	}
}

private func convert(_ value: TypeNameFormatPigeon) -> NFCTypeNameFormat {
	print("[NfcManagerPlugin] convert(TypeNameFormatPigeon) called.")
	switch value {
	case .empty: return .empty
	case .wellKnown: return .nfcWellKnown
	case .media: return .media
	case .absoluteUri: return .absoluteURI
	case .external: return .nfcExternal
	case .unknown: return .unknown
	case .unchanged: return .unchanged
	}
}

private func convert(_ value: NFCTypeNameFormat) -> TypeNameFormatPigeon {
	print("[NfcManagerPlugin] convert(NFCTypeNameFormat) called.")
	switch value {
	case .empty: return .empty
	case .nfcWellKnown: return .wellKnown
	case .media: return .media
	case .absoluteURI: return .absoluteUri
	case .nfcExternal: return .external
	case .unknown: return .unknown
	case .unchanged: return .unchanged
	default: fatalError()
	}
}

private func convert(_ value: NfcVasCommandConfigurationModePigeon)
	-> NFCVASCommandConfiguration.Mode
{
	print("[NfcManagerPlugin] convert(NfcVasCommandConfigurationModePigeon) called.")
	switch value {
	case .normal: return .normal
	case .urlOnly: return .urlOnly
	}
}

private func convert(_ value: NFCReaderError.Code) -> NfcReaderErrorCodePigeon {
	print("[NfcManagerPlugin] convert(NFCReaderError.Code) called.")
	switch value {
	case .readerSessionInvalidationErrorFirstNDEFTagRead:
		return .readerSessionInvalidationErrorFirstNdefTagRead
	case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
		return .readerSessionInvalidationErrorSessionTerminatedUnexpectedly
	case .readerSessionInvalidationErrorSessionTimeout:
		return .readerSessionInvalidationErrorSessionTimeout
	case .readerSessionInvalidationErrorSystemIsBusy:
		return .readerSessionInvalidationErrorSystemIsBusy
	case .readerSessionInvalidationErrorUserCanceled:
		return .readerSessionInvalidationErrorUserCanceled
	case .ndefReaderSessionErrorTagNotWritable: return .ndefReaderSessionErrorTagNotWritable
	case .ndefReaderSessionErrorTagSizeTooSmall: return .ndefReaderSessionErrorTagSizeTooSmall
	case .ndefReaderSessionErrorTagUpdateFailure: return .ndefReaderSessionErrorTagUpdateFailure
	case .ndefReaderSessionErrorZeroLengthMessage: return .ndefReaderSessionErrorZeroLengthMessage
	case .readerTransceiveErrorRetryExceeded: return .readerTransceiveErrorRetryExceeded
	case .readerTransceiveErrorTagConnectionLost: return .readerTransceiveErrorTagConnectionLost
	case .readerTransceiveErrorTagNotConnected: return .readerTransceiveErrorTagNotConnected
	case .readerTransceiveErrorTagResponseError: return .readerTransceiveErrorTagResponseError
	case .readerTransceiveErrorSessionInvalidated: return .readerTransceiveErrorSessionInvalidated
	case .readerTransceiveErrorPacketTooLong: return .readerTransceiveErrorPacketTooLong
	case .tagCommandConfigurationErrorInvalidParameters:
		return .tagCommandConfigurationErrorInvalidParameters
	case .readerErrorUnsupportedFeature: return .readerErrorUnsupportedFeature
	case .readerErrorInvalidParameter: return .readerErrorInvalidParameter
	case .readerErrorInvalidParameterLength: return .readerErrorInvalidParameterLength
	case .readerErrorParameterOutOfBound: return .readerErrorParameterOutOfBound
	case .readerErrorRadioDisabled: return .readerErrorRadioDisabled
	case .readerErrorSecurityViolation: return .readerErrorSecurityViolation
	default: fatalError()
	}
}

private func convert(_ value: NFCVASResponse.ErrorCode) -> NfcVasResponseErrorCodePigeon {
	print("[NfcManagerPlugin] convert(NFCVASResponse.ErrorCode) called.")
	switch value {
	case .success: return .success
	case .userIntervention: return .userIntervention
	case .dataNotActivated: return .dataNotActivated
	case .dataNotFound: return .dataNotFound
	case .incorrectData: return .incorrectData
	case .unsupportedApplicationVersion: return .unsupportedApplicationVersion
	case .wrongLCField: return .wrongLCField
	case .wrongParameters: return .wrongParameters
	default: fatalError()
	}
}

private func convert(_ value1: Int64, _ value2: Int64) -> NSRange {
	print("[NfcManagerPlugin] convert(Int64, Int64) called.")
	return NSRange(location: Int(value1), length: Int(value2))
}

extension FlutterError: Error {}
