const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { spawn } = require("node:child_process");

const [executable, workingDirectory, documentPath, hoverLine = "0", hoverCharacter = "12", expectedHover = "IO"] = process.argv.slice(2);
if (!executable || !workingDirectory || !documentPath) {
  throw new Error("Usage: node test-lean-lsp.js <lean.exe> <working-directory> <Main.lean> [line] [character] [expected-hover]");
}
const hoverPosition = { line: Number(hoverLine), character: Number(hoverCharacter) };
const expectedHoverPattern = new RegExp(expectedHover);

const child = spawn(executable, ["--server"], {
  cwd: workingDirectory,
  shell: false,
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env,
});
let buffer = Buffer.alloc(0);
let stderr = "";
let nextId = 1;
const pending = new Map();

function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii");
  child.stdin.write(Buffer.concat([header, body]));
}

function request(method, params, timeoutMs = 90000) {
  const id = nextId++;
  const response = new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for '${method}'.\nstderr: ${stderr}`));
    }, timeoutMs);
    pending.set(id, message => {
      clearTimeout(timer);
      resolve(message);
    });
  });
  send({ jsonrpc: "2.0", id, method, params });
  return response;
}

function replyToServerRequest(message) {
  let result = null;
  if (message.method === "workspace/configuration") {
    result = (message.params?.items || []).map(() => null);
  } else if (message.method === "workspace/applyEdit") {
    result = { applied: false };
  }
  send({ jsonrpc: "2.0", id: message.id, result });
}

function parseMessages() {
  for (;;) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const header = buffer.subarray(0, headerEnd).toString("ascii");
    const match = /^Content-Length:\s*(\d+)$/im.exec(header);
    if (!match) throw new Error(`Invalid LSP header: ${header}`);
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    if (buffer.length < bodyStart + length) return;
    const message = JSON.parse(buffer.subarray(bodyStart, bodyStart + length).toString("utf8"));
    buffer = buffer.subarray(bodyStart + length);
    if (message.id !== undefined && message.method) {
      replyToServerRequest(message);
    } else if (message.id !== undefined && pending.has(message.id)) {
      const resolve = pending.get(message.id);
      pending.delete(message.id);
      resolve(message);
    }
  }
}

child.stdout.on("data", chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  try {
    parseMessages();
  } catch (error) {
    console.error(error);
    child.kill();
    process.exitCode = 1;
  }
});
child.stderr.on("data", chunk => (stderr += chunk.toString("utf8")));
child.on("error", error => {
  console.error(error);
  process.exitCode = 1;
});

(async () => {
  const rootUri = pathToFileURL(path.resolve(workingDirectory)).href;
  const uri = pathToFileURL(path.resolve(documentPath)).href;
  const text = fs.readFileSync(documentPath, "utf8");
  const initialized = await request("initialize", {
    processId: process.pid,
    rootUri,
    workspaceFolders: [{ uri: rootUri, name: path.basename(workingDirectory) }],
    capabilities: {
      workspace: { configuration: true, workspaceFolders: true },
      textDocument: { hover: { contentFormat: ["markdown", "plaintext"] } },
    },
  });
  if (initialized.error || !initialized.result?.capabilities?.hoverProvider) {
    throw new Error(`Lean LSP initialize failed: ${JSON.stringify(initialized)}`);
  }

  send({ jsonrpc: "2.0", method: "initialized", params: {} });
  send({
    jsonrpc: "2.0",
    method: "textDocument/didOpen",
    params: { textDocument: { uri, languageId: "lean4", version: 1, text } },
  });

  let hover;
  for (let attempt = 0; attempt < 20; attempt++) {
    hover = await request("textDocument/hover", {
      textDocument: { uri },
      position: hoverPosition,
    });
    if (hover.result && expectedHoverPattern.test(JSON.stringify(hover.result))) break;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  const rendered = JSON.stringify(hover?.result);
  if (hover?.error || !hover?.result || !expectedHoverPattern.test(rendered)) {
    throw new Error(`Expected a Lean hover matching ${expectedHoverPattern}, received: ${JSON.stringify(hover)}\nstderr: ${stderr}`);
  }
  console.log(`Lean LSP hover OK: ${rendered}`);

  const shutdown = await request("shutdown", null, 30000);
  if (shutdown.error) throw new Error(`Lean LSP shutdown failed: ${JSON.stringify(shutdown.error)}`);
  send({ jsonrpc: "2.0", method: "exit", params: null });
  child.stdin.end();
})().catch(error => {
  console.error(error);
  child.kill();
  process.exitCode = 1;
});

