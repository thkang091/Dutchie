import UIKit
import Vision

// MARK: - Document Classifier (Apple Vision — local, no API cost)
// Uses fast on-device OCR to classify the image as receipt, transaction_history, or neither.
// No GPT call needed for classification — Vision runs in ~100-200ms.

enum DocumentClassifier {

    enum DocumentKind {
        case receipt
        case transactionHistory
        case neither
    }

    struct ClassifierResult {
        let kind:         DocumentKind
        let confidence:   Float
        let debugSummary: String

        var rejectionReason: String? {
            kind == .neither
                ? "This doesn't look like a receipt or transaction statement. Please retake the photo."
                : nil
        }
    }

    static func classify(
        _ image: UIImage,
        completion: @escaping (ClassifierResult) -> Void
    ) {
        guard let cgImage = image.cgImage else {
            completion(ClassifierResult(kind: .neither, confidence: 0.1, debugSummary: "no_cgimage"))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            let sema = DispatchSemaphore(value: 0)

            let request = VNRecognizeTextRequest { req, _ in
                defer { sema.signal() }
                lines = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            sema.wait()

            let fullText    = lines.joined(separator: "\n").lowercased()
            let lineCount   = lines.count
            let priceCount  = fullText.ranges(of: #"\d+\.\d{2}"#, options: String.CompareOptions.regularExpression).count
            let hasCurrency = fullText.range(of: #"[\$€£¥₩₹]\s*\d"#, options: .regularExpression) != nil
            let hasTotal    = fullText.range(of: #"\btotal\b"#,       options: .regularExpression) != nil

            let receiptKws     = ["receipt","subtotal","tax","thank you","change","cashier",
                                  "item","qty","quantity","order","table"]
            let transactionKws = ["balance","statement","transaction","debit","credit",
                                  "available","account","payment due","minimum payment",
                                  "deposit","withdrawal","posting date","description"]

            let recKwCnt   = receiptKws.filter    { fullText.contains($0) }.count
            let transKwCnt = transactionKws.filter { fullText.contains($0) }.count

            var recScore:   Float = 0
            var transScore: Float = 0

            if hasCurrency     { recScore += 0.20 }
            if hasTotal        { recScore += 0.20 }
            if priceCount >= 2 { recScore += 0.20 }
            if priceCount >= 4 { recScore += 0.10 }
            if lineCount >= 8  { recScore += 0.10 }
            recScore += Float(recKwCnt) * 0.08

            if lineCount >= 12                        { transScore += 0.10 }
            if transKwCnt >= 2                        { transScore += 0.35 }
            if transKwCnt >= 4                        { transScore += 0.20 }
            if priceCount >= 5 && lineCount >= 12     { transScore += 0.20 }

            let maxScore = max(recScore, transScore)
            guard maxScore >= 0.25 else {
                let result = ClassifierResult(kind: .neither, confidence: maxScore,
                    debugSummary: "local:neither score=\(String(format: "%.2f", maxScore))")
                DispatchQueue.main.async { completion(result) }
                return
            }

            let kind: DocumentKind = recScore >= transScore ? .receipt : .transactionHistory
            let result = ClassifierResult(kind: kind, confidence: maxScore,
                debugSummary: "local:\(kind) rec=\(String(format: "%.2f", recScore)) trans=\(String(format: "%.2f", transScore))")
            DispatchQueue.main.async { completion(result) }
        }
    }
}


enum QualityScorer {

    typealias Score = Float

    struct Report {
        let score:                     Score
        let isSufficientForTabscanner: Bool
        let signals:                   [Signal]
        let failReasons:               [String]

        /// True when quality is so poor that even GPT should be used for total extraction
        /// instead of relying on Vision's quick-total pass.
        var requiresGPTForTotal: Bool {
            // If multiple quality issues exist, or blur/contrast is severe, Vision likely can't read totals
            let severeBlur = signals.contains(where: {
                if case .blurry(let v) = $0 { return v < 30.0 } // very blurry
                return false
            })
            let severeDark = signals.contains(where: {
                if case .dark(let v) = $0 { return v < 0.08 }
                return false
            })
            let severeContrast = signals.contains(where: {
                if case .lowContrast(let v) = $0 { return v < 0.04 }
                return false
            })
            let tilted = signals.contains(where: {
                if case .largeSkew(let deg) = $0 { return deg > 20 }
                return false
            })
            let issueCount = [severeBlur, severeDark, severeContrast, tilted,
                              !isSufficientForTabscanner].filter { $0 }.count
            return issueCount >= 2 || severeBlur || tilted
        }

        var grade: Grade {
            switch score {
            case 0.85...: return .excellent
            case 0.65...: return .good
            case 0.45...: return .fair
            default:      return .poor
            }
        }

        var qualityWarningMessage: String? {
            guard !failReasons.isEmpty else { return nil }
            if failReasons.count == 1 { return failReasons[0] }
            return "Receipt quality is low (\(failReasons.prefix(2).joined(separator: "; "))). GPT is reading it carefully."
        }

        enum Grade: String { case excellent, good, fair, poor }
    }

    enum Signal {
        case blurry(laplacianVariance: Double)
        case dark(meanLuminance: Double)
        case overexposed(meanLuminance: Double)
        case lowContrast(rmsContrast: Double)
        case tooSmall(pixels: Int)
        case largeSkew(degrees: Float)
        case ok
    }

    private enum T {
        static let minPixels:          Int    = 400_000
        static let blurThreshold:      Double = 80.0
        static let darkThreshold:      Double = 0.15
        static let brightThreshold:    Double = 0.92
        static let contrastThreshold:  Double = 0.08
        static let tabscannerMinScore: Float  = 0.85
        static let skewThreshold:      Float  = 15.0  // degrees
    }

    static func evaluate(_ image: UIImage) -> Report {
        var signals = [Signal](); var failReasons = [String]()

        let pixels = Int(image.size.width * image.scale) * Int(image.size.height * image.scale)
        let resScore: Score
        if pixels < T.minPixels {
            resScore = max(0, Float(pixels) / Float(T.minPixels))
            signals.append(.tooSmall(pixels: pixels))
            failReasons.append("Image resolution too low (\(pixels / 1000)K px).")
        } else {
            resScore = 1.0
            signals.append(.ok)
        }

        let (luminance, rmsContrast) = computeLuminanceAndContrast(image)

        let lumScore: Score
        if luminance < T.darkThreshold {
            lumScore = Float(luminance / T.darkThreshold)
            signals.append(.dark(meanLuminance: luminance))
            failReasons.append("Image is too dark (luminance \(String(format: "%.2f", luminance))).")
        } else if luminance > T.brightThreshold {
            let excess = Float((luminance - T.brightThreshold) / (1.0 - T.brightThreshold))
            lumScore   = max(0, 1 - excess)
            signals.append(.overexposed(meanLuminance: luminance))
            failReasons.append("Image is overexposed.")
        } else {
            lumScore = 1.0
        }

        let contrastScore: Score
        if rmsContrast < T.contrastThreshold {
            contrastScore = Float(rmsContrast / T.contrastThreshold)
            signals.append(.lowContrast(rmsContrast: rmsContrast))
            failReasons.append("Low contrast — text may be unreadable.")
        } else {
            contrastScore = 1.0
        }

        let lapVar = laplacianVariance(image)
        let blurScore: Score
        if lapVar < T.blurThreshold {
            blurScore = Float(lapVar / T.blurThreshold)
            signals.append(.blurry(laplacianVariance: lapVar))
            failReasons.append("Image appears blurry (sharpness \(String(format: "%.0f", lapVar))).")
        } else {
            blurScore = 1.0
        }

        // ── Skew / tilt detection via Vision text observations ──────────────
        let skewDeg = estimateSkewDegrees(image)
        let skewScore: Score
        if skewDeg > T.skewThreshold {
            let excess = min((skewDeg - T.skewThreshold) / 30.0, 1.0)
            skewScore = max(0, 1.0 - excess)
            signals.append(.largeSkew(degrees: skewDeg))
            failReasons.append("Receipt appears tilted (\(String(format: "%.0f", skewDeg))°). Hold camera straight above.")
        } else {
            skewScore = 1.0
        }

        // Weighted score: blur is most impactful for OCR, then luminance, then contrast, skew, resolution
        let score: Score = resScore      * 0.15
                         + lumScore      * 0.20
                         + contrastScore * 0.15
                         + blurScore     * 0.35
                         + skewScore     * 0.15

        let sufficient = score >= T.tabscannerMinScore && failReasons.isEmpty
        return Report(score: score, isSufficientForTabscanner: sufficient, signals: signals, failReasons: failReasons)
    }

    // MARK: - Skew estimation using VNDetectTextRectanglesRequest bounding boxes

    private static func estimateSkewDegrees(_ image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0 }
        var angles: [Float] = []
        let sema = DispatchSemaphore(value: 0)

        let request = VNDetectTextRectanglesRequest { req, _ in
            defer { sema.signal() }
            guard let obs = req.results as? [VNTextObservation] else { return }
            // Each observation has a boundingBox in normalized coords.
            // We estimate skew from the angle of each box's top edge.
            for ob in obs {
                // VNTextObservation has topLeft, topRight, bottomLeft, bottomRight
                // Use the characterBoxes' angles if available, else skip
                let tl = ob.topLeft
                let tr = ob.topRight
                let dx = Float(tr.x - tl.x)
                let dy = Float(tr.y - tl.y)
                if dx > 0.05 { // only wide-enough lines
                    let angle = abs(atan2(dy, dx) * 180 / .pi)
                    angles.append(angle)
                }
            }
        }
        request.reportCharacterBoxes = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        sema.wait()

        guard !angles.isEmpty else { return 0 }
        // Median angle as skew estimate
        let sorted = angles.sorted()
        return sorted[sorted.count / 2]
    }

    private static func computeLuminanceAndContrast(_ image: UIImage) -> (mean: Double, rms: Double) {
        guard let cgImage = image.cgImage else { return (0.5, 0.5) }
        let ciImage = CIImage(cgImage: cgImage)

        guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform") else { return (0.5, 0.5) }
        let scale = 64.0 / max(ciImage.extent.width, ciImage.extent.height)
        scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale,   forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0,     forKey: kCIInputAspectRatioKey)
        guard let small = scaleFilter.outputImage else { return (0.5, 0.5) }

        let w = Int(small.extent.width); let h = Int(small.extent.height)
        guard w > 0, h > 0 else { return (0.5, 0.5) }

        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
        guard let smallCG = ciCtx.createCGImage(small, from: small.extent) else { return (0.5, 0.5) }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return (0.5, 0.5) }
        ctx.draw(smallCG, in: CGRect(origin: .zero, size: CGSize(width: w, height: h)))

        let n = Double(w * h)
        let sum   = pixels.reduce(0) { $0 + Int($1) }
        let mean  = Double(sum) / (n * 255.0)
        let sumSq = pixels.reduce(0.0) { $0 + pow(Double($1) / 255.0 - mean, 2) }
        return (mean, sqrt(sumSq / n))
    }

    private static func laplacianVariance(_ image: UIImage) -> Double {
        let size = 256
        guard let cgSrc = image.cgImage else { return 50 }
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 50 }
        ctx.draw(cgSrc, in: CGRect(origin: .zero, size: CGSize(width: size, height: size)))

        var lapValues = [Double]()
        lapValues.reserveCapacity((size - 2) * (size - 2))
        for y in 1 ..< (size - 1) {
            for x in 1 ..< (size - 1) {
                let center = Int(pixels[y * size + x])
                let top    = Int(pixels[(y - 1) * size + x])
                let bottom = Int(pixels[(y + 1) * size + x])
                let left   = Int(pixels[y * size + (x - 1)])
                let right  = Int(pixels[y * size + (x + 1)])
                lapValues.append(Double(4 * center - top - bottom - left - right))
            }
        }

        let n = Double(lapValues.count)
        let mean = lapValues.reduce(0, +) / n
        return lapValues.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
    }
}

