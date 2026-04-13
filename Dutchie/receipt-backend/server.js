import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import { Mistral } from "@mistralai/mistralai";
import { z } from "zod";
import { responseFormatFromZodObject } from "@mistralai/mistralai/extra/structChat.js";

dotenv.config();

const app = express();
app.use(cors());
app.use(express.json({ limit: "20mb" }));

const PORT = Number(process.env.PORT || 3001);
const APP_BEARER_TOKEN = process.env.APP_BEARER_TOKEN || "";
const MISTRAL_API_KEY = process.env.MISTRAL_API_KEY || "";
const TEMP_DIR = path.resolve(process.cwd(), "tmp_receipts");

// ============================================================
// ENVIRONMENT VALIDATION
// ============================================================

if (!APP_BEARER_TOKEN) {
  console.error("❌ Missing APP_BEARER_TOKEN in environment");
  process.exit(1);
}

if (!MISTRAL_API_KEY) {
  console.error("❌ Missing MISTRAL_API_KEY in environment");
  process.exit(1);
}

fs.mkdirSync(TEMP_DIR, { recursive: true });

const client = new Mistral({ apiKey: MISTRAL_API_KEY });

console.log("\n" + "=".repeat(80));
console.log("  PRODUCTION RECEIPT PARSER - MISTRAL OCR + CONTRADICTION RESOLVER");
console.log("=".repeat(80));
console.log(`  Port: ${PORT}`);
console.log(`  Environment: ${process.env.NODE_ENV || "development"}`);
console.log(`  Auth: ${APP_BEARER_TOKEN ? "✓" : "✗"}`);
console.log(`  Mistral API: ${MISTRAL_API_KEY ? "✓" : "✗"}`);
console.log("=".repeat(80) + "\n");

// ============================================================
// ZOD SCHEMAS - PRODUCTION GRADE
// ============================================================

const ConfidenceEnum = z.enum(["high", "medium", "low"]);
const StatusEnum = z.enum(["success", "partial", "needs_review"]);
const SourceEnum = z.enum(["model", "deterministic", "merged"]);

const ReceiptItemSchema = z.object({
  name: z.string().describe("Item name as shown on receipt"),
  amount: z.number().describe("FINAL charged amount after item-level discounts"),
  originalAmount: z.number().nullable().optional().describe("Amount before item-level discount"),
  itemDiscount: z.number().nullable().optional().describe("Discount amount applied to this specific item (positive number)"),
  qty: z.number().nullable().optional().describe("Quantity purchased"),
  unitPrice: z.number().nullable().optional().describe("Price per unit before discounts"),
  weightLbs: z.number().nullable().optional().describe("Weight in pounds for weighted items"),
  confidence: ConfidenceEnum.optional().describe("Extraction confidence for this item"),
  source: SourceEnum.optional().describe("Where this item came from: model, deterministic, or merged"),
});

const MistralReceiptSchema = z.object({
  merchant: z.string().describe("Merchant name from top of receipt"),
  receiptDate: z.string().nullable().optional().describe("Receipt date YYYY-MM-DD format"),
  currency: z.string().describe("Currency code (USD, CAD, EUR, etc.)"),
  items: z.array(ReceiptItemSchema).describe("Purchased items with final prices after item-level discounts"),
  subtotal: z.number().nullable().optional().describe("Subtotal if explicitly shown"),
  tax: z.number().nullable().optional().describe("Sales tax amount"),
  tip: z.number().nullable().optional().describe("Tip/gratuity amount"),
  fees: z.number().nullable().optional().describe("Service fees, delivery fees, bag fees, etc."),
  orderLevelDiscount: z.number().nullable().optional().describe("Order-wide discounts (not item-specific)"),
  grandTotal: z.number().nullable().optional().describe("Final total (BALANCE DUE, GRAND TOTAL, etc.)"),
  confidence: ConfidenceEnum.describe("Overall extraction confidence"),
  notes: z.string().nullable().optional().describe("Parsing notes or warnings"),
});

// ============================================================
// MISTRAL EXTRACTION PROMPT
// ============================================================

