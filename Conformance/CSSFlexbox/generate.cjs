// CSS Flexbox conformance fixtures: every case is rendered by real Chromium (Playwright), and
// the resulting frame of every node becomes the expected value the layout engine is compared
// against (Tests/TrellisCoreTests/Layout/CSSConformanceTests.swift).
//
// Run from the repository root:
//   NODE_PATH="$(npm root -g)" node Conformance/CSSFlexbox/generate.cjs
//
// Rules shared by the HTML side and the engine side (README.md explains why):
// - every node is `display: flex` (every Trellis node is a flex container);
// - `box-sizing: border-box` (width/height include padding, as in the engine);
// - every node is `position: relative`, so an absolute child is placed against its parent;
// - no fonts: a leaf with `content: [w, h]` gets a rigid inner block of that size; a leaf
//   with `text: [lineHeight, word, word, …]` is a plain block holding inline-block "words"
//   of those widths, which wrap like text but do not depend on any font;
// - all lengths are CSS px = points; percentages are strings like "50%".

'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

// ---------------------------------------------------------------------------------------------
// Case DSL

const cases = [];
let currentGroup = 'misc';

function group(name, body) {
  currentGroup = name;
  body();
}

// A node: `n(style, ...children)`. `style.content = [w, h]` makes a leaf with intrinsic size.
function n(style = {}, ...children) {
  return { style, children };
}

function add(name, root) {
  const full = `${currentGroup}/${name}`;
  if (cases.some((c) => c.name === full)) throw new Error(`duplicate case ${full}`);
  cases.push({ name: full, group: currentGroup, root });
}

const box = (w, h, extra = {}) => n({ width: w, height: h, ...extra });

// ---------------------------------------------------------------------------------------------
// Cases

const directions = ['row', 'column', 'row-reverse', 'column-reverse'];
const justifies = ['flex-start', 'flex-end', 'center', 'space-between', 'space-around', 'space-evenly'];
const alignContents = ['flex-start', 'flex-end', 'center', 'stretch', 'space-between', 'space-around', 'space-evenly'];

group('justify-content', () => {
  for (const dir of directions) {
    for (const j of justifies) {
      add(`${dir}-${j}`, n(
        { width: 300, height: 300, flexDirection: dir, justifyContent: j },
        box(40, 30), box(60, 20), box(30, 50),
      ));
    }
  }
});

group('align-items', () => {
  for (const dir of ['row', 'column']) {
    for (const a of ['stretch', 'flex-start', 'flex-end', 'center']) {
      add(`${dir}-${a}`, n(
        { width: 300, height: 200, flexDirection: dir, alignItems: a },
        box(40, 30), n({ width: 50 }), n({ height: 40 }), n({}),
      ));
    }
  }
});

group('align-self', () => {
  for (const s of ['auto', 'stretch', 'flex-start', 'flex-end', 'center']) {
    add(`row-items-center-self-${s}`, n(
      { width: 300, height: 200, alignItems: 'center' },
      box(40, 30), n({ width: 50, alignSelf: s }), box(30, 60),
    ));
  }
  add('column-stretch-self-end', n(
    { width: 300, height: 200, flexDirection: 'column' },
    n({ height: 30 }), n({ height: 30, width: 80, alignSelf: 'flex-end' }),
  ));
});

group('wrap', () => {
  add('nowrap-overflow', n(
    { width: 200, height: 100 },
    box(80, 20, { flexShrink: 0 }), box(80, 20, { flexShrink: 0 }), box(80, 20, { flexShrink: 0 }),
  ));
  for (const w of ['wrap', 'wrap-reverse']) {
    for (const ac of alignContents) {
      add(`${w}-align-content-${ac}`, n(
        { width: 200, height: 300, flexWrap: w, alignContent: ac },
        box(80, 20), box(80, 30), box(80, 20), box(80, 40), box(80, 20),
      ));
    }
  }
  add('wrap-column', n(
    { width: 300, height: 100, flexDirection: 'column', flexWrap: 'wrap' },
    box(50, 40), box(60, 40), box(40, 40), box(70, 40),
  ));
  add('wrap-stretch-lines-auto-height-items', n(
    { width: 200, height: 200, flexWrap: 'wrap' },
    n({ width: 120 }), n({ width: 120, height: 30 }), n({ width: 50 }),
  ));
  add('wrap-grow-per-line', n(
    { width: 200, height: 100, flexWrap: 'wrap' },
    box(80, 20, { flexGrow: 1 }), box(80, 20), box(80, 20, { flexGrow: 1 }),
  ));
});

