import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import crypto from "crypto";
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
const DATA_DIR = path.resolve(process.cwd(), "data");
const SAVE_TEMP_RECEIPTS = process.env.SAVE_TEMP_RECEIPTS === "true";
const RECOMMENDED_IMAGE_MAX_BYTES = 2 * 1024 * 1024;
const MISTRAL_OCR_MODEL = process.env.MISTRAL_OCR_MODEL || "mistral-ocr-latest";
const ADMIN_BEARER_TOKEN = process.env.ADMIN_BEARER_TOKEN || "";
const ANALYTICS_EVENTS_FILE = process.env.ANALYTICS_EVENTS_FILE || path.join(DATA_DIR, "analytics_events.jsonl");
const ANALYTICS_RETENTION_DAYS = Number(process.env.ANALYTICS_RETENTION_DAYS || 90);
const ANALYTICS_MAX_EVENT_BYTES = Number(process.env.ANALYTICS_MAX_EVENT_BYTES || 16 * 1024);
const ENABLE_DEBUG_RESPONSE =
  process.env.ENABLE_DEBUG_RESPONSE === "true" &&
  process.env.NODE_ENV !== "production";
const MAX_UPLOAD_BYTES = Number(process.env.MAX_UPLOAD_BYTES || 20 * 1024 * 1024);
const MAX_PDF_PAGES = Number(process.env.MAX_PDF_PAGES || 12);
const OCR_LOW_CONFIDENCE_THRESHOLD = Number(process.env.OCR_LOW_CONFIDENCE_THRESHOLD || 0.75);
const ALLOWED_MIME_TYPES = new Set([
  "application/pdf",
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
]);
const parseCache = new Map();
const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS || 10 * 60 * 1000);

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

fs.mkdirSync(DATA_DIR, { recursive: true });
if (SAVE_TEMP_RECEIPTS) fs.mkdirSync(TEMP_DIR, { recursive: true });

const client = new Mistral({ apiKey: MISTRAL_API_KEY });

console.log("\n" + "=".repeat(80));
console.log("  PRODUCTION RECEIPT PARSER - MISTRAL OCR SINGLE PASS");
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

const BankTransactionSchema = z.object({
  transactionDate: z.string().nullable(),
  postedDate: z.string().nullable(),
  description: z.string(),
  amount: z.number(),
  direction: z.enum(["debit", "credit", "unknown"]),
  status: z.enum(["posted", "pending", "unknown"]),
  balanceAfterTransaction: z.number().nullable(),
  sourceText: z.string(),
  confidence: z.number().nullable(),
});

const BankDocumentSchema = z.object({
  documentType: z.enum([
    "bank_statement",
    "account_activity_screenshot",
    "credit_card_activity_screenshot",
  ]),
  institutionName: z.string().nullable(),
  accountName: z.string().nullable(),
  accountLast4: z.string().nullable(),
  currency: z.string().nullable(),
  statementPeriod: z.object({
    startDate: z.string().nullable(),
    endDate: z.string().nullable(),
  }),
  balances: z.object({
    openingBalance: z.number().nullable(),
    closingBalance: z.number().nullable(),
    availableBalance: z.number().nullable(),
    currentBalance: z.number().nullable(),
  }),
  transactions: z.array(BankTransactionSchema),
  partialDocument: z.boolean(),
  warnings: z.array(z.string()),
});

const SAFE_ITEM_ABBREVIATIONS = {
  KS: "Kirkland Signature",
  ORG: "Organic",
  CKN: "Chicken",
  GUAC: "Guacamole",
  SNGL: "Single-Serve",
  FR: "Free-Range",
  ABF: "Antibiotic-Free",
  ROT: "Rotisserie",
  LB: "lb",
  OZ: "oz",
  PK: "Pack",
  CT: "Count",
  ZIPLC: "Ziploc",
  TOV: "Tomatoes on the Vine",
  SLCD: "Sliced",
  EVOO: "Extra Virgin Olive Oil",
  BROCC: "Broccoli",
  PTTO: "Potato",
  YLW: "Yellow",
};

const SAFE_OCR_REPLACEMENTS = [
  [/\bBANANASS\b/gi, "Bananas"],
  [/\bTENDERION\b/gi, "Tenderloin"],
  [/\bORGSPRINGMIX\b/gi, "Organic Spring Mix"],
  [/\bSPAGHTTI\b/gi, "Spaghetti"],
  [/\bCHOPONION\b/gi, "Chopped Onion"],
  [/\bCHIPTLE\b/gi, "Chipotle"],
];

// ============================================================
// FINANCIAL DOCUMENT HELPERS
// ============================================================

function toMinorUnits(value, currency = "USD") {
  if (value == null || Number.isNaN(Number(value))) return null;
  const decimals = ["JPY", "KRW"].includes(String(currency).toUpperCase()) ? 0 : 2;
  return Math.round(Number(value) * Math.pow(10, decimals));
}

function fromMinorUnits(value, currency = "USD") {
  if (value == null) return null;
  const decimals = ["JPY", "KRW"].includes(String(currency).toUpperCase()) ? 0 : 2;
  return Number((value / Math.pow(10, decimals)).toFixed(decimals));
}

function moneyEqualWithinTolerance(a, b, toleranceMinorUnits = 1) {
  if (a == null || b == null) return false;
  return Math.abs(a - b) <= toleranceMinorUnits;
}

