#!/usr/bin/env bun
/**
 * Enhanced SiliconFlow Image Generator
 * Supports baoyu-imagine CLI interface with style/quality/aspect parameters
 * Compatible with: black-forest-labs/FLUX.1-dev
 * 
 * Supported args:
 *   --prompt <text>       Prompt text
 *   --promptfiles <files> Read prompt from files (space-separated)
 *   --image <path>        Output image path (required)
 *   --ar <ratio>          Aspect ratio: 1:1, 16:9, 9:16, 4:3, 3:4, 2.35:1
 *   --size <WxH>          Explicit size, e.g. 1024x1024 (overrides --ar)
 *   --quality <preset>    normal (default) | 2k
 *   --n <count>           Number of images (default: 1)
 *   --seed <number>       Random seed
 *   --model <id>          Model ID (default: black-forest-labs/FLUX.1-dev)
 */

import { mkdir } from "node:fs/promises";
import { readFile } from "node:fs/promises";
import { dirname } from "node:path";

interface CliArgs {
  prompt: string;
  promptFiles: string[];
  imagePath: string;
  aspectRatio: string | null;
  size: string | null;
  quality: "normal" | "2k";
  n: number;
  seed: number | null;
  model: string;
}

// ==================== Aspect Ratio Mapping ====================
// Maps common ratios to exact pixel dimensions (max 2,359,296 pixels per SiliconFlow limit)
const AR_MAP: Record<string, string> = {
  "1:1": "1024x1024",
  "16:9": "1024x576",
  "9:16": "576x1024",
  "4:3": "1024x768",
  "3:4": "768x1024",
  "2.35:1": "1024x435",
  "21:9": "1024x439",
  "3:2": "1024x683",
  "2:3": "683x1024",
};

// ==================== Argument Parser ====================
function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = {
    prompt: "",
    promptFiles: [],
    imagePath: "",
    aspectRatio: null,
    size: null,
    quality: "normal",
    n: 1,
    seed: null,
    model: "Kwai-Kolors/Kolors",  // Default: Kolors (available). Fallback to FLUX.1-dev if authorized.
  };

  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const val = argv[++i] || "";

    if (flag === "--prompt" || flag === "-p") {
      args.prompt = val;
    } else if (flag === "--promptfiles") {
      while (i + 1 < argv.length && !argv[i + 1].startsWith("-")) {
        args.promptFiles.push(argv[++i]);
      }
    } else if (flag === "--image") {
      args.imagePath = val;
    } else if (flag === "--ar") {
      args.aspectRatio = val;
    } else if (flag === "--size") {
      args.size = val;
    } else if (flag === "--quality") {
      if (val === "2k" || val === "normal") args.quality = val as "normal" | "2k";
    } else if (flag === "--n") {
      const n = parseInt(val, 10);
      if (!isNaN(n) && n > 0) args.n = Math.min(n, 4);
    } else if (flag === "--seed") {
      const s = parseInt(val, 10);
      if (!isNaN(s)) args.seed = s;
    } else if (flag === "--model" || flag === "-m") {
      args.model = val;
    }
  }

  return args;
}

// ==================== Prompt Builder ====================
async function buildPrompt(args: CliArgs): Promise<string> {
  const parts: string[] = [];

  // 1. From prompt files (highest priority)
  for (const file of args.promptFiles) {
    try {
      const content = await readFile(file, "utf-8");
      parts.push(content.trim());
    } catch (e) {
      console.error(`⚠️  Failed to read prompt file: ${file}`);
    }
  }

  // 2. From inline prompt
  if (args.prompt) {
    parts.push(args.prompt);
  }

  let prompt = parts.join("\n\n").trim();

  // 3. Quality enhancement suffixes
  const suffixes: string[] = [];
  if (args.quality === "2k") {
    suffixes.push("high quality, highly detailed, sharp focus, professional");
  }
  suffixes.push("best quality, masterpiece");

  if (suffixes.length > 0) {
    prompt = prompt ? `${prompt}, ${suffixes.join(", ")}` : suffixes.join(", ");
  }

  return prompt;
}

// ==================== Image Size Resolver ====================
function resolveImageSize(args: CliArgs): string {
  // Explicit size wins
  if (args.size) {
    const [w, h] = args.size.split("x").map(Number);
    if (!isNaN(w) && !isNaN(h) && w * h <= 2359296) {
      return args.size;
    }
    console.warn(`⚠️  Invalid size ${args.size}, falling back to aspect ratio`);
  }

  // Aspect ratio mapping
  if (args.aspectRatio && AR_MAP[args.aspectRatio]) {
    return AR_MAP[args.aspectRatio];
  }

  // Default
  return "1024x1024";
}

// ==================== Inference Steps Resolver ====================
function resolveSteps(quality: string): number {
  return quality === "2k" ? 28 : 20;
}