group('grow', () => {
  add('single', n({ width: 300, height: 50 }, n({ flexGrow: 1 })));
  add('weighted-1-2-1', n({ width: 300, height: 50 },
    n({ flexGrow: 1, width: 30 }), n({ flexGrow: 2, width: 30 }), n({ flexGrow: 1, width: 30 })));
  add('with-fixed-sibling', n({ width: 300, height: 50 }, box(100, 20), n({ flexGrow: 1 })));
  add('clamped-by-max-width', n({ width: 300, height: 50 },
    n({ flexGrow: 1, maxWidth: 50 }), n({ flexGrow: 1 })));
  add('clamped-by-max-width-redistributes', n({ width: 300, height: 50 },
    n({ flexGrow: 1, maxWidth: 50 }), n({ flexGrow: 1 }), n({ flexGrow: 1 })));
  add('fractional', n({ width: 300, height: 50 }, n({ flexGrow: 0.25 }), n({ flexGrow: 0.25 })));
  add('column', n({ width: 100, height: 300, flexDirection: 'column' },
    n({ flexGrow: 1 }), box(20, 50), n({ flexGrow: 3 })));
  add('basis-zero-equal', n({ width: 300, height: 50 },
    n({ flexGrow: 1, flexBasis: 0, width: 100 }), n({ flexGrow: 1, flexBasis: 0 })));
  add('with-gap', n({ width: 300, height: 50, columnGap: 10 },
    n({ flexGrow: 1 }), n({ flexGrow: 1 }), n({ flexGrow: 1 })));
  add('with-margin', n({ width: 300, height: 50 },
    n({ flexGrow: 1, margin: [0, 20, 0, 10] }), n({ flexGrow: 1 })));
});

group('shrink', () => {
  add('default-overflow', n({ width: 200, height: 50 }, box(150, 20), box(150, 20)));
  add('weighted-by-basis', n({ width: 200, height: 50 }, box(100, 20), box(200, 20)));
  add('shrink-zero', n({ width: 200, height: 50 }, box(150, 20, { flexShrink: 0 }), box(150, 20)));
  add('shrink-weights', n({ width: 200, height: 50 },
    box(150, 20, { flexShrink: 1 }), box(150, 20, { flexShrink: 3 })));
  add('clamped-by-min-width', n({ width: 200, height: 50 },
    box(150, 20, { minWidth: 130 }), box(150, 20)));
  add('column', n({ width: 50, height: 200, flexDirection: 'column' }, box(20, 150), box(20, 150)));
  add('with-padding-and-gap', n({ width: 200, height: 50, padding: 10, columnGap: 20 },
    box(150, 20), box(150, 20)));
  add('all-shrink-zero-overflow', n({ width: 200, height: 50 },
    box(150, 20, { flexShrink: 0 }), box(150, 20, { flexShrink: 0 })));
});

group('basis', () => {
  add('basis-over-width', n({ width: 300, height: 50 }, n({ flexBasis: 100, width: 50, height: 20 })));
  add('basis-zero', n({ width: 300, height: 50 }, n({ flexBasis: 0, width: 50, height: 20 })));
  add('basis-percent', n({ width: 300, height: 50 }, n({ flexBasis: '50%', height: 20 })));
  add('basis-clamped-by-min', n({ width: 300, height: 50 }, n({ flexBasis: 20, minWidth: 60, height: 20 })));
  add('basis-clamped-by-max', n({ width: 300, height: 50 }, n({ flexBasis: 200, maxWidth: 80, height: 20 })));
  add('basis-auto-content', n({ width: 300, height: 50 }, n({ content: [70, 20] })));
  add('column-basis', n({ width: 50, height: 300, flexDirection: 'column' }, n({ flexBasis: 120 }), n({ flexBasis: 30 })));
});