const EXTRACTION_PROMPT = `You are a production-grade receipt data extraction system.

Extract receipt data into structured JSON with EXACT financial accuracy.

CRITICAL RULES:
1. NEVER invent data not visible on the receipt
2. Item amounts must be FINAL prices after item-level discounts
3. Distinguish item-level discounts from order-level discounts
4. Do not include payment methods, totals, or metadata as items
5. Only extract fields clearly supported by OCR text
6. Financial accuracy > completeness - if uncertain, use null

ITEM EXTRACTION:
- Items are purchased products: EGGS, MILK, BREAD, etc.
- Each item needs: name (string) and amount (number)
- Amount = final charged price after any item-level discount

Example - Item with discount:
  STEAK 25.00
  MEMBER DISCOUNT -5.00
  → Extract ONE item: name="STEAK", amount=20.00, originalAmount=25.00, itemDiscount=5.00

Example - Weighted item:
  APPLES 1.2 lb @ 2.99/lb 3.59
  → name="APPLES", amount=3.59, qty=1.2, weightLbs=1.2, unitPrice=2.99

Example - Multi-quantity:
  YOGURT 4 @ 1.25
  → name="YOGURT", amount=5.00, qty=4, unitPrice=1.25

NOT ITEMS:
- VISA, MASTERCARD, AMEX → payment method
- TOTAL, SUBTOTAL, BALANCE DUE → summary
- TAX, TIP, FEE → charges (separate fields)
- YOU SAVED, TOTAL SAVINGS → discount (orderLevelDiscount or itemDiscount)
- AUTH CODE, APPROVAL → metadata

DISCOUNT TYPES:

1. Item-Level Discount (reduce item amount):
   - Appears directly after specific item
   - Keywords: "You saved", "Member savings", "Instant savings", "Coupon"
   - Action: Reduce the item's amount field and set itemDiscount

2. Order-Level Discount (orderLevelDiscount field):
   - Appears in totals section
   - Keywords: "TOTAL SAVINGS", "ORDER DISCOUNT", "PROMOTIONAL DISCOUNT"
   - Action: Put in orderLevelDiscount field, NOT in items

MULTI-LINE MERGING:
OCR often splits items across lines - merge them carefully:
- "O EGGS VF PSTR RS" + "7.99 NF" → ONE item: name="EGGS VF PSTR RS", amount=7.99
- Weighted produce across multiple lines → merge into single item with weight info
- Item + discount line immediately after → merge into one item with reduced amount

TOTAL PRIORITY (choose strongest):
1. BALANCE DUE
2. GRAND TOTAL
3. TOTAL
4. AMOUNT DUE
5. TOTAL DUE

Ignore payment processor totals if clearer receipt total exists.

CONFIDENCE:
- "high": Clear extraction, clean OCR, no ambiguity, math likely correct
- "medium": Some merged lines or minor uncertainties, but credible
- "low": OCR issues, unclear items, ambiguous structure, or likely math mismatch

CRITICAL FINANCIAL VALIDATION:
Before returning, verify: sum(items) + tax + tip + fees - orderLevelDiscount ≈ grandTotal
If this doesn't match, re-check your item amounts and discount classification.

Return clean JSON. Do not invent fields. Prioritize correctness over completeness.`;

// ============================================================
// UTILITY FUNCTIONS
// ============================================================

function round2(value) {
  if (value == null) return null;
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}

function toNumber(value) {
  if (value == null) return null;
  const num = Number(value);
  return isNaN(num) ? null : round2(num);
}

function normalizeMerchant(merchant) {
  if (!merchant) return "";
  return merchant
    .toUpperCase()
    .trim()
    .replace(/\s+/g, " ")
    .substring(0, 100);
}

function normalizeItemName(name) {
  if (!name) return "Unknown Item";
  
  let normalized = name.trim();
  normalized = normalized.replace(/^[O*\-•]\s+/, "");
  normalized = normalized.replace(/\s+(NF|N F|T|TX|F|E|B|A)$/i, "");
  normalized = normalized.replace(/\s+/g, " ");
  
  return normalized.substring(0, 200);
}

function isPaymentLine(text) {
  const lower = text.toLowerCase().trim();
  const paymentKeywords = [
    "visa", "mastercard", "amex", "discover", "debit", "credit",
    "card", "approved", "approval", "auth code", "authorization",
    "aid:", "tvr:", "tsi:", "rrn:"
  ];
  return paymentKeywords.some(kw => lower.includes(kw));
}

function isTotalLine(text) {
  const lower = text.toLowerCase().trim();
  
  // CRITICAL FIX: Exclude lines with weight/volume measurements (these are products!)
  if (/\d+\s*(oz|lb|g|kg|ml|l)\b/i.test(text)) {
    return false;
  }
  
  const totalKeywords = [
    "total", "subtotal", "balance due", "amount due", "grand total",
    "order total", "transaction total", "sum", "net"
  ];
  
  // CRITICAL FIX: Use word boundaries to prevent partial matches
  // "POTATO STARCH" should NOT match "TOTAL"
  return totalKeywords.some(kw => {
    const regex = new RegExp(`\\b${kw}\\b`, 'i');
    return regex.test(lower);
  }) && !lower.includes("items");
}