function detectMimeType(buffer, claimedMimeType = "") {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return null;
  if (buffer.subarray(0, 4).toString("latin1") === "%PDF") return "application/pdf";
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return "image/jpeg";
  if (buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (buffer.subarray(0, 4).toString("latin1") === "RIFF" && buffer.subarray(8, 12).toString("latin1") === "WEBP") return "image/webp";
  const brand = buffer.subarray(4, 12).toString("latin1");
  if (brand.includes("ftypheic") || brand.includes("ftypheix") || brand.includes("ftyphevc") || brand.includes("ftypmif1")) return "image/heic";
  return ALLOWED_MIME_TYPES.has(claimedMimeType) ? claimedMimeType : null;
}

function validateUploadBuffer(buffer, claimedMimeType) {
  if (!buffer || buffer.length < 128) {
    return { ok: false, status: 400, code: "UNSUPPORTED_FILE_TYPE", message: "File is too small or corrupt." };
  }
  if (buffer.length > MAX_UPLOAD_BYTES) {
    return { ok: false, status: 413, code: "FILE_TOO_LARGE", message: "This file is too large to parse." };
  }
  const actualMimeType = detectMimeType(buffer, claimedMimeType);
  if (!actualMimeType || !ALLOWED_MIME_TYPES.has(actualMimeType)) {
    return { ok: false, status: 415, code: "UNSUPPORTED_FILE_TYPE", message: "Unsupported file type. Upload a PDF, JPG, PNG, WEBP, or HEIC file." };
  }
  return { ok: true, mimeType: actualMimeType };
}

function getTempExtension(mimeType) {
  if (mimeType === "application/pdf") return ".pdf";
  if (mimeType === "image/png") return ".png";
  if (mimeType === "image/webp") return ".webp";
  if (mimeType === "image/heic") return ".heic";
  return ".jpg";
}

function buildMistralDocument(buffer, mimeType) {
  const base64 = buffer.toString("base64");
  const dataUrl = `data:${mimeType};base64,${base64}`;
  if (mimeType === "application/pdf") return { type: "document_url", documentUrl: dataUrl };
  return { type: "image_url", imageUrl: dataUrl };
}

function decodeBase64Payload(value) {
  let base64Data = String(value || "");
  const idx = base64Data.indexOf("base64,");
  if (idx >= 0) base64Data = base64Data.slice(idx + 7);
  return Buffer.from(base64Data, "base64");
}

function fileHash(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function getCachedParse(hash, namespace) {
  const key = `${namespace}:${hash}`;
  const cached = parseCache.get(key);
  if (!cached) return null;
  if (Date.now() - cached.createdAt > CACHE_TTL_MS) {
    parseCache.delete(key);
    return null;
  }
  return cached.value;
}

function setCachedParse(hash, namespace, value) {
  parseCache.set(`${namespace}:${hash}`, { createdAt: Date.now(), value });
}

function parseAndValidateDocumentAnnotation(annotation, schema) {
  if (!annotation) {
    const error = new Error("No structured annotation returned by Mistral");
    error.code = "MALFORMED_ANNOTATION";
    throw error;
  }
  let raw;
  try {
    raw = JSON.parse(annotation);
  } catch (err) {
    const error = new Error("Structured annotation JSON is malformed");
    error.code = "MALFORMED_ANNOTATION";
    error.cause = err;
    throw error;
  }
  try {
    return schema.parse(raw);
  } catch (err) {
    const error = new Error("Structured annotation failed schema validation");
    error.code = "SCHEMA_VALIDATION_FAILED";
    error.cause = err;
    throw error;
  }
}

function redactSensitiveText(value) {
  return String(value || "")
    .replace(/\b(?:\d[ -]?){13,19}\b/g, "[REDACTED_CARD_OR_ACCOUNT]")
    .replace(/\b(account|acct|card)\s*(?:number|no|#)?\s*[:#]?\s*[A-Z0-9* -]{6,}/gi, "$1 [REDACTED]");
}

// ============================================================
// INTERNAL ANALYTICS - FILE-BACKED, NON-BLOCKING
// ============================================================

const BLOCKED_ANALYTICS_KEYS = [
  "imagebase64",
  "filebase64",
  "base64",
  "ocrtext",
  "rawocr",
  "rawtext",
  "receipttext",
  "statementtext",
  "transactiondescription",
  "description",
  "sourcetext",
  "apikey",
  "api_key",
  "authorization",
  "bearer",
  "token",
  "password",
  "secret",
  "mistral",
  "openai",
];

const ANALYTICS_FAILURE_REASONS = {
  receipt: new Set([
    "blurry_image",
    "invalid_document",
    "valid_receipt_incorrectly_rejected",
    "unsupported_file_type",
    "pdf_extraction_failed",
    "ocr_timeout",
    "ocr_provider_error",
    "parse_failed",
    "missing_total",
    "subtotal_selected_as_grand_total",
    "reconciliation_failed",
    "backend_timeout",
    "unknown_error",
  ]),
  statement: new Set([
    "blurry_statement",
    "invalid_statement",
    "valid_statement_incorrectly_rejected",
    "screenshot_classification_failed",
    "pdf_extraction_failed",
    "password_protected_pdf",
    "transaction_extraction_failed",
    "parse_failed",
    "backend_timeout",
    "unknown_error",
  ]),
};

function safeString(value, maxLength = 300) {
  return redactSensitiveText(value)
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [REDACTED]")
    .replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, "[REDACTED_EMAIL]")
    .replace(/\+?\d[\d .()\-]{8,}\d/g, "[REDACTED_PHONE_OR_ACCOUNT]")
    .slice(0, maxLength);
}

function isBlockedAnalyticsKey(key) {
  const normalized = String(key || "").replace(/[^a-zA-Z0-9_]/g, "").toLowerCase();
  return BLOCKED_ANALYTICS_KEYS.some(blocked => normalized.includes(blocked));
}

function sanitizeAnalyticsValue(value, depth = 0) {
  if (depth > 4) return "[MAX_DEPTH]";
  if (value == null) return value;
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "string") return safeString(value);
  if (Array.isArray(value)) {
    return value.slice(0, 25).map(item => sanitizeAnalyticsValue(item, depth + 1));
  }
  if (typeof value === "object") {
    const output = {};
    for (const [key, raw] of Object.entries(value).slice(0, 80)) {
      if (isBlockedAnalyticsKey(key)) {
        output[key] = "[REDACTED]";
      } else {
        output[key] = sanitizeAnalyticsValue(raw, depth + 1);
      }
    }
    return output;
  }
  return String(value);
}

function sanitizeAnalyticsProperties(properties = {}) {
  const sanitized = sanitizeAnalyticsValue(properties);
  const encoded = JSON.stringify(sanitized);
  if (Buffer.byteLength(encoded, "utf8") <= ANALYTICS_MAX_EVENT_BYTES) return sanitized;
  return {
    truncated: true,
    original_size_bytes: Buffer.byteLength(encoded, "utf8"),
  };
}

function normalizeAnalyticsFailureReason(kind, reason) {
  const normalized = String(reason || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  const allowed = ANALYTICS_FAILURE_REASONS[kind];
  if (allowed?.has(normalized)) return normalized;
  if (normalized.includes("timeout")) return "backend_timeout";
  if (normalized.includes("unsupported")) return "unsupported_file_type";
  if (normalized.includes("pdf")) return "pdf_extraction_failed";
  if (normalized.includes("ocr")) return kind === "receipt" ? "ocr_provider_error" : "transaction_extraction_failed";
  if (normalized.includes("parse") || normalized.includes("schema")) return "parse_failed";
  if (normalized.includes("statement")) return kind === "statement" ? "invalid_statement" : "invalid_document";
  return "unknown_error";
}

function requestIdFrom(req) {
  const provided =
    req.headers["x-request-id"] ||
    req.headers["x-dutchie-request-id"] ||
    req.body?.request_id ||
    req.body?.requestId;
  if (typeof provided === "string" && /^[A-Za-z0-9_.:-]{6,96}$/.test(provided)) {
    return provided;
  }
  return `req_${Date.now().toString(36)}_${crypto.randomBytes(4).toString("hex")}`;
}

function analyticsContextFromRequest(req, reqId) {
  return {
    user_id: req.body?.user_id || req.body?.userId || req.headers["x-user-id"] || null,
    anonymous_id: req.body?.anonymous_id || req.body?.anonymousId || req.headers["x-anonymous-id"] || null,
    session_id: req.body?.session_id || req.body?.sessionId || req.headers["x-session-id"] || "unknown",
    request_id: reqId,
    platform: req.body?.platform || req.headers["x-platform"] || "ios",
    app_version: req.body?.app_version || req.body?.appVersion || req.headers["x-app-version"] || null,
  };
}

function compactAnalyticsEvent(event) {
  return {
    id: event.id || `evt_${Date.now().toString(36)}_${crypto.randomBytes(6).toString("hex")}`,
    user_id: event.user_id ?? null,
    anonymous_id: event.anonymous_id ?? null,
    session_id: event.session_id || "unknown",
    request_id: event.request_id ?? null,
    event_name: event.event_name,
    platform: event.platform || "backend",
    app_version: event.app_version ?? null,
    properties: sanitizeAnalyticsProperties(event.properties || {}),
    created_at: event.created_at || new Date().toISOString(),
  };
}

function trackAnalyticsEvent(event) {
  if (!event?.event_name) return;
  try {
    const compacted = compactAnalyticsEvent(event);
    fs.promises
      .appendFile(ANALYTICS_EVENTS_FILE, JSON.stringify(compacted) + "\n", "utf8")
      .catch(error => {
        console.warn("[analytics] write failed:", error?.message || error);
      });
  } catch (error) {
    console.warn("[analytics] event dropped:", error?.message || error);
  }
}

async function readAnalyticsEvents({ limit = 5000, from, to } = {}) {
  try {
    const raw = await fs.promises.readFile(ANALYTICS_EVENTS_FILE, "utf8");
    const fromTime = from ? Date.parse(from) : null;
    const toTime = to ? Date.parse(to) : null;
    const rows = raw
      .split(/\n+/)
      .filter(Boolean)
      .map(line => {
        try { return JSON.parse(line); } catch { return null; }
      })
      .filter(Boolean)
      .filter(event => {
        const created = Date.parse(event.created_at);
        if (fromTime && created < fromTime) return false;
        if (toTime && created > toTime) return false;
        return true;
      });
    return rows.slice(-Math.max(1, Math.min(Number(limit) || 5000, 20000)));
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

async function cleanupAnalyticsEvents() {
  if (!Number.isFinite(ANALYTICS_RETENTION_DAYS) || ANALYTICS_RETENTION_DAYS <= 0) return;
  try {
    const cutoff = Date.now() - ANALYTICS_RETENTION_DAYS * 24 * 60 * 60 * 1000;
    const events = await readAnalyticsEvents({ limit: 200000 });
    const retained = events.filter(event => Date.parse(event.created_at) >= cutoff);
    if (retained.length !== events.length) {
      await fs.promises.writeFile(
        ANALYTICS_EVENTS_FILE,
        retained.map(event => JSON.stringify(event)).join("\n") + (retained.length ? "\n" : ""),
        "utf8"
      );
      console.log(`[analytics] Retention cleanup kept ${retained.length}/${events.length} events`);
    }
  } catch (error) {
    console.warn("[analytics] retention cleanup failed:", error?.message || error);
  }
}

function summarizeAnalytics(events) {
  const counts = {};
  const users = new Set();
  const sessions = new Set();
  const errors = {};
  const durations = [];
  for (const event of events) {
    counts[event.event_name] = (counts[event.event_name] || 0) + 1;
    if (event.user_id) users.add(event.user_id);
    if (event.session_id) sessions.add(event.session_id);
    const reason = event.properties?.failure_reason || event.properties?.error_code;
    if (reason) errors[reason] = (errors[reason] || 0) + 1;
    const ms = event.properties?.processing_time_ms ?? event.properties?.total_ms;
    if (Number.isFinite(ms)) durations.push(ms);
  }
  durations.sort((a, b) => a - b);
  const percentile = p => durations.length ? durations[Math.min(durations.length - 1, Math.floor(durations.length * p))] : 0;
  return {
    total_events: events.length,
    unique_users: users.size,
    unique_sessions: sessions.size,
    counts,
    receipt_success_rate: rate(counts.receipt_parse_completed, counts.receipt_upload_started),
    statement_success_rate: rate(counts.statement_parse_completed, counts.statement_upload_started),
    ocr_success_rate: rate(counts.receipt_ocr_completed, (counts.receipt_ocr_started || 0) + (counts.statement_extraction_started || 0)),
    most_common_errors: Object.entries(errors)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 12)
      .map(([reason, count]) => ({ reason, count })),
    response_time_ms: {
      average: durations.length ? Math.round(durations.reduce((sum, ms) => sum + ms, 0) / durations.length) : 0,
      p95: percentile(0.95),
      p99: percentile(0.99),
    },
  };
}

function rate(success = 0, total = 0) {
  return total > 0 ? Number(((success / total) * 100).toFixed(1)) : 0;
}

function hashIdentifier(value) {
  if (!value) return null;
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 24);
}

function classifyFinancialDocument({ ocrText, uploadIntent, sourceType, mimeType }) {
  const text = String(ocrText || "").toLowerCase();
  const hasReceiptSignals = /\b(receipt|subtotal|sales tax|tax|tip|gratuity|total due|balance due|items sold|cashier|merchant)\b/.test(text);
  const hasStatementSignals = /\b(statement period|opening balance|closing balance|account number|account summary|statement date|new balance)\b/.test(text);
  const hasActivitySignals = /\b(account activity|transaction history|pending|posted|available balance|current balance|deposit|withdrawal|transfer|merchant name|transaction description|payments and other credits|purchase)\b/.test(text);
  const hasCardSignals = /\b(credit card|card activity|minimum payment|payment due|statement balance|available credit|cash back|purchase apr|credit line|cardmember|freedom)\b/.test(text);
  const hasTransactionRows = (text.match(/\$?[-+]?\d{1,3}(?:,\d{3})*\.\d{2}/g) || []).length >= 2;
  const isPdf = sourceType === "pdf" || mimeType === "application/pdf";

  if (uploadIntent === "scan_statement" && hasCardSignals && hasTransactionRows) {
    return { documentType: "credit_card_activity_screenshot", confidence: 0.94, reason: "Credit-card statement/activity language and transaction rows were detected." };
  }
  if (uploadIntent === "scan_statement" && (hasStatementSignals || isPdf) && hasTransactionRows) {
    return { documentType: "bank_statement", confidence: 0.93, reason: "Statement-like document and transaction rows were detected." };
  }
  if (uploadIntent === "scan_statement" && hasActivitySignals && hasTransactionRows) {
    return { documentType: "account_activity_screenshot", confidence: 0.9, reason: "Account activity labels and visible transaction rows were detected." };
  }
  if (hasStatementSignals && hasTransactionRows) return { documentType: "bank_statement", confidence: 0.95, reason: "Statement period, balances, or account summary signals were detected with transaction amounts." };
  if (hasCardSignals && hasTransactionRows) return { documentType: "credit_card_activity_screenshot", confidence: 0.92, reason: "Credit-card activity language and transaction amounts were detected." };
  if (hasActivitySignals && hasTransactionRows) return { documentType: "account_activity_screenshot", confidence: 0.9, reason: "Account activity language and visible transaction rows were detected." };
  if (hasReceiptSignals && uploadIntent !== "scan_statement") return { documentType: "receipt", confidence: 0.86, reason: "Receipt-style totals and purchased-item signals were detected." };
  if (hasTransactionRows && uploadIntent === "scan_statement") return { documentType: isPdf ? "bank_statement" : "account_activity_screenshot", confidence: 0.72, reason: "Visible transaction-like rows were detected, but document labels are limited." };
  if (hasReceiptSignals && uploadIntent === "scan_statement") return { documentType: "ambiguous", confidence: 0.62, reason: "The upload was intended as a statement, but receipt-style fields were detected." };
  return { documentType: "unsupported", confidence: 0.25, reason: "No supported receipt, statement, or account-activity evidence was detected." };
}

function classifyReceiptUpload({ ocrText, parsed }) {
  const text = String(ocrText || "").toLowerCase();
  const words = text.match(/[a-z0-9$.,#-]+/g) || [];
  const amountCount = (text.match(/\$?[-+]?\d{1,3}(?:,\d{3})*\.\d{2}/g) || []).length;
  const receiptSignals = [
    /\breceipt\b/,
    /\bsubtotal\b/,
    /\bsales\s+tax\b/,
    /\btax\b/,
    /\btip\b/,
    /\bgratuity\b/,
    /\btotal\s+(?:due|paid|amount|sale|order)\b/,
    /\bbalance\s+due\b/,
    /\bitems?\s+sold\b/,
    /\bcashier\b/,
    /\btender\b/,
    /\bchange\b/,
    /\border\s*(?:#|number|no\.?|id)\b/,
    /\binvoice\b/,
    /\bmerchant\s+copy\b/,
    /\b(?:visa|mastercard|amex|discover)\b/,
    /\bauth\s*(?:code|#)\b/,
  ];
  const statementSignals = /\b(statement period|opening balance|closing balance|account number|account summary|statement date|new balance|minimum payment|payment due|available credit|transaction history|account activity)\b/.test(text);
  const receiptSignalCount = receiptSignals.reduce((count, regex) => count + (regex.test(text) ? 1 : 0), 0);
  const itemCount = Array.isArray(parsed?.items) ? parsed.items.length : 0;
  const hasVisibleTotal = parsed?.grandTotal != null || parsed?.subtotal != null || /\b(?:grand\s+total|total|amount\s+due|balance\s+due)\b/.test(text);

  if (statementSignals) {
    return {
      ok: false,
      code: "NOT_A_RECEIPT",
      confidence: 0.2,
      reason: "Statement or account-activity text was detected, not a receipt.",
    };
  }

  if (receiptSignalCount >= 1 && amountCount >= 1 && itemCount >= 1) {
    return { ok: true, confidence: Math.min(0.98, 0.75 + receiptSignalCount * 0.04), reason: "Receipt text, prices, and purchased items were detected." };
  }

  if (receiptSignalCount >= 2 && amountCount >= 1 && hasVisibleTotal) {
    return { ok: true, confidence: 0.84, reason: "Receipt totals and receipt-style labels were detected." };
  }

  if (itemCount >= 2 && amountCount >= 2 && hasVisibleTotal && receiptSignalCount >= 1) {
    return { ok: true, confidence: 0.82, reason: "Receipt-like item rows and totals were detected." };
  }

  if (words.length < 8 || receiptSignalCount === 0) {
    return {
      ok: false,
      code: "NOT_A_RECEIPT",
      confidence: 0.18,
      reason: "No reliable receipt text was detected. A photo of food or an object should not be parsed as a receipt.",
    };
  }

  return {
    ok: false,
    code: "NOT_A_RECEIPT",
    confidence: 0.45,
    reason: "The upload did not contain enough receipt evidence to safely parse financial values.",
  };
}

const BANK_DOCUMENT_PROMPT = `You extract transaction rows from bank statements, credit-card statements, and banking activity screenshots.

Product goal:
- Treat statements like receipt itemization, but each extracted item is a transaction row.
- For PDFs, inspect all pages and find the pages or sections dedicated to transactions/account activity/purchases/payments.
- For screenshots, use the visible transaction page only.
- The document may not show a subtotal, statement total, or balance. That is normal. Do not require one.

Extract only transaction rows visibly supported by the document.
Ignore non-transaction content such as account messages, ads, summaries, year-to-date fee boxes, payment coupons, instructions, and headers.
Never invent a transaction, balance, account name, account number, date, status, or statement period.
Return null when a non-transaction field is absent or unclear.
If no transaction rows are visible, return an empty transactions array and explain in warnings.
If a screenshot is cropped or rows appear cut off, set partialDocument = true.

Transaction rules:
- description is the merchant/payee/transaction description exactly enough for a user to recognize it.
- amount is the visible transaction amount as a positive number.
- direction = debit for purchases, withdrawals, fees, charges, card purchases, or money spent.
- direction = credit for payments, deposits, refunds, credits, rewards, or money received.
- On credit-card statements, PURCHASE sections are debit/spending even if printed as positive amounts.
- On credit-card statements, PAYMENTS AND OTHER CREDITS sections are credit even if printed with a minus sign.
- status = pending only when visibly labeled pending; otherwise posted or unknown.
- Preserve the original visible transaction row in sourceText.

Privacy:
Do not return a full bank-account number or full credit-card number. Only return last four digits when visibly present.

Return JSON only.`;

function parseBankAmountText(value) {
  const raw = String(value || "").trim();
  if (!raw) return null;
  const isNegative = /^\s*[-(]/.test(raw) || /\)\s*$/.test(raw);
  const cleaned = raw.replace(/[$,()\s]/g, "").replace(/^\+/, "");
  const amount = Number(cleaned);
  if (!Number.isFinite(amount) || Math.abs(amount) < 0.01) return null;
  return { amount: round2(Math.abs(amount)), isNegative };
}

function extractBankTransactionsFromOcrText(ocrText, documentType) {
  const transactions = [];
  let section = "unknown";
  const lines = String(ocrText || "")
    .split(/\r?\n/)
    .map(line => line.replace(/\|/g, " ").replace(/\s+/g, " ").trim())
    .filter(Boolean);

  for (const line of lines) {
    const upper = line.toUpperCase();
    const startsWithDate = /^\d{1,2}\/\d{1,2}/.test(line);
    if (!startsWithDate && /PAYMENTS?\s+AND\s+OTHER\s+CREDITS|CREDITS?/.test(upper) && !/PAYMENT\s+DUE/.test(upper)) {
      section = "credit";
      continue;
    }
    if (!startsWithDate && /PURCHASES?|TRANSACTIONS?|ACCOUNT\s+ACTIVITY|DEBITS?|WITHDRAWALS?/.test(upper)) {
      section = /ACCOUNT\s+ACTIVITY|TRANSACTIONS?/.test(upper) ? "unknown" : "debit";
      continue;
    }

    const match = line.match(/^(\d{1,2}\/\d{1,2}(?:\/\d{2,4})?)\s+(.+?)\s+([-+]?\$?\(?\d{1,3}(?:,\d{3})*\.\d{2}\)?)$/);
    if (!match) continue;

    const [, transactionDate, rawDescription, rawAmount] = match;
    const parsedAmount = parseBankAmountText(rawAmount);
    if (!parsedAmount) continue;

    const description = rawDescription
      .replace(/^&\s*/, "")
      .replace(/\s{2,}/g, " ")
      .trim();
    if (!description || /merchant name|transaction description|amount/i.test(description)) continue;

    let direction = section;
    if (parsedAmount.isNegative) direction = "credit";
    if (direction === "unknown" && documentType === "credit_card_activity_screenshot") {
      direction = parsedAmount.isNegative ? "credit" : "debit";
    }

    transactions.push({
      transactionDate,
      postedDate: null,
      description: redactSensitiveText(description),
      amount: parsedAmount.amount,
      direction,
      status: "posted",
      balanceAfterTransaction: null,
      sourceText: redactSensitiveText(line),
      confidence: 0.74,
    });
  }

  return transactions;
}

function mergeBankTransactions(primaryTransactions, fallbackTransactions) {
  const merged = [...(primaryTransactions || [])];
  const seen = new Set(merged.map(tx => [tx.transactionDate || "", tx.postedDate || "", tx.description || "", Number(tx.amount || 0).toFixed(2)].join("|")));

  for (const tx of fallbackTransactions || []) {
    const key = [tx.transactionDate || "", tx.postedDate || "", tx.description || "", Number(tx.amount || 0).toFixed(2)].join("|");
    if (!seen.has(key)) {
      merged.push(tx);
      seen.add(key);
    }
  }
  return merged;
}

function normalizeBankDocument(doc, classifiedType) {
  const sanitizedLast4 = doc.accountLast4 ? String(doc.accountLast4).replace(/\D/g, "").slice(-4) : null;
  return {
    documentType: ["bank_statement", "account_activity_screenshot", "credit_card_activity_screenshot"].includes(classifiedType) ? classifiedType : doc.documentType,
    institutionName: doc.institutionName || null,
    accountName: doc.accountName || null,
    accountLast4: sanitizedLast4,
    currency: doc.currency || "USD",
    statementPeriod: {
      startDate: doc.statementPeriod?.startDate || null,
      endDate: doc.statementPeriod?.endDate || null,
    },
    balances: {
      openingBalance: toNumber(doc.balances?.openingBalance),
      closingBalance: toNumber(doc.balances?.closingBalance),
      availableBalance: toNumber(doc.balances?.availableBalance),
      currentBalance: toNumber(doc.balances?.currentBalance),
    },
    transactions: (doc.transactions || []).map(tx => ({
      transactionDate: tx.transactionDate || null,
      postedDate: tx.postedDate || null,
      description: redactSensitiveText(tx.description),
      amount: round2(Math.abs(Number(tx.amount || 0))),
      direction: tx.direction || "unknown",
      status: tx.status || "unknown",
      balanceAfterTransaction: toNumber(tx.balanceAfterTransaction),
      sourceText: redactSensitiveText(tx.sourceText || tx.description || ""),
      confidence: tx.confidence ?? null,
    })).filter(tx => tx.description && tx.amount > 0),
    partialDocument: !!doc.partialDocument,
    warnings: (doc.warnings || []).map(redactSensitiveText),
  };
}

function reconcileBankDocument(bankDocument) {
  const currency = bankDocument.currency || "USD";
  const posted = bankDocument.transactions.filter(tx => tx.status !== "pending");
  const pending = bankDocument.transactions.filter(tx => tx.status === "pending");
  const postedDebits = posted.filter(tx => tx.direction === "debit").reduce((sum, tx) => sum + (toMinorUnits(tx.amount, currency) || 0), 0);
  const postedCredits = posted.filter(tx => tx.direction === "credit").reduce((sum, tx) => sum + (toMinorUnits(tx.amount, currency) || 0), 0);
  const pendingTotal = pending.reduce((sum, tx) => sum + (toMinorUnits(tx.amount, currency) || 0), 0);
  const opening = toMinorUnits(bankDocument.balances.openingBalance, currency);
  const closing = toMinorUnits(bankDocument.balances.closingBalance, currency);
  if (opening != null && closing != null) {
    const calculatedClosing = opening + postedCredits - postedDebits;
    const verified = moneyEqualWithinTolerance(calculatedClosing, closing);
    return {
      status: verified ? "verified" : "ambiguous",
      reason: verified ? "Opening balance plus posted credits minus posted debits matches the closing balance." : "Visible balances do not reconcile with visible posted transactions; the document may be partial or OCR may need review.",
      visiblePostedDebitTotal: fromMinorUnits(postedDebits, currency),
      visiblePostedCreditTotal: fromMinorUnits(postedCredits, currency),
      pendingTransactionTotal: fromMinorUnits(pendingTotal, currency),
      calculatedClosingBalance: fromMinorUnits(calculatedClosing, currency),
      totalGap: fromMinorUnits(Math.abs(calculatedClosing - closing), currency),
    };
  }
  if (bankDocument.partialDocument) return { status: "partially_verified", reason: "This appears to be a partial screenshot. Only visible transactions were extracted.", visiblePostedDebitTotal: fromMinorUnits(postedDebits, currency), visiblePostedCreditTotal: fromMinorUnits(postedCredits, currency), pendingTransactionTotal: fromMinorUnits(pendingTotal, currency) };
  return { status: "not_applicable", reason: "No opening balance, closing balance, or running balance is visible.", visiblePostedDebitTotal: fromMinorUnits(postedDebits, currency), visiblePostedCreditTotal: fromMinorUnits(postedCredits, currency), pendingTransactionTotal: fromMinorUnits(pendingTotal, currency) };
}

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
- Some promo labels describe savings without reducing the receipt total. If subtracting an itemDiscount makes items + charges lower than grandTotal by exactly that discount amount, keep the item amount that reconciles to grandTotal and do not mark it as itemDiscount.

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

const ITEM_NAME_NORMALIZATION_PROMPT = `
You conservatively clean OCR-extracted receipt item names.

Use only raw_name.
Do not use merchant, item_code, or price to invent product details.
Do not use web search or external knowledge.

Rules:
1. Expand only obvious retail abbreviations.
2. Correct only obvious OCR mistakes.
3. Preserve unclear tokens.
4. Never invent product type, animal type, flavor, size, count, weight, brand, or preparation method.
5. A short generic label is better than an unsupported guess.
6. Return exactly one item for every input index.
7. Return JSON only.

Safe examples:
KS ORG TOFU -> Kirkland Signature Organic Tofu
ORGSPRINGMIX -> Organic Spring Mix
ROT CHKN -> Rotisserie Chicken
ORG 4BRY 5LB -> Organic 4-Berry, 5 lb
TENDERLOIN -> Tenderloin
SKO 5X -> SKO 5X
TERRA DLYSSA -> Terra Dlyssa
AUSSIE BITES -> Aussie Bites
ZIPLC SLIDER -> Ziploc Slider
TIRE EXT. -> Tire Ext.

Confidence:
- 0.95 to 1.00: clear readable text or obvious expansion
- 0.85 to 0.94: safe OCR correction
- 0.60 to 0.84: partial interpretation
- 0.00 to 0.59: unclear; preserve raw text

If confidence < 0.85:
- needsVerification = true

Allowed categories:
produce, meat_seafood, dairy_eggs, bakery, pantry, frozen,
beverages, snacks, prepared_food, household, personal_care,
health_wellness, pet, baby, alcohol, restaurant,
general_merchandise, other

Return:
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
      "reason": "short explanation",
      "category": "other",
      "categoryConfidence": 0.00,
      "categoryReason": "short explanation"
    }
  ]
}
`;

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

function toReadableTitleToken(token) {
  if (!token) return token;
  if (/^[A-Z0-9]+$/.test(token)) return token;
  return token
    .split(/([-'./])/)
    .map(part => {
      if (/^[-'./]$/.test(part) || !part) return part;
      if (/^[A-Z0-9]+$/.test(part)) return part;
      return part.charAt(0).toUpperCase() + part.slice(1).toLowerCase();
    })
    .join("");
}

function applySafeLocalItemNameCleanup(name) {
  if (!name) return "Unknown Item";

  let normalized = String(name).trim().replace(/\s+/g, " ");

  for (const [pattern, replacement] of SAFE_OCR_REPLACEMENTS) {
    normalized = normalized.replace(pattern, replacement);
  }

  normalized = normalized
    .split(/\s+/)
    .flatMap(token => {
      const exactToken = token.replace(/^[^\w]+|[^\w]+$/g, "");
      const prefix = token.match(/^[^\w]+/)?.[0] || "";
      const suffix = token.match(/[^\w]+$/)?.[0] || "";
      const expansion = SAFE_ITEM_ABBREVIATIONS[exactToken];

      if (!expansion) {
        return [`${prefix}${toReadableTitleToken(exactToken || token)}${suffix}`];
      }

      const expandedTokens = expansion.split(/\s+/);
      if (expandedTokens.length === 1) {
        return [`${prefix}${expandedTokens[0]}${suffix}`];
      }
      return [`${prefix}${expandedTokens[0]}`, ...expandedTokens.slice(1, -1), `${expandedTokens.at(-1)}${suffix}`];
    })
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();

  return normalized || name;
}

function containsLikelyUnknownAbbreviation(name) {
  const tokens = String(name || "").match(/[A-Za-z0-9.]+/g) || [];
  const ordinaryReadableWords = new Set([
    "kirkland", "signature", "organic", "chicken", "guacamole", "single", "serve",
    "free", "range", "antibiotic", "rotisserie", "pack", "count", "ziploc",
    "tomatoes", "on", "the", "vine", "sliced", "extra", "virgin", "olive",
    "oil", "broccoli", "potato", "yellow", "bananas", "banana", "tenderloin",
    "spring", "mix", "spaghetti", "chopped", "onion", "chipotle", "lb", "oz",
    "aussie", "bites", "terra", "dlyssa", "slider", "tire",
  ]);

  return tokens.some(token => {
    if (/^EXT\.?$/i.test(token)) return true;
    if (/^MEDITERR$/i.test(token)) return true;
    if (/^(?=.*[A-Za-z])(?=.*\d)[A-Za-z0-9]+$/.test(token)) return true;
    if (/^[A-Z]{2,}$/.test(token) && !ordinaryReadableWords.has(token.toLowerCase())) return true;
    return false;
  });
}

function applyFastLocalNormalization(receipt) {
  if (!receipt?.items?.length) {
    return receipt;
  }

  return {
    ...receipt,
    items: receipt.items.map(item => {
      const rawName = item.name;
      const locallyNormalizedName = applySafeLocalItemNameCleanup(rawName);
      const containsUnknownAbbreviation = containsLikelyUnknownAbbreviation(locallyNormalizedName);

      return {
        ...item,
        rawName,
        normalizedName: locallyNormalizedName,
        normalizationSource: "local",
        normalizationConfidence: locallyNormalizedName === item.name ? 0.5 : 0.85,
        normalizationAmbiguous: containsUnknownAbbreviation,
        needsNameVerification: containsUnknownAbbreviation,
        possibleNameAlternatives: [],
        normalizationReason: containsUnknownAbbreviation
          ? "Applied safe local cleanup and preserved unclear tokens."
          : "Applied safe local normalization.",
        category: inferFallbackItemCategory(locallyNormalizedName),
        categoryConfidence: 0.5,
        categoryReason: "Category inferred locally from normalized receipt text.",
      };
    }),
  };
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

async function runMistralOcr({
  buffer,
  mimeType,
  reqId,
  documentAnnotationFormat,
  documentAnnotationPrompt,
}) {
  console.log(`[${reqId}] Calling Mistral OCR (${mimeType})...`);

  const result = await client.ocr.process({
    model: MISTRAL_OCR_MODEL,
    document: buildMistralDocument(buffer, mimeType),
    confidenceScoresGranularity: "word",
    documentAnnotationFormat,
    documentAnnotationPrompt,
  });

  const pages = result.pages || [];
  const ocrText = pages.map(page => page.markdown || "").join("\n\n");

  return {
    ocrText,
    pages,
    pageCount: pages.length || 1,
    model: MISTRAL_OCR_MODEL,
    wordConfidenceScores: pages.flatMap(page => page.words || page.wordConfidenceScores || []),
    lowConfidenceFields: [],
    documentAnnotation: result.documentAnnotation || null,
    result,
  };
}

async function callMistralOCR(imageBuffer, mimeType, reqId) {
  const ocr = await runMistralOcr({
    buffer: imageBuffer,
    mimeType,
    reqId,
    documentAnnotationFormat: responseFormatFromZodObject(MistralReceiptSchema),
    documentAnnotationPrompt: EXTRACTION_PROMPT,
  });

  let parsed = null;
  try {
    parsed = parseAndValidateDocumentAnnotation(ocr.documentAnnotation, MistralReceiptSchema);
    console.log(`[${reqId}] ✓ Structured extraction successful`);
  } catch (err) {
    console.log(`[${reqId}] ⚠️ Structured extraction validation failed: ${err.message}`);
  }

  return { parsed, ocrText: ocr.ocrText, result: ocr.result, ocr };
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

      return {
        name: normalizeItemName(item.name),
        amount: round2(item.amount),
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

function sumPositiveItemDiscounts(items) {
  return round2((items || []).reduce((sum, item) => {
    const discount = item.itemDiscount ?? 0;
    return sum + (discount > 0 ? discount : 0);
  }, 0));
}

function buildRestoreItemDiscountCandidate(normalized, reqId) {
  const reconciliation = reconcileReceipt(normalized);
  const grandTotal = normalized.grandTotal;

  if (grandTotal == null || reconciliation.calculatedFromItems == null) {
    return null;
  }

  const totalItemDiscounts = sumPositiveItemDiscounts(normalized.items);
  if (totalItemDiscounts <= 0) {
    return null;
  }

  const signedTotalGap = round2(grandTotal - reconciliation.calculatedFromItems);
  if (signedTotalGap <= 0) {
    return null;
  }

  if (Math.abs(signedTotalGap - totalItemDiscounts) > 0.01) {
    return null;
  }

  console.log(
    `[${reqId}] Item discounts match positive total gap (${signedTotalGap.toFixed(2)}); trying non-subtractive discount repair`
  );

  return {
    label: "restore_non_subtractive_item_discounts",
    receipt: {
      ...normalized,
      items: normalized.items.map(item => {
        const discount = item.itemDiscount ?? 0;
        if (discount <= 0) {
          return item;
        }

        const restoredAmount = round2((item.amount || 0) + discount);
        return {
          ...item,
          amount: restoredAmount,
          originalAmount: null,
          itemDiscount: null,
          itemDiscountLabel: null,
        };
      }),
      notes: [
        normalized.notes,
        "A printed promo/savings label matched the receipt total gap, so it was treated as non-subtractive display text.",
      ].filter(Boolean).join(" "),
    },
    changes: [
      `Restored ${totalItemDiscounts.toFixed(2)} to item amounts because the receipt total did not subtract those item discounts`,
    ],
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

  const itemDiscountRepair = buildRestoreItemDiscountCandidate(normalized, reqId);
  if (itemDiscountRepair) {
    candidates.push(itemDiscountRepair);
  }

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
    const itemDiscountRepair = buildRestoreItemDiscountCandidate(normalized, reqId);

    if (itemDiscountRepair) {
      const scored = [
        { label: "original", receipt: normalized, changes: [] },
        itemDiscountRepair,
      ].map(c => scoreInterpretation(c, reqId));
      scored.sort((a, b) => a.score - b.score);

      const best = scored[0];
      console.log(`[${reqId}] No suspicious items detected, but discount repair was evaluated`);
      console.log(`[${reqId}] ✓ Selected: ${best.label} (score: ${best.score.toFixed(3)})`);

      if (best.changes.length > 0) {
        console.log(`[${reqId}] Changes applied:`);
        best.changes.forEach(change => console.log(`[${reqId}]   - ${change}`));
      }

      return {
        receipt: best.receipt,
        selectedCandidate: best.label,
        candidatesTried: scored.length,
        suspicious: [],
        changes: best.changes,
        allCandidates: scored,
      };
    }

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
const ITEM_NAME_NORMALIZATION_TIMEOUT_MS = 6000;

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
    items: (receipt.items || []).map(item => {
      const fallbackName = item.normalizedName || item.name;
      return {
        ...item,
        rawName: item.rawName || item.name,
        normalizedName: fallbackName,
        normalizationSource: item.normalizationSource || "fallback",
        normalizationConfidence: item.normalizationConfidence ?? 0,
        normalizationAmbiguous: item.normalizationAmbiguous ?? true,
        needsNameVerification: item.needsNameVerification ?? true,
        possibleNameAlternatives: item.possibleNameAlternatives ?? [],
        normalizationReason: item.normalizationReason || "Normalization unavailable; preserved raw receipt text.",
        category: item.category || inferFallbackItemCategory(fallbackName),
        categoryConfidence: item.categoryConfidence ?? 0.35,
        categoryReason: item.categoryReason || "Fallback category inferred from raw receipt text.",
      };
    }),
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
          normalizationSource: "mistral",
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
  if (resolutionResult?.selectedCandidate && resolutionResult.selectedCandidate !== "original") {
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
      nameNormalizationStatus: "local_complete",
      timings,
    };
  }

  const hasRefund = hasRefundIndicators(ocrText);
  const { confidence, status } = determineParseStatus(reconciliation, parsed, hasRefund, resolutionResult);

  let route = "mistral_single_pass";
  let routeReason = "mistral_structured_receipt_parse";

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
      normalizationSource: item.normalizationSource || "local",
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
      category: item.category || "other",
      categoryConfidence: item.categoryConfidence ?? 0,
      categoryReason: item.categoryReason ?? "Category unavailable.",
      normalizationConfidence: item.normalizationConfidence ?? 0,
      normalizationAmbiguous: item.normalizationAmbiguous ?? true,
      needsNameVerification: item.needsNameVerification ?? true,
      possibleNameAlternatives: item.possibleNameAlternatives ?? [],
      normalizationReason:
        item.normalizationReason ??
        "Preserved raw receipt text.",
    })),
    subtotal: parsed.subtotal,
    tax: parsed.tax,
    tip: parsed.tip,
    fees: parsed.fees,
    grandTotal: parsed.grandTotal,
    confidence,
    status,
    notes: parsed.notes,
    nameNormalizationStatus: "local_complete",
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
    debug: ENABLE_DEBUG_RESPONSE ? {
      parser_version: "production_v3_mistral_single_pass",
      model_used: result?.model || "mistral-ocr-latest",
      ocr_text_length: ocrText.length,
      ocr_text: ocrText,
      rejected_items: rejected || [],
      has_refund_indicators: hasRefund,
      item_name_normalization: {
        model: null,
        enabled: true,
        status: "local_complete",
        items: parsed.items.map(item => ({
          rawName: item.rawName || item.name,
          normalizedName: item.normalizedName || item.name,
          source: item.normalizationSource || "local",
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
        enabled: false,
        reason: "disabled_to_preserve_mistral_itemization_and_discount_interpretation",
        suspicious_items_detected: resolutionResult?.suspicious?.length || 0,
        suspicious_items: (resolutionResult?.suspicious || []).map(s => ({
          name: s.item.name,
          amount: s.item.amount,
          flags: s.flags,
          suspicion_score: s.suspicionScore,
        })),
        candidates_tried: resolutionResult?.candidatesTried || 0,
        selected_candidate: resolutionResult?.selectedCandidate || "not_run",
        changes_applied: resolutionResult?.changes || [],
      },
      arithmetic_breakdown: {
        items_detail: reconciliation.itemBreakdown,
        formula: `sum(items) + tax + tip + fees - orderDiscount = calculated`,
        calculation: `${reconciliation.itemSum} + ${parsed.tax ?? 0} + ${parsed.tip ?? 0} + ${parsed.fees ?? 0} - ${parsed.orderLevelDiscount ?? 0} = ${reconciliation.calculatedFromItems}`,
        vs_grand_total: `${reconciliation.calculatedFromItems} vs ${parsed.grandTotal ?? "null"}`,
        gap: reconciliation.totalGap != null ? `$${reconciliation.totalGap.toFixed(2)}` : "N/A",
      },
    } : undefined
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

function requireAdminAuth(req, res, next) {
  const authHeader = req.headers.authorization || "";
  const token = ADMIN_BEARER_TOKEN || (process.env.NODE_ENV !== "production" ? APP_BEARER_TOKEN : "");
  if (!token || authHeader !== `Bearer ${token}`) {
    return res.status(401).json({ ok: false, error: "Admin authorization required" });
  }
  next();
}

app.post("/parse-receipt", requireAppAuth, async (req, res) => {
  const reqId = requestIdFrom(req);
  const startedAt = Date.now();
  let tempImagePath = null;
  const analyticsContext = analyticsContextFromRequest(req, reqId);
  const timings = {
    decode_ms: 0,
    temp_file_write_ms: 0,
    ocr_ms: 0,
    deterministic_cleanup_ms: 0,
    contradiction_resolution_ms: 0,
    reconciliation_ms: 0,
    total_ms: 0,
  };

  console.log("\n" + "=".repeat(80));
  console.log(`[${reqId}] RECEIPT PARSE REQUEST (MISTRAL SINGLE PASS)`);
  console.log("=".repeat(80));

  try {
    const { imageBase64, mimeType = "image/jpeg", sourceType = "unknown", mode = "unknown" } = req.body || {};

    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_upload_started",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: mimeType,
        expected_document_type: "receipt",
        mode,
      },
    });

    if (!imageBase64) {
      console.log(`[${reqId}] ✗ Missing imageBase64`);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: { request_id: reqId, failure_reason: "invalid_document", error_code: "MISSING_IMAGE" },
      });
      return res.status(400).json({ error: "Missing imageBase64 in request body" });
    }

    const decodeStart = Date.now();
    let base64Data = imageBase64;
    const idx = base64Data.indexOf("base64,");
    if (idx >= 0) {
      base64Data = base64Data.slice(idx + 7);
    }

    const buffer = Buffer.from(base64Data, "base64");
    const uploadValidation = validateUploadBuffer(buffer, mimeType);
    if (!uploadValidation.ok) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: normalizeAnalyticsFailureReason("receipt", uploadValidation.code),
          error_code: uploadValidation.code,
          file_type: mimeType,
        },
      });
      return res.status(uploadValidation.status).json({
        error: { code: uploadValidation.code, message: uploadValidation.message },
        request_id: reqId,
        timings,
      });
    }
    const safeMimeType = uploadValidation.mimeType;
    timings.decode_ms = Date.now() - decodeStart;
    console.log(`[${reqId}] Image size: ${(buffer.length / 1024).toFixed(2)} KB`);
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_upload_validated",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: safeMimeType,
        image_size_bytes: buffer.length,
        mode,
      },
    });

    if (buffer.length > RECOMMENDED_IMAGE_MAX_BYTES) {
      console.log(`[${reqId}] Large image detected. Compress on the client for faster OCR.`);
    }

    if (buffer.length < 128) {
      console.log(`[${reqId}] ✗ Image too small`);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: { request_id: reqId, failure_reason: "invalid_document", error_code: "IMAGE_TOO_SMALL" },
      });
      return res.status(400).json({ error: "Image too small or corrupt" });
    }

    if (SAVE_TEMP_RECEIPTS) {
      const tempFileWriteStart = Date.now();
      const ext = getTempExtension(safeMimeType);
      const filename = `receipt_${Date.now()}_${Math.random().toString(36).slice(2)}${ext}`;
      tempImagePath = path.join(TEMP_DIR, filename);
      await fs.promises.writeFile(tempImagePath, buffer);
      timings.temp_file_write_ms = Date.now() - tempFileWriteStart;
    }

    const ocrStart = Date.now();
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_ocr_started",
      properties: { request_id: reqId, ocr_provider: "mistral", file_type: safeMimeType, mode },
    });
    const { parsed, ocrText, result } = await callMistralOCR(buffer, safeMimeType, reqId);
    timings.ocr_ms = Date.now() - ocrStart;
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_ocr_completed",
      properties: {
        request_id: reqId,
        ocr_provider: "mistral",
        processing_time_ms: timings.ocr_ms,
        detected_document_type: "receipt_candidate",
        ocr_text_length: ocrText.length,
      },
    });

    const receiptClassification = classifyReceiptUpload({ ocrText, parsed });
    console.log(`[${reqId}] Receipt classification: ${receiptClassification.ok ? "receipt" : "reject"} confidence=${receiptClassification.confidence} reason=${receiptClassification.reason}`);
    if (!receiptClassification.ok) {
      timings.total_ms = Date.now() - startedAt;
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: "invalid_document",
          detected_document_type: "not_receipt",
          classification_confidence: receiptClassification.confidence,
          processing_time_ms: timings.total_ms,
          error_code: receiptClassification.code || "NOT_A_RECEIPT",
        },
      });
      return res.status(422).json({
        ok: false,
        error: {
          code: receiptClassification.code || "NOT_A_RECEIPT",
          message: "This does not look like a receipt. Please scan a receipt image instead.",
        },
        request_id: reqId,
        classification: receiptClassification,
        timings,
      });
    }
    
    let normalized = null;
    let rejected = [];
    let resolutionResult = {
      receipt: null,
      selectedCandidate: "not_run",
      candidatesTried: 0,
      suspicious: [],
      changes: [],
      allCandidates: [],
    };
    
    if (parsed) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_parse_started",
        properties: { request_id: reqId, parser: "mistral_structured_output", mode },
      });
      const deterministicCleanupStart = Date.now();
      normalized = normalizeParsedReceipt(parsed);
      timings.deterministic_cleanup_ms = Date.now() - deterministicCleanupStart;

      resolutionResult = {
        receipt: normalized,
        selectedCandidate: "not_run",
        candidatesTried: 0,
        suspicious: [],
        changes: [],
        allCandidates: [],
      };

      normalized = applyFastLocalNormalization(normalized);
      resolutionResult.receipt = normalized;
    }

    const reconciliationStart = Date.now();
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
    timings.reconciliation_ms = Date.now() - reconciliationStart;

    timings.total_ms = Date.now() - startedAt;

    // Enhanced logging
    console.log(`[${reqId}] Final Results:`);
    console.log(`[${reqId}]   - Items: ${normalized?.items.length || 0} (Mistral itemization preserved)`);
    
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

    console.log(`[${reqId}] Timing breakdown:`);
    console.log(`[${reqId}]   - Decode: ${timings.decode_ms}ms`);
    console.log(`[${reqId}]   - Temp file write: ${timings.temp_file_write_ms}ms`);
    console.log(`[${reqId}]   - OCR: ${timings.ocr_ms}ms`);
    console.log(`[${reqId}]   - Mistral result shaping: ${timings.deterministic_cleanup_ms}ms`);
    console.log(`[${reqId}]   - Contradiction resolution: ${timings.contradiction_resolution_ms}ms (disabled)`);
    console.log(`[${reqId}]   - Reconciliation: ${timings.reconciliation_ms}ms`);
    console.log(`[${reqId}]   - Total: ${timings.total_ms}ms`);

    const response = buildApiResponse(
      { parsed: normalized, ocrText, result, reconciliation, rejected, resolutionResult },
      timings,
      reqId
    );
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_parse_completed",
      properties: {
        request_id: reqId,
        processing_time_ms: timings.total_ms,
        item_count: normalized?.items.length || 0,
        subtotal_found: normalized?.subtotal != null,
        tax_found: normalized?.tax != null,
        tip_found: normalized?.tip != null,
        fees_found: normalized?.fees != null,
        discount_found: normalized?.orderLevelDiscount != null || (normalized?.items || []).some(item => (item.itemDiscount ?? 0) > 0),
        grand_total_found: normalized?.grandTotal != null,
        reconciliation_passed: Boolean(reconciliation.mathCheckPassed),
        correction_count: 0,
        status: response.status,
        route: response.route,
      },
    });

    console.log(`[${reqId}] ✓ Complete in ${timings.total_ms}ms`);
    console.log(`[${reqId}] Status: ${response.status} | Confidence: ${response.confidence}`);
    console.log(`[${reqId}] Route: ${response.route}`);
    console.log("=".repeat(80) + "\n");

    return res.json(response);

  } catch (error) {
    timings.total_ms = Date.now() - startedAt;
    console.error(`[${reqId}] ✗ ERROR:`, error);
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: error?.message?.toLowerCase().includes("ocr") ? "receipt_ocr_failed" : "receipt_parse_failed",
      properties: {
        request_id: reqId,
        failure_reason: normalizeAnalyticsFailureReason("receipt", error?.code || error?.message),
        error_code: error?.code || "UNKNOWN_PARSE_ERROR",
        sanitized_message: safeString(error?.message || "unknown_error"),
        processing_time_ms: timings.total_ms,
      },
    });
    return res.status(500).json({
      error: "Failed to parse receipt",
      detail: error?.message || "unknown_error",
      request_id: reqId,
      timings,
    });
  } finally {
    if (SAVE_TEMP_RECEIPTS && tempImagePath) {
      try {
        await fs.promises.unlink(tempImagePath);
      } catch {}
    }
  }
});