group('min-max', () => {
  add('min-width-over-width', n({ width: 300, height: 50 }, box(40, 20, { minWidth: 80 })));
  add('max-width-under-width', n({ width: 300, height: 50 }, box(140, 20, { maxWidth: 80 })));
  add('min-height-column', n({ width: 100, height: 300, flexDirection: 'column' }, box(40, 20, { minHeight: 70 })));
  add('max-height-column', n({ width: 100, height: 300, flexDirection: 'column' }, box(40, 200, { maxHeight: 70 })));
  add('min-over-max', n({ width: 300, height: 50 }, box(40, 20, { minWidth: 100, maxWidth: 60 })));
  add('percent-max-width', n({ width: 300, height: 50 }, n({ flexGrow: 1, maxWidth: '25%' })));
  add('stretch-clamped-by-max-height', n({ width: 300, height: 100 }, n({ width: 40, maxHeight: 60 })));
  add('stretch-raised-by-min-height', n({ width: 300, height: 100, alignItems: 'flex-start' },
    n({ width: 40, minHeight: 60 })));
});

group('auto-min-size', () => {
  // CSS `min-width: auto` on a flex item = its min-content size: content never shrinks below it.
  add('content-does-not-shrink', n({ width: 100, height: 50 }, n({ content: [80, 20] }), n({ content: [80, 20] })));
  add('min-width-zero-allows-shrink', n({ width: 100, height: 50 },
    n({ content: [80, 20], minWidth: 0 }), n({ content: [80, 20], minWidth: 0 })));
  add('explicit-width-caps-auto-min', n({ width: 100, height: 50 },
    n({ content: [80, 20], width: 50 }), n({ content: [80, 20] })));
  add('column-content-does-not-shrink', n({ width: 50, height: 100, flexDirection: 'column' },
    n({ content: [20, 80] }), n({ content: [20, 80] })));
  add('nested-container-min-content', n({ width: 100, height: 50 },
    n({}, n({ content: [70, 20] })), n({ content: [70, 20] })));
  add('grow-with-content', n({ width: 300, height: 50 },
    n({ flexGrow: 1, content: [100, 20] }), n({ flexGrow: 1, content: [20, 20] })));
  add('basis-zero-grow-with-content', n({ width: 300, height: 50 },
    n({ flexGrow: 1, flexBasis: 0, content: [200, 20] }), n({ flexGrow: 1, flexBasis: 0, content: [20, 20] })));
});

group('gap', () => {
  add('row-column-gap', n({ width: 300, height: 100, columnGap: 10 }, box(40, 20), box(40, 20), box(40, 20)));
  add('column-row-gap', n({ width: 100, height: 300, flexDirection: 'column', rowGap: 15 }, box(40, 20), box(40, 20)));
  add('wrap-both-gaps', n({ width: 200, height: 200, flexWrap: 'wrap', rowGap: 8, columnGap: 12, alignContent: 'flex-start' },
    box(80, 20), box(80, 20), box(80, 20), box(80, 20)));
  add('space-between-with-gap', n({ width: 300, height: 100, columnGap: 10, justifyContent: 'space-between' },
    box(40, 20), box(40, 20), box(40, 20)));
  add('gap-larger-than-space', n({ width: 100, height: 100, columnGap: 50 }, box(40, 20, { flexShrink: 0 }), box(40, 20, { flexShrink: 0 })));
  add('column-wrap-gaps', n({ width: 300, height: 100, flexDirection: 'column', flexWrap: 'wrap', rowGap: 10, columnGap: 20, alignContent: 'flex-start' },
    box(40, 40), box(40, 40), box(40, 40)));
});

