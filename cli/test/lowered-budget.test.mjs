import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));

function runCli(cwd, ...arguments_) {
  return spawnSync(process.execPath, [cli, ...arguments_], { cwd, encoding: "utf8" });
}

function fixture(source, files = {}) {
  const root = mkdtempSync(join(tmpdir(), "weaver-lowered-budget-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "widget.tsx"), source, "utf8");
  for (const [name, contents] of Object.entries(files)) writeFileSync(join(widget, name), contents, "utf8");
  return { root, widget };
}

function source(tree) {
  return `import { widget } from "@weaver/sdk";
export default widget({ name: "Lowered Budget", size: [320, 200] }, () => (${tree}));
`;
}

test("check rejects node counts after painted row, column, and stack lowering", () => {
  const groups = Array.from({ length: 16 }, (_, group) =>
    `<column key="g${group}">${Array.from({ length: 32 }, (_, child) => `<row key="r${group}-${child}" class="bg-[#111]" />`).join("")}</column>`,
  ).join("");
  const { root, widget } = fixture(source(`<column>${groups}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1041 Native nodes \(limit 1024\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check counts the painted stack wrapper", () => {
  let tree = "<text>leaf</text>";
  for (let index = 0; index < 16; index += 1) tree = `<stack class="shadow-inner">${tree}</stack>`;
  const { root, widget } = fixture(source(tree));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetDepthLimit: this tree lowers to depth 33 \(Native limit 32\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check rejects depth after painted layout lowering", () => {
  let tree = "<text>leaf</text>";
  for (let index = 0; index < 16; index += 1) tree = `<row class="border">${tree}</row>`;
  const { root, widget } = fixture(source(tree));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetDepthLimit: this tree lowers to depth 33 \(Native limit 32\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

function nested(open, close, levels) {
  return open.repeat(levels) + "<text>leaf</text>" + close.repeat(levels);
}

function checkDepth(tree) {
  const { root, widget } = fixture(source(tree));
  try {
    return runCli(root, "check", widget);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// Each case was checked against the runtime: the same tree built by
// recursion (which check cannot see) renders at 32 lowered levels and goes
// blank at 33, exactly where check now passes or rejects. Every case asserts
// the whole check result, so a pass means no error of any kind.
const depthError = /LoweredWidgetDepthLimit: this tree lowers to depth (\d+) \(Native limit 32\)/;
const pressable = ['<button onPress={() => {}} accessibilityLabel="target">', "</button>"];

function expectDepth(tree, depth, label) {
  const checked = checkDepth(tree);
  if (depth > 32) {
    assert.equal(checked.status, 1, `${label}: ${checked.stderr}`);
    assert.equal(checked.stderr.match(depthError)?.[1], String(depth), `${label}: ${checked.stderr}`);
  } else {
    assert.equal(checked.status, 0, `${label}: ${checked.stderr}`);
  }
}

test("check counts painted boxes and panels as two levels, like the runtime", () => {
  const gradient = `{{ type: "linear", start: [0, 0], end: [1, 1], stops: [{ offset: 0, color: "cyan-400" }, { offset: 1, color: "violet-500" }] }}`;
  for (const [open, close] of [
    ["<panel>", "</panel>"],
    ['<column class="bg-gradient-to-r from-[#111111] to-[#222222]">', "</column>"],
    [`<column background=${gradient}>`, "</column>"],
    ['<column class="rounded-tl-[0px]">', "</column>"],
  ]) {
    expectDepth(nested(open, close, 16), 33, open);
    expectDepth(open.repeat(15) + "<column><text>leaf</text></column>" + close.repeat(15), 32, open);
  }
});

test("check counts interaction-only paint as two levels inside a pressable", () => {
  for (const [open, close] of [
    ['<column class="hover:bg-[#112233]">', "</column>"],
    ['<column class="pressed:bg-[#112233]">', "</column>"],
    ['<column class="hover:opacity-50">', "</column>"],
    ['<column class="hover:shadow-none">', "</column>"],
  ]) {
    // The button is one level: 1 + 16 x 2 + text = 34; 1 + 15 x 2 + text = 32.
    expectDepth(pressable[0] + nested(open, close, 16) + pressable[1], 34, open);
    expectDepth(pressable[0] + nested(open, close, 15) + pressable[1], 32, open);
  }
});

test("check does not count what the runtime treats as unpainted", () => {
  for (const [open, close] of [
    ['<column class="shadow-none">', "</column>"],
    ['<column class="rounded-[0px]">', "</column>"],
    ['<column class="text-shadow-md">', "</column>"],
    ["<column background={(undefined)}>", "</column>"],
    ["<column background={void 0}>", "</column>"],
  ]) {
    expectDepth(nested(open, close, 16), 17, open);
  }
});

test("check counts nothing Native-side below leaves, but still budgets their retained nodes", () => {
  const slider = '<slider accessibilityLabel="volume" value={1} max={10} onChange={() => {}}>';
  // Depth: 40 nested columns under a slider are never drawn (runtime: 1 node).
  expectDepth(`${slider}${nested("<column>", "</column>", 40)}</slider>`, 1, "slider over 40 nested columns");
  // 1 + 16 columns x (1 + 32 panels) = 529 retained nodes; Native gets one.
  const hidden = Array.from({ length: 16 }, (_, group) =>
    `<column key="c${group}">${Array.from({ length: 32 }, (_, child) => `<panel key="p${group}-${child}" />`).join("")}</column>`,
  ).join("");
  expectDepth(`${slider}${hidden}</slider>`, 1, "slider over 529 retained nodes");
  const tooMany = Array.from({ length: 40 }, (_, group) =>
    `<column key="c${group}">${Array.from({ length: 30 }, (_, child) => `<column key="r${group}-${child}" />`).join("")}</column>`,
  ).join("");
  const checked = checkDepth(`${slider}${tooMany}</slider>`);
  assert.equal(checked.status, 1, checked.stderr);
  assert.match(checked.stderr, /RetainedWidgetNodeLimit: this tree creates 1241 retained nodes \(limit 1024\)/);
  assert.doesNotMatch(checked.stderr, /LoweredWidgetNodeLimit/);
});

test("check budgets the painted branch of a finite class expression", () => {
  let tree = "<text>leaf</text>";
  for (let index = 0; index < 16; index += 1) {
    tree = `<row class={painted ? "border" : ""}>${tree}</row>`;
  }
  const widgetSource = `import { widget } from "@weaver/sdk";
const painted = true;
export default widget({ name: "Conditional Painted Budget", size: [320, 200] }, () => (${tree}));
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetDepthLimit: this tree lowers to depth 33 \(Native limit 32\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check budgets only the exported widget's reachable tree", () => {
  const dead = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
const DeadPreview = () => (${dead});
export default widget({ name: "Reachable Budget", size: [320, 200] }, () => <text>live</text>);
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check takes the maximum across every JSX return branch", () => {
  const oversized = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
function Branch({ large }: { large: boolean }) {
  if (!large) return <text>small</text>;
  return (${oversized});
}
export default widget({ name: "Branch Budget", size: [320, 200] }, () => <Branch large={true} />);
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check does not sum mutually exclusive JSX return branches", () => {
  const group = () => `<column>${Array.from({ length: 20 }, () => "<row />").join("")}</column>`;
  const branch = () => `<column>${Array.from({ length: 4 }, group).join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
function Branch({ first }: { first: boolean }) {
  if (first) return (${branch()});
  return (${branch()});
}
export default widget({ name: "Branch Maximum", size: [320, 200] }, () => <Branch first={true} />);
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check names the direct-child budget and authored ask", () => {
  const children = Array.from({ length: 65 }, () => "<row />").join("");
  const { root, widget } = fixture(source(`<column>${children}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetChildLimit/);
    assert.match(checked.stderr, /max_children=64, asked for 65, headroom=-1/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check names the static text byte budget and authored ask", () => {
  const { root, widget } = fixture(source(`<text>${"x".repeat(1025)}</text>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetTextLimit/);
    assert.match(checked.stderr, /max_text_bytes=1024, asked for 1025, headroom=-1/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check names the canvas budget and authored ask", () => {
  const canvases = Array.from({ length: 9 }, () => '<canvas class="w-[10px] h-[10px]" fps={0} onFrame={() => {}} />').join("");
  const { root, widget } = fixture(source(`<column>${canvases}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetCanvasLimit/);
    assert.match(checked.stderr, /max_canvases=8, asked for 9, headroom=-1/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check counts statically evident implicit text children", () => {
  const primitives = Array.from({ length: 1024 }, (_, index) => `{${index}}`).join("");
  const { root, widget } = fixture(source(`<column>${primitives}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves one level of local imported components", () => {
  const importedTree = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import { ImportedTree as Tree } from "./tree";
export default widget({ name: "Imported Budget", size: [320, 200] }, () => <Tree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "tree.tsx": `export function ImportedTree() { return (${importedTree}); }\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
    assert.match(checked.stderr, /one level of relative imports/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves a directly imported default function component", () => {
  const importedTree = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import Tree from "./tree";
export default widget({ name: "Default Import Budget", size: [320, 200] }, () => <Tree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "tree.tsx": `export default function Tree() { return (${importedTree}); }\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves a directly imported aliased default export", () => {
  const importedTree = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import Tree from "./tree";
export default widget({ name: "Aliased Default Budget", size: [320, 200] }, () => <Tree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "tree.tsx": `function Tree() { return (${importedTree}); }\nexport { Tree as default };\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves nested helpers in their declaring module", () => {
  const oversized = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import { SmallTree } from "./small";
import { LargeTree } from "./large";
void SmallTree;
export default widget({ name: "Module Scope Budget", size: [320, 200] }, () => <LargeTree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "small.tsx": `function Helper() { return <text>small</text>; }\nexport function SmallTree() { return <Helper />; }\n`,
    "large.tsx": `function Helper() { return (${oversized}); }\nexport function LargeTree() { return <Helper />; }\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