// MARK: - OCR Service

class OCRService {
    
    private static let tabscannerAPIKey = API.tabscannerAPIKey
    private static let openAIAPIKey     = API.openAIAPIKey

    static let lowConfidenceThreshold: Float = 0.75

    enum DocumentType { case receipt, transactionHistory, unknown }
    enum AccountType   { case creditCard, debitCard }

    // MARK: - Processing Status Callback
    // Allows UploadView to show live status messages during the pipeline.
    // Fires with a non-nil String when entering a special state (e.g. low-quality GPT),
    // and with nil when that state ends / processing is done.
    static var onStatusUpdate: ((String?) -> Void)?

    struct ConfidenceField<T> {
        var value:       T
        var confidence:  Float
        var needsReview: Bool { confidence < OCRService.lowConfidenceThreshold }
    }

    struct ParsedLineItem {
        var name:       ConfidenceField<String>
        var qty:        ConfidenceField<Double>
        var unitPrice:  ConfidenceField<Double>
        var totalPrice: ConfidenceField<Double>
        var discount:   Double
        var taxPortion: Double
        var isSelected: Bool
        var needsReview: Bool { name.needsReview || totalPrice.needsReview }

        func toReceiptLineItem() -> ReceiptLineItem {
            ReceiptLineItem(
                name:          name.value,
                originalPrice: totalPrice.value + discount,
                discount:      discount,
                amount:        totalPrice.value,
                taxPortion:    taxPortion,
                isSelected:    isSelected
            )
        }
    }

    struct ReceiptData {
        var merchant:             String
        var amounts:              [Double]
        var hasReceiptStructure:  Bool
        var confidence:           Float
        var likelyTotal:          Double?
        var lineItems:            [ReceiptLineItem]
        var processingMethod:     ProcessingMethod
        var receiptDate:          String?
        var taxAmount:            Double?
        var subtotal:             Double?
        var totalSavings:         Double?
        var isQuickResult:        Bool
        var currency:             String?
        var lowConfidenceFields:  Set<String> = []
        var imageQualityWarning:  String?     = nil
        var qualityScore:         Float       = 0
        var backgroundResultToken: String?    = nil
    }

    enum ProcessingMethod {
        case tabscanner
        case gptMini
        case gptFourO
        case visionFallback
    }

    struct TransactionItem {
        var description: String
        var amount:      Double
        var date:        String?
        var isDebit:     Bool
    }

    struct TransactionData {
        var items:        [TransactionItem]
        var accountType:  AccountType
        var totalDebits:  Double
        var totalCredits: Double
        var confidence:   Float
    }