// ==================== Main Generation ====================
async function generateImage(args: CliArgs): Promise<void> {
  const apiKey = process.env.SILICONFLOW_API_KEY;
  if (!apiKey) {
    console.error("❌ Error: SILICONFLOW_API_KEY not set");
    console.error("   Please set SILICONFLOW_API_KEY environment variable");
    process.exit(1);
  }

  // Redirect /tmp/ paths to image_cache for web accessibility
  if (args.imagePath.startsWith("/tmp/")) {
    const filename = args.imagePath.slice("/tmp/".length);
    args.imagePath = `/data/.hermes/image_cache/${filename}`;
    console.log(`📁 Redirected output to: ${args.imagePath}`);
  }

  const prompt = await buildPrompt(args);
  const imageSize = resolveImageSize(args);
  const numInferenceSteps = resolveSteps(args.quality);

  console.log(`🎨 Generating image with ${args.model}`);
  console.log(`   Prompt: ${prompt.slice(0, 100)}${prompt.length > 100 ? "..." : ""}`);
  console.log(`   Size: ${imageSize} | Quality: ${args.quality} | Steps: ${numInferenceSteps}`);
  if (args.seed) console.log(`   Seed: ${args.seed}`);

  const requestBody: any = {
    model: args.model,
    prompt: prompt,
    image_size: imageSize,
    num_inference_steps: numInferenceSteps,
  };

  if (args.seed !== null) {
    requestBody.seed = args.seed;
  }

  // Call SiliconFlow API
  const response = await fetch("https://api.siliconflow.cn/v1/images/generations", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(requestBody),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`❌ API error (${response.status}): ${errorText}`);
    
    if (response.status === 403) {
      console.error("");
      console.error("🔍 诊断: SiliconFlow API 返回 403 Forbidden");
      console.error("   网络连接正常，但所选模型需要额外授权");
      console.error("");
      
      // 自动 fallback 到 Kolors（已验证可用）
      if (args.model !== "Kwai-Kolors/Kolors") {
        console.error(`🔄 自动切换至备用模型: Kwai-Kolors/Kolors`);
        args.model = "Kwai-Kolors/Kolors";
        return generateImage(args);  // 递归重试
      }
      
      console.error("解决步骤:");
      console.error("  1. 访问 https://cloud.siliconflow.cn 检查账户状态");
      console.error("  2. 确认 API Key 有效且余额充足");
      console.error("  3. 确认已开通所选模型的使用权限");
    }
    
    process.exit(1);
  }

  const result = await response.json();

  if (!result.images || result.images.length === 0) {
    console.error("❌ Error: No images in response");
    console.error(JSON.stringify(result, null, 2));
    process.exit(1);
  }

  // Ensure output directory exists
  const outDir = dirname(args.imagePath);
  await mkdir(outDir, { recursive: true });

  // Download and save images
  // Note: SiliconFlow currently returns 1 image per request regardless of --n
  for (let idx = 0; idx < result.images.length; idx++) {
    const imageUrl = result.images[idx].url;
    console.log(`📥 Downloading from: ${imageUrl}`);

    const imageResponse = await fetch(imageUrl);
    if (!imageResponse.ok) {
      console.error(`❌ Download failed: ${imageResponse.status}`);
      continue;
    }

    // Validate response is actually an image
    const contentType = imageResponse.headers.get("content-type") || "";
    // Allow image/* and application/octet-stream (common for CDN-hosted images)
    if (!contentType.startsWith("image/") && !contentType.includes("octet-stream")) {
      const text = await imageResponse.text();
      console.error(`❌ Unexpected response type: ${contentType}`);
      console.error(`   Body: ${text.slice(0, 200)}`);
      continue;
    }

    const imageBuffer = await imageResponse.arrayBuffer();

    // Handle multiple images naming
    let outPath = args.imagePath;
    if (result.images.length > 1) {
      const dotIdx = outPath.lastIndexOf(".");
      const ext = dotIdx > 0 ? outPath.slice(dotIdx) : ".png";
      const base = dotIdx > 0 ? outPath.slice(0, dotIdx) : outPath;
      outPath = `${base}-${String(idx + 1).padStart(2, "0")}${ext}`;
    }

    await Bun.write(outPath, new Uint8Array(imageBuffer));
    console.log(`✅ Saved: ${outPath} (${imageBuffer.byteLength} bytes)`);
  }
}

// ==================== CLI Entry ====================
const args = parseArgs(process.argv.slice(2));

if (!args.imagePath) {
  console.error("Usage: bun main.ts --prompt <text> --image <path> [options]");
  console.error("");
  console.error("Options:");
  console.error("  --prompt <text>       Prompt text");
  console.error("  --promptfiles <f...>  Read prompt from files");
  console.error("  --image <path>        Output image path (required)");
  console.error("  --ar <ratio>          Aspect ratio: 1:1, 16:9, 9:16, 4:3, 3:4, 2.35:1");
  console.error("  --size <WxH>          Explicit size, e.g. 1024x576");
  console.error("  --quality <preset>    normal (default) | 2k");
  console.error("  --n <count>           Number of images (1-4)");
  console.error("  --seed <number>       Random seed");
  console.error("  --model <id>          Model ID (default: black-forest-labs/FLUX.1-dev)");
  console.error("");
  console.error("Example:");
  console.error('  bun main.ts --prompt "a cute cat" --image ./cat.png --ar 16:9 --quality 2k');
  process.exit(1);
}

// Validate prompt source
if (!args.prompt && args.promptFiles.length === 0) {
  console.error("❌ Error: --prompt or --promptfiles required");
  process.exit(1);
}

await generateImage(args);