function isChargeLine(text) {
  const lower = text.toLowerCase().trim();
  const chargeKeywords = [
    "tax", "tip", "gratuity", "fee", "service", "delivery", 
    "hst", "gst", "pst", "vat", "sales tax"
  ];
  return chargeKeywords.some(kw => lower.includes(kw));
}

function isDiscountLine(text) {
  const lower = text.toLowerCase().trim();
  const discountKeywords = [
    "discount", "savings", "saved", "coupon", "promo", "promotion",
    "instant savings", "member savings", "store coupon", "you saved"
  ];
  return discountKeywords.some(kw => lower.includes(kw));
}

function hasRefundIndicators(text) {
  const lower = text.toLowerCase();
  return /\b(refund|return|returned|void|credit)\b/.test(lower);
}

// ============================================================
// STAGE 2: PRIMARY OCR / STRUCTURED PARSE
// ============================================================

async function callMistralOCR(imageBuffer, mimeType, reqId) {
  console.log(`[${reqId}] Calling Mistral OCR (single-pass)...`);
  
  const base64Image = imageBuffer.toString("base64");
  const dataUrl = `data:${mimeType};base64,${base64Image}`;

  const result = await client.ocr.process({
    model: "mistral-ocr-latest",
    document: {
      type: "image_url",
      imageUrl: dataUrl,
    },
    documentAnnotationFormat: responseFormatFromZodObject(MistralReceiptSchema),
    documentAnnotationPrompt: EXTRACTION_PROMPT,
  });

  const ocrText = result.pages.map(page => page.markdown).join("\n\n");
  
  let parsed = null;
  if (result.documentAnnotation) {
    try {
      parsed = JSON.parse(result.documentAnnotation);
      console.log(`[${reqId}] ✓ Structured extraction successful`);
    } catch (err) {
      console.log(`[${reqId}] ⚠️ Failed to parse documentAnnotation: ${err.message}`);
    }
  } else {
    console.log(`[${reqId}] ⚠️ No documentAnnotation returned`);
  }

  return { parsed, ocrText, result };
}

// ============================================================
// STAGE 3: DETERMINISTIC RECEIPT NORMALIZATION
// ============================================================

function normalizeParsedReceipt(parsed) {
  if (!parsed) return null;

  return {
    merchant: normalizeMerchant(parsed.merchant),
    receiptDate: parsed.receiptDate || null,
    currency: parsed.currency || "USD",
    items: (parsed.items || []).map(item => ({
      name: normalizeItemName(item.name),
      amount: round2(item.amount),
      originalAmount: toNumber(item.originalAmount),
      itemDiscount: toNumber(item.itemDiscount),
      qty: toNumber(item.qty),
      unitPrice: toNumber(item.unitPrice),
      weightLbs: toNumber(item.weightLbs),
      confidence: item.confidence || "medium",
      source: item.source || "model",
    })),
    subtotal: toNumber(parsed.subtotal),
    tax: toNumber(parsed.tax),
    tip: toNumber(parsed.tip),
    fees: toNumber(parsed.fees),
    orderLevelDiscount: toNumber(parsed.orderLevelDiscount),
    grandTotal: toNumber(parsed.grandTotal),
    confidence: parsed.confidence || "medium",
    notes: parsed.notes || null,
  };
}

function filterNonItems(items, ocrText) {
  const filtered = [];
  const rejected = [];

  for (const item of items) {
    const name = item.name.toLowerCase();
    
    if (isPaymentLine(name)) {
      rejected.push({ item, reason: "payment_line" });
      continue;
    }
    
    if (isTotalLine(name)) {
      rejected.push({ item, reason: "total_line" });
      continue;
    }
    
    if (isChargeLine(name)) {
      rejected.push({ item, reason: "charge_line" });
      continue;
    }
    
    if (isDiscountLine(name)) {
      rejected.push({ item, reason: "discount_line" });
      continue;
    }
    
    if (item.amount == null || item.amount < 0.01) {
      rejected.push({ item, reason: "invalid_amount" });
      continue;
    }
    
    if (!item.name || item.name.trim().length < 2) {
      rejected.push({ item, reason: "no_name" });
      continue;
    }
    
    filtered.push(item);
  }

  return { filtered, rejected };
}

