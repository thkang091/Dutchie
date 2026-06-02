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
const ItemCategoryEnum = z.enum([
  "produce",
  "meat_seafood",
  "dairy_eggs",
  "bakery",
  "pantry",
  "frozen",
  "beverages",
  "snacks",
  "prepared_food",
  "household",
  "personal_care",
  "health_wellness",
  "pet",
  "baby",
  "alcohol",
  "restaurant",
  "general_merchandise",
  "other",
]);

const ReceiptItemSchema = z.object({
  name: z.string().describe("Item name as shown on receipt"),
  amount: z.number().describe("FINAL charged amount after item-level discounts"),
  originalAmount: z.number().nullable().optional().describe("Amount before item-level discount"),
  itemDiscount: z.number().nullable().optional().describe("Discount amount applied to this specific item (positive number)"),
  itemDiscountLabel: z.string().nullable().optional().describe("Visible label for the item-specific discount, such as coupon, member savings, or instant savings"),
  itemCode: z
    .string()
    .nullable()
    .optional()
    .describe("Retailer item number or SKU printed directly next to the item, if visible"),
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

const NormalizedItemNameSchema = z.object({
  index: z.number().int(),
  original: z.string(),
  normalizedName: z.string(),
  confidence: z.number().min(0).max(1),
  ambiguous: z.boolean(),
  needsVerification: z.boolean(),
  possibleAlternatives: z.array(z.string()),
  reason: z.string(),
  category: ItemCategoryEnum,
  categoryConfidence: z.number().min(0).max(1),
  categoryReason: z.string(),
});

const ItemNameNormalizationResponseSchema = z.object({
  items: z.array(NormalizedItemNameSchema),
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
  → Extract ONE item: name="STEAK", amount=20.00, originalAmount=25.00, itemDiscount=5.00, itemDiscountLabel="MEMBER DISCOUNT"

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
   - Often appears on the next line, indented line, or paired line before the next purchased item
   - Keywords: "You saved", "Member savings", "Instant savings", "Coupon", "Digital coupon", "Store coupon", "Sale", "Promo"
   - Action: Reduce the item's amount field and set itemDiscount
   - Preserve the visible discount text in itemDiscountLabel when present
   - itemDiscount must be a positive number, even if the receipt prints the discount as negative

2. Order-Level Discount (orderLevelDiscount field):
   - Appears in totals section
   - Keywords: "TOTAL SAVINGS", "ORDER DISCOUNT", "PROMOTIONAL DISCOUNT"
   - Action: Put in orderLevelDiscount field, NOT in items

DISCOUNT ACCURACY:
- If an item has a printed price followed by a specific discount line, originalAmount is the printed price before discount.
- The final item amount must equal originalAmount - itemDiscount.
- Do not create a separate item for a discount line.
- Do not drop an item-specific discount just because a total savings line also exists.
- If the receipt only shows "YOU SAVED" or "TOTAL SAVINGS" without a clear item attachment, classify it as orderLevelDiscount or notes, not itemDiscount.
- If uncertain whether a discount belongs to a specific item, keep the item amount visible on the purchased item and mention the uncertainty in notes.

MULTI-LINE MERGING:
OCR often splits items across lines - merge them carefully:
- "O EGGS VF PSTR RS" + "7.99 NF" → ONE item: name="EGGS VF PSTR RS", amount=7.99
- Weighted produce across multiple lines → merge into single item with weight info
- Item + discount line immediately after → merge into one item with reduced amount

ITEM CODE:
- If a retailer item number or SKU is visibly printed next to a purchased item, extract it as itemCode.
- Preserve leading zeros.
- Treat itemCode as a string.
- If no item code is visible, use null.
- Never invent an item code.

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

const ITEM_NAME_NORMALIZATION_PROMPT = `You are a conservative receipt item normalization engine.

Your task is to convert OCR-extracted receipt item text into a clean, concise, human-readable label using only information directly supported by the input text.

You do not have access to web search, product catalogs, retailer databases, or external tools.

Your goal is readability, not exact product identification.

You also assign a simple split-friendly category so people can scan and divide the receipt faster.

CORE PRINCIPLE

When uncertain, preserve the original meaning instead of guessing.

A shorter generic label is better than a specific but unsupported product name.

INPUT FORMAT

You receive a JSON object:

{
  "merchant": "string",
  "items": [
    {
      "index": 0,
      "raw_name": "string",
      "item_code": "string or null",
      "price": 0.00
    }
  ]
}

The merchant, item_code, and price are metadata.

Do not use item_code, price, or merchant name to invent product details.
Use raw_name as the primary evidence. You may use common receipt vocabulary, obvious OCR repair, and widely recognized retail brand/category signals only when the raw text strongly supports them.

NORMALIZATION RULES

1. Expand only clear and widely recognized receipt abbreviations.

Safe abbreviation examples:
- KS -> Kirkland Signature
- ORG -> Organic
- CKN -> Chicken
- GUAC -> Guacamole
- SNGL -> Single-Serve
- FR -> Free-Range
- ABF -> Antibiotic-Free
- ROT -> Rotisserie
- LB -> lb
- OZ -> oz
- PK -> Pack
- CT -> Count
- ZIPLC -> Ziploc
- TOV -> Tomatoes on the Vine
- SLCD -> Sliced
- EVOO -> Extra Virgin Olive Oil
- BROCC -> Broccoli
- PTTO -> Potato
- YLW -> Yellow
- PROBIC -> Probiotic
- PROBIO -> Probiotic
- PROBIOT -> Probiotic
- PROB -> Probiotic when attached to a supplement, vitamin, or probiotic brand token

2. Preserve unclear tokens instead of guessing.

Examples:
- SKO 5X -> SKO 5X
- TERRA DLYSSA -> Terra Dlyssa
- ORG MORNING -> Organic Morning
- ORG MEDITERR -> Organic Mediterr
- SPCL -> Special

3. Remove receipt-only offer, promo, and pricing fragments from normalizedName when they are not part of the item identity.

Examples:
- RAO'S 2/31.7 -> Rao's
- RAC'S 2/31.7 -> Rao's
- RAOS 2 FOR 31.70 -> Rao's
- CULTURELLE BO 2/$30 -> Culturelle Probiotic

Do not include:
- 2/31.7
- 2 FOR
- 2/$
- BOGO
- EA
- regular price / sale price markers
- taxability letters

4. Use conservative brand and category recognition when directly supported by raw_name.

This is allowed:
- Correct obvious OCR misspellings of a brand when the raw token is very close to the brand.
- Add a broad product category when the raw brand/token strongly and commonly identifies that category.
- Expand a visible abbreviated category token such as PROBIC, PROBIO, PROBIOT, or PROB to Probiotic.

This is not allowed:
- Use external lookup, product catalogs, retailer APIs, or web search.
- Use price to identify a product.
- Use merchant alone to decide the item category.
- Add flavor, count, size, animal type, package type, or product variant unless printed in raw_name.

Brand/category examples:
- CULTURELLE BO -> Culturelle Probiotic
  Culturelle is a probiotic brand and BO is an unclear trailing token. Keep the label concise.

- CULTRELLE PROB -> Culturelle Probiotic
  Correct the obvious OCR brand typo and expand PROB.

- NB PROBIC 70 -> NB Probiotic 70
  Expand PROBIC, preserve NB because it is not enough evidence to expand the brand.

- RAC'S 2/31.7 -> Rao's
  Correct the obvious OCR confusion and remove the offer/pricing fragment.

- RAOS -> Rao's
  Add the apostrophe because the raw token clearly supports the brand.

5. Do not use memorized knowledge of a brand or product to add unsupported details beyond conservative brand/category recognition.

Examples:
- AUSSIE BITES -> Aussie Bites
  Do not add "Dog Treats", "Organic", or a package size unless stated.

- TERRA DLYSSA -> Terra Dlyssa
  Do not add "Olive Oil", "Yogurt", or "Drink" unless stated.

- ZIPLC SLIDER -> Ziploc Slider
  Do not add "Bags", "Sandwiches", "Frozen Appetizers", or food-related details unless stated.

- TIRE EXT. -> Tire Ext.
  Do not expand it into "Tire Extension Kit", "Fire Extinguisher", or another specific product.

6. Do not invent:
- product type
- animal type
- flavor
- package count
- unit size
- weight
- brand
- dietary attribute
- preparation method
- category-specific details

unless directly supported by raw_name.

Exception: a broad category may be used when raw_name contains a strong brand/category signal as described above, such as Culturelle -> Probiotic.

7. Never use price to infer:
- weight
- quantity
- package size
- product category
- product quality
- product identity

8. Never use merchant context alone to infer a product.

A Costco receipt does not mean every item is Kirkland Signature.
A grocery receipt does not mean every unclear item is food.
A brand-like phrase does not reveal the exact product type.

9. Correct OCR only when the intended text is highly obvious.

Safe OCR corrections:
- BANANASS -> Bananas
- TENDERION -> Tenderloin
- ORGSPRINGMIX -> Organic Spring Mix
- SPAGHTTI -> Spaghetti
- CHOPONION -> Chopped Onion
- CHIPTLE -> Chipotle
- ONTO -> Onion only when strongly supported by context such as VIDALIA ONTO
- CULTRELLE -> Culturelle
- CULTUREL -> Culturelle
- PROBIC -> Probiotic
- PROBIO -> Probiotic
- RAOS -> Rao's
- RAO S -> Rao's
- RAC'S -> Rao's only when the token is brand-like and paired with grocery/sauce-style receipt text or promo fragments

Unsafe OCR corrections:
- SKO 5X -> Skoal Bandits 5-Pack
- TERRA DLYSSA -> Terra Delyssa Olive Oil
- TIRE EXT. -> Fire Extinguisher
- ORG MORNING -> Organic Morning Blend Coffee
- ZIPLC SLIDER -> Ziploc Slider Bags

10. If an abbreviation has multiple reasonable interpretations:
- preserve the unclear token or use a generic expansion
- set ambiguous to true
- set needsVerification to true
- lower confidence
- include alternatives only when directly supported by the text

11. Do not create alternatives merely to fill the array.
Return an empty array when reliable alternatives are unavailable.

12. Do not include unsupported speculation inside normalizedName.

Never include:
- likely
- probably
- possibly
- maybe
- parenthetical guesses
- explanatory notes

13. Keep normalizedName concise.
Usually use 1 to 7 words.

IMPORTANT EDGE CASES

- TENDERLOIN -> Tenderloin
  Do not infer beef, pork, chicken, or lamb.
  Mark ambiguous because the animal type is unclear.

- ORG 4BRY 5LB -> Organic 4-Berry, 5 lb
  Do not convert 4BRY into Blueberries.
  Do not add "Blend" unless explicitly stated.

- ABF CKN CUBE -> Antibiotic-Free Cubed Chicken
  ABF means Antibiotic-Free.
  Do not expand ABF into Airline Breast.

- AUSSIE BITES -> Aussie Bites
  Do not infer that it is a dog treat.

- ZIPLC SLIDER -> Ziploc Slider
  Do not infer whether it is a bag, sandwich, or food product.

- TIRE EXT. -> Tire Ext.
  Preserve the unclear abbreviation.
  Do not guess the full product name.

- CULTURELLE BO -> Culturelle Probiotic
  Use the widely recognized probiotic brand signal. Do not include BO unless it is clearly meaningful.

- NB PROBIC 70 -> NB Probiotic 70
  Expand PROBIC to Probiotic. Preserve NB and 70 because they are printed; do not invent the full brand name.

- RAC'S 2/31.7 -> Rao's
  Correct the obvious OCR brand confusion and remove the promo/pricing fragment.

- RAOS 2 FOR 31.70 -> Rao's
  Normalize the brand and remove the offer fragment.

CONFIDENCE GUIDELINES

1.00
- Exact readable text with no abbreviation or ambiguity
- Example: BANANAS -> Bananas

0.95 to 0.99
- Clear standard abbreviation expansion
- Example: ROT CHKN -> Rotisserie Chicken
- Example: KS ORG TOFU -> Kirkland Signature Organic Tofu

0.85 to 0.94
- Strong OCR cleanup or obvious abbreviation expansion with minor uncertainty
- Example: CHERRY TOV -> Cherry Tomatoes on the Vine
- Example: ORGSPRINGMIX -> Organic Spring Mix
- Example: CULTURELLE BO -> Culturelle Probiotic
- Example: RAC'S 2/31.7 -> Rao's

0.60 to 0.84
- Partially understandable, but one or more tokens remain unclear
- Example: ORG 4BRY 5LB -> Organic 4-Berry, 5 lb
- Example: TENDERLOIN -> Tenderloin
- Example: NB PROBIC 70 -> NB Probiotic 70

0.30 to 0.59
- Highly ambiguous text
- Example: SKO 5X -> SKO 5X
- Example: TIRE EXT. -> Tire Ext.

0.00 to 0.29
- Cannot reliably determine meaning
- Example: MISC -> Misc
- Example: ITEM -> Item

VERIFICATION RULES

If confidence < 0.85:
- set needsVerification to true

If confidence >= 0.85:
- set needsVerification to false

Set ambiguous to true whenever:
- more than one reasonable interpretation exists
- a meaningful token remains unresolved
- the normalized label is intentionally generic
- an OCR correction is uncertain

Set ambiguous to false only when the cleaned meaning is clear.

CATEGORY RULES

Assign exactly one category to every item:
- produce
- meat_seafood
- dairy_eggs
- bakery
- pantry
- frozen
- beverages
- snacks
- prepared_food
- household
- personal_care
- health_wellness
- pet
- baby
- alcohol
- restaurant
- general_merchandise
- other

Use the raw_name and normalizedName only.
Do not use price to infer category.
Do not use merchant alone to infer category.

Category examples:
- Organic Spring Mix -> produce
- Cherry Tomatoes on the Vine -> produce
- Pasture Eggs -> dairy_eggs
- Pork Belly -> meat_seafood
- Rao's -> pantry
- Culturelle Probiotic -> health_wellness
- NB Probiotic 70 -> health_wellness
- Ziploc Slider -> household
- Avocado Mash -> prepared_food if it appears ready-to-eat, otherwise produce

If the category is unclear, use other.
If the item is a broad non-food retail item, use general_merchandise.

OUTPUT RULES

Return valid JSON only.
Do not include markdown.
Do not include explanations outside JSON.
Return exactly one result for every input item.
Preserve the original input order.
Preserve the input index.
Do not omit fields.
Use an empty array when there are no alternatives.

Return exactly this structure:

{
  "items": [
    {
      "index": 0,
      "original": "string",
      "normalizedName": "string",
      "confidence": 0.00,
      "ambiguous": true,
      "needsVerification": true,
      "possibleAlternatives": [],
      "reason": "Short explanation based only on raw_name.",
      "category": "produce",
      "categoryConfidence": 0.00,
      "categoryReason": "Short category explanation based only on raw_name and normalizedName."
    }
  ]
}`;

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

function inferFallbackItemCategory(name) {
  const lower = (name || "").toLowerCase();

  if (/\b(lettuce|spring mix|tomato|tomatoes|banana|apple|avocado|berry|berries|kiwi|onion|potato|broccoli|produce|fruit|vegetable)\b/.test(lower)) {
    return "produce";
  }
  if (/\b(chicken|beef|pork|belly|steak|tenderloin|fish|salmon|shrimp|seafood|meat)\b/.test(lower)) {
    return "meat_seafood";
  }
  if (/\b(egg|eggs|milk|cheese|yogurt|butter|cream|dairy)\b/.test(lower)) {
    return "dairy_eggs";
  }
  if (/\b(bread|bagel|muffin|cake|bakery|croissant|bun|roll)\b/.test(lower)) {
    return "bakery";
  }
  if (/\b(rao|pasta|sauce|rice|flour|oil|spaghetti|pantry|cereal|beans)\b/.test(lower)) {
    return "pantry";
  }
  if (/\b(frozen|ice cream)\b/.test(lower)) {
    return "frozen";
  }
  if (/\b(water|juice|soda|coffee|tea|drink|beverage)\b/.test(lower)) {
    return "beverages";
  }
  if (/\b(chip|chips|cookie|cookies|cracker|crackers|snack|candy|chocolate)\b/.test(lower)) {
    return "snacks";
  }
  if (/\b(prepared|rotisserie|deli|meal|salad|soup|guac|guacamole|mash)\b/.test(lower)) {
    return "prepared_food";
  }
  if (/\b(ziploc|trash|paper|towel|detergent|cleaner|soap|household)\b/.test(lower)) {
    return "household";
  }
  if (/\b(shampoo|toothpaste|lotion|deodorant|personal care)\b/.test(lower)) {
    return "personal_care";
  }
  if (/\b(probiotic|vitamin|medicine|supplement|culturelle|health|wellness)\b/.test(lower)) {
    return "health_wellness";
  }
  if (/\b(dog|cat|pet)\b/.test(lower)) {
    return "pet";
  }
  if (/\b(baby|diaper|formula)\b/.test(lower)) {
    return "baby";
  }
  if (/\b(beer|wine|vodka|alcohol|liquor)\b/.test(lower)) {
    return "alcohol";
  }

  return "other";
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
    items: (parsed.items || []).map(item => {
      const originalAmount = toNumber(item.originalAmount);
      const itemDiscount = toNumber(item.itemDiscount);
      let amount = round2(item.amount);

      if (
        originalAmount != null &&
        itemDiscount != null &&
        itemDiscount > 0 &&
        originalAmount >= itemDiscount
      ) {
        const discountedAmount = round2(originalAmount - itemDiscount);
        if (amount == null || Math.abs(amount - discountedAmount) > 0.01) {
          amount = discountedAmount;
        }
      }

      return {
        name: normalizeItemName(item.name),
        amount,
        originalAmount,
        itemDiscount,
        itemDiscountLabel: item.itemDiscountLabel ?? null,
        itemCode: item.itemCode ?? null,
        qty: toNumber(item.qty),
        unitPrice: toNumber(item.unitPrice),
        weightLbs: toNumber(item.weightLbs),
        confidence: item.confidence || "medium",
        source: item.source || "model",
      };
    }),
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
// STAGE 9: ITEM NAME NORMALIZATION
// ============================================================

const ITEM_NAME_NORMALIZATION_MODEL = "ministral-14b-latest";
const ITEM_NAME_NORMALIZATION_TIMEOUT_MS = 20000;

function withTimeout(promise, timeoutMs, label) {
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      reject(new Error(`${label} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });

  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutId));
}

function fallbackNameNormalization(receipt) {
  return {
    ...receipt,
    items: (receipt.items || []).map(item => ({
      ...item,
      rawName: item.name,
      normalizedName: item.name,
      normalizationConfidence: 0,
      normalizationAmbiguous: true,
      needsNameVerification: true,
      possibleNameAlternatives: [],
      normalizationReason: "Normalization unavailable; preserved raw receipt text.",
      category: inferFallbackItemCategory(item.name),
      categoryConfidence: 0.35,
      categoryReason: "Fallback category inferred from raw receipt text.",
    })),
  };
}

function validateItemNameNormalizationResponse(response, inputCount) {
  const parsed = ItemNameNormalizationResponseSchema.parse(response);

  if (parsed.items.length !== inputCount) {
    throw new Error(`Expected ${inputCount} normalized items, received ${parsed.items.length}`);
  }

  const seen = new Set();
  for (const item of parsed.items) {
    if (item.index < 0 || item.index >= inputCount) {
      throw new Error(`Unexpected normalized item index: ${item.index}`);
    }
    if (seen.has(item.index)) {
      throw new Error(`Duplicate normalized item index: ${item.index}`);
    }
    seen.add(item.index);
  }

  for (let i = 0; i < inputCount; i++) {
    if (!seen.has(i)) {
      throw new Error(`Missing normalized item index: ${i}`);
    }
  }

  return parsed;
}

async function normalizeItemNamesWithMistral(receipt, reqId) {
  if (!receipt?.items?.length) {
    return receipt;
  }

  const startedAt = Date.now();
  console.log(`[${reqId}] Starting item-name normalization pass...`);
  console.log(`[${reqId}]   - Model: ${ITEM_NAME_NORMALIZATION_MODEL}`);
  console.log(`[${reqId}]   - Items sent: ${receipt.items.length}`);

  const payload = {
    merchant: receipt.merchant,
    items: receipt.items.map((item, index) => ({
      index,
      raw_name: item.name,
      item_code: item.itemCode ?? null,
      price: item.amount,
    })),
  };

  try {
    const completion = await withTimeout(
      client.chat.parse({
        model: ITEM_NAME_NORMALIZATION_MODEL,
        messages: [
          { role: "system", content: ITEM_NAME_NORMALIZATION_PROMPT },
          { role: "user", content: JSON.stringify(payload) },
        ],
        temperature: 0,
        responseFormat: ItemNameNormalizationResponseSchema,
      }),
      ITEM_NAME_NORMALIZATION_TIMEOUT_MS,
      "Item-name normalization"
    );

    const message = completion.choices?.[0]?.message;
    const rawResponse = message?.parsed ?? JSON.parse(message?.content || "{}");
    const validated = validateItemNameNormalizationResponse(rawResponse, receipt.items.length);
    const byIndex = new Map(validated.items.map(item => [item.index, item]));

    const normalizedReceipt = {
      ...receipt,
      items: receipt.items.map((item, index) => {
        const aiResult = byIndex.get(index);
        return {
          ...item,
          rawName: item.name,
          normalizedName: aiResult.normalizedName,
          normalizationConfidence: aiResult.confidence,
          normalizationAmbiguous: aiResult.ambiguous,
          needsNameVerification: aiResult.needsVerification,
          possibleNameAlternatives: aiResult.possibleAlternatives,
          normalizationReason: aiResult.reason,
          category: aiResult.category,
          categoryConfidence: aiResult.categoryConfidence,
          categoryReason: aiResult.categoryReason,
        };
      }),
    };

    console.log(`[${reqId}] ✓ Item-name normalization complete in ${Date.now() - startedAt}ms (fallback=false)`);
    return normalizedReceipt;
  } catch (error) {
    console.log(`[${reqId}] ⚠️ Item-name normalization failed: ${error.message}`);
    console.log(`[${reqId}] ✓ Item-name normalization fallback complete in ${Date.now() - startedAt}ms (fallback=true)`);
    return fallbackNameNormalization(receipt);
  }
}

// ============================================================
// STAGE 10: CONFIDENCE + STATUS
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
      name: item.normalizedName || item.name,
      rawName: item.rawName || item.name,
      normalizedName: item.normalizedName || item.name,
      itemCode: item.itemCode ?? null,
      amount: item.amount,
      originalAmount: item.originalAmount ?? null,
      itemDiscount: item.itemDiscount ?? null,
      itemDiscountLabel: item.itemDiscountLabel ?? null,
      hasItemDiscount: (item.itemDiscount ?? 0) > 0,
      discountDisplayLabel:
        (item.itemDiscount ?? 0) > 0
          ? item.itemDiscountLabel || `Discount applied - $${item.itemDiscount.toFixed(2)}`
          : null,
      qty: item.qty,
      unitPrice: item.unitPrice,
      weightLbs: item.weightLbs,
      confidence: item.confidence,
      category: item.category || inferFallbackItemCategory(item.normalizedName || item.name),
      categoryConfidence: item.categoryConfidence ?? 0,
      categoryReason: item.categoryReason ?? "Category unavailable.",
      normalizationConfidence: item.normalizationConfidence ?? 0,
      normalizationAmbiguous: item.normalizationAmbiguous ?? true,
      needsNameVerification: item.needsNameVerification ?? true,
      possibleNameAlternatives: item.possibleNameAlternatives ?? [],
      normalizationReason:
        item.normalizationReason ??
        "Normalization unavailable; preserved raw receipt text.",
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
      item_name_normalization: {
        model: ITEM_NAME_NORMALIZATION_MODEL,
        enabled: true,
        items: parsed.items.map(item => ({
          rawName: item.rawName || item.name,
          normalizedName: item.normalizedName || item.name,
          confidence: item.normalizationConfidence ?? 0,
          ambiguous: item.normalizationAmbiguous ?? true,
          needsVerification: item.needsNameVerification ?? true,
          alternatives: item.possibleNameAlternatives ?? [],
          reason: item.normalizationReason ?? null,
          category: item.category || inferFallbackItemCategory(item.normalizedName || item.name),
          categoryConfidence: item.categoryConfidence ?? 0,
          categoryReason: item.categoryReason ?? null,
        })),
      },
      item_discounts: {
        enabled: true,
        items: parsed.items
          .filter(item => (item.itemDiscount ?? 0) > 0)
          .map(item => ({
            rawName: item.rawName || item.name,
            normalizedName: item.normalizedName || item.name,
            originalAmount: item.originalAmount ?? null,
            finalAmount: item.amount,
            itemDiscount: item.itemDiscount,
            itemDiscountLabel: item.itemDiscountLabel ?? null,
          })),
      },
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
    let normalizationMs = 0;
    
    if (parsed) {
      normalized = normalizeParsedReceipt(parsed);
      const filterResult = filterNonItems(normalized.items, ocrText);
      normalized.items = filterResult.filtered;
      rejected = filterResult.rejected;

      // Contradiction resolution layer
      resolutionResult = resolveFinancialContradictions(normalized, reqId);
      normalized = resolutionResult.receipt;

      const normalizationStart = Date.now();
      normalized = await normalizeItemNamesWithMistral(normalized, reqId);
      normalizationMs = Date.now() - normalizationStart;
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
      { parse_ms: parseMs, normalization_ms: normalizationMs, total_ms: totalMs },
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
