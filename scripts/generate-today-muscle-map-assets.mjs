#!/usr/bin/env node

// Regenerates Baseline/Assets.xcassets/TodayMuscleMap from the committed
// react-native-body-highlighter path data in .lavish/muscle-assets (MIT; the
// license ships alongside the assets as MuscleMapLicense.dataset).
// Requires `rsvg-convert` (brew install librsvg) to rasterize SVG to PDF.

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const sourceDirectory = join(repositoryRoot, ".lavish", "muscle-assets");
const outputDirectory = join(repositoryRoot, "Baseline", "Assets.xcassets", "TodayMuscleMap");

const views = [
  { name: "Front", file: "bodyFront.json", viewBox: "0 0 724 1448" },
  { name: "Back", file: "bodyBack.json", viewBox: "724 0 724 1448" },
];

const assetContents = (filename, isTemplate) => JSON.stringify({
  images: [{ filename, idiom: "universal" }],
  info: { author: "xcode", version: 1 },
  properties: {
    "preserves-vector-representation": true,
    ...(isTemplate ? { "template-rendering-intent": "template" } : {}),
  },
}, null, 2) + "\n";

const groupContents = JSON.stringify({
  info: { author: "xcode", version: 1 },
}, null, 2) + "\n";

const maskSvg = (viewBox, paths) => [
  "<svg xmlns=\"http://www.w3.org/2000/svg\"",
  ` viewBox="${viewBox}" width="724" height="1448">`,
  ...paths.map(path => `<path d="${path}" fill="#ffffff"/>`),
  "</svg>",
].join("");

const anatomicalFill = slug => {
  const neutral = new Set(["ankles", "feet", "hair", "hands", "head", "knees"]);
  return neutral.has(slug) ? "#e6e2ec" : "#c6b1ed";
};

const baseSvg = (viewBox, entries) => [
  "<svg xmlns=\"http://www.w3.org/2000/svg\"",
  ` viewBox="${viewBox}" width="724" height="1448">`,
  ...entries.flatMap(entry => allPaths(entry).map(path => [
    `<path d="${path}" fill="${anatomicalFill(entry.slug)}"`,
    " stroke=\"#0c0a10\" stroke-opacity=\"0.5\" stroke-width=\"2.5\"/>",
  ].join(""))),
  "</svg>",
].join("");

const allPaths = entry => Object.values(entry.path).flat();
const assetName = (view, slug) => `MuscleMap${view}${slug.split("-").map(part => part[0].toUpperCase() + part.slice(1)).join("")}`;

rmSync(outputDirectory, { force: true, recursive: true });
mkdirSync(outputDirectory, { recursive: true });
writeFileSync(join(outputDirectory, "Contents.json"), groupContents);

for (const view of views) {
  const entries = JSON.parse(readFileSync(join(sourceDirectory, view.file), "utf8"));
  const layers = [{ slug: "base", source: baseSvg(view.viewBox, entries), isTemplate: false }]
    .concat(entries.map(entry => ({
      slug: entry.slug,
      source: maskSvg(view.viewBox, allPaths(entry)),
      isTemplate: true,
    })));

  for (const layer of layers) {
    const name = assetName(view.name, layer.slug);
    const imageSet = join(outputDirectory, `${name}.imageset`);
    const source = join(imageSet, `${name}.svg`);
    const output = join(imageSet, `${name}.pdf`);
    mkdirSync(imageSet, { recursive: true });
    writeFileSync(source, layer.source);
    execFileSync("rsvg-convert", ["--format=pdf", "--output", output, source]);
    rmSync(source);
    writeFileSync(join(imageSet, "Contents.json"), assetContents(basename(output), layer.isTemplate));
  }
}

const license = readFileSync(join(sourceDirectory, "react-native-body-highlighter-LICENSE.txt"));
const licenseSet = join(outputDirectory, "MuscleMapLicense.dataset");
mkdirSync(licenseSet, { recursive: true });
writeFileSync(join(licenseSet, "react-native-body-highlighter-LICENSE.txt"), license);
writeFileSync(join(licenseSet, "Contents.json"), JSON.stringify({
  data: [{ filename: "react-native-body-highlighter-LICENSE.txt", idiom: "universal" }],
  info: { author: "xcode", version: 1 },
}, null, 2) + "\n");