// ============================================================
// STAGE 4: SUSPICIOUS ITEM DETECTION
// ============================================================

function detectSuspiciousItems(items, orderLevelDiscount, reqId) {
  const suspicious = [];

  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const amount = item.amount ?? 0;
    
    // Flag 1: Tiny amounts under $1.00
    const isTiny = amount > 0 && amount < 1.0;
    
    // Flag 2: Find if there's a same-name item with larger amount
    const sameNameLarger = items.find((other, idx) =>
      idx !== i &&
      other.name.toLowerCase() === item.name.toLowerCase() &&
      (other.amount ?? 0) > amount
    );
    
    // Flag 3: Amount matches orderLevelDiscount
    const matchesOrderDiscount = orderLevelDiscount != null && 
      orderLevelDiscount > 0 && 
      Math.abs(amount - orderLevelDiscount) <= 0.01;
    
    // Build suspicion profile
    const flags = [];
    if (isTiny) flags.push("tiny_amount");
    if (sameNameLarger) flags.push("duplicate_name_larger_exists");
    if (matchesOrderDiscount) flags.push("matches_order_discount");
    
    // Calculate suspicion score
    let suspicionScore = 0;
    if (isTiny) suspicionScore += 1;
    if (sameNameLarger) suspicionScore += 2;
    if (matchesOrderDiscount) suspicionScore += 3;
    
    if (flags.length > 0) {
      suspicious.push({
        index: i,
        item,
        flags,
        suspicionScore,
        sameNameLarger: sameNameLarger || null,
      });
    }
  }

  if (suspicious.length > 0) {
    console.log(`[${reqId}] Detected ${suspicious.length} suspicious items:`);
    suspicious.forEach(s => {
      console.log(`[${reqId}]   - "${s.item.name}" ($${s.item.amount}): ${s.flags.join(", ")} [score: ${s.suspicionScore}]`);
    });
  }

  return suspicious;
}

// ============================================================
// STAGE 5: RECONCILIATION ENGINE (FIXED)
// ============================================================

function reconcileReceipt(normalized) {
  const items = normalized.items || [];
  const subtotal = normalized.subtotal;
  const tax = normalized.tax ?? 0;
  const tip = normalized.tip ?? 0;
  const fees = normalized.fees ?? 0;
  const orderDiscount = normalized.orderLevelDiscount ?? 0;
  const grandTotal = normalized.grandTotal;

  const itemSum = round2(items.reduce((sum, item) => sum + (item.amount || 0), 0));
  const calculatedFromItems = round2(itemSum + tax + tip + fees - orderDiscount);

  let calculatedFromSubtotal = null;
  if (subtotal != null) {
    calculatedFromSubtotal = round2(subtotal + tax + tip + fees - orderDiscount);
  }

  const subtotalGap = subtotal != null ? round2(Math.abs(itemSum - subtotal)) : null;
  const totalGapFromItems = grandTotal != null ? round2(Math.abs(calculatedFromItems - grandTotal)) : null;
  const totalGapFromSubtotal = grandTotal != null && calculatedFromSubtotal != null 
    ? round2(Math.abs(calculatedFromSubtotal - grandTotal)) 
    : null;

  // CRITICAL FIX: Don't let subtotal hide missing items!
  // Always validate items first, then validate subtotal against grand total
  let bestTotalGap = totalGapFromItems;
  let mathCheckPassed = false;
  
  // If items don't match subtotal, something is wrong with item extraction
  const hasSubtotalMismatch = subtotalGap != null && subtotalGap > 0.01;
  
  if (hasSubtotalMismatch) {
    // Items don't sum to subtotal - FAIL
    bestTotalGap = totalGapFromItems;
    mathCheckPassed = false;
  } else if (totalGapFromItems != null && totalGapFromItems <= 0.01) {
    // Items + charges = grand total (perfect!)
    bestTotalGap = totalGapFromItems;
    mathCheckPassed = true;
  } else if (totalGapFromSubtotal != null && totalGapFromSubtotal <= 0.01 && !hasSubtotalMismatch) {
    // Subtotal + charges = grand total AND items = subtotal (also perfect!)
    bestTotalGap = totalGapFromSubtotal;
    mathCheckPassed = true;
  }

  const mismatchReasons = [];
  if (hasSubtotalMismatch) {
    mismatchReasons.push(`item_sum_vs_subtotal_gap_$${subtotalGap.toFixed(2)}`);
  }
  if (bestTotalGap != null && bestTotalGap > 0.01) {
    mismatchReasons.push(`total_gap_$${bestTotalGap.toFixed(2)}`);
  }
  if (grandTotal == null) {
    mismatchReasons.push("no_grand_total");
  }
  if (items.length === 0) {
    mismatchReasons.push("no_items_extracted");
  }

  const itemBreakdown = items.map((item, idx) => {
    const parts = [];
    parts.push(`${item.name}: $${item.amount.toFixed(2)}`);
    
    if (item.qty != null) parts.push(`qty=${item.qty}`);
    if (item.unitPrice != null) parts.push(`unit=$${item.unitPrice.toFixed(2)}`);
    if (item.weightLbs != null) parts.push(`weight=${item.weightLbs}lb`);
    if (item.originalAmount != null) parts.push(`original=$${item.originalAmount.toFixed(2)}`);
    if (item.itemDiscount != null && item.itemDiscount > 0) parts.push(`item_discount=$${item.itemDiscount.toFixed(2)}`);
    
    return `  ${idx + 1}. ${parts.join(", ")}`;
  });

  return {
    itemSum: round2(itemSum),
    subtotalGap,
    totalGap: bestTotalGap,
    calculatedFromItems: round2(calculatedFromItems),
    calculatedFromSubtotal,
    mathCheckPassed,
    mismatchReasons,
    itemBreakdown,
  };
}

