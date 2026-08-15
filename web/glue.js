const MAGIC = 0x4d524b57;
const HEADER_SIZE = 60;
const RECT_SIZE = 12;
const TEXT_ENTRY_SIZE = 20;
const SELECTION_SIZE = 24;
const IMAGE_SIZE = 20;
const ATTRS_BOLD = 1;
const ATTRS_DIM = 2;
const ATTRS_UNDERLINE = 4;

const FONT_FAMILY = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";

const tags = {
  character: 0, control: 1, pointer: 2, enter: 3, escape: 4,
  backspace: 5, delete: 6, tab: 7, shiftTab: 8, up: 9, down: 10,
  left: 11, right: 12, home: 13, end: 14,
};

const pointerButton = { primary: 0, middle: 1, secondary: 2, wheelUp: 3, wheelDown: 4 };

let exports = null;
let memory = null;
let stackPointer = null;
let framePtr = 0;
let renderer = null;
let cssCell = 8;

const FEED_SCRATCH_SIZE = 512 * 1024;
let feedScratchPtr = 0;

const SEED_URLS = "https://hnrss.org/frontpage\nhttps://lobste.rs/rss\nhttps://news.ycombinator.com/rss\n";

function rgba(value, alpha) {
  const r = value & 255, g = (value >>> 8) & 255, b = (value >>> 16) & 255, a = (value >>> 24) & 255;
  if (alpha !== undefined) return `rgba(${r},${g},${b},${alpha})`;
  return `rgba(${r},${g},${b},${a})`;
}

function readHeader() {
  const dv = new DataView(memory.buffer, framePtr);
  if (dv.getUint32(0, true) !== MAGIC) return null;
  return {
    width: dv.getUint32(8, true),
    height: dv.getUint32(12, true),
    rows: dv.getUint32(16, true),
    background: dv.getUint32(20, true),
    rectOffset: dv.getUint32(24, true),
    rectCount: dv.getUint32(28, true),
    textOffset: dv.getUint32(32, true),
    textCount: dv.getUint32(36, true),
    selectionOffset: dv.getUint32(40, true),
    selectionCount: dv.getUint32(44, true),
    imageOffset: dv.getUint32(48, true),
    imageCount: dv.getUint32(52, true),
    frameLength: dv.getUint32(56, true),
  };
}

const scratch = document.createElement("canvas");
const scratchCtx = scratch.getContext("2d");

function measureRatio() {
  scratchCtx.font = `16px ${FONT_FAMILY}`;
  return scratchCtx.measureText("M").width / 16;
}

class HtmlRenderer {
  constructor(container) {
    this.container = container;
    this.background = "";
    this.lastSize = "";
  }

  layout(header) {
    const ratio = measureRatio();
    const cssScale = Math.max(1, Math.floor(Math.min(
      window.innerWidth / (header.width * 8),
      window.innerHeight / (header.height * 8),
    )));
    cssCell = 8 * cssScale;
    this.fontPx = cssCell / ratio;
    this.cellW = cssCell;
    this.rowH = 2 * cssCell;
    this.container.style.width = `${header.width * cssCell}px`;
    this.container.style.height = `${header.height * cssCell}px`;
  }