app.get("/", (req, res) => {
  res.json({ ok: true, service: "financial-document-parser", health: "/health" });
});

app.post("/analytics/events", requireAppAuth, (req, res) => {
  const reqId = requestIdFrom(req);
  const context = analyticsContextFromRequest(req, reqId);
  const events = Array.isArray(req.body?.events) ? req.body.events : [req.body];
  let accepted = 0;

  for (const event of events.slice(0, 50)) {
    if (!event?.event_name && !event?.eventName) continue;
    trackAnalyticsEvent({
      ...context,
      user_id: event.user_id ?? event.userId ?? context.user_id,
      anonymous_id: event.anonymous_id ?? event.anonymousId ?? context.anonymous_id,
      session_id: event.session_id ?? event.sessionId ?? context.session_id,
      request_id: event.request_id ?? event.requestId ?? context.request_id,
      event_name: event.event_name ?? event.eventName,
      platform: event.platform ?? context.platform,
      app_version: event.app_version ?? event.appVersion ?? context.app_version,
      properties: event.properties || {},
    });
    accepted += 1;
  }

  res.json({ ok: true, accepted, request_id: reqId });
});

function parseAnalyticsRange(query) {
  const now = new Date();
  const preset = query.range || "7d";
  let from = query.from;
  let to = query.to;
  if (!from) {
    const days =
      preset === "today" ? 1 :
      preset === "30d" ? 30 :
      preset === "all" ? 3650 :
      7;
    from = new Date(now.getTime() - days * 24 * 60 * 60 * 1000).toISOString();
  }
  if (!to) to = now.toISOString();
  return { from, to };
}