// ============================================================
// STAGE 6: REPAIR CANDIDATE BUILDER
// ============================================================

function buildRepairCandidates(normalized, suspicious, reqId) {
  const candidates = [];

  // Candidate 0: Original interpretation (baseline)
  candidates.push({
    label: "original",
    receipt: normalized,
    changes: [],
  });

  // Candidate 1: Drop each highly suspicious item
  suspicious
    .filter(s => s.suspicionScore >= 3)
    .forEach(s => {
      candidates.push({
        label: `drop_suspicious_item_${s.index}`,
        receipt: {
          ...normalized,
          items: normalized.items.filter((_, idx) => idx !== s.index),
        },
        changes: [`Removed suspicious item: "${s.item.name}" ($${s.item.amount})`],
      });
    });

  // Candidate 2: Drop suspicious item AND clear orderLevelDiscount if they match
  suspicious
    .filter(s => s.flags.includes("matches_order_discount"))
    .forEach(s => {
      candidates.push({
        label: `drop_item_and_clear_discount_${s.index}`,
        receipt: {
          ...normalized,
          items: normalized.items.filter((_, idx) => idx !== s.index),
          orderLevelDiscount: 0,
        },
        changes: [
          `Removed suspicious item: "${s.item.name}" ($${s.item.amount})`,
          `Cleared orderLevelDiscount (was $${normalized.orderLevelDiscount ?? 0})`,
        ],
      });
    });

  // Candidate 3: Clear orderLevelDiscount only (if it exists)
  if ((normalized.orderLevelDiscount ?? 0) > 0) {
    candidates.push({
      label: "clear_order_discount",
      receipt: {
        ...normalized,
        orderLevelDiscount: 0,
      },
      changes: [`Cleared orderLevelDiscount (was $${normalized.orderLevelDiscount})`],
    });
  }

  // Candidate 4: Drop ALL tiny duplicates with same-name-larger pattern
  const tinyDuplicates = suspicious.filter(s => 
    s.flags.includes("tiny_amount") && 
    s.flags.includes("duplicate_name_larger_exists")
  );
  
  if (tinyDuplicates.length > 0) {
    const indicesToRemove = tinyDuplicates.map(s => s.index);
    candidates.push({
      label: "drop_all_tiny_duplicates",
      receipt: {
        ...normalized,
        items: normalized.items.filter((_, idx) => !indicesToRemove.includes(idx)),
      },
      changes: tinyDuplicates.map(s => 
        `Removed tiny duplicate: "${s.item.name}" ($${s.item.amount})`
      ),
    });
  }

  console.log(`[${reqId}] Built ${candidates.length} repair candidates`);

  return candidates;
}

// ============================================================
// STAGE 7: INTERPRETATION SCORER
// ============================================================