group('padding-margin', () => {
  add('container-padding', n({ width: 300, height: 100, padding: [10, 20, 30, 40] }, box(50, 20), n({ flexGrow: 1 })));
  add('item-margins-row', n({ width: 300, height: 100 }, box(50, 20, { margin: [5, 10, 15, 20] }), box(50, 20)));
  add('item-margins-column', n({ width: 300, height: 300, flexDirection: 'column' }, box(50, 20, { margin: [5, 10, 15, 20] }), box(50, 20)));
  add('stretch-with-margin', n({ width: 300, height: 100 }, n({ width: 50, margin: [10, 0, 20, 0] })));
  add('center-with-margin', n({ width: 300, height: 100, alignItems: 'center', justifyContent: 'center' }, box(50, 20, { margin: [0, 0, 0, 40] })));
  add('padding-auto-size-child', n({ width: 300, height: 100 }, n({ padding: 10 }, box(30, 30))));
});

group('margin-auto', () => {
  add('push-right', n({ width: 300, height: 50 }, box(50, 20), box(50, 20, { margin: [0, 0, 0, 'auto'] })));
  add('center-both-axes', n({ width: 300, height: 100 }, box(50, 20, { margin: 'auto' })));
  add('split-space', n({ width: 300, height: 50 }, box(50, 20, { margin: [0, 'auto', 0, 0] }), box(50, 20), box(50, 20, { margin: [0, 0, 0, 'auto'] })));
  add('column-push-bottom', n({ width: 100, height: 300, flexDirection: 'column' }, box(50, 20), box(50, 20, { margin: ['auto', 0, 0, 0] })));
});

group('absolute', () => {
  add('top-left', n({ width: 300, height: 200 }, box(50, 20), box(40, 30, { position: 'absolute', top: 10, left: 20 })));
  add('bottom-right', n({ width: 300, height: 200 }, box(40, 30, { position: 'absolute', bottom: 10, right: 20 })));
  add('left-right-stretch', n({ width: 300, height: 200 }, n({ height: 30, position: 'absolute', left: 10, right: 30 })));
  add('static-position', n({ width: 300, height: 200, padding: 10 }, box(40, 30, { position: 'absolute' })));
  add('with-container-padding', n({ width: 300, height: 200, padding: 20 }, box(40, 30, { position: 'absolute', top: 0, left: 0 })));
  add('static-position-centered', n({ width: 300, height: 200, justifyContent: 'center', alignItems: 'center' }, box(40, 30, { position: 'absolute' })));
  add('auto-size-with-content', n({ width: 300, height: 200 }, n({ position: 'absolute', top: 5, left: 5 }, box(60, 40))));
});

group('aspect-ratio', () => {
  add('width-given', n({ width: 300, height: 200, alignItems: 'flex-start' }, n({ width: 100, aspectRatio: 2 })));
  add('height-given', n({ width: 300, height: 200, alignItems: 'flex-start' }, n({ height: 60, aspectRatio: 0.5 })));
  add('stretched-cross', n({ width: 300, height: 100 }, n({ aspectRatio: 1 })));
  add('column-width-from-stretch', n({ width: 120, height: 300, flexDirection: 'column' }, n({ aspectRatio: 2 })));
});

group('percent', () => {
  add('width-50', n({ width: 300, height: 100 }, n({ width: '50%', height: 20 })));
  add('height-50-column', n({ width: 100, height: 300, flexDirection: 'column' }, n({ width: 20, height: '50%' })));
  add('nested-percent', n({ width: 400, height: 100 }, n({ width: '50%' }, n({ width: '50%', height: 20 }))));
  add('percent-with-padding-parent', n({ width: 300, height: 100, padding: 50 }, n({ width: '50%', height: 20 })));
});