function filterAnalyticsEvents(events, query) {
  const filters = {
    user_id: query.user_id,
    anonymous_id: query.anonymous_id,
    session_id: query.session_id,
    request_id: query.request_id,
    app_version: query.app_version,
    platform: query.platform,
    event_name: query.event_name,
  };
  return events.filter(event => {
    for (const [key, value] of Object.entries(filters)) {
      if (value && String(event[key] || "") !== String(value)) return false;
    }
    const props = event.properties || {};
    if (query.mode && props.mode !== query.mode) return false;
    if (query.document_type && props.detected_document_type !== query.document_type && props.expected_document_type !== query.document_type) return false;
    if (query.file_type && props.file_type !== query.file_type) return false;
    if (query.error_category && props.failure_reason !== query.error_category && props.error_code !== query.error_category) return false;
    if (query.subscription_product && props.product_id !== query.subscription_product) return false;
    return true;
  });
}

app.get("/admin/analytics/summary", requireAdminAuth, async (req, res) => {
  const range = parseAnalyticsRange(req.query);
  const events = filterAnalyticsEvents(await readAnalyticsEvents({ ...range, limit: 20000 }), req.query);
  res.json({ ok: true, range, summary: summarizeAnalytics(events) });
});

app.get("/admin/analytics/events", requireAdminAuth, async (req, res) => {
  const range = parseAnalyticsRange(req.query);
  const limit = Math.min(Number(req.query.limit || 500), 5000);
  const events = filterAnalyticsEvents(await readAnalyticsEvents({ ...range, limit: 20000 }), req.query).slice(-limit).reverse();
  res.json({ ok: true, range, events });
});