function scoreInterpretation(candidate, reqId) {
  const reconciliation = reconcileReceipt(candidate.receipt);
  
  // Primary score: total gap (lower is better)
  let score = reconciliation.totalGap ?? 999;
  
  // Secondary penalty: subtotal gap
  if (reconciliation.subtotalGap != null) {
    score += reconciliation.subtotalGap * 0.5;
  }
  
  // Penalty for having no items
  if (candidate.receipt.items.length === 0) {
    score += 1000;
  }
  
  // Small bonus for math check passed
  if (reconciliation.mathCheckPassed) {
    score -= 0.01;
  }

  return {
    ...candidate,
    reconciliation,
    score: round2(score),
  };
}

// ============================================================
// STAGE 8: CONTRADICTION RESOLVER (MAIN LOGIC)
// ============================================================

function resolveFinancialContradictions(normalized, reqId) {
  console.log(`[${reqId}] Starting financial contradiction resolution...`);
  
  // Step 1: Detect suspicious items
  const suspicious = detectSuspiciousItems(
    normalized.items, 
    normalized.orderLevelDiscount, 
    reqId
  );

  if (suspicious.length === 0) {
    console.log(`[${reqId}] No suspicious items detected - using original interpretation`);
    return {
      receipt: normalized,
      selectedCandidate: "original",
      candidatesTried: 1,
      suspicious: [],
      changes: [],
    };
  }

  // Step 2: Build repair candidates
  const candidates = buildRepairCandidates(normalized, suspicious, reqId);

  // Step 3: Score each candidate
  const scored = candidates.map(c => scoreInterpretation(c, reqId));

  // Step 4: Sort by score (lowest = best)
  scored.sort((a, b) => a.score - b.score);

  // Step 5: Log scoring results
  console.log(`[${reqId}] Candidate scores:`);
  scored.forEach(c => {
    console.log(`[${reqId}]   - ${c.label}: score=${c.score.toFixed(3)}, gap=$${c.reconciliation.totalGap?.toFixed(2) ?? "N/A"}, math=${c.reconciliation.mathCheckPassed ? "✓" : "✗"}`);
  });

  // Step 6: Select best candidate
  const best = scored[0];
  console.log(`[${reqId}] ✓ Selected: ${best.label} (score: ${best.score.toFixed(3)})`);

  if (best.changes.length > 0) {
    console.log(`[${reqId}] Changes applied:`);
    best.changes.forEach(change => console.log(`[${reqId}]   - ${change}`));
  }

  return {
    receipt: best.receipt,
    selectedCandidate: best.label,
    candidatesTried: candidates.length,
    suspicious,
    changes: best.changes,
    allCandidates: scored,
  };
}

// ============================================================
// STAGE 9: CONFIDENCE + STATUS
// ============================================================

function determineParseStatus(reconciliation, normalized, hasRefund, resolutionResult) {
  let confidence = normalized.confidence || "medium";
  let status = "success";

  // Downgrade for refund indicators
  if (hasRefund) {
    confidence = "low";
    status = "needs_review";
  }

  // Status based on reconciliation
  if (reconciliation.mathCheckPassed && normalized.items.length > 0) {
    status = "success";
  } else if (reconciliation.mismatchReasons.length > 0 && normalized.items.length > 0) {
    status = "partial";
    confidence = confidence === "high" ? "medium" : "low";
  } else {
    status = "needs_review";
    confidence = "low";
  }

  // Adjust confidence based on contradiction resolution
  if (resolutionResult.selectedCandidate !== "original") {
    // Applied a repair - slightly lower confidence
    confidence = confidence === "high" ? "medium" : confidence;
  }

  if (reconciliation.totalGap != null) {
    if (reconciliation.totalGap > 5.00) {
      confidence = "low";
    } else if (reconciliation.totalGap > 1.00) {
      confidence = confidence === "high" ? "medium" : "low";
    }
  }

  if (normalized.items.length === 0) {
    confidence = "low";
    status = "needs_review";
  }

  return { confidence, status };
}