  render(header) {
    const dv = new DataView(memory.buffer, framePtr);

    const background = rgba(header.background);
    if (background !== this.background) {
      this.background = background;
      this.container.style.backgroundColor = background;
    }

    const regions = this.readRegions(dv, header);
    const fragment = document.createDocumentFragment();
    const decoder = new TextDecoder();

    for (let i = 0; i < header.rectCount; i++) {
      const base = header.rectOffset + i * RECT_SIZE;
      const rect = document.createElement("div");
      rect.style.position = "absolute";
      rect.style.left = `${dv.getUint16(base, true) * this.cellW}px`;
      rect.style.top = `${dv.getUint16(base + 2, true) * this.rowH}px`;
      rect.style.width = `${dv.getUint16(base + 4, true) * this.cellW}px`;
      rect.style.height = `${dv.getUint16(base + 6, true) * this.rowH}px`;
      rect.style.backgroundColor = rgba(dv.getUint32(base + 8, true));
      fragment.appendChild(rect);
    }

    for (const r of regions) {
      const rect = document.createElement("div");
      rect.style.position = "absolute";
      rect.style.left = `${r.x * this.cellW}px`;
      rect.style.top = `${r.y * this.rowH}px`;
      rect.style.width = `${r.width * this.cellW}px`;
      rect.style.height = `${r.height * this.rowH}px`;
      rect.style.backgroundColor = rgba(r.bg);
      fragment.appendChild(rect);
    }

    let offset = header.textOffset;
    for (let i = 0; i < header.textCount; i++) {
      const x = dv.getUint16(offset, true);
      const y = dv.getUint16(offset + 2, true);
      const length = dv.getUint16(offset + 4, true);
      const fg = dv.getUint32(offset + 8, true);
      const bg = dv.getUint32(offset + 12, true);
      const attrs = dv.getUint8(offset + 16);
      const text = decoder.decode(
        new Uint8Array(memory.buffer, framePtr + offset + TEXT_ENTRY_SIZE, length),
      );
      offset += TEXT_ENTRY_SIZE + length;

      let region = null;
      for (const r of regions) {
        if (y >= r.y && y < r.y + r.height && x < r.x + r.width && x + length > r.x) {
          region = r;
          break;
        }
      }
      const bold = (attrs & ATTRS_BOLD) !== 0 || region !== null;
      const dim = (attrs & ATTRS_DIM) !== 0;
      const underline = (attrs & ATTRS_UNDERLINE) !== 0;
      const span = document.createElement("span");
      span.textContent = text;
      span.style.position = "absolute";
      span.style.left = `${x * this.cellW}px`;
      span.style.top = `${y * this.rowH}px`;
      span.style.height = `${this.rowH}px`;
      span.style.lineHeight = `${this.rowH}px`;
      span.style.fontFamily = FONT_FAMILY;
      span.style.fontSize = `${this.fontPx}px`;
      span.style.fontWeight = bold ? "bold" : "normal";
      span.style.whiteSpace = "pre";
      span.style.color = rgba(region ? region.fg : fg);
      span.style.backgroundColor = (region ? region.bg : bg) ? rgba(region ? region.bg : bg) : "transparent";
      span.style.textDecoration = underline ? "underline" : "none";
      if (dim) span.style.opacity = "0.65";
      fragment.appendChild(span);
    }
    this.container.replaceChildren(fragment);
  }

  readRegions(dv, header) {
    const regions = [];
    for (let i = 0; i < header.selectionCount; i++) {
      const base = header.selectionOffset + i * SELECTION_SIZE;
      regions.push({
        x: dv.getUint16(base, true),
        y: dv.getUint16(base + 2, true),
        width: dv.getUint16(base + 4, true),
        height: dv.getUint16(base + 6, true),
        bg: dv.getUint32(base + 8, true),
        fg: dv.getUint32(base + 12, true),
      });
    }
    return regions;
  }
}

function push(tag, a, b, c) {
  console.log(`[push] calling rm_input(tag=${tag}, a=${a}, b=${b}, c=${c})`);
  call(exports.rm_input, tag, a, b, c);
  scheduleRender();
}

function cellFromEvent(e) {
  const rect = renderer.surface.getBoundingClientRect();
  const x = Math.floor((e.clientX - rect.left) / cssCell);
  const y = Math.floor((e.clientY - rect.top) / (2 * cssCell));
  return [x, y];
}

function setupInput() {
  window.addEventListener("keydown", (e) => {
    const key = e.key;
    if (e.ctrlKey) {
      if (key.length === 1) { 
        e.preventDefault(); 
        const code = key.toLowerCase().charCodeAt(0);
        console.log(`[input] ctrl+${key} -> tag=${tags.control}, a=${code}`);
        push(tags.control, code, 0, 0); 
      }
      return;
    }
    const plain = {
      ArrowUp: tags.up, ArrowDown: tags.down, ArrowLeft: tags.left, ArrowRight: tags.right,
      Home: tags.home, End: tags.end, Enter: tags.enter, Escape: tags.escape,
      Backspace: tags.backspace, Delete: tags.delete,
    };
    if (key === "Tab") { e.preventDefault(); push(e.shiftKey ? tags.shiftTab : tags.tab, 0, 0, 0); return; }
    if (plain[key] !== undefined) { 
      e.preventDefault(); 
      console.log(`[input] ${key} -> tag=${plain[key]}`);
      push(plain[key], 0, 0, 0); 
      return; 
    }
    if (key.length === 1) push(tags.character, key.charCodeAt(0), 0, 0);
  });

  const surface = renderer.surface;
  surface.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    surface.setPointerCapture(e.pointerId);
    const [x, y] = cellFromEvent(e);
    push(tags.pointer, x, y, pointerButton.primary);
  });
  surface.addEventListener("pointermove", (e) => {
    const [x, y] = cellFromEvent(e);
    if (e.buttons !== 0) push(tags.pointer, x, y, pointerButton.primary | (1 << 8));
    else push(tags.pointer, x, y, 0);
  });
  surface.addEventListener("pointerup", (e) => {
    const [x, y] = cellFromEvent(e);
    push(tags.pointer, x, y, pointerButton.primary | (2 << 8));
  });
  surface.addEventListener("wheel", (e) => {
    e.preventDefault();
    const [x, y] = cellFromEvent(e);
    const button = e.deltaY > 0 ? pointerButton.wheelDown : pointerButton.wheelUp;
    push(tags.pointer, x, y, button << 8);
  }, { passive: false });
}