app.get("/admin/analytics", requireAdminAuth, async (req, res) => {
  const range = parseAnalyticsRange(req.query);
  const events = filterAnalyticsEvents(await readAnalyticsEvents({ ...range, limit: 20000 }), req.query);
  const summary = summarizeAnalytics(events);
  const recent = events.slice(-100).reverse();
  res.type("html").send(renderAnalyticsDashboard({ range, summary, recent }));
});

function renderAnalyticsDashboard({ range, summary, recent }) {
  const eventRows = recent.map(event => `
    <tr>
      <td>${escapeHtml(event.created_at)}</td>
      <td>${escapeHtml(event.event_name)}</td>
      <td>${escapeHtml(event.user_id || "")}</td>
      <td>${escapeHtml(event.session_id || "")}</td>
      <td>${escapeHtml(event.request_id || "")}</td>
      <td>${escapeHtml(event.properties?.failure_reason || event.properties?.error_code || "")}</td>
      <td><pre>${escapeHtml(JSON.stringify(event.properties || {}, null, 2))}</pre></td>
    </tr>
  `).join("");

  const countCards = Object.entries(summary.counts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 24)
    .map(([name, count]) => `<div class="card"><strong>${escapeHtml(name)}</strong><span>${count}</span></div>`)
    .join("");

  const errors = summary.most_common_errors
    .map(error => `<li>${escapeHtml(error.reason)} <strong>${error.count}</strong></li>`)
    .join("");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Dutchie Analytics</title>
  <style>
    :root { color-scheme: light; --ink:#1c1a16; --cream:#fffdf7; --line:#ded8ca; --muted:#777168; }
    body { margin:0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background:var(--cream); color:var(--ink); }
    header { padding:28px 32px 18px; border-bottom:2px dashed var(--line); }
    h1 { margin:0; font-size:28px; letter-spacing:.04em; }
    main { padding:24px 32px 48px; }
    .grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap:12px; margin:18px 0 28px; }
    .card { border:1px solid var(--line); background:white; padding:14px; display:flex; justify-content:space-between; gap:12px; }
    .card strong { font-size:11px; text-transform:uppercase; color:var(--muted); }
    .card span { font-size:24px; font-weight:800; }
    .tabs { display:grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap:12px; }
    section { margin-top:26px; }
    table { width:100%; border-collapse:collapse; background:white; border:1px solid var(--line); }
    th, td { padding:10px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; font-size:12px; }
    th { background:#f3efe5; text-transform:uppercase; letter-spacing:.08em; }
    pre { white-space:pre-wrap; max-width:420px; margin:0; color:var(--muted); }
    a { color:var(--ink); }
  </style>
</head>
<body>
  <header>
    <h1>Dutchie Analytics</h1>
    <p>Range: ${escapeHtml(range.from)} to ${escapeHtml(range.to)}</p>
  </header>
  <main>
    <div class="grid">
      <div class="card"><strong>Total events</strong><span>${summary.total_events}</span></div>
      <div class="card"><strong>Unique users</strong><span>${summary.unique_users}</span></div>
      <div class="card"><strong>Unique sessions</strong><span>${summary.unique_sessions}</span></div>
      <div class="card"><strong>Receipt success</strong><span>${summary.receipt_success_rate}%</span></div>
      <div class="card"><strong>Statement success</strong><span>${summary.statement_success_rate}%</span></div>
      <div class="card"><strong>OCR success</strong><span>${summary.ocr_success_rate}%</span></div>
      <div class="card"><strong>Avg ms</strong><span>${summary.response_time_ms.average}</span></div>
      <div class="card"><strong>P95 ms</strong><span>${summary.response_time_ms.p95}</span></div>
    </div>

    <section>
      <h2>Event Counts</h2>
      <div class="grid">${countCards || "<p>No events yet.</p>"}</div>
    </section>

    <section>
      <h2>Most Common Errors</h2>
      <ul>${errors || "<li>No errors recorded.</li>"}</ul>
    </section>

    <section>
      <h2>Recent Events</h2>
      <table>
        <thead>
          <tr><th>Timestamp</th><th>Event</th><th>User</th><th>Session</th><th>Request</th><th>Error</th><th>Properties</th></tr>
        </thead>
        <tbody>${eventRows || "<tr><td colspan='7'>No events yet.</td></tr>"}</tbody>
      </table>
    </section>
  </main>
</body>
</html>`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

app.post("/parse-financial-document", requireAppAuth, async (req, res) => {
  const reqId = requestIdFrom(req);
  const startedAt = Date.now();
  let tempPath = null;
  const analyticsContext = analyticsContextFromRequest(req, reqId);

  console.log("\n" + "=".repeat(80));
  console.log(`[${reqId}] FINANCIAL DOCUMENT PARSE REQUEST`);
  console.log("=".repeat(80));

  try {
    const { fileBase64, imageBase64, mimeType = "image/jpeg", uploadIntent = "scan_statement", sourceType = "screenshot", mode = "statement" } = req.body || {};
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_upload_started",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: mimeType,
        expected_document_type: "bank_statement",
        mode,
      },
    });
    const encoded = fileBase64 || imageBase64;
    if (!encoded) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: { request_id: reqId, failure_reason: "invalid_statement", error_code: "MISSING_FILE" },
      });
      return res.status(400).json({ ok: false, request_id: reqId, error: { code: "MISSING_FILE", message: "Missing fileBase64 in request body." } });
    }

    const buffer = decodeBase64Payload(encoded);
    const uploadValidation = validateUploadBuffer(buffer, mimeType);
    if (!uploadValidation.ok) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: normalizeAnalyticsFailureReason("statement", uploadValidation.code),
          error_code: uploadValidation.code,
          file_type: mimeType,
        },
      });
      return res.status(uploadValidation.status).json({ ok: false, request_id: reqId, error: { code: uploadValidation.code, message: uploadValidation.message } });
    }

    const safeMimeType = uploadValidation.mimeType;
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_upload_validated",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: safeMimeType,
        file_size_bytes: buffer.length,
        mode,
      },
    });
    const hash = fileHash(buffer);
    const cached = getCachedParse(hash, "financial_document");
    if (cached) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_parse_completed",
        properties: {
          request_id: reqId,
          cache_hit: true,
          detected_document_type: cached.documentType,
          transaction_count: cached.data?.transactions?.length || 0,
          processing_time_ms: Date.now() - startedAt,
        },
      });
      return res.json({ ...cached, request_id: cached.request_id || reqId });
    }

    if (SAVE_TEMP_RECEIPTS) {
      const filename = `financial_${Date.now()}_${Math.random().toString(36).slice(2)}${getTempExtension(safeMimeType)}`;
      tempPath = path.join(TEMP_DIR, filename);
      await fs.promises.writeFile(tempPath, buffer);
    }

    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_extraction_started",
      properties: { request_id: reqId, ocr_provider: "mistral", file_type: safeMimeType, mode },
    });
    const ocr = await runMistralOcr({
      buffer,
      mimeType: safeMimeType,
      reqId,
      documentAnnotationFormat: responseFormatFromZodObject(BankDocumentSchema),
      documentAnnotationPrompt: BANK_DOCUMENT_PROMPT,
    });

    if (safeMimeType === "application/pdf" && ocr.pageCount > MAX_PDF_PAGES) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: "pdf_extraction_failed",
          error_code: "PDF_PAGE_LIMIT_EXCEEDED",
          page_count: ocr.pageCount,
        },
      });
      return res.status(413).json({ ok: false, request_id: reqId, error: { code: "PDF_PAGE_LIMIT_EXCEEDED", message: `This PDF has ${ocr.pageCount} pages. The current limit is ${MAX_PDF_PAGES} pages.` } });
    }
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_extraction_completed",
      properties: {
        request_id: reqId,
        ocr_provider: "mistral",
        processing_time_ms: Date.now() - startedAt,
        page_count: ocr.pageCount,
        low_confidence_field_count: ocr.lowConfidenceFields?.length || 0,
      },
    });

    const classification = classifyFinancialDocument({ ocrText: ocr.ocrText, uploadIntent, sourceType, mimeType: safeMimeType });
    const baseResponse = {
      ok: true,
      parseVersion: "financial_doc_parser_v1",
      documentType: classification.documentType,
      classification: { confidence: classification.confidence, reason: classification.reason },
      data: {},
      reconciliation: { status: "not_applicable", reason: "No reconciliation was run for this document type." },
      warnings: [],
      reviewRequired: false,
      ocr: { model: ocr.model, pageCount: ocr.pageCount, lowConfidenceFields: ocr.lowConfidenceFields },
      request_id: reqId,
    };

    if (["unsupported", "ambiguous", "receipt"].includes(classification.documentType)) {
      const response = {
        ...baseResponse,
        ok: false,
        error: {
          code: "NOT_A_STATEMENT",
          message: "This does not look like a statement or transaction-history screenshot. Please upload a bank/credit-card statement, PDF, or transaction screenshot.",
        },
        reviewRequired: true,
        warnings: [classification.reason],
      };
      setCachedParse(hash, "financial_document", response);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: classification.documentType === "receipt" ? "invalid_statement" : "screenshot_classification_failed",
          detected_document_type: classification.documentType,
          classification_confidence: classification.confidence,
          error_code: "NOT_A_STATEMENT",
          processing_time_ms: Date.now() - startedAt,
        },
      });
      return res.status(422).json(response);
    }

    let bankDocument;
    let bankRaw;
    try {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_parse_started",
        properties: { request_id: reqId, parser: "mistral_structured_output", detected_document_type: classification.documentType },
      });
      bankRaw = parseAndValidateDocumentAnnotation(ocr.documentAnnotation, BankDocumentSchema);
      bankDocument = normalizeBankDocument(bankRaw, classification.documentType);
    } catch (annotationError) {
      const fallbackOnlyTransactions = extractBankTransactionsFromOcrText(ocr.ocrText, classification.documentType);
      if (fallbackOnlyTransactions.length === 0) {
        throw annotationError;
      }
      bankDocument = normalizeBankDocument({
        documentType: classification.documentType,
        institutionName: null,
        accountName: null,
        accountLast4: null,
        statementPeriod: { startDate: null, endDate: null },
        currency: "USD",
        partialDocument: sourceType !== "pdf",
        transactions: fallbackOnlyTransactions,
        warnings: ["Structured extraction was incomplete, so transaction rows were recovered from OCR text."],
      }, classification.documentType);
    }

    const fallbackTransactions = extractBankTransactionsFromOcrText(ocr.ocrText, bankDocument.documentType);
    if (fallbackTransactions.length > 0 && bankDocument.transactions.length < fallbackTransactions.length) {
      bankDocument.transactions = mergeBankTransactions(bankDocument.transactions, fallbackTransactions);
      bankDocument.warnings.push("Some transaction rows were recovered from OCR text because structured extraction was incomplete.");
    }
    const reconciliation = reconcileBankDocument(bankDocument);
    const warnings = [...(bankDocument.warnings || [])];
    if (bankDocument.partialDocument) warnings.push("This appears to be a partial screenshot. Only the visible transactions were imported.");
    if (bankDocument.transactions.length === 0) {
      warnings.push("No visible transactions were detected.");
      const response = {
        ...baseResponse,
        ok: false,
        error: {
          code: "NO_STATEMENT_TRANSACTIONS",
          message: "No statement transactions were detected. Please upload a clearer statement or transaction-history screenshot.",
        },
        documentType: bankDocument.documentType,
        data: bankDocument,
        reconciliation,
        warnings,
        reviewRequired: true,
      };
      setCachedParse(hash, "financial_document", response);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_parse_failed",
        properties: {
          request_id: reqId,
          failure_reason: "transaction_extraction_failed",
          detected_document_type: bankDocument.documentType,
          error_code: "NO_STATEMENT_TRANSACTIONS",
          processing_time_ms: Date.now() - startedAt,
        },
      });
      return res.status(422).json(response);
    }

    const response = {
      ...baseResponse,
      documentType: bankDocument.documentType,
      data: bankDocument,
      reconciliation,
      warnings,
      reviewRequired: bankDocument.transactions.length === 0 || classification.confidence < 0.75,
    };
    setCachedParse(hash, "financial_document", response);
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_parse_completed",
      properties: {
        request_id: reqId,
        detected_document_type: bankDocument.documentType,
        transaction_count: bankDocument.transactions.length,
        processing_time_ms: Date.now() - startedAt,
        reconciliation_status: reconciliation.status,
        file_type: safeMimeType,
        mode,
      },
    });
    console.log(`[${reqId}] ✓ Financial document parse complete in ${Date.now() - startedAt}ms type=${response.documentType}`);
    return res.json(response);
  } catch (error) {
    const code = error?.code || (error?.message?.toLowerCase().includes("timeout") ? "MISTRAL_TIMEOUT" : "UNKNOWN_PARSE_ERROR");
    console.error(`[${reqId}] ✗ FINANCIAL DOCUMENT ERROR:`, code, error?.message);
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: code === "MISTRAL_TIMEOUT" ? "statement_extraction_failed" : "statement_parse_failed",
      properties: {
        request_id: reqId,
        failure_reason: normalizeAnalyticsFailureReason("statement", code || error?.message),
        error_code: code,
        sanitized_message: safeString(error?.message || "Failed to parse financial document."),
        processing_time_ms: Date.now() - startedAt,
      },
    });
    return res.status(code === "MALFORMED_ANNOTATION" || code === "SCHEMA_VALIDATION_FAILED" ? 422 : 500).json({ ok: false, request_id: reqId, error: { code, message: error?.message || "Failed to parse financial document." } });
  } finally {
    if (SAVE_TEMP_RECEIPTS && tempPath) {
      try { await fs.promises.unlink(tempPath); } catch {}
    }
  }
});

app.post("/normalize-item-names", requireAppAuth, async (req, res) => {
  const reqId = `req_${Date.now().toString(36)}`;

  console.log("\n" + "=".repeat(80));
  console.log(`[${reqId}] OPTIONAL ITEM-NAME NORMALIZATION REQUEST`);
  console.log("=".repeat(80));

  try {
    const { merchant = "", items = [] } = req.body || {};

    if (!Array.isArray(items)) {
      return res.status(400).json({ error: "items must be an array" });
    }

    const receipt = applyFastLocalNormalization({
      merchant,
      items: items.map(item => ({
        name: item.name || item.rawName || "Unknown Item",
        itemCode: item.itemCode ?? null,
        amount: item.amount,
        originalAmount: item.originalAmount ?? null,
        itemDiscount: item.itemDiscount ?? null,
        itemDiscountLabel: item.itemDiscountLabel ?? null,
        qty: item.qty,
        unitPrice: item.unitPrice,
        weightLbs: item.weightLbs,
        confidence: item.confidence,
      })),
    });

    const enriched = await normalizeItemNamesWithMistral(receipt, reqId);

    console.log(`[${reqId}] ✓ Optional item-name normalization complete`);
    console.log("=".repeat(80) + "\n");

    return res.json({
      items: (enriched.items || []).map(item => ({
        name: item.normalizedName || item.name,
        rawName: item.rawName || item.name,
        normalizedName: item.normalizedName || item.name,
        normalizationSource: item.normalizationSource || "local",
        itemCode: item.itemCode ?? null,
        amount: item.amount,
        originalAmount: item.originalAmount ?? null,
        itemDiscount: item.itemDiscount ?? null,
        itemDiscountLabel: item.itemDiscountLabel ?? null,
        hasItemDiscount: (item.itemDiscount ?? 0) > 0,
        qty: item.qty,
        unitPrice: item.unitPrice,
        weightLbs: item.weightLbs,
        confidence: item.confidence,
        category: item.category || "other",
        categoryConfidence: item.categoryConfidence ?? 0,
        categoryReason: item.categoryReason ?? "Category unavailable.",
        normalizationConfidence: item.normalizationConfidence ?? 0,
        normalizationAmbiguous: item.normalizationAmbiguous ?? true,
        needsNameVerification: item.needsNameVerification ?? true,
        possibleNameAlternatives: item.possibleNameAlternatives ?? [],
        normalizationReason:
          item.normalizationReason ??
          "Preserved raw receipt text.",
      })),
    });
  } catch (error) {
    console.error(`[${reqId}] ✗ OPTIONAL NORMALIZATION ERROR:`, error);
    return res.status(500).json({
      error: "Failed to normalize item names",
      detail: error?.message || "unknown_error",
    });
  }
});

app.get("/health", (req, res) => {
  res.json({
    ok: true,
    timestamp: new Date().toISOString(),
    version: "2.1.0",
    parser: "production_mistral_single_pass_receipt_parser",
    analytics: {
      storage: "jsonl_file",
      retentionDays: ANALYTICS_RETENTION_DAYS,
      adminEnabled: Boolean(ADMIN_BEARER_TOKEN) || process.env.NODE_ENV !== "production",
    },
  });
});

// ============================================================
// SERVER STARTUP
// ============================================================

cleanupAnalyticsEvents();

if (process.env.NODE_ENV !== "test") {
  app.listen(PORT, "0.0.0.0", () => {
    console.log("✓ Server ready on http://0.0.0.0:" + PORT);
    console.log("  Endpoint: POST /parse-receipt (Mistral single-pass receipt parsing)");
    console.log("  Endpoint: POST /parse-financial-document (statements and transaction screenshots)");
    console.log("  Endpoint: POST /normalize-item-names (optional item-name enrichment)");
    console.log("  Endpoint: POST /analytics/events (client analytics ingestion)");
    console.log("  Admin: GET /admin/analytics");
    console.log("  Health: GET /health\n");
  });
}

export {
  app,
  hashIdentifier,
  normalizeAnalyticsFailureReason,
  sanitizeAnalyticsProperties,
  safeString,
  summarizeAnalytics,
};