group('nested', () => {
  add('row-in-column', n({ width: 300, height: 200, flexDirection: 'column', padding: 10, rowGap: 10 },
    n({ columnGap: 8 }, box(40, 40), n({ flexGrow: 1 }), box(30, 30)),
    n({ flexGrow: 1 })));
  add('auto-size-container', n({ width: 300, height: 200, alignItems: 'flex-start' },
    n({ padding: 5, columnGap: 4 }, box(20, 20), box(30, 10))));
  add('stretch-propagates', n({ width: 300, height: 200 },
    n({ flexDirection: 'column', width: 100 }, n({}), box(20, 20))));
  add('profile-card', n({ width: 320, height: 100, padding: 16, columnGap: 12, alignItems: 'center' },
    box(48, 48),
    n({ flexDirection: 'column', rowGap: 4, flexGrow: 1, flexShrink: 1 }, n({ content: [120, 20] }), n({ content: [90, 16] })),
    n({ content: [70, 32] })));
  add('column-center-in-row', n({ width: 300, height: 200, justifyContent: 'center', alignItems: 'center' },
    n({ flexDirection: 'column', alignItems: 'center', rowGap: 6 }, box(60, 20), box(30, 20))));
  add('deep-grow', n({ width: 300, height: 60 },
    n({ flexGrow: 1 }, n({ flexGrow: 1 }, n({ flexGrow: 1 })))));
  add('wrap-inside-column', n({ width: 200, height: 300, flexDirection: 'column' },
    n({ flexWrap: 'wrap' }, box(80, 20), box(80, 20), box(80, 20)), box(30, 30)));
  add('auto-height-root-content', n({ width: 200 }, n({ flexDirection: 'column' }, box(30, 25), box(30, 35))));
});

group('rtl', () => {
  add('row-start', n({ width: 300, height: 100, direction: 'rtl' }, box(40, 20), box(60, 20)));
  add('row-end', n({ width: 300, height: 100, direction: 'rtl', justifyContent: 'flex-end' }, box(40, 20), box(60, 20)));
  add('row-reverse', n({ width: 300, height: 100, direction: 'rtl', flexDirection: 'row-reverse' }, box(40, 20), box(60, 20)));
  add('padding-margin', n({ width: 300, height: 100, direction: 'rtl', padding: [0, 10, 0, 30] }, box(40, 20, { margin: [0, 5, 0, 15] }), box(60, 20)));
  add('absolute-left', n({ width: 300, height: 100, direction: 'rtl' }, box(40, 20, { position: 'absolute', left: 10, top: 10 })));
});

group('order', () => {
  add('reorder', n({ width: 300, height: 50 }, box(40, 20, { order: 2 }), box(50, 20, { order: 1 }), box(60, 20)));
  add('negative', n({ width: 300, height: 50 }, box(40, 20), box(50, 20, { order: -1 })));
});

// ---------------------------------------------------------------------------------------------
// HTML

const px = (v) => (typeof v === 'number' ? `${v}px` : String(v));

function edges(v) {
  // [top, right, bottom, left] or a single value, CSS shorthand order.
  const e = Array.isArray(v) ? v : [v, v, v, v];
  return e.map(px).join(' ');
}

const cssName = (k) => k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);

function css(style) {
  const out = [style.text ? 'display:block' : 'display:flex', 'box-sizing:border-box', 'position:relative'];
  if (style.text) out.push('font-size:0', 'line-height:0');
  // A leaf is content, not a container: properties of a flex container mean nothing to it,
  // and in the browser they would move its content inside it (and with it the baseline).
  const containerOnly = ['flexDirection', 'flexWrap', 'justifyContent', 'alignItems', 'alignContent', 'rowGap', 'columnGap'];
  for (const [k, v] of Object.entries(style)) {
    if (k === 'content' || k === 'text') continue;
    if ((style.text || style.content) && containerOnly.includes(k)) continue;
    if (k === 'padding' || k === 'margin') out.push(`${k}:${edges(v)}`);
    else if (['flexGrow', 'flexShrink', 'order', 'aspectRatio'].includes(k)) out.push(`${cssName(k)}:${v}`);
    else out.push(`${cssName(k)}:${px(v)}`);
  }
  return out.join(';');
}

function assignIDs(node, counter = { i: 0 }) {
  node.id = `n${counter.i++}`;
  for (const child of node.children) assignIDs(child, counter);
  return node;
}

function html(node) {
  let content = node.style.content
    ? `<div data-content style="flex-shrink:0;width:${node.style.content[0]}px;height:${node.style.content[1]}px"></div>`
    : '';
  if (node.style.text) {
    const [lineHeight, ...words] = node.style.text;
    content = words
      .map((w) => `<span data-content style="display:inline-block;width:${w}px;height:${lineHeight}px"></span>`)
      .join('');
  }
  return `<div id="${node.id}" style="${css(node.style)}">${content}${node.children.map(html).join('')}</div>`;
}

