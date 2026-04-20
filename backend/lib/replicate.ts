import Replicate from "replicate";

const replicate = new Replicate({ auth: process.env.REPLICATE_API_TOKEN! });

/**
 * Runs `black-forest-labs/flux-fill-pro` with a padded input image and mask.
 * The model generates content in the masked (white) region.
 *
 * Returns the URL of the result image. The caller downloads it and passes the
 * bytes back to the app.
 */
export async function outpaint(input: {
  imageDataUrl: string; // padded source with whitespace where we want new content
  maskDataUrl: string;  // black = keep, white = generate
  prompt: string;
}): Promise<string> {
  const output = (await replicate.run("black-forest-labs/flux-fill-pro", {
    input: {
      image: input.imageDataUrl,
      mask: input.maskDataUrl,
      prompt: input.prompt,
      // Reasonable defaults for body outpainting; tune after real-world usage.
      guidance: 60,
      num_inference_steps: 50,
      safety_tolerance: 2,
      output_format: "png",
    },
  })) as unknown;

  // Replicate returns either a string URL or a File-like object depending on
  // the SDK version; handle both.
  if (typeof output === "string") return output;
  if (Array.isArray(output) && typeof output[0] === "string") return output[0];
  if (output && typeof output === "object" && "url" in output) {
    const fn = (output as { url: () => string }).url;
    if (typeof fn === "function") return fn();
  }
  throw new Error("Unexpected Replicate output shape");
}

export const EXTEND_BODY_PROMPT =
  "natural continuation of the person's shoulders, torso and clothing; " +
  "matching skin tone and lighting; photograph, photorealistic, same outfit";
