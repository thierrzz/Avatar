import sharp from "sharp";

/** How much extra canvas we add below the original, as a fraction of height. */
export const EXTEND_RATIO = 0.4;

/**
 * Prepares the inputs for flux-fill-pro outpainting:
 * - Takes a transparent-background cutout PNG.
 * - Flattens it on white (fill-pro expects RGB).
 * - Pads 40% white space below.
 * - Returns a matching black-above / white-below mask.
 *
 * Both images are returned as data-URLs so they can be sent to Replicate
 * without intermediate hosting.
 */
export async function prepareOutpaintInputs(cutoutPng: Buffer): Promise<{
  imageDataUrl: string;
  maskDataUrl: string;
  originalHeight: number;
  paddedHeight: number;
  width: number;
}> {
  const src = sharp(cutoutPng);
  const meta = await src.metadata();
  if (!meta.width || !meta.height) {
    throw new Error("Invalid cutout PNG: missing dimensions");
  }
  const width = meta.width;
  const origHeight = meta.height;
  const padBelow = Math.round(origHeight * EXTEND_RATIO);
  const paddedHeight = origHeight + padBelow;

  // 1. Flatten cutout on white (drop alpha), then extend the canvas downward
  //    with white fill. This is the `image` input for flux-fill-pro.
  const paddedImage = await sharp(cutoutPng)
    .flatten({ background: { r: 255, g: 255, b: 255 } })
    .extend({
      top: 0,
      bottom: padBelow,
      left: 0,
      right: 0,
      background: { r: 255, g: 255, b: 255 },
    })
    .png()
    .toBuffer();

  // 2. Build the mask: black where we want to keep the original, white where
  //    we want to generate. Black = keep, white = inpaint.
  const mask = await sharp({
    create: {
      width,
      height: paddedHeight,
      channels: 3,
      background: { r: 0, g: 0, b: 0 },
    },
  })
    .composite([
      {
        input: {
          create: {
            width,
            height: padBelow,
            channels: 3,
            background: { r: 255, g: 255, b: 255 },
          },
        },
        top: origHeight,
        left: 0,
      },
    ])
    .png()
    .toBuffer();

  return {
    imageDataUrl: `data:image/png;base64,${paddedImage.toString("base64")}`,
    maskDataUrl: `data:image/png;base64,${mask.toString("base64")}`,
    originalHeight: origHeight,
    paddedHeight,
    width,
  };
}
