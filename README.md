# Dutchi

> **Split bills with friends — scan, split, settle in seconds.**

Dutchi is a production iOS app built in Swift and SwiftUI that eliminates the friction of splitting shared expenses. Point your camera at a receipt, choose who's splitting, and Dutchi calculates the minimum number of payments needed to settle everyone's debt — then sends Venmo and Zelle deep-links directly to your friends' phones.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [OCR Pipeline](#ocr-pipeline)
- [Settlement Algorithm](#settlement-algorithm)
- [Data Model](#data-model)
- [Navigation](#navigation)
- [Features](#features)
- [Setup](#setup)
- [Tech Stack](#tech-stack)

---

## Overview

Dutchi solves a deceptively hard product problem: getting from a crumpled receipt photo to a settled group payment request in as few taps as possible. Most competing apps require manual item entry or accept fuzzy totals. Dutchi instead runs a multi-stage OCR pipeline that combines on-device Vision, Tabscanner, and GPT-4o-mini — selecting the right engine based on real-time image quality signals — to extract structured line items automatically, including merchant name, per-item amounts, tax, discounts, and total.

The settlement engine runs a greedy debt-consolidation algorithm that minimises the number of payment edges in the group graph. A six-person dinner that naively requires fifteen payments is reduced to at most five.

---

## Architecture

Dutchi uses a **unidirectional data flow** pattern. A single `AppState` object — a `@MainActor`-bound `ObservableObject` — is the single source of truth for all mutable application state. It is injected at the root via `.environmentObject(_:)` and consumed by views at any depth without prop-drilling.

```
App Entry Point
    └── AppState         (@MainActor ObservableObject, persisted to UserDefaults)
    └── Router           (@MainActor ObservableObject, owns NavigationPath)
    └── TutorialManager  (ObservableObject, coordinates cross-view tutorial state)

Navigation Stack (NavigationStack + NavigationPath)
    UploadView → PeopleView → ProcessingView → ReviewView → SettleShareView
                                                    ↑
                                               ProfileView (modal sheet)
```

### AppState

`AppState` is the application's model layer. It owns:

| Property | Type | Role |
|---|---|---|
| `profile` | `Profile` | Persisted user identity and payment methods |
| `uploadedReceipts` | `[UploadedReceipt]` | In-flight OCR results awaiting review |
| `transactions` | `[Transaction]` | Confirmed items ready to split |
| `people` | `[Person]` | Current session participants |
| `manualTransactions` | `[(name, amount)]` | Items entered without a receipt |
| `savedGroups` | `[Group]` | Quick-groups persisted across sessions |

Profile serialisation separates the large `splitHistory` array into its own `UserDefaults` key so the main profile object stays small and decodes quickly at launch. A hand-rolled `Codable` implementation in `Profile` handles three generations of schema transparently — the legacy `phoneNumber` key is silently promoted to `zelleContactInfo`, and the old `paymentQRCode` field is promoted to `venmoQRCode` — so users upgrading from older builds never lose data.

### Router

`Router` wraps SwiftUI's `NavigationPath` with typed navigation methods (`navigateToReview()`, `navigateToSettle()`, etc.) and owns the `showProfile` flag driving the modal profile sheet. This keeps views free of raw string identifiers and makes navigation logic testable in isolation. The `handleTutorialNavigation(for:)` method centralises all tutorial-driven navigation so `TutorialManager` never imports any view type.

### TutorialManager

The tutorial system coordinates an 8-step onboarding sequence across five separate views without any view knowing about the others. It does this through three mechanisms:

1. **`@Published var currentStepIndex`** — views observe this and show/hide overlays reactively.
2. **`registerFrame(_:for:)`** — views register their bounding rects in global coordinates so the spotlight mask can cut the correct region out of the darkened overlay, including multi-target spotlights that expose two UI regions simultaneously.
3. **Signal buses** (`shouldOpenBreakdownSheet`, `shouldAutoApplyBreakdown`) — `TutorialManager` posts signals that individual views subscribe to, avoiding direct coupling between the manager and view internals.

A `isNavigatingToSettle` guard flag prevents a race condition where `ReviewView`'s `onDisappear` fires during a Router pop+push and incorrectly calls `complete()` mid-flow before `SettleShareView` has appeared.

---

## OCR Pipeline

The pipeline runs in `OCRService` and selects its strategy dynamically based on a document type hint and real-time image quality. All heavy work happens off the main thread; results are dispatched back via `@MainActor`.

```
User selects image
        │
        ├─ hint == .transactionHistory ─────────────────► Apple Vision (on-device)
        │                                                        │
        │                                                  parseTransactionLines()
        │                                                  promptForAccountType()
        │
        └─ hint == .receipt / .unknown
                │
                ├── GPT-4o-mini classify (parallel) ──► receipt | transaction | neither
                └── Apple Vision quick-total  (parallel) ──► (total, merchant)
                        │
                        └── both complete
                                │
                                ├── neither    ─────────────────► reject with reason
                                ├── transaction ────────────────► re-route to Vision path
                                └── receipt
                                        │
                                        QualityScorer.evaluate(image)
                                        │
                                        ├── Vision got no total ──► GPT immediate full extraction
                                        │                          (fires onStatusUpdate "low_quality_gpt:")
                                        │
                                        └── Vision has total
                                                │
                                                fire quickResult (isQuickResult=true) ──► completion (< 200ms)
                                                │
                                                └── background OCR (async, non-blocking)
                                                        │
                                                        ├── isSufficientForTabscanner == true
                                                        │       ├── Tabscanner API
                                                        │       └── on failure ──► GPT fallback
                                                        └── isSufficientForTabscanner == false
                                                                └── GPT-4o-mini
                                                        │
                                                        storeBackgroundResult(data, for: token)
```

### Two-Phase Result Delivery

The pipeline delivers results in two phases to keep the UI responsive. Phase one fires immediately with a `ReceiptData` where `isQuickResult = true` — it carries the Vision-extracted total and merchant name, enough to render a thumbnail card in `UploadView` within ~200ms of the image being selected. Phase two fires asynchronously (typically 3–8 seconds later) with the full structured result from Tabscanner or GPT, stored in a thread-safe dictionary keyed on a `backgroundResultToken` UUID.

`ReviewView` fetches the full result lazily via `OCRService.fetchBackgroundResult(for:)` when the user opens the breakdown sheet. If the result is already cached the call returns synchronously; if the background job is still running the callback is queued and fired on completion. After a 60-second timeout the view falls back to a fresh synchronous OCR call as a safety net.

This design means the user never waits at a blocking spinner — they can continue adding receipts, adding people, and navigating while extraction runs in parallel.

### Image Quality Scoring

`QualityScorer` evaluates five independent signals before choosing an OCR engine:

| Signal | Metric | Failure Threshold |
|---|---|---|
| Blur | Laplacian variance on a 256×256 grayscale downsample | < 80.0 |
| Luminance | Mean pixel intensity (CIFilter → CGContext pipeline) | < 0.15 or > 0.92 |
| Contrast | RMS contrast | < 0.08 |
| Resolution | Total pixel count | < 400,000 px |
| Skew | Median angle from `VNDetectTextRectanglesRequest` bounding boxes | > 15° |

Scores are combined with weights (blur 35%, luminance 20%, skew 15%, contrast 15%, resolution 15%) into a composite `[0, 1]` score. A score ≥ 0.85 with no individual failures routes to Tabscanner; anything lower routes to GPT-4o-mini. A `requiresGPTForTotal` flag is raised when two or more severe quality failures co-occur — this bypasses the quick-result phase entirely and blocks until GPT returns a reliable total, preventing the user from seeing a wrong amount briefly then having it corrected.

### Transaction History Parsing

Bank and credit card statements are processed fully on-device with `VNRecognizeTextRequest` at `.accurate` level. The parser uses three coordinated regex patterns — decimal amounts `(-?\$?\d{1,3}(?:,\d{3})*\.\d{2})`, date strings in two formats, and description lines — to reconstruct `TransactionItem` records from unstructured OCR text. Because credit card statements represent purchases as positive charges (increasing the balance) while debit statements show them as negative (decreasing it), the polarity of all `isDebit` flags is inverted when `accountType == .creditCard` after the user confirms the account type via a native prompt.

---

## Settlement Algorithm

`AppState.calculateSettlements()` implements a greedy debt-minimisation algorithm running in O(n log n) time where n is the number of participants.

**Step 1 — Build a balance vector.** For each transaction, every person in `splitWith` owes their proportional share to the payer. Shares respect the optional `splitQuantities` multiplier map — the Advanced Split feature — which allows one participant to be assigned 2× or 3× the base share (e.g. someone who ordered two entrees).

```swift
let share = transaction.amount * (units / totalUnits)
balances[person.id]  -= share   // person owes this much
balances[paidById]   += share   // payer is owed this much
```

**Step 2 — Partition.** Separate the balance vector into creditors (positive balance, are owed money) and debtors (negative balance, owe money), sorted by magnitude descending.

**Step 3 — Greedy two-pointer settlement.** Match the largest creditor against the largest debtor. Emit a `PaymentLink` for `min(credit, abs(debit))`, reduce both balances by that amount, and advance whichever pointer reaches zero. This produces the minimum number of directed payment edges for any debt graph — at most `n - 1` payments for `n` participants, regardless of how many transactions are involved.

---

## Data Model

### `Transaction`

The core unit of work. Carries a reference to `paidBy: Person`, `splitWith: [Person]`, an optional `receiptImage: Data`, `lineItems: [ReceiptLineItem]`, and a `backgroundResultToken: String?` that threads the OCR cache reference from `UploadView` through `AppState` all the way to `ReviewView`. The `weightedAmount(for:)` method computes a specific person's share respecting any custom multipliers without exposing `splitQuantities` to callers. `hasCustomSplit` is a derived property that signals the UI to show split percentage labels.

### `ReceiptLineItem`

Represents a single parsed line on a receipt. Tracks `originalPrice`, `discount`, `amount` (post-discount), and `taxPortion` independently so the breakdown sheet can display accurate per-item totals with tax while the settlement engine works cleanly from pre-tax item amounts. The `id` property is excluded from `CodingKeys` so re-hydrated items always get fresh UUIDs, avoiding identity collisions when the same receipt is processed twice.

### `Profile`

Fully `Codable` with a custom decoder handling three schema generations. Payment method visibility is controlled by optional `venmoShared` / `zelleQRShared` booleans that default to `true` via computed `isVenmoShared` / `isZelleQRShared` accessors, so new installs get sharing enabled without a migration path. The `splitHistory` array is stored under a separate `UserDefaults` key and is capped at 20 records to bound storage growth. Duplicate detection uses a `contentHash` derived from settlement amounts and participant counts, guarded by a 5-minute window, to avoid creating multiple identical records when the view re-appears.

### `PaymentLink`

An ephemeral model (not persisted) representing a directed payment edge in the settlement graph — from debtor to creditor with a specific amount. `SettleShareView` constructs Venmo deep links (`venmo://paycharge?txn=pay&recipients=username&amount=X&note=...`) and Zelle universal links from the receiver's profile at share time. Multiple outstanding debts for the current user are queued and presented as sequential `PaymentPromptView` sheets so the user can action each one without losing their place.

### `Person`

`Hashable` and `Codable`, identified by stable `UUID`. Carries an optional `contactImage: Data` for avatar rendering and an optional `phoneNumber` for direct iMessage composition. `initials` is a derived property used by `AvatarView` as a fallback when no contact photo is available.

---

## Navigation

Dutchi uses SwiftUI's `NavigationStack` with a type-erased `NavigationPath`. `Router` provides a typed API so no view ever contains raw string identifiers or switch statements on navigation destinations.

The user flow is linear with one persistent modal branch:

```
Logo intro (one-time, dismissed via Router.dismissLogoIntro())
    ↓
UploadView         — scan receipts, add manual items, batch photo processing
    ↓
PeopleView         — add participants from Contacts or by name, manage quick groups
    ↓
ProcessingView     — bridges UploadedReceipts → Transactions (keeps ReviewView clean)
    ↓
ReviewView         — edit transactions, trigger receipt breakdown, advanced split
    ↓
SettleShareView    — payment graph, Venmo/Zelle deep links, share sheet, history save

ProfileView        — modal sheet, accessible at any step via avatar button
```

`ProcessingView` exists as a dedicated transition screen that runs `appState.makeTransaction(from:)` for each receipt and calls `router.navigateToReview()` on completion. This boundary keeps `ReviewView` free of any upload or OCR logic and makes the data handoff explicit.

---

## Features

### Multi-Image Batch Processing
`MultiImagePicker` wraps `PHPickerViewController` with `selectionLimit = 0` and a `DispatchGroup` to collect results in original selection order. A queue-based processing loop runs images sequentially, updating a progress bar and processing message after each completion. The `processingToken` integer cancels stale callbacks when the user cancels mid-batch.

### Advanced Split
The Advanced Split sheet allows per-person quantity multipliers on any transaction. The live preview recomputes all percentages and dollar amounts on every `+`/`-` tap using `PersonQuantity.share(in:)` — a pure function that computes `quantity / totalUnits` — so the UI always reflects the exact weighted split without any stale state.

### Receipt Breakdown
When the breakdown button is tapped in `ReviewView`, the view checks the background result cache before starting any network call. If the full OCR result is already cached, the sheet opens with all line items immediately. If still processing, the sheet opens in a loading state showing the Vision-extracted total so the user sees a confirmed amount while line items load. The sheet supports inline name and amount editing for every line item, gap detection with a "Missing Item(s)" placeholder, and one-tap addition of tax as a standalone splittable line.

### Group Persistence
`PeopleStorageManager` persists recent individual contacts and named groups to `UserDefaults` independently of `AppState`. This means quick-group data survives session resets. The `GroupRow` component implements swipe-to-delete via a `DragGesture` with spring snapping, an inline chip-selection grid so the user can add a partial group in a single gesture, and a quantity badge showing how many members are selected before confirming.

### Payment Deep Links
`SettleShareView` composes per-payment message strings containing Venmo `venmo://` URLs, Zelle universal links extracted from QR codes via `QRCodeScanner`, and a plain-text fallback for SMS. When the current user is the debtor, the app surfaces a `PaymentPromptView` sheet offering Venmo or Zelle directly. Multiple outstanding debts are queued in `pendingSettlementQueue` and presented sequentially, one sheet at a time.

### Onboarding Tutorial
An 8-step tutorial coordinates across five views using `GeometryReader` preference keys (`TutorialFrameKey`) for single-target spotlights and a polling `registerFrame(_:for:)` mechanism for multi-target spotlights. The overlay uses `compositingGroup()` and `.blendMode(.destinationOut)` to punch transparent holes in the darkened background at exact UI coordinates. Tutorial mock data is fully cleared on completion — all injected transactions, receipts, and non-user people are removed — so the tutorial leaves zero trace in the real session.

---

## Setup

### Prerequisites

- Xcode 15+
- iOS 16+ deployment target
- CocoaPods (`gem install cocoapods`)

### Installation

```bash
git clone <repo-url>
cd Dutchi
pod install
open Dutchi.xcworkspace
```

### API Keys

Create `Dutchi/Config.xcconfig` (this file is gitignored):

```
OPENAI_API_KEY = sk-proj-...
TABSCANNER_API_KEY = your-key-here
```

Add to `Info.plist`:

```xml
<key>OPENAI_API_KEY</key>
<string>$(OPENAI_API_KEY)</string>
<key>TABSCANNER_API_KEY</key>
<string>$(TABSCANNER_API_KEY)</string>
```

Assign `Config.xcconfig` to both Debug and Release in **Xcode → Project → Info → Configurations**. Clean build after any `.xcconfig` change (`⇧⌘K`).

### External APIs

| Service | Purpose | Docs |
|---|---|---|
| OpenAI GPT-4o-mini | Receipt classification and full structured extraction (JSON Schema mode) | [platform.openai.com](https://platform.openai.com/docs) |
| Tabscanner | High-confidence structured receipt parsing with line-item confidence scores | [tabscanner.com](https://tabscanner.com/api) |

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 5.9 |
| UI Framework | SwiftUI (declarative, adaptive dark/light mode) |
| On-device OCR | Apple Vision (`VNRecognizeTextRequest`, `VNDetectTextRectanglesRequest`) |
| Image quality analysis | Core Image (`CILanczosScaleTransform`), Core Graphics |
| Receipt parsing | Tabscanner REST API (multipart upload + polling) |
| AI extraction | OpenAI GPT-4o-mini (vision input, JSON Schema structured outputs) |
| Contacts | Contacts framework (`CNContactPickerViewController`, `PHPickerViewController`) |
| Messaging | MessageUI (`MFMessageComposeViewController`) |
| Animations | Lottie (onboarding), SwiftUI spring physics |
| Persistence | `UserDefaults` (profile, history, recent people, groups) |
| State management | `@MainActor ObservableObject` + `@EnvironmentObject` + `@Published` |
| Navigation | `NavigationStack` + type-erased `NavigationPath` |
| Haptics | `UIImpactFeedbackGenerator`, `UINotificationFeedbackGenerator` |
| Dependency management | CocoaPods |
| Minimum iOS | iOS 16 |

---

## Author

**Taehoon Kang** — Founder, Dutchi