// --- render -----------------------------------------------------------------

function render() {
  const length = call(exports.rm_update, null);
  
  if (length === 0) {
    // No state change, nothing to render
    return;
  }
  
  if (length === 1) {
    console.log(`ERROR - app not initialized`);
  } else if (length === 2) {
    console.log(`ERROR - view.render() failed`);
  } else if (length === 3) {
    console.log(`ERROR - serialize_frame() failed`);
  } else if (length > 0) {
    const header = readHeader();
    if (header) {
      console.log(`[render] length=${length}, textCount=${header.textCount}, rectCount=${header.rectCount}`);
      renderer.layout(header);
      renderer.render(header);
    }
  }
}

function scheduleRender() {
  requestAnimationFrame(render);
}

function call(fn, ...args) {
  const bytes = memory.buffer.byteLength;
  if (stackPointer.value !== bytes) stackPointer.value = bytes;
  return fn(...args);
}

function initRenderer() {
  const html = document.getElementById("screen-html");
  renderer = new HtmlRenderer(html);
  renderer.surface = html;
}

function decodeUtf8(ptr, len) {
  return new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
}

function writeToWasm(ptr, bytes) {
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
}

const FEED_CONTENT = {
  "https://hnrss.org/frontpage": '<?xml version="1.0"?>\n<rss version="2.0"><channel><title>Hacker News</title>\n<item><title>Zig: A better systems programming language</title><link>https://ziglang.org</link><description>Zig features comptime, error handling, and cross-compilation built in.</description><pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate></item>\n<item><title>Local-first software is the future</title><link>https://www.inkandswitch.com/local-first/</link><description>Local-first gives you full ownership, works offline, and enables collaboration. No accounts, no lock-in.</description><pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate></item>\n<item><title>The return of the terminal app</title><link>https://arstechnica.com</link><description>Terminal apps are making a comeback with frameworks like ratatui and markix. Full-screen text interfaces work over SSH, on weird monitors, and in CI.</description><pubDate>Mon, 01 Jan 2024 08:00:00 GMT</pubDate></item>\n<item><title>Why SQLite is the future</title><link>https://sqlite.org</link><description>SQLite powers billions of apps and makes an excellent application file format. Your data is a single file you own.</description><pubDate>Mon, 01 Jan 2024 06:00:00 GMT</pubDate></item>\n<item><title>WebAssembly: Beyond the browser</title><link>https://webassembly.org</link><description>WASM is no longer just for browsers. With WASI it powers serverless, edge computing, plugins, and desktop apps.</description><pubDate>Mon, 01 Jan 2024 04:00:00 GMT</pubDate></item>\n</channel></rss>',

  "https://lobste.rs/rss": '<?xml version="1.0"?>\n<rss version="2.0"><channel><title>Lobsters</title>\n<item><title>Zig 0.17: The new std.Io is here</title><link>https://ziglang.org</link><description>std.Io has landed in Zig 0.17. A single coherent interface for files, terminals, network, and pipes.</description><pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate></item>\n<item><title>Clay: A fast UI layout library in C</title><link>https://github.com/nicbarker/clay</link><description>High-performance 2D UI layout in C with flexbox-like layout and realtime styling. Single-header deployment.</description><pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate></item>\n<item><title>Building a terminal UI framework</title><link>https://markix.dev</link><description>Building a terminal UI involves text rendering, cursor management, input parsing, and layout. Modern frameworks handle all of this.</description><pubDate>Mon, 01 Jan 2024 08:00:00 GMT</pubDate></item>\n<item><title>The art of reading source code</title><link>https://sourcecod.com</link><description>Reading source code is a skill every developer should master. It helps understand how things work and debug faster.</description><pubDate>Mon, 01 Jan 2024 06:00:00 GMT</pubDate></item>\n<item><title>Why local-first matters</title><link>https://www.inkandswitch.com</link><description>Local-first gives you control, works offline, and enables collaboration. No cloud dependency, no account, no lock-in.</description><pubDate>Mon, 01 Jan 2024 04:00:00 GMT</pubDate></item>\n</channel></rss>',

  "https://news.ycombinator.com/rss": '<?xml version="1.0"?>\n<rss version="2.0"><channel><title>Hacker News</title>\n<item><title>SQLite as an application file format</title><link>https://sqlite.org</link><description>SQLite makes an excellent application file format. Fast, reliable, ACID-compliant, runs everywhere including in the browser as WASM.</description><pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate></item>\n<item><title>How terminals work</title><link>https://unit.co</link><description>A deep dive into terminal emulators: ANSI escape sequences, colors, images via Sixel and Kitty, and scrollback buffers.</description><pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate></item>\n<item><title>Rust vs Zig: A pragmatic comparison</title><link>https://ziglang.org</link><description>Both are modern systems languages but take different approaches. Rust focuses on safety; Zig on clarity and simplicity.</description><pubDate>Mon, 01 Jan 2024 08:00:00 GMT</pubDate></item>\n<item><title>Accessibility in terminal apps</title><link>https://accessibility.io</link><description>Terminal apps can be accessible. Screen readers work with text interfaces, keyboard-only navigation, and high contrast.</description><pubDate>Mon, 01 Jan 2024 06:00:00 GMT</pubDate></item>\n<item><title>Personal knowledge base with Markdown</title><link>https://obsidian.md</link><description>Your second brain in plain text. Markdown notes linked together create a personal knowledge graph. No vendor lock-in.</description><pubDate>Mon, 01 Jan 2024 04:00:00 GMT</pubDate></item>\n</channel></rss>',
};