// ---------------------------------------------------------------------------------------------
// Text: content whose height depends on its width. Kept in its own fixture file.

const textCases = [];
{
  const saved = cases.length;
  const t = (lineHeight, ...words) => [lineHeight, ...words];
  group('text', () => {
    add('row-two-paragraphs-shrink', n({ width: 200, height: 100, alignItems: 'flex-start' },
      n({ text: t(10, 40, 30, 50, 30) }), n({ text: t(10, 60, 40, 50) })));
    add('row-min-content-floor', n({ width: 100, height: 100, alignItems: 'flex-start' },
      n({ text: t(10, 70, 20) }), n({ text: t(10, 60, 30) })));
    add('column-wraps-at-width', n({ width: 100, height: 200, flexDirection: 'column' },
      n({ text: t(10, 40, 30, 50, 30, 20) }), n({ text: t(20, 90, 10) })));
    add('basis-zero-grow', n({ width: 240, height: 100, alignItems: 'flex-start' },
      n({ flexGrow: 1, flexBasis: 0, text: t(10, 50, 50, 50) }), n({ flexGrow: 1, flexBasis: 0, text: t(10, 30) })));
    add('column-center-fit-content', n({ width: 120, height: 200, flexDirection: 'column', alignItems: 'center' },
      n({ text: t(10, 30, 20) }), n({ text: t(10, 60, 50, 40) })));
    add('padding-and-limits', n({ width: 300, height: 200, flexDirection: 'column', alignItems: 'flex-start' },
      n({ padding: 10, text: t(10, 50, 50, 50, 50) }), n({ maxWidth: 90, text: t(10, 40, 40, 40) }),
      n({ minWidth: 150, text: t(10, 20, 20) })));
    add('width-below-longest-word', n({ width: 200, height: 100, alignItems: 'flex-start' },
      n({ width: 30, text: t(10, 50, 10, 10) })));
    add('profile-card', n({ width: 220, height: 120, padding: 16, columnGap: 12, alignItems: 'center' },
      box(48, 48),
      n({ flexDirection: 'column', rowGap: 4, flexGrow: 1, flexShrink: 1 },
        n({ text: t(16, 40, 30, 50, 20) }), n({ text: t(12, 30, 30, 30, 30) })),
      n({ content: [60, 28] })));
    add('wrap-chips', n({ width: 160, height: 200, flexWrap: 'wrap', columnGap: 8, rowGap: 8, alignContent: 'flex-start' },
      n({ padding: 4, text: t(10, 40) }), n({ padding: 4, text: t(10, 30, 30) }), n({ padding: 4, text: t(10, 70) }),
      n({ padding: 4, text: t(10, 20) })));
    add('stretched-row-height', n({ width: 150, height: 200, alignItems: 'stretch', alignContent: 'flex-start', flexWrap: 'wrap' },
      n({ width: 70, text: t(10, 30, 30, 30) }), n({ width: 70, text: t(10, 20) })));
    add('absolute-shrink-to-fit', n({ width: 200, height: 200 },
      n({ position: 'absolute', top: 10, left: 10, text: t(10, 50, 50, 50, 50, 50) })));
    add('nested-column-in-row', n({ width: 180, height: 150, alignItems: 'flex-start' },
      n({ flexDirection: 'column', flexGrow: 1 }, n({ text: t(10, 40, 40, 40, 40) })),
      n({ flexDirection: 'column', width: 60 }, n({ text: t(10, 30, 30, 30) }))));
  });
  group('baseline', () => {
    add('row-text', n({ width: 300, height: 100, alignItems: 'baseline' },
      n({ text: t(10, 40) }), n({ text: t(24, 30, 30) }), n({ padding: [6, 0, 0, 0], text: t(16, 50) })));
    add('image-and-empty-box', n({ width: 300, height: 100, alignItems: 'baseline' },
      n({ text: t(20, 40) }), n({ padding: [5, 0, 7, 0], content: [30, 15] }), n({ width: 20, height: 30 })));
    add('wrapped-text-uses-first-line', n({ width: 300, height: 100, alignItems: 'baseline' },
      n({ width: 60, text: t(10, 40, 40, 40) }), n({ text: t(30, 30) })));
    add('nested-container', n({ width: 300, height: 120, alignItems: 'baseline' },
      n({ text: t(12, 40) }),
      n({ flexDirection: 'column', padding: [8, 0, 0, 0] }, n({ text: t(20, 50) }), n({ text: t(10, 50) })),
      n({ padding: [4, 0, 0, 0] }, n({ text: t(16, 30) }))));
    add('align-self-in-center', n({ width: 300, height: 100, alignItems: 'center' },
      n({ alignSelf: 'baseline', text: t(10, 40) }), n({ alignSelf: 'baseline', text: t(30, 40) }), n({ text: t(20, 20) })));
    add('wrap-per-line', n({ width: 120, height: 200, flexWrap: 'wrap', alignItems: 'baseline', alignContent: 'flex-start' },
      n({ text: t(10, 50) }), n({ text: t(20, 50) }), n({ text: t(30, 50) }), n({ text: t(12, 50) })));
    add('column-falls-back-to-start', n({ width: 200, height: 200, flexDirection: 'column', alignItems: 'baseline' },
      n({ text: t(10, 40) }), n({ text: t(20, 60) })));
    add('margins', n({ width: 300, height: 100, alignItems: 'baseline' },
      n({ margin: [10, 0, 0, 0], text: t(10, 40) }), n({ text: t(20, 40) })));
  });
  textCases.push(...cases.splice(saved));
}