function buildApiResponse(parseResult, timings, reqId) {
  const { parsed, ocrText, result, reconciliation, rejected, resolutionResult } = parseResult;

  if (!parsed) {
    return {
      error: "No structured data could be extracted",
      merchant: "",
      items: [],
      confidence: "low",
      status: "needs_review",
      route: "extraction_failed",
      routeReason: "no_structured_output_from_mistral",
      timings,
    };
  }

  const hasRefund = hasRefundIndicators(ocrText);
  const { confidence, status } = determineParseStatus(reconciliation, parsed, hasRefund, resolutionResult);

  let route = "mistral_single_pass";
  let routeReason = "exact_reconciliation";

  if (resolutionResult.selectedCandidate !== "original") {
    route = "mistral_with_contradiction_repair";
    routeReason = `applied_${resolutionResult.selectedCandidate}`;
  }

  if (status === "success" && reconciliation.mathCheckPassed) {
    routeReason = reconciliation.mathCheckPassed ? "exact_reconciliation" : routeReason;
  } else if (status === "partial") {
    routeReason = reconciliation.mismatchReasons.join(", ") || "partial_extraction";
  } else if (status === "needs_review") {
    routeReason = "reconciliation_failed_or_no_items";
  }

  return {
    merchant: parsed.merchant || "",
    receiptDate: parsed.receiptDate,
    currency: parsed.currency || "USD",
    items: parsed.items.map(item => ({
      name: item.name,
      amount: item.amount,
      qty: item.qty,
      unitPrice: item.unitPrice,
      weightLbs: item.weightLbs,
      confidence: item.confidence,
    })),
    subtotal: parsed.subtotal,
    tax: parsed.tax,
    tip: parsed.tip,
    fees: parsed.fees,
    grandTotal: parsed.grandTotal,
    confidence,
    status,
    notes: parsed.notes,
    reconciliation: {
      itemSum: reconciliation.itemSum,
      subtotalGap: reconciliation.subtotalGap,
      totalGap: reconciliation.totalGap,
      calculatedFromItems: reconciliation.calculatedFromItems,
      calculatedFromSubtotal: reconciliation.calculatedFromSubtotal,
      mathCheckPassed: reconciliation.mathCheckPassed,
      mismatchReasons: reconciliation.mismatchReasons,
    },
    route,
    routeReason,
    timings,
    debug: {
      parser_version: "production_v2_contradiction_resolver_fixed",
      model_used: result?.model || "mistral-ocr-latest",
      ocr_text_length: ocrText.length,
      ocr_text: ocrText,
      rejected_items: rejected || [],
      has_refund_indicators: hasRefund,
      contradiction_resolution: {
        suspicious_items_detected: resolutionResult.suspicious.length,
        suspicious_items: resolutionResult.suspicious.map(s => ({
          name: s.item.name,
          amount: s.item.amount,
          flags: s.flags,
          suspicion_score: s.suspicionScore,
        })),
        candidates_tried: resolutionResult.candidatesTried,
        selected_candidate: resolutionResult.selectedCandidate,
        changes_applied: resolutionResult.changes,
      },
      arithmetic_breakdown: {
        items_detail: reconciliation.itemBreakdown,
        formula: `sum(items) + tax + tip + fees - orderDiscount = calculated`,
        calculation: `${reconciliation.itemSum} + ${parsed.tax ?? 0} + ${parsed.tip ?? 0} + ${parsed.fees ?? 0} - ${parsed.orderLevelDiscount ?? 0} = ${reconciliation.calculatedFromItems}`,
        vs_grand_total: `${reconciliation.calculatedFromItems} vs ${parsed.grandTotal ?? "null"}`,
        gap: reconciliation.totalGap != null ? `$${reconciliation.totalGap.toFixed(2)}` : "N/A",
      },
    },
  };
}

// ============================================================
// API ENDPOINTS
// ============================================================

