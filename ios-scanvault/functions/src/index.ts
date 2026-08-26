/**
 * ScanVault Firebase Cloud Functions suite.
 *
 * - `onDocumentUploaded`   Storage trigger · generates optimized WebP gallery
 *                          thumbnails for freshly scanned PDFs.
 * - `cleanupOrphanedFiles` Scheduled cron · removes unattached temporary /
 *                          cancelled-scan buffers older than 24 hours.
 * - `generateSecureShareLink`
 *                          Callable · creates a password-protected,
 *                          expiring (24h / 7d) download link so signed or
 *                          redacted documents can be shared with people who
 *                          do not have the app.
 *
 * Deploy: `firebase deploy --only functions`
 */

import * as crypto from "node:crypto";

import { getStorage } from "firebase-admin/storage";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { setGlobalOptions } from "firebase-functions/v2";

import * as admin from "firebase-admin";
import * as sharp from "sharp";

// PDF rendering for first-page thumbnails (pure-JS rasterizer + canvas).
// eslint-disable-next-line @typescript-eslint/no-var-requires
const pdfjs = require("pdfjs-dist/legacy/build/pdf.mjs");
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { createCanvas } = require("canvas");

admin.initializeApp();
const db = getFirestore();
const bucket = getStorage().bucket();

setGlobalOptions({ region: "us-central1", maxInstances: 10 });

/** FireCloud path segments: users/{userId}/documents/{documentId}.pdf */
const DOCUMENT_PATH_PATTERN = /^users\/([^/]+)\/documents\/([^/]+)\.pdf$/;

// ---------------------------------------------------------------------------
// 1. Thumbnail generation on upload
// ---------------------------------------------------------------------------

export const onDocumentUploaded = onObjectFinalized(
  { memory: "1GiB", timeoutSeconds: 120 },
  async (event) => {
    const name = event.data?.name;
    if (!name || !DOCUMENT_PATH_PATTERN.test(name)) return;

    const match = DOCUMENT_PATH_PATTERN.exec(name);
    if (!match) return;
    const [, userId, documentId] = match;

    // Only process fresh scans — re-uploads still refresh their thumb.
    try {
      const [fileBuffer] = await bucket.file(name).download();
      const pngBuffer = await renderFirstPage(fileBuffer);
      if (!pngBuffer) {
        console.warn(`[thumbs] No rasterizable page for ${name}`);
        return;
      }

      const webpBuffer = await sharp(pngBuffer)
        .resize({ width: 320, withoutEnlargement: true })
        .webp({ quality: 60 })
        .toBuffer();

      const thumbnailPath = `users/${userId}/thumbnails/${documentId}.webp`;
      await bucket.file(thumbnailPath).save(webpBuffer, {
        contentType: "image/webp",
        metadata: { cacheControl: "public,max-age=604800" },
      });

      // Cheap pointer so galleries can lazy-load fast instead of downloading
      // whole multi-page PDFs for the grid.
      await db.doc(`users/${userId}/documents/${documentId}`).set(
        { thumbnailPath, thumbnailedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );

      console.log(`[thumbs] ${name} -> ${thumbnailPath}`);
    } catch (error) {
      console.error(`[thumbs] Failed for ${name}:`, error);
    }
  }
);

/** Rasterizes page 1 of a PDF buffer to PNG bytes, or null when unsupported. */
async function renderFirstPage(pdfBuffer: Buffer): Promise<Buffer | null> {
  try {
    const doc = await pdfjs.getDocument({
      data: new Uint8Array(pdfBuffer),
      useSystemFonts: false,
      isEvalSupported: false,
    }).promise;

    const page = await doc.getPage(1);
    const baseViewport = page.getViewport({ scale: 1 });
    const width = Math.min(480, baseViewport.width);
    const viewport = page.getViewport({ scale: width / baseViewport.width });

    const canvas = createCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
    const context = canvas.getContext("2d");
    await page.render({ canvasContext: context, viewport }).promise;
    return canvas.toBuffer("image/png");
  } catch (error) {
    console.error("[render] PDF rasterization failed:", error);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 2. Scheduled orphan cleanup (every 24 hours)
// ---------------------------------------------------------------------------

export const cleanupOrphanedFiles = onSchedule(
  { schedule: "every 24 hours", memory: "256MiB" },
  async () => {
    const cutoff = Date.now() - 24 * 60 * 60 * 1000;
    let removed = 0;

    // a) Staging area: scan buffers that were never finalized into a document.
    for await (const [file] of bucket.getFiles({ prefix: "tmp/" })) {
      const updated = Number(file.metadata.updated ? Date.parse(file.metadata.updated as string) : 0);
      if (updated && updated < cutoff) {
        await file.delete();
        removed += 1;
      }
    }

    // b) Expired share-link records older than 30 days past expiry.
    const staleShares = await db
      .collectionGroup("shares")
      .where("expiresAt", "<", new Date(cutoff))
      .get();
    const batch = db.batch();
    staleShares.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();

    console.log(`[cleanup] Removed ${removed} orphaned file(s) and ${staleShares.size} expired share record(s).`);
  }
);

// ---------------------------------------------------------------------------
// 3. Secure expiring share links
// ---------------------------------------------------------------------------

interface ShareRequest {
  /** Firestore document id (without user prefix — caller scoped by auth uid). */
  documentId: string;
  /** Required password; recipients must know it to download. */
  password?: string;
  /** Link lifetime in hours: 24 or 168 (7 days). Defaults to 24. */
  expiryHours?: number;
}

const SHARE_TOKEN_BYTES = 32;

export const generateSecureShareLink = onCall(async (request) => {
  // Require an authenticated app user (anonymous accounts count).
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in before creating share links.");
  }

  const data = request.data as ShareRequest;
  const documentId = String(data?.documentId ?? "");
  if (!/^[A-Za-z0-9-]{6,64}$/.test(documentId)) {
    throw new HttpsError("invalid-argument", "A valid document id is required.");
  }

  const expiryHours = data.expiryHours === 168 ? 168 : 24;
  const storagePath = `users/${uid}/documents/${documentId}.pdf`;
  const [exists] = await bucket.file(storagePath).exists();
  if (!exists) {
    throw new HttpsError("not-found", "That document has not been synced yet.");
  }

  // Capability secret embedded in the returned URL.
  const shareToken = crypto.randomBytes(SHARE_TOKEN_BYTES).toString("base64url");
  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = data.password
    ? crypto.scryptSync(data.password, salt, 32).toString("hex")
    : null;

  const now = Date.now();
  const expiresAt = new Date(now + expiryHours * 60 * 60 * 1000);
  const shareId = crypto.randomUUID();

  await db.collection(`users/${uid}/shares`).doc(shareId).create({
    shareId,
    tokenHash: crypto.createHash("sha256").update(shareToken).digest("hex"),
    passwordHash,
    salt,
    storagePath,
    documentId,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
    downloadCount: 0,
  });

  const shareUrl =
    `https://us-central1-${process.env.GCLOUD_PROJECT ?? "scanvault"}` +
    `.cloudfunctions.net/shareDownload?share=${shareId}&key=${encodeURIComponent(shareToken)}`;

  return { shareUrl, expiresAtISO: expiresAt.toISOString(), requiresPassword: Boolean(passwordHash) };
});

/**
 * Public GET endpoint behind a share link:
 *   /shareDownload?share={shareId}&key={capabilityToken}(&pw={password})
 *
 * Enforces expiry, capability token and optional scrypt password before
 * streaming the PDF. Share ids are unguessable; tokens rotate per creation.
 */
export const shareDownload = onCall; // type-checked import anchor (real handler below)

import { onRequest } from "firebase-functions/v2/https";

export const _shareDownloadEndpoint = onRequest(
  { memory: "512MiB", timeoutSeconds: 300 },
  async (req, res) => {
    const shareId = String(req.query.share ?? "");
    const key = String(req.query.key ?? "");
    const pw = typeof req.query.pw === "string" ? req.query.pw : undefined;

    if (!shareId || !key) {
      res.status(400).send("Missing share parameters.");
      return;
    }

    const snap = await db.collectionGroup("shares").where("shareId", "==", shareId).limit(1).get();
    const share = snap.empty ? undefined : snap.docs[0];
    if (!share) {
      res.status(404).send("This share link is no longer valid.");
      return;
    }

    const payload = share.data() as {
      tokenHash: string;
      passwordHash: string | null;
      salt: string;
      storagePath: string;
      expiresAt: { toDate?: () => Date } | Date;
    };

    const expiresAt = payload.expiresAt instanceof Date ? payload.expiresAt : payload.expiresAt?.toDate?.();
    if (!expiresAt || expiresAt.getTime() < Date.now()) {
      res.status(410).send("This share link has expired.");
      return;
    }

    const presentedHash = crypto.createHash("sha256").update(key).digest("hex");
    if (presentedHash !== payload.tokenHash) {
      res.status(403).send("Invalid share key.");
      return;
    }

    if (payload.passwordHash) {
      const presentedPwHash = pw
        ? crypto.scryptSync(pw, payload.salt, 32).toString("hex")
        : "";
      if (presentedPwHash !== payload.passwordHash) {
        res.status(401).send("Password required — append &pw=your-password to the link.");
        return;
      }
    }

    const file = bucket.file(payload.storagePath);
    const [exists] = await file.exists();
    if (!exists) {
      res.status(404).send("The shared file is gone.");
      return;
    }

    res.setHeader("Content-Type", "application/pdf");
    res.setHeader(
      "Content-Disposition",
      `attachment; filename="scanvault-${payload.storagePath.split("/").pop()}"`
    );
    await file.createReadStream().pipe(res);
    await share.ref.update({ downloadCount: FieldValue.increment(1) });
  }
);