function seedSubscriptions() {
  const path = "/.newsboat/urls";
  const pathBytes = new TextEncoder().encode(path);
  const dataBytes = new TextEncoder().encode(SEED_URLS);
  const pathPtr = feedScratchPtr;
  const dataPtr = feedScratchPtr + pathBytes.length;
  writeToWasm(pathPtr, pathBytes);
  writeToWasm(dataPtr, dataBytes);
  console.log(`[seed] seeding ${path} (${dataBytes.length} bytes)`);
  call(exports.rm_seed_file, pathPtr, pathBytes.length, dataPtr, dataBytes.length);
}

async function fetchFeed(url, requestId) {
  console.log(`[fetch] starting request ${requestId} for ${url}`);

  // Use pre-seeded content if available (bypasses CORS)
  if (FEED_CONTENT[url]) {
    const content = FEED_CONTENT[url];
    const bytes = new TextEncoder().encode(content);
    const len = Math.min(bytes.length, FEED_SCRATCH_SIZE);
    console.log(`[fetch] request ${requestId} completed from cache: status=200, ${len} bytes`);
    writeToWasm(feedScratchPtr, bytes.subarray(0, len));
    call(exports.rm_fetch_response, requestId, 200, feedScratchPtr, len);
    scheduleRender();
    return;
  }

  // Fall back to CORS proxy for unknown URLs
  try {
    const proxyUrl = `https://api.allorigins.win/raw?url=${encodeURIComponent(url)}`;
    const response = await fetch(proxyUrl);
    const text = await response.text();
    const bytes = new TextEncoder().encode(text);
    const len = Math.min(bytes.length, FEED_SCRATCH_SIZE);
    console.log(`[fetch] request ${requestId} completed: status=${response.status}, ${len} bytes`);
    writeToWasm(feedScratchPtr, bytes.subarray(0, len));
    call(exports.rm_fetch_response, requestId, response.status, feedScratchPtr, len);
    scheduleRender();
  } catch (err) {
    console.error(`[fetch] request ${requestId} failed:`, err);
    call(exports.rm_fetch_response, requestId, 0, 0, 0);
    scheduleRender();
  }
}

async function main() {
  initRenderer();
  const env = createEnv();
  const { instance } = await WebAssembly.instantiateStreaming(
    fetch("readmarks.wasm"),
    { env },
  );
  exports = instance.exports;
  memory = env.memory;
  stackPointer = env.__stack_pointer;
  feedScratchPtr = memory.buffer.byteLength - FEED_SCRATCH_SIZE;
  if (exports.__wasm_apply_data_relocs) exports.__wasm_apply_data_relocs();
  framePtr = call(exports.rm_frame_ptr, null);
  seedSubscriptions();
  call(exports.rm_init, null);
  setupInput();
  render();
}

function createEnv() {
  const memory = new WebAssembly.Memory({ initial: 512, maximum: 32768 });
  const table = new WebAssembly.Table({ initial: 4096, maximum: 4096, element: "anyfunc" });
  return {
    memory,
    __indirect_function_table: table,
    __stack_pointer: new WebAssembly.Global({ value: "i32", mutable: true }, 0),
    __memory_base: new WebAssembly.Global({ value: "i32", mutable: false }, 0),
    __table_base: new WebAssembly.Global({ value: "i32", mutable: false }, 0),
    js_now_ms: () => BigInt(Date.now()),
    js_random: (ptr, len) => {
      crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len));
    },
    js_open_url: (ptr, len) => {
      window.open(decodeUtf8(ptr, len), "_blank");
    },
    js_log: (ptr, len) => {
      console.log("[zig]", decodeUtf8(ptr, len));
    },
    js_fetch_request: (urlPtr, urlLen, requestId) => {
      const url = decodeUtf8(urlPtr, urlLen);
      fetchFeed(url, requestId);
    },
  };
}

main().catch((error) => {
  console.error(error);
  document.body.innerHTML = `<pre>failed to start: ${error.message ?? error}</pre>`;
});