function requireAppAuth(req, res, next) {
  const authHeader = req.headers.authorization || "";
  if (authHeader !== `Bearer ${APP_BEARER_TOKEN}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
}

app.post("/parse-receipt", requireAppAuth, async (req, res) => {
  const reqId = `req_${Date.now().toString(36)}`;
  const startedAt = Date.now();
  let tempImagePath = null;

  console.log("\n" + "=".repeat(80));
  console.log(`[${reqId}] RECEIPT PARSE REQUEST (WITH CONTRADICTION RESOLUTION)`);
  console.log("=".repeat(80));

  try {
    const { imageBase64, mimeType = "image/jpeg" } = req.body || {};

    if (!imageBase64) {
      console.log(`[${reqId}] ✗ Missing imageBase64`);
      return res.status(400).json({ error: "Missing imageBase64 in request body" });
    }

    let base64Data = imageBase64;
    const idx = base64Data.indexOf("base64,");
    if (idx >= 0) {
      base64Data = base64Data.slice(idx + 7);
    }

    const buffer = Buffer.from(base64Data, "base64");
    console.log(`[${reqId}] Image size: ${(buffer.length / 1024).toFixed(2)} KB`);

    if (buffer.length < 128) {
      console.log(`[${reqId}] ✗ Image too small`);
      return res.status(400).json({ error: "Image too small or corrupt" });
    }

    const ext = mimeType.includes("png") ? ".png" : ".jpg";
    const filename = `receipt_${Date.now()}_${Math.random().toString(36).slice(2)}${ext}`;
    tempImagePath = path.join(TEMP_DIR, filename);
    await fs.promises.writeFile(tempImagePath, buffer);

    // OCR + Normalization
    const parseStart = Date.now();
    const { parsed, ocrText, result } = await callMistralOCR(buffer, mimeType, reqId);
    
    let normalized = null;
    let rejected = [];
    let resolutionResult = null;
    
    if (parsed) {
      normalized = normalizeParsedReceipt(parsed);
      const filterResult = filterNonItems(normalized.items, ocrText);
      normalized.items = filterResult.filtered;
      rejected = filterResult.rejected;

      // Contradiction resolution layer
      resolutionResult = resolveFinancialContradictions(normalized, reqId);
      normalized = resolutionResult.receipt;
    }

    // Reconciliation
    const reconciliation = normalized ? reconcileReceipt(normalized) : {
      itemSum: null,
      subtotalGap: null,
      totalGap: null,
      calculatedFromItems: null,
      calculatedFromSubtotal: null,
      mathCheckPassed: false,
      mismatchReasons: ["no_data_extracted"],
      itemBreakdown: [],
    };

    const parseMs = Date.now() - parseStart;
    const totalMs = Date.now() - startedAt;

    // Enhanced logging
    console.log(`[${reqId}] Final Results:`);
    console.log(`[${reqId}]   - Items: ${normalized?.items.length || 0} (${rejected.length} rejected)`);
    
    if (reconciliation.itemBreakdown && reconciliation.itemBreakdown.length > 0) {
      console.log(`[${reqId}]   - Item Details:`);
      reconciliation.itemBreakdown.forEach(line => console.log(`[${reqId}]     ${line}`));
    }
    
    console.log(`[${reqId}]   - Subtotal: $${normalized?.subtotal?.toFixed(2) ?? "null"}`);
    console.log(`[${reqId}]   - Tax: $${normalized?.tax?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Tip: $${normalized?.tip?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Fees: $${normalized?.fees?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Order Discount: $${normalized?.orderLevelDiscount?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Item Sum: $${reconciliation.itemSum?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Calculated Total: $${reconciliation.calculatedFromItems?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Grand Total (receipt): $${normalized?.grandTotal?.toFixed(2) ?? "null"}`);
    console.log(`[${reqId}]   - Math check: ${reconciliation.mathCheckPassed ? "✓ PASS" : "✗ FAIL"}`);
    console.log(`[${reqId}]   - Total gap: $${reconciliation.totalGap?.toFixed(2) ?? "N/A"}`);

    if (rejected.length > 0) {
      console.log(`[${reqId}]   - Rejected items:`);
      rejected.forEach(r => console.log(`[${reqId}]     • ${r.item.name} ($${r.item.amount}) - ${r.reason}`));
    }

    const response = buildApiResponse(
      { parsed: normalized, ocrText, result, reconciliation, rejected, resolutionResult },
      { parse_ms: parseMs, total_ms: totalMs },
      reqId
    );

    console.log(`[${reqId}] ✓ Complete in ${totalMs}ms`);
    console.log(`[${reqId}] Status: ${response.status} | Confidence: ${response.confidence}`);
    console.log(`[${reqId}] Route: ${response.route}`);
    console.log("=".repeat(80) + "\n");

    return res.json(response);

  } catch (error) {
    console.error(`[${reqId}] ✗ ERROR:`, error);
    return res.status(500).json({
      error: "Failed to parse receipt",
      detail: error?.message || "unknown_error",
    });
  } finally {
    if (tempImagePath) {
      try {
        await fs.promises.unlink(tempImagePath);
      } catch {}
    }
  }
});

app.get("/health", (req, res) => {
  res.json({
    ok: true,
    timestamp: new Date().toISOString(),
    version: "2.0.1",
    parser: "production_mistral_contradiction_resolver_fixed",
  });
});

// ============================================================
// SERVER STARTUP
// ============================================================

app.listen(PORT, "0.0.0.0", () => {
  console.log("✓ Server ready on http://0.0.0.0:" + PORT);
  console.log("  Endpoint: POST /parse-receipt (with contradiction resolution)");
  console.log("  Health: GET /health\n");
});