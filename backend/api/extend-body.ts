import type { VercelRequest, VercelResponse } from "@vercel/node";
import { checkRateLimit, requireUser } from "../lib/auth.js";
import { currentCredits, ensureUser, logCredit } from "../lib/supabase.js";
import { prepareOutpaintInputs } from "../lib/image.js";
import { EXTEND_BODY_PROMPT, outpaint } from "../lib/replicate.js";

export const config = {
  api: {
    bodyParser: { sizeLimit: "15mb" },
  },
};

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  const user = await requireUser(req, res);
  if (!user) return;

  if (!checkRateLimit(user.id)) {
    res.status(429).json({ error: "Too many requests" });
    return;
  }

  const base64 = (req.body?.cutoutPNGBase64 ?? "") as string;
  if (!base64 || typeof base64 !== "string") {
    res.status(400).json({ error: "Missing cutoutPNGBase64" });
    return;
  }

  const cleaned = base64.replace(/^data:image\/png;base64,/i, "");
  let cutout: Buffer;
  try {
    cutout = Buffer.from(cleaned, "base64");
  } catch {
    res.status(400).json({ error: "Invalid base64" });
    return;
  }
  if (cutout.length === 0 || cutout.length > 12 * 1024 * 1024) {
    res.status(400).json({ error: "Cutout size out of range" });
    return;
  }

  try {
    await ensureUser(user.id);
    const credits = await currentCredits(user.id);
    if (credits < 1) {
      res.status(402).json({ error: "No credits remaining" });
      return;
    }

    const inputs = await prepareOutpaintInputs(cutout);
    const resultUrl = await outpaint({
      imageDataUrl: inputs.imageDataUrl,
      maskDataUrl: inputs.maskDataUrl,
      prompt: EXTEND_BODY_PROMPT,
    });

    const download = await fetch(resultUrl);
    if (!download.ok) {
      throw new Error(`Replicate result fetch failed: ${download.status}`);
    }
    const bytes = Buffer.from(await download.arrayBuffer());

    // Deduct only on success.
    await logCredit({
      userId: user.id,
      delta: -1,
      reason: "extend_body",
      ref: resultUrl,
    });

    res.status(200).json({
      imageBase64: bytes.toString("base64"),
      width: inputs.width,
      paddedHeight: inputs.paddedHeight,
      originalHeight: inputs.originalHeight,
    });
  } catch (err) {
    console.error("/api/extend-body error", err);
    res.status(500).json({ error: "Extend body failed" });
  }
}