    private static let paymentNoisePatterns: [String] = [
        "approved","approval","auth","authorization",
        "balance due","amount due",
        "visa","mastercard","amex","american express","discover",
        "debit","credit card","card ending","card#","acct#",
        "payment","tender","cash","change due","change:",
        "usd $","usd:","account",
        "exp date","expiry","ref #","ref:","trace",
        "terminal","merchant id","store #","store id","store no",
        "cashier","operator","clerk","server",
        "receipt #","ticket #","order #","trans #","transaction #","invoice #",
        "subtotal","sub total","sub-total",
        "total tax","sales tax","hst","gst","pst","vat",
        "grand total","amount total","net total",
        "tip","gratuity","service charge","service fee",
        "you saved","savings","rewards","points earned","points redeemed",
        "member","loyalty",
        "thank you","please come again","have a nice",
        "balance","no. items","items sold",
        "barcode","upc","sku",
    ]

    private struct GPTReceiptResponse: Codable {
        let merchant:   String?
        let date:       String?
        let currency:   String?
        let subtotal:   Double?
        let tax:        Double?
        let total:      Double
        let line_items: [GPTLineItem]

        struct GPTLineItem: Codable {
            let name:   String
            let amount: Double
            let qty:    Double?
        }
    }

    // MARK: - Background Line-Item Cache

    private static var lineItemCache:     [String: ReceiptData]             = [:]
    private static var lineItemCallbacks: [String: [(ReceiptData) -> Void]] = [:]

    private static func storeBackgroundResult(_ data: ReceiptData, for token: String) {
        DispatchQueue.main.async {
            lineItemCache[token] = data
            lineItemCallbacks[token]?.forEach { $0(data) }
            lineItemCallbacks[token] = nil
        }
    }

    static func fetchBackgroundResult(
        for token: String,
        timeout: TimeInterval = 60,
        completion: @escaping (ReceiptData?) -> Void
    ) {
        if let cached = lineItemCache[token] {
            completion(cached); return
        }
        if lineItemCallbacks[token] == nil { lineItemCallbacks[token] = [] }
        lineItemCallbacks[token]?.append(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard lineItemCallbacks[token] != nil else { return }
            lineItemCallbacks[token] = nil
            completion(nil)
        }
    }

    // MARK: - Main Entry Point

    static func processDocument(
        from image: UIImage,
        hint: DocumentType = .unknown,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        print("\n=== OCR PIPELINE START === (hint: \(hint))")

        if hint == .transactionHistory {
            print("  Transaction hint → using Apple Vision (local processing)")
            processTransactionHistory(from: image, completion: completion)
            return
        }

        if hint == .receipt {
            print("  Receipt hint → GPT classification + Vision total running in parallel")
            processReceiptWithParallelClassification(image: image, completion: completion)
            return
        }

        // ── UNKNOWN HINT ──────────────────────────────────────────────────────
        var classifyResult: DocumentClassifier.ClassifierResult? = nil
        var quickTotal:     Double? = nil
        var quickMerchant:  String  = ""
        var parallelDone            = 0

        func checkBothReady() {
            parallelDone += 1
            guard parallelDone == 2 else { return }

            guard let cls = classifyResult else {
                completion(.failure(nsError(-100, "Classification failed")))
                return
            }

            print("  DocClass: \(cls.kind) — \(cls.debugSummary)")

            switch cls.kind {
            case .neither:
                print("  REJECTED")
                completion(.failure(nsError(-100,
                    cls.rejectionReason ?? "This doesn't look like a receipt or transaction statement. Please retake the photo.")))
                return

            case .transactionHistory:
                print("  Classified as transaction → using Apple Vision")
                processTransactionHistory(from: image, completion: completion)
                return

            case .receipt:
                break
            }

            let quality = QualityScorer.evaluate(image)
            print("  Quality: \(String(format: "%.2f", quality.score)) [\(quality.grade)] requiresGPTForTotal=\(quality.requiresGPTForTotal)")

            if quality.signals.contains(where: {
                if case .tooSmall(let px) = $0, px < 100_000 { return true }
                return false
            }) {
                completion(.failure(nsError(-100, "Image resolution is too low to extract text.")))
                return
            }

            // Vision returning no total is the real signal the image is unreadable on-device.
            // Use GPT immediately regardless of what the pixel quality scorer says.
            let visionGotNoTotal = (quickTotal == nil || quickTotal == 0.0)
            if visionGotNoTotal {
                print("  Vision got no total → GPT immediate full extraction")
                fireGPTImmediateFullExtraction(
                    image:   image,
                    quality: quality,
                    completion: completion
                )
                return
            }

            fireQuickResultAndStartBackground(
                image:         image,
                quality:       quality,
                quickTotal:    quickTotal,
                quickMerchant: quickMerchant,
                completion:    completion
            )
        }

        DocumentClassifier.classify(image) { cls in
            classifyResult = cls
            checkBothReady()
        }

        extractQuickTotal(from: image) { total, merchant in
            quickTotal    = total
            quickMerchant = merchant
            print("  QuickTotal: \(total ?? 0), merchant: \(merchant)")
            checkBothReady()
        }
    }

    // MARK: - Receipt Parallel Classification (hint == .receipt)

    private static func processReceiptWithParallelClassification(
        image:      UIImage,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        var gptKind:       GPTDocumentKind? = nil
        var gptRejection:  String?          = nil
        var quickTotal:    Double?          = nil
        var quickMerchant: String           = ""
        var parallelDone                    = 0

        func checkBothReady() {
            parallelDone += 1
            guard parallelDone == 2 else { return }

            switch gptKind {
            case .transactionHistory:
                // User uploaded a transaction statement via the Receipt button — silently re-route.
                print("  [Receipt] GPT detected transaction history → re-routing to transaction pipeline")
                processTransactionHistory(from: image, completion: completion)
                return
            case .neither:
                let reason = gptRejection ?? "This doesn't look like a receipt or statement. Please retake the photo."
                print("  [Receipt] GPT rejected: \(reason)")
                completion(.failure(nsError(-100, reason)))
                return
            case .receipt, .none:
                break   // .none = network error, fail open and treat as receipt
            }

            let quality = QualityScorer.evaluate(image)
            print("  [Receipt] GPT confirmed receipt. Quality: \(String(format: "%.2f", quality.score)) [\(quality.grade)] requiresGPTForTotal=\(quality.requiresGPTForTotal)")

            if quality.signals.contains(where: {
                if case .tooSmall(let px) = $0, px < 100_000 { return true }
                return false
            }) {
                completion(.failure(nsError(-100, "Image resolution is too low to extract text.")))
                return
            }

            // If Vision got no usable total the image is unreadable by on-device OCR —
            // this is the real signal regardless of pixel quality score.
            // (foreign script, unusual font, glare, rotation — quality scorer misses all of these)
            let visionGotNoTotal = (quickTotal == nil || quickTotal == 0.0)
            if visionGotNoTotal {
                print("  [Receipt] Vision got no total → GPT immediate full extraction")
                fireGPTImmediateFullExtraction(
                    image:   image,
                    quality: quality,
                    completion: completion
                )
                return
            }

            fireQuickResultAndStartBackground(
                image:         image,
                quality:       quality,
                quickTotal:    quickTotal,
                quickMerchant: quickMerchant,
                completion:    completion
            )
        }

        classifyWithGPT(image: image) { kind, rejection in
            gptKind      = kind
            gptRejection = rejection
            print("  [Receipt] GPT classify done — kind: \(kind)")
            checkBothReady()
        }

        extractQuickTotal(from: image) { total, merchant in
            quickTotal    = total
            quickMerchant = merchant
            print("  [Receipt] Vision total done — total: \(total ?? 0), merchant: \(merchant)")
            checkBothReady()
        }
    }

    // MARK: - GPT Immediate Full Extraction (poor quality path)
    //
    // Called when image quality is too poor for Vision to reliably extract a total.
    // GPT runs immediately (not in background) for both total + line items.
    // Notifies UploadView via onStatusUpdate so it can show "taking longer" message.
    // Returns a NON-quick ReceiptData (isQuickResult = false) once GPT finishes.

    private static func fireGPTImmediateFullExtraction(
        image:      UIImage,
        quality:    QualityScorer.Report,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        // Notify UploadView to show the "taking longer" message
        let qualityMsg = quality.qualityWarningMessage
            ?? "The receipt photo isn't very clear, but we're reading it carefully."
        DispatchQueue.main.async {
            onStatusUpdate?("low_quality_gpt: \(qualityMsg)")
        }

        print("  [GPT Immediate] Starting full extraction for poor-quality image…")

        processWithGPTMini(image: image, qualityScore: quality.score) { result in
            switch result {
            case .success(var data):
                data.imageQualityWarning = qualityMsg
                data.isQuickResult       = false
                print("  [GPT Immediate] Done — total: \(data.likelyTotal ?? 0), items: \(data.lineItems.count)")
                DispatchQueue.main.async {
                    onStatusUpdate?(nil)   // signal "done" — clears low-quality mode in UploadView
                    completion(.success(data as Any))
                }
            case .failure(let err):
                print("  [GPT Immediate] Failed: \(err.localizedDescription)")
                // Last-resort: return an empty result rather than blocking the user
                DispatchQueue.main.async {
                    completion(.failure(err))
                }
            }
        }
    }

    // MARK: - GPT Lightweight Classifier
    //
    // Returns one of three document kinds so the hint=.receipt path can
    // silently re-route to transaction processing instead of rejecting the user.

    enum GPTDocumentKind { case receipt, transactionHistory, neither }