// ---------------------------------------------------------------------------------------------
// Random trees
//
// Hand-written cases only check what their author thought of. Random trees combine the same
// vocabulary in ways nobody wrote down; a fixed seed keeps the set reproducible. Properties
// the engine is known not to model yet are left out (baseline alignment, percentage padding
// and margins, text).

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomTree(rng, withText = false, withBaseline = false) {
  const pick = (values) => values[Math.floor(rng() * values.length)];
  const chance = (p) => rng() < p;

  function node(depth, isRoot) {
    const s = {};
    if (isRoot) {
      s.width = pick([200, 300, 360]);
      s.height = pick([100, 200, 300]);
      if (chance(0.15)) s.direction = 'rtl';
    }
    if (chance(0.5)) s.flexDirection = pick(directions);
    if (chance(0.3)) s.flexWrap = pick(['wrap', 'wrap-reverse']);
    if (chance(0.4)) s.justifyContent = pick(justifies);
    if (chance(0.4)) s.alignItems = pick(withBaseline ? ['stretch', 'baseline', 'flex-end', 'center'] : ['stretch', 'flex-start', 'flex-end', 'center']);
    if (chance(0.25)) s.alignContent = pick(alignContents);
    if (chance(0.3)) s.rowGap = pick([0, 4, 10]);
    if (chance(0.3)) s.columnGap = pick([0, 4, 10]);
    if (chance(0.3)) {
      s.padding = chance(0.5) ? pick([4, 10]) : [pick([0, 5]), pick([0, 10]), pick([0, 5]), pick([0, 15])];
    }
    if (!isRoot) {
      if (chance(0.35)) s.flexGrow = pick([0, 1, 2, 0.5]);
      if (chance(0.25)) s.flexShrink = pick([0, 1, 3]);
      if (chance(0.25)) s.flexBasis = pick([0, 20, 60, '50%', 'auto']);
      if (chance(0.5)) s.width = pick([20, 40, 80, 120, '50%', '25%']);
      if (chance(0.5)) s.height = pick([10, 20, 40, 80, '50%']);
      if (chance(0.15)) s.minWidth = pick([0, 30, 60]);
      if (chance(0.15)) s.maxWidth = pick([40, 100, '50%']);
      if (chance(0.1)) s.minHeight = pick([0, 30]);
      if (chance(0.1)) s.maxHeight = pick([20, 60]);
      if (chance(0.25)) s.alignSelf = pick(withBaseline ? ['auto', 'stretch', 'baseline', 'flex-end', 'center'] : ['auto', 'stretch', 'flex-start', 'flex-end', 'center']);
      if (chance(0.25)) {
        s.margin = chance(0.3)
          ? pick([5, 'auto'])
          : [pick([0, 5, 'auto']), pick([0, 10, 'auto']), pick([0, 5]), pick([0, 10, 'auto'])];
      }
      if (chance(0.08)) s.aspectRatio = pick([1, 2, 0.5]);
      if (chance(0.1)) s.order = pick([-1, 1, 2]);
      if (chance(0.08)) {
        s.position = 'absolute';
        for (const side of ['top', 'right', 'bottom', 'left']) {
          if (chance(0.4)) s[side] = pick([0, 5, 20]);
        }
      }
    }
    const children = [];
    if (depth < 3 && (isRoot || chance(0.45))) {
      const count = isRoot ? 1 + Math.floor(rng() * 5) : 1 + Math.floor(rng() * 3);
      for (let i = 0; i < count; i++) children.push(node(depth + 1, false));
    } else if (!isRoot && withText && chance(0.6)) {
      const words = [];
      const count = 1 + Math.floor(rng() * 7);
      for (let i = 0; i < count; i++) words.push(pick([10, 20, 30, 40, 60]));
      s.text = [pick([10, 20]), ...words];
    } else if (!isRoot && chance(0.5)) {
      s.content = [pick([10, 30, 50, 90]), pick([10, 20, 30])];
    }
    return n(s, ...children);
  }

  return node(0, true);
}

const randomTextSeed = 7;
const randomTextCount = 200;
const randomTextCases = [];
{
  const rng = mulberry32(randomTextSeed);
  for (let i = 0; i < randomTextCount; i++) {
    const name = `random-text/${String(i).padStart(4, '0')}`;
    randomTextCases.push({ name, group: 'random-text', root: randomTree(rng, true) });
  }
}

const randomBaselineSeed = 11;
const randomBaselineCount = 150;
const randomBaselineCases = [];
{
  const rng = mulberry32(randomBaselineSeed);
  for (let i = 0; i < randomBaselineCount; i++) {
    const name = `random-baseline/${String(i).padStart(4, '0')}`;
    randomBaselineCases.push({ name, group: 'random-baseline', root: randomTree(rng, true, true) });
  }
}

const randomSeed = 2026;
const randomCount = 400;
const randomCases = [];
{
  const rng = mulberry32(randomSeed);
  for (let i = 0; i < randomCount; i++) {
    const name = `random/${String(i).padStart(4, '0')}`;
    randomCases.push({ name, group: 'random', root: randomTree(rng) });
  }
}

// ---------------------------------------------------------------------------------------------
// Render

async function render(browser, list, file, extra) {
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  const out = [];
  for (const c of list) {
    assignIDs(c.root);
    await page.setContent(
      `<!doctype html><html><body style="margin:0"><div style="position:absolute;left:0;top:0">${html(c.root)}</div></body></html>`,
    );
    const frames = await page.evaluate(() => {
      const root = document.getElementById('n0').getBoundingClientRect();
      return [...document.querySelectorAll('[id^=n]')].map((e) => {
        const r = e.getBoundingClientRect();
        return { id: e.id, x: r.x - root.x, y: r.y - root.y, width: r.width, height: r.height };
      });
    });
    out.push({ name: c.name, group: c.group, root: c.root, expected: frames });
  }
  await page.close();
  const fixture = {
    generator: 'Conformance/CSSFlexbox/generate.cjs',
    browser: `chromium ${browser.version()}`,
    ...extra,
    caseCount: out.length,
    cases: out,
  };
  const target = path.join(__dirname, 'fixtures', file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify(fixture, null, 1)}\n`);
  console.log(`wrote ${out.length} cases to ${path.relative(process.cwd(), target)}`);
}

(async () => {
  const browser = await chromium.launch();
  await render(browser, cases, 'flexbox.json', {});
  await render(browser, randomCases, 'random.json', { seed: randomSeed });
  await render(browser, textCases, 'text.json', {});
  await render(browser, randomTextCases, 'random-text.json', { seed: randomTextSeed });
  await render(browser, randomBaselineCases, 'random-baseline.json', { seed: randomBaselineSeed });
  await browser.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