    private static func classifyWithGPT(
        image:      UIImage,
        completion: @escaping (_ kind: GPTDocumentKind, _ rejectionReason: String?) -> Void
    ) {
        guard let imageData = image.jpegData(compressionQuality: 0.5) else {
            completion(.receipt, nil); return   // fail open
        }

        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 80,
            "response_format": ["type": "json_object"],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": [
                        "url": "data:image/jpeg;base64,\(imageData.base64EncodedString())",
                        "detail": "low"
                    ]],
                    ["type": "text", "text": """
                    Classify this image. Respond ONLY with JSON in one of these three forms:
                    {"kind": "receipt"}                              — retail/restaurant receipt or purchase document
                    {"kind": "transaction_history"}                  — bank/card statement or transaction list
                    {"kind": "neither", "reason": "brief reason"}    — anything else
                    """]
                ]
            ]]
        ]

        guard
            let url      = URL(string: "https://api.openai.com/v1/chat/completions"),
            let jsonData = try? JSONSerialization.data(withJSONObject: requestBody)
        else {
            completion(.receipt, nil); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody   = jsonData
        req.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(openAIAPIKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let _ = error { completion(.receipt, nil); return }   // fail open on network error

                guard
                    let data    = data,
                    let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let choices = json["choices"] as? [[String: Any]],
                    let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
                    let parsed  = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
                else {
                    completion(.receipt, nil); return
                }

                switch parsed["kind"] as? String {
                case "receipt":
                    completion(.receipt, nil)
                case "transaction_history":
                    completion(.transactionHistory, nil)
                default:
                    let reason = parsed["reason"] as? String
                    completion(.neither, reason)
                }
            }
        }.resume()
    }

    // MARK: - Shared: fire quick result + launch background extraction

    private static func fireQuickResultAndStartBackground(
        image:         UIImage,
        quality:       QualityScorer.Report,
        quickTotal:    Double?,
        quickMerchant: String,
        completion:    @escaping (Result<Any, Error>) -> Void
    ) {
        let bgToken = UUID().uuidString

        let total     = quickTotal ?? 0
        let quickData = ReceiptData(
            merchant:              quickMerchant,
            amounts:               total > 0 ? [total] : [],
            hasReceiptStructure:   true,
            confidence:            0.6,
            likelyTotal:           total > 0 ? total : nil,
            lineItems:             [],
            processingMethod:      .visionFallback,
            receiptDate:           nil,
            taxAmount:             nil,
            subtotal:              nil,
            totalSavings:          nil,
            isQuickResult:         true,
            currency:              "USD",
            qualityScore:          quality.score,
            backgroundResultToken: bgToken
        )

        print("  → Quick result (total: \(total), merchant: \(quickMerchant), token: \(bgToken.prefix(8))…)")
        completion(.success(quickData as Any))

        print("  → Background OCR starting (\(quality.isSufficientForTabscanner ? "Tabscanner" : "GPT"))…")

        if quality.isSufficientForTabscanner {
            processWithTabscanner(image: image) { result in
                switch result {
                case .success(let (data, _)):
                    var out = data; out.qualityScore = quality.score
                    print("  [BG] Tabscanner done — \(out.lineItems.count) items")
                    storeBackgroundResult(out, for: bgToken)
                case .failure(let err):
                    print("  [BG] Tabscanner failed (\(err.localizedDescription)) → GPT fallback")
                    processWithGPTMini(image: image, qualityScore: quality.score) { r in
                        if case .success(let data) = r {
                            print("  [BG] GPT done — \(data.lineItems.count) items")
                            storeBackgroundResult(data, for: bgToken)
                        }
                    }
                }
            }
        } else {
            processWithGPTMini(image: image, qualityScore: quality.score) { r in
                if case .success(let data) = r {
                    print("  [BG] GPT done — \(data.lineItems.count) items")
                    storeBackgroundResult(data, for: bgToken)
                }
            }
        }
    }

    // MARK: - Vision Quick Total

    private static func extractQuickTotal(
        from image: UIImage,
        completion: @escaping (_ total: Double?, _ merchant: String) -> Void
    ) {
        guard let cgImage = image.cgImage else { completion(nil, ""); return }

        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            let sema = DispatchSemaphore(value: 0)

            let request = VNRecognizeTextRequest { req, _ in
                defer { sema.signal() }
                lines = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            sema.wait()

            var allAmounts = [Double](); var taxAmt: Double?; var subAmt: Double?
            let total = findTotal(in: lines, allAmounts: &allAmounts, tax: &taxAmt, subtotal: &subAmt)

            var merchant = ""
            for line in lines.prefix(6) {
                let c = line.trimmingCharacters(in: .whitespaces)
                let letterRatio = Double(c.filter { $0.isLetter || $0.isWhitespace }.count) / Double(max(c.count, 1))
                if c.count >= 3, c.count <= 50, letterRatio > 0.5 { merchant = c; break }
            }

            DispatchQueue.main.async { completion(total, merchant) }
        }
    }

    // MARK: - GPT Mini (background full receipt extraction)

    private static func processWithGPTMini(
        image:        UIImage,
        qualityScore: Float,
        completion:   @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        print("\n=== GPT-4o-mini (Structured Outputs) ===")
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            completion(.failure(nsError(-1, "Failed to encode image for GPT")))
            return
        }
        print("  JPEG payload: \(imageData.count / 1024)KB")

        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 1500,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "receipt_extraction",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "merchant":   ["type": "string",         "description": "Store or merchant name"],
                            "date":       ["type": ["string","null"], "description": "Receipt date if visible"],
                            "currency":   ["type": "string",         "description": "ISO 4217 currency code (e.g. USD)"],
                            "subtotal":   ["type": ["number","null"], "description": "Subtotal before tax"],
                            "tax":        ["type": ["number","null"], "description": "Tax amount"],
                            "total":      ["type": "number",         "description": "Total amount paid"],
                            "line_items": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "name":   ["type": "string",         "description": "Item description"],
                                        "amount": ["type": "number",         "description": "Item price (positive number)"],
                                        "qty":    ["type": ["number","null"], "description": "Quantity if visible"]
                                    ],
                                    "required": ["name","amount","qty"],
                                    "additionalProperties": false
                                ]
                            ]
                        ],
                        "required": ["merchant","date","currency","subtotal","tax","total","line_items"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": [
                        "url": "data:image/jpeg;base64,\(imageData.base64EncodedString())",
                        "detail": "high"
                    ]],
                    ["type": "text", "text": gptReceiptPromptStructured]
                ]
            ]]
        ]

        guard
            let url      = URL(string: "https://api.openai.com/v1/chat/completions"),
            let jsonData = try? JSONSerialization.data(withJSONObject: requestBody)
        else {
            completion(.failure(nsError(-301, "Failed to build GPT request")))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody   = jsonData
        req.setValue("application/json",       forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(openAIAPIKey)",  forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let e = error { completion(.failure(e)); return }
                guard
                    let data    = data,
                    let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let choices = json["choices"] as? [[String: Any]],
                    let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
                else {
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err  = (json["error"] as? [String: Any])?["message"] as? String {
                        completion(.failure(nsError(-302, "GPT API Error: \(err)")))
                    } else {
                        completion(.failure(nsError(-302, "Invalid GPT response")))
                    }
                    return
                }
                print("  GPT-mini content received (\(content.count) chars)")
                parseGPTStructuredResponse(content, qualityScore: qualityScore,
                                           qualityWarn: nil, method: .gptMini, completion: completion)
            }
        }.resume()
    }

    // MARK: - GPT Prompt

    private static let gptReceiptPromptStructured = """
    Extract receipt information from this image. Follow these rules carefully:

    1. **Merchant**: Extract the store/restaurant name at the top of the receipt
    2. **Date**: Extract date if clearly visible (any format)
    3. **Currency**: Determine currency from receipt (USD, EUR, GBP, etc.) — default to USD if unclear
    4. **Amounts**: All amounts must be positive numbers without currency symbols
    5. **Line Items**: Include ONLY purchased products/items:
       - Include: food items, retail products, services purchased
       - Exclude: subtotals, tax lines, tips, payment methods, totals, discounts, card numbers
       - Each item needs a name and amount
       - Extract quantity if visible on receipt
    6. **Total**: The final amount paid (required)
    7. **Tax & Subtotal**: Extract if clearly labeled

    Note: The image may be blurry, tilted, or partially obscured. Do your best to read all visible text accurately.
    If merchant is not visible, use empty string "". If any optional field is not found, use null.
    Be precise with amounts — read carefully to avoid OCR errors on similar-looking numbers (0 vs 8, 1 vs 7).
    """

    // MARK: - GPT Response Parsing

    private static func parseGPTStructuredResponse(
        _ text:       String,
        qualityScore: Float,
        qualityWarn:  String?,
        method:       ProcessingMethod,
        completion:   @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        guard let jsonData = text.data(using: .utf8) else {
            completion(.success(emptyReceiptData(method: method))); return
        }

        do {
            let response = try JSONDecoder().decode(GPTReceiptResponse.self, from: jsonData)
            print("  Parsed: merchant=\(response.merchant ?? "(empty)") total=\(response.total) items=\(response.line_items.count)")

            let merchant  = response.merchant ?? ""
            let total     = response.total
            let tax       = response.tax
            let subtotRaw = response.subtotal ?? 0
            let currency  = (response.currency?.isEmpty == false) ? response.currency! : "USD"

            var lineItems = [ReceiptLineItem]()
            for item in response.line_items {
                guard !item.name.isEmpty, item.amount > 0 else { continue }
                let lower = item.name.lowercased()
                if paymentNoisePatterns.contains(where: { lower.contains($0) }) { continue }
                lineItems.append(ReceiptLineItem(
                    name: item.name, originalPrice: item.amount,
                    discount: 0, amount: item.amount, taxPortion: 0, isSelected: true
                ))
            }

            // Gap check against pre-tax subtotal only (tax will be its own item)
            let pretaxTarget: Double = subtotRaw > 0
                ? subtotRaw
                : (total > 0 && (tax ?? 0) > 0)
                    ? round((total - (tax ?? 0)) * 100) / 100
                    : total

            let itemsSum = lineItems.reduce(0.0) { $0 + $1.amount }
            let gap      = round((pretaxTarget - itemsSum) * 100) / 100
            if pretaxTarget > 0.01, gap > 0.01 {
                lineItems.append(ReceiptLineItem(
                    name: "Missing Item(s)", originalPrice: gap,
                    discount: 0, amount: gap, taxPortion: 0, isSelected: true
                ))
            }

            // Add tax as its own visible line item (no distribution into taxPortion)
            if let t = tax, t > 0 {
                lineItems.append(ReceiptLineItem(
                    name: "Tax", originalPrice: t,
                    discount: 0, amount: t, taxPortion: 0, isSelected: true
                ))
            }
            

            let finalSub = lineItems.reduce(0.0) { $0 + $1.amount }
            var confidence: Float = 0.5
            if !merchant.isEmpty  { confidence += 0.15 }
            if total > 0          { confidence += 0.20 }
            if !lineItems.isEmpty { confidence += 0.15 }

            completion(.success(ReceiptData(
                merchant:            merchant,
                amounts:             lineItems.map(\.amount) + [total, tax ?? 0, subtotRaw].filter { $0 > 0 },
                hasReceiptStructure: true,
                confidence:          min(confidence, 1.0),
                likelyTotal:         total > 0 ? total : nil,
                lineItems:           lineItems,
                processingMethod:    method,
                receiptDate:         response.date,
                taxAmount:           tax,
                subtotal:            finalSub > 0 ? finalSub : nil,
                totalSavings:        nil,
                isQuickResult:       false,
                currency:            currency,
                imageQualityWarning: qualityWarn,
                qualityScore:        qualityScore
            )))

        } catch {
            print("  JSON decode error: \(error)")
            var data = parseGPTResponseLegacy(text)
            data.processingMethod    = method
            data.imageQualityWarning = nil
            data.qualityScore        = qualityScore
            completion(.success(data))
        }
    }

    private static func parseGPTResponseLegacy(_ text: String) -> ReceiptData {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let jsonData = cleaned.data(using: .utf8),
            let json     = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            print("  Legacy JSON parse failed")
            return emptyReceiptData(method: .gptMini)
        }

        let merchant  = json["merchant"] as? String ?? ""
        let dateStr   = json["date"]     as? String
        let total     = json["total"]    as? Double ?? 0
        let tax       = json["tax"]      as? Double
        let subtotRaw = json["subtotal"] as? Double ?? 0
        let rawCur    = json["currency"] as? String ?? ""
        let currency  = rawCur.isEmpty ? "USD" : rawCur

        var lineItems = [ReceiptLineItem]()
        if let rawItems = json["line_items"] as? [[String: Any]] {
            for item in rawItems {
                guard let name   = item["name"]   as? String,
                      let amount = item["amount"] as? Double,
                      !name.isEmpty, amount > 0 else { continue }
                let lower = name.lowercased()
                if paymentNoisePatterns.contains(where: { lower.contains($0) }) { continue }
                lineItems.append(ReceiptLineItem(
                    name: name, originalPrice: amount,
                    discount: 0, amount: amount, taxPortion: 0, isSelected: true
                ))
            }
        }

        let pretaxTarget: Double = subtotRaw > 0
            ? subtotRaw
            : (total > 0 && (tax ?? 0) > 0)
                ? round((total - (tax ?? 0)) * 100) / 100
                : total

        let itemsSum = lineItems.reduce(0.0) { $0 + $1.amount }
        let gap      = round((pretaxTarget - itemsSum) * 100) / 100
        if pretaxTarget > 0.01, gap > 0.01 {
            lineItems.append(ReceiptLineItem(
                name: "Missing Item(s)", originalPrice: gap, discount: 0,
                amount: gap, taxPortion: 0, isSelected: true
            ))
        }

        // Add tax as its own visible line item (no distribution into taxPortion)
        if let t = tax, t > 0 {
            lineItems.append(ReceiptLineItem(
                name: "Tax", originalPrice: t,
                discount: 0, amount: t, taxPortion: 0, isSelected: true
            ))
        }

        let finalSub = lineItems.reduce(0.0) { $0 + $1.amount }
        var confidence: Float = 0.6
        if !merchant.isEmpty  { confidence += 0.10 }
        if total > 0          { confidence += 0.15 }
        if !lineItems.isEmpty { confidence += 0.15 }

        return ReceiptData(
            merchant: merchant, amounts: lineItems.map(\.amount) + [total, tax ?? 0, subtotRaw].filter { $0 > 0 },
            hasReceiptStructure: true, confidence: min(confidence, 1.0),
            likelyTotal: total > 0 ? total : nil, lineItems: lineItems,
            processingMethod: .gptMini, receiptDate: dateStr, taxAmount: tax,
            subtotal: finalSub > 0 ? finalSub : nil, totalSavings: nil, isQuickResult: false, currency: currency
        )
    }

    // MARK: - Tabscanner

    private static func processWithTabscanner(
        image: UIImage,
        completion: @escaping (Result<(ReceiptData, [String: Any]), Error>) -> Void
    ) {
        guard !tabscannerAPIKey.isEmpty, tabscannerAPIKey != "YOUR_TABSCANNER_API_KEY_HERE" else {
            completion(.failure(nsError(-10, "Tabscanner API key not configured")))
            return
        }
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            completion(.failure(nsError(-1, "Failed to encode image")))
            return
        }
        submitToTabscanner(imageData: imageData) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let token):
                print("  Tabscanner token: \(token)")
                pollTabscanner(token: token, completion: completion)
            }
        }
    }

    private static func submitToTabscanner(
        imageData: Data,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req      = URLRequest(url: URL(string: "https://api.tabscanner.com/api/2/process")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(tabscannerAPIKey,                            forHTTPHeaderField: "apikey")
        req.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"documentType\"\r\n\r\nreceipt\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"receipt.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let e = error { completion(.failure(e)); return }
                guard
                    let data,
                    let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let token = json["token"] as? String
                else {
                    completion(.failure(nsError(-3, "No token from Tabscanner")))
                    return
                }
                completion(.success(token))
            }
        }.resume()
    }

    private static func pollTabscanner(
        token:      String,
        attempt:    Int = 0,
        completion: @escaping (Result<(ReceiptData, [String: Any]), Error>) -> Void
    ) {
        let delay: TimeInterval = attempt == 0 ? 5.0 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var req = URLRequest(url: URL(string: "https://api.tabscanner.com/api/result/\(token)")!)
            req.httpMethod = "GET"
            req.setValue(tabscannerAPIKey, forHTTPHeaderField: "apikey")
            req.timeoutInterval = 15

            URLSession.shared.dataTask(with: req) { data, response, error in
                DispatchQueue.main.async {
                    if let e = error { completion(.failure(e)); return }
                    guard let http = response as? HTTPURLResponse else {
                        completion(.failure(nsError(-4, "Invalid response"))); return
                    }
                    switch http.statusCode {
                    case 200:
                        guard let data else { completion(.failure(nsError(-5, "Empty 200 response"))); return }
                        do    { completion(.success(try parseTabscannerResponse(data: data))) }
                        catch { completion(.failure(error)) }
                    case 202:
                        print("  Tabscanner processing… attempt \(attempt + 1)")
                        if attempt < 15 {
                            pollTabscanner(token: token, attempt: attempt + 1, completion: completion)
                        } else {
                            completion(.failure(nsError(-6, "Tabscanner timeout after 15 attempts")))
                        }
                    default:
                        let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(http.statusCode)"
                        completion(.failure(nsError(-7, msg)))
                    }
                }
            }.resume()
        }
    }

    private static func parseTabscannerResponse(data: Data) throws -> (ReceiptData, [String: Any]) {
        guard
            let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any]
        else { throw nsError(-8, "Invalid Tabscanner response structure") }

        let merchant  = result["establishment"] as? String ?? ""
        let dateStr   = result["date"]          as? String
        let total     = result["total"]         as? Double ?? 0.0
        let subtotRaw = result["subTotal"]      as? Double ?? 0.0
        let rawCur    = result["currency"]      as? String ?? ""
        let currency  = rawCur.isEmpty ? (detectCurrency(from: result) ?? "USD") : rawCur

        var tax = result["tax"] as? Double
        if (tax ?? 0) == 0, let sumItems = result["summaryItems"] as? [[String: Any]] {
            let taxes: [Double] = sumItems.compactMap { item in
                guard let desc = item["descClean"] as? String,
                      let amt  = item["lineTotal"] as? Double, amt > 0 else { return nil }
                let l = desc.lowercased()
                guard (l.contains("tax") && !l.contains("tax id"))
                        || l.contains("hst") || l.contains("gst") || l.contains("pst")
                else { return nil }
                return amt
            }
            if !taxes.isEmpty { tax = taxes.max() }
        }

        var discountMap: [String: Double] = [:]
        var lineItems: [ReceiptLineItem] = []

        if let items = result["lineItems"] as? [[String: Any]] {
            for item in items {
                guard let tot  = item["lineTotal"]   as? Double,
                      let code = item["productCode"] as? String,
                      let syms = item["symbols"]     as? [String],
                      tot > 0, !code.isEmpty, syms.contains("-")
                else { continue }
                if let target = code.split(separator: "/").map(String.init).last {
                    discountMap[target] = tot
                }
            }
            for item in items {
                guard let desc    = item["descClean"] as? String,
                      let lineTot = item["lineTotal"] as? Double,
                      let syms    = item["symbols"]   as? [String],
                      !desc.isEmpty, lineTot > 0, !syms.contains("-")
                else { continue }

                let lower = desc.lowercased()
                if paymentNoisePatterns.contains(where: { lower.contains($0) }) { continue }
                if let lt = item["lineType"] as? String, !lt.isEmpty {
                    if ["total","subtotal","tax","tip","payment","discount","summary"].contains(lt.lowercased()) { continue }
                }
                let code     = item["productCode"] as? String ?? ""
                let discount = code.isEmpty ? 0.0 : (discountMap[code] ?? 0.0)
                lineItems.append(ReceiptLineItem(
                    name: desc, originalPrice: lineTot, discount: discount,
                    amount: lineTot - discount, taxPortion: 0, isSelected: true
                ))
                print("  TS item: \(desc): \(formatCurrency(lineTot - discount, currency: currency))")
            }
        }

        let pretaxTarget: Double = subtotRaw > 0
            ? subtotRaw
            : (total > 0 && (tax ?? 0) > 0)
                ? round((total - (tax ?? 0)) * 100) / 100
                : total

        let itemsSum = lineItems.reduce(0.0) { $0 + $1.amount }
        let gap      = round((pretaxTarget - itemsSum) * 100) / 100
        if pretaxTarget > 0.01, gap > 0.01 {
            lineItems.append(ReceiptLineItem(
                name: "Missing Item(s)", originalPrice: gap, discount: 0,
                amount: gap, taxPortion: 0, isSelected: true
            ))
        }

        if let t = tax, t > 0 {
            lineItems.append(ReceiptLineItem(
                name: "Tax", originalPrice: t,
                discount: 0, amount: t, taxPortion: 0, isSelected: true
            ))
        }
        

        let finalSub     = lineItems.reduce(0.0) { $0 + $1.amount }
        let tabConf      = result["totalConfidence"] as? Double ?? 0
        let totalSavings = lineItems.reduce(0.0) { $0 + $1.discount }

        return (ReceiptData(
            merchant:            merchant,
            amounts:             lineItems.map(\.amount) + [total, tax ?? 0, subtotRaw].filter { $0 > 0 },
            hasReceiptStructure: true,
            confidence:          Float(tabConf),
            likelyTotal:         total > 0 ? total : nil,
            lineItems:           lineItems,
            processingMethod:    .tabscanner,
            receiptDate:         dateStr,
            taxAmount:           tax,
            subtotal:            finalSub > 0 ? finalSub : nil,
            totalSavings:        totalSavings,
            isQuickResult:       false,
            currency:            currency
        ), json)
    }

    // MARK: - Transaction History (Apple Vision — local)

    private static func processTransactionHistory(
        from image: UIImage,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        guard let cgImage = image.cgImage else {
            completion(.failure(nsError(-1, "Failed to prepare image"))); return
        }
        let request = VNRecognizeTextRequest { req, _ in
            guard let obs = req.results as? [VNRecognizedTextObservation] else {
                completion(.failure(nsError(-2, "No text found"))); return
            }
            let lines = obs.compactMap { $0.topCandidates(1).first?.string }
            let txns  = parseTransactionLines(lines)
            guard !txns.isEmpty else {
                DispatchQueue.main.async { completion(.failure(nsError(-3, "No transactions found"))) }
                return
            }
            DispatchQueue.main.async {
                promptForAccountType { type in
                    completion(.success(finalizeTransactionData(transactions: txns, accountType: type)))
                }
            }
        }
        request.recognitionLevel = .accurate
        DispatchQueue.global(qos: .userInitiated).async {
            do    { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request]) }
            catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    private static func parseTransactionLines(_ lines: [String]) -> [TransactionItem] {
        var txns: [TransactionItem] = []
        let amtPat   = #"(-?\$?\s*\d{1,3}(?:,\d{3})*\.\d{2})"#
        let datePat1 = #"\d{1,2}/\d{1,2}/\d{2,4}"#
        let datePat2 = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\s+\d{1,2},\s*\d{4}"#
        var currentDesc = ""; var currentDate: String?; var prevLines: [String] = []

        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.count > 2 else { continue }

            if let r = line.range(of: datePat1, options: .regularExpression) {
                currentDate = String(line[r]); continue
            }
            if let r = line.range(of: datePat2, options: [.regularExpression, .caseInsensitive]) {
                currentDate = String(line[r]); continue
            }
            if let r = line.range(of: amtPat, options: .regularExpression) {
                let raw = String(line[r])
                    .replacingOccurrences(of: "$", with: "")
                    .replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let amt = Double(raw), abs(amt) > 0.01 {
                    var desc = line.replacingOccurrences(of: raw, with: "")
                        .replacingOccurrences(of: "$", with: "")
                        .replacingOccurrences(of: "-", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if desc.count < 3 {
                        desc = currentDesc.isEmpty
                            ? prevLines.suffix(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                            : currentDesc
                    }
                    desc = desc.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
                    let noise = ["statement","eligible","pay over time","balance","available"]
                    if !noise.contains(where: { desc.lowercased().contains($0) }), !desc.isEmpty {
                        txns.append(TransactionItem(
                            description: desc.isEmpty ? "Transaction" : desc,
                            amount:      abs(amt),
                            date:        currentDate,
                            isDebit:     amt < 0
                        ))
                        currentDesc = ""; currentDate = nil; prevLines.removeAll()
                    }
                }
            } else {
                let clean = line.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
                if clean.contains(where: { $0.isLetter }), clean.count >= 3 {
                    currentDesc = clean; prevLines.append(clean)
                }
            }
        }
        return txns
    }

    private static var accountTypeCompletion: ((AccountType) -> Void)?

    private static func promptForAccountType(completion: @escaping (AccountType) -> Void) {
        accountTypeCompletion = completion
        NotificationCenter.default.post(name: NSNotification.Name("RequestAccountType"), object: nil)
    }

    static func setAccountType(_ t: AccountType)  { accountTypeCompletion?(t); accountTypeCompletion = nil }
    static func cancelAccountTypeSelection()      { accountTypeCompletion = nil }

    private static func finalizeTransactionData(transactions: [TransactionItem], accountType: AccountType) -> TransactionData {
        var items = [TransactionItem](); var debits = 0.0; var credits = 0.0
        for t in transactions {
            var ft = t
            if accountType == .creditCard { ft.isDebit = !t.isDebit }
            if ft.isDebit { debits += t.amount } else { credits += t.amount }
            items.append(ft)
        }
        return TransactionData(items: items, accountType: accountType,
                               totalDebits: debits, totalCredits: credits, confidence: 0.85)
    }

    // MARK: - Apple Vision Fallback

    private static func fallbackProcessing(
        image: UIImage,
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        guard let cgImage = image.cgImage else {
            completion(.failure(nsError(-11, "Failed to process image"))); return
        }
        let req = VNRecognizeTextRequest { r, _ in
            guard let obs = r.results as? [VNRecognizedTextObservation] else {
                completion(.failure(nsError(-12, "No text found"))); return
            }
            let lines = obs.compactMap { $0.topCandidates(1).first?.string }
            completion(.success(parseBasic(rawText: lines.joined(separator: "\n"))))
        }
        req.recognitionLevel = .accurate
        DispatchQueue.global(qos: .userInitiated).async {
            do    { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req]) }
            catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    private static func parseBasic(rawText: String) -> ReceiptData {
        let lines = rawText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var merchant = ""; var allAmounts = [Double](); var tax: Double?; var subtotal: Double?

        for line in lines.prefix(5) {
            let c = line.trimmingCharacters(in: .whitespaces)
            if c.count >= 3, c.count <= 50,
               Double(c.filter { $0.isLetter || $0.isWhitespace }.count) / Double(c.count) > 0.5 {
                merchant = c; break
            }
        }
        let total = findTotal(in: lines, allAmounts: &allAmounts, tax: &tax, subtotal: &subtotal)
        return ReceiptData(
            merchant: merchant, amounts: allAmounts, hasReceiptStructure: true,
            confidence: 0.5, likelyTotal: total, lineItems: [],
            processingMethod: .visionFallback, receiptDate: nil,
            taxAmount: tax, subtotal: subtotal, totalSavings: nil,
            isQuickResult: false, currency: "USD"
        )
    }

    // MARK: - Public Convenience API

    static func extractText(
        from image: UIImage,
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        processDocument(from: image) { result in
            switch result {
            case .success(let any):
                if let data = any as? ReceiptData {
                    completion(.success(data))
                } else {
                    completion(.failure(nsError(-1, "Unexpected result type")))
                }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    static func extractLineItems(
        from image: UIImage,
        completion: @escaping (Result<[ReceiptLineItem], Error>) -> Void
    ) {
        extractText(from: image) { result in
            switch result {
            case .success(let d):
                d.lineItems.isEmpty
                    ? completion(.failure(nsError(-4, "No line items found")))
                    : completion(.success(d.lineItems))
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    static func isLikelyReceipt(
        image: UIImage,
        completion: @escaping (Bool, String?) -> Void
    ) {
        extractText(from: image) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let d):
                    if !d.amounts.isEmpty && !d.merchant.isEmpty && d.confidence > 0.5 {
                        completion(true, nil)
                    } else if d.amounts.isEmpty {
                        completion(false, "No transaction amounts found.")
                    } else {
                        completion(false, "Unable to read receipt. Please try a clearer photo.")
                    }
                case .failure:
                    completion(false, "Unable to process this image.")
                }
            }
        }
    }

    // MARK: - Shared Utilities

    private static func emptyReceiptData(method: ProcessingMethod) -> ReceiptData {
        ReceiptData(
            merchant: "", amounts: [], hasReceiptStructure: false, confidence: 0,
            likelyTotal: nil, lineItems: [], processingMethod: method,
            receiptDate: nil, taxAmount: nil, subtotal: nil,
            totalSavings: nil, isQuickResult: false, currency: "USD"
        )
    }

    private static func distributeTax(lineItems: [ReceiptLineItem], totalTax: Double) -> [ReceiptLineItem] {
        let sub = lineItems.reduce(0.0) { $0 + $1.amount }
        guard sub > 0 else { return lineItems }
        var out = [ReceiptLineItem](); var dist = 0.0
        for (i, item) in lineItems.enumerated() {
            var copy = item
            copy.taxPortion = i == lineItems.count - 1
                ? round((totalTax - dist) * 100) / 100
                : round((item.amount / sub) * totalTax * 100) / 100
            dist += copy.taxPortion
            out.append(copy)
        }
        return out
    }

    private static func detectCurrency(from result: [String: Any]) -> String? {
        let text = [result["establishment"] as? String ?? "", result["address"] as? String ?? ""].joined()
        if text.range(of: "\\p{Hangul}",                 options: .regularExpression) != nil { return "KRW" }
        if text.range(of: "\\p{Hiragana}|\\p{Katakana}", options: .regularExpression) != nil { return "JPY" }
        if text.range(of: "\\p{Han}",                    options: .regularExpression) != nil { return "CNY" }
        if let addr    = result["addressNorm"] as? [String: Any],
           let country = addr["country"]       as? String {
            let map: [String: String] = [
                "GB":"GBP","UK":"GBP","CA":"CAD","AU":"AUD","JP":"JPY","KR":"KRW",
                "CN":"CNY","AE":"AED","CH":"CHF","HK":"HKD","BR":"BRL","ZA":"ZAR",
                "DE":"EUR","FR":"EUR","IT":"EUR","ES":"EUR","NL":"EUR"
            ]
            if let c = map[country.uppercased()] { return c }
        }
        return nil
    }

    static func formatAmount(_ amount: Double, currency: String) -> String { formatCurrency(amount, currency: currency) }

    static func formatCurrency(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle  = .currency
        f.currencyCode = currency
        f.locale       = Locale(identifier: currencyLocale(for: currency))
        return f.string(from: NSNumber(value: amount))
            ?? "\(currencySymbol(for: currency))\(String(format: "%.2f", amount))"
    }

    private static func currencySymbol(for c: String) -> String {
        switch c {
        case "USD","CAD","AUD": return "$"
        case "EUR": return "€"; case "GBP": return "£"
        case "JPY","CNY": return "¥"; case "CHF": return "Fr"
        case "HKD": return "HK$"; case "KRW": return "₩"
        case "BRL": return "R$"; case "ZAR": return "R"
        default: return "$"
        }
    }

    private static func currencyLocale(for c: String) -> String {
        switch c {
        case "USD": return "en_US"; case "EUR": return "en_DE"; case "GBP": return "en_GB"
        case "JPY": return "ja_JP"; case "KRW": return "ko_KR"; case "CNY": return "zh_CN"
        case "CAD": return "en_CA"; case "AUD": return "en_AU"; case "CHF": return "de_CH"
        case "HKD": return "zh_HK"; case "BRL": return "pt_BR"; case "ZAR": return "en_ZA"
        default: return "en_US"
        }
    }

    private static func findTotal(
        in lines:   [String],
        allAmounts: inout [Double],
        tax:        inout Double?,
        subtotal:   inout Double?
    ) -> Double? {
        for line in lines { allAmounts.append(contentsOf: extractAmounts(from: line)) }
        var candidates = [(Double, Int)]()
        for line in lines {
            let lower = line.lowercased()
            if (lower.contains("tax") && !lower.contains("tax id"))
                || lower.contains("hst") || lower.contains("gst") {
                if let a = extractAmounts(from: line).last, a > 0 { tax = a }
            }
            if lower.contains("subtotal") || lower.contains("sub total") {
                if let a = extractAmounts(from: line).last, a > 0 { subtotal = a }
            }
            if lower.contains("total") && !lower.contains("subtotal") {
                if let a = extractAmounts(from: line).last, a > 0 { candidates.append((a, 1)) }
            }
        }
        candidates.sort { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 > $1.0) }
        return candidates.first?.0 ?? allAmounts.filter { $0 > 0 }.max()
    }

    private static func extractAmounts(from text: String) -> [Double] {
        var results = [Double]()
        let decimalPattern = #"(-?\$?\s*\d{1,3}(?:,\d{3})*\.\d{2})\b"#
        if let regex = try? NSRegularExpression(pattern: decimalPattern) {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range(at: 1))
                    .replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: "$", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let v = Double(s), abs(v) >= 0.01, abs(v) < 100_000 {
                    results.append(round(v * 100) / 100)
                }
            }
        }
        if results.isEmpty {
            let wholePattern = #"(?<!\d)(\d{1,3}(?:,\d{3})+)(?!\d|\.)"#
            if let regex = try? NSRegularExpression(pattern: wholePattern) {
                let ns = text as NSString
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let s = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
                    if let v = Double(s), v >= 100, v < 10_000_000 { results.append(v) }
                }
            }
        }
        return results
    }

    private static func nsError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "OCRService", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - String Extension

extension String {
    func ranges(of searchString: String, options: String.CompareOptions = []) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var startIndex = self.startIndex
        while startIndex < self.endIndex,
              let range = self.range(of: searchString, options: options, range: startIndex..<self.endIndex) {
            ranges.append(range)
            startIndex = range.upperBound
        }
        return ranges
    }
}
