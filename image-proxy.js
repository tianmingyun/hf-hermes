/**
 * Image Proxy + BFF Reverse Proxy
 *
 * 在 BFF (hermes-web-ui) 前端增加一层轻量代理:
 *   - /images/          → 列出所有已生成图片 (HTML 页面)
 *   - /images/<file>    → 直接下载/预览图片
 *   - 其他所有请求       → 透传给 BFF (含 WebSocket)
 *
 * 端口: 7860 (HF Spaces 对外端口)
 * BFF:  7861 (内部端口, 仅本代理访问)
 * 图片目录: /data/.hermes/image_cache (主目录)
 *           /data/cover-image (baoyu-cover-image 输出目录)
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');

const BFF_HOST = '127.0.0.1';
const BFF_PORT = parseInt(process.env.BFF_PORT || '7861', 10);
const LISTEN_PORT = parseInt(process.env.LISTEN_PORT || '7860', 10);
const IMAGE_DIR = process.env.IMAGE_DIR || '/data/.hermes/image_cache';

// 额外的图片搜索路径（baoyu-cover-image 等技能的输出目录）
const EXTRA_IMAGE_DIRS = [
  '/data/cover-image',
  '/data/.hermes/image_cache',
];

const MIME_TYPES = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain',
  '.json': 'application/json',
  '.md': 'text/markdown',
};

// ==================== 图片文件服务 ====================

function serveImageList(res) {
  const allImageFiles = [];
  let dirsScanned = 0;
  const totalDirs = EXTRA_IMAGE_DIRS.length;

  function checkComplete() {
    dirsScanned++;
    if (dirsScanned < totalDirs) return;

    const uniqueFiles = Array.from(new Map(allImageFiles.map(f => [f.path, f])).values());
    uniqueFiles.sort((a, b) => b.mtime - a.mtime);

    const html = buildImageListHtml(uniqueFiles);
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  }

  EXTRA_IMAGE_DIRS.forEach(dir => {
    function scanDir(currentDir, relativePath, callback) {
      fs.readdir(currentDir, { withFileTypes: true }, (err, entries) => {
        if (err) {
          callback();
          return;
        }

        let pending = entries.length;
        if (pending === 0) {
          callback();
          return;
        }

        entries.forEach(entry => {
          const fullPath = path.join(currentDir, entry.name);
          const relPath = path.join(relativePath, entry.name);

          if (entry.isDirectory()) {
            scanDir(fullPath, relPath, () => {
              pending--;
              if (pending === 0) callback();
            });
          } else if (/\.(png|jpe?g|gif|webp|svg|bmp)$/i.test(entry.name)) {
            try {
              const stat = fs.statSync(fullPath);
              allImageFiles.push({
                name: entry.name,
                path: fullPath,
                relPath: relPath,
                dir: dir,
                size: stat.size,
                mtime: stat.mtime
              });
            } catch (e) {}
            pending--;
            if (pending === 0) callback();
          } else {
            pending--;
            if (pending === 0) callback();
          }
        });
      });
    }

    scanDir(dir, '', () => {
      checkComplete();
    });
  });
}

function buildImageListHtml(imageFiles) {
  const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>🖼️ Image Cache - Hermes Agent</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0f0f23; color: #e0e0e0; padding: 2em; }
  h1 { color: #7eb8da; margin-bottom: 1em; font-size: 1.5em; }
  .card { background: #1a1a3e; border-radius: 12px; padding: 1.5em;
          margin-bottom: 1.5em; box-shadow: 0 4px 12px rgba(0,0,0,.3); }
  .card h3 { color: #9dd6e8; margin-bottom: 0.8em; font-size: 1.1em; }
  .card img { max-width: 100%; border-radius: 8px; cursor: pointer;
             transition: transform .2s; }
  .card img:hover { transform: scale(1.02); }
  .actions { margin-top: 0.8em; display: flex; gap: 1em; flex-wrap: wrap; }
  .actions a { color: #7eb8da; text-decoration: none; padding: 0.4em 1em;
               border: 1px solid #7eb8da; border-radius: 6px; font-size: 0.9em;
               transition: background .2s; }
  .actions a:hover { background: #7eb8da22; }
  .meta { color: #888; font-size: 0.85em; margin-top: 0.5em; }
  .path { color: #666; font-size: 0.8em; margin-top: 0.3em; }
  .empty { text-align: center; padding: 3em; color: #888; }
  .empty p { margin-top: 1em; font-size: 0.95em; }
</style>
</head>
<body>
<h1>🖼️ Image Cache</h1>
${
  imageFiles.length === 0
    ? `<div class="empty"><p style="font-size:2em">📭</p><p>暂无图片。让 agent 生成图片后将自动出现在此。</p>
       <p>提示: 让 agent 使用 baoyu-imagine 技能，并将图片保存到 /data/.hermes/image_cache/</p></div>`
    : imageFiles
        .map((f) => {
          const sizeMB = (f.size / 1024 / 1024).toFixed(2);
          const mtime = f.mtime.toISOString().replace('T', ' ').slice(0, 19);
          return `<div class="card">
  <h3>${f.name}</h3>
  <div class="path">${f.relPath}</div>
  <img src="/images/${encodeURIComponent(f.relPath)}" alt="${f.name}" loading="lazy" />
  <div class="meta">${sizeMB} MB · ${mtime}</div>
  <div class="actions">
    <a href="/images/${encodeURIComponent(f.relPath)}" download="${f.name}">⬇️ 下载</a>
    <a href="/images/${encodeURIComponent(f.relPath)}" target="_blank">🔍 原始大小</a>
  </div>
</div>`;
        })
        .join('\n')
}
</body></html>`;
  return html;
}

function serveImage(urlPath, res) {
  const relativePath = decodeURIComponent(urlPath.slice('/images/'.length));

  // Try each image directory in order
  function tryDir(index) {
    if (index >= EXTRA_IMAGE_DIRS.length) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found');
      return;
    }

    const dir = EXTRA_IMAGE_DIRS[index];
    const filePath = path.join(dir, relativePath);
    const resolved = path.resolve(filePath);

    // Security: prevent directory traversal
    const imageRoot = path.resolve(dir);
    if (!resolved.startsWith(imageRoot + path.sep) && resolved !== imageRoot) {
      tryDir(index + 1);
      return;
    }

    fs.stat(resolved, (err, stat) => {
      if (err || !stat.isFile()) {
        tryDir(index + 1);
        return;
      }

      const ext = path.extname(resolved).toLowerCase();
      const contentType = MIME_TYPES[ext] || 'application/octet-stream';

      res.writeHead(200, {
        'Content-Type': contentType,
        'Content-Length': stat.size,
        'Cache-Control': 'public, max-age=3600',
        'Content-Disposition': `inline; filename="${path.basename(resolved)}"`,
      });
      fs.createReadStream(resolved).pipe(res);
    });
  }

  tryDir(0);
}

// ==================== HTTP 反向代理 ====================

function proxyHttpRequest(clientReq, clientRes) {
  const options = {
    hostname: BFF_HOST,
    port: BFF_PORT,
    path: clientReq.url,
    method: clientReq.method,
    headers: { ...clientReq.headers, host: `${BFF_HOST}:${BFF_PORT}` },
  };

  const bffReq = http.request(options, (bffRes) => {
    clientRes.writeHead(bffRes.statusCode, bffRes.headers);
    bffRes.pipe(clientRes, { end: true });
  });

  bffReq.on('error', () => {
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { 'Content-Type': 'text/plain' });
      clientRes.end('Bad Gateway: BFF server unavailable');
    }
  });

  clientReq.pipe(bffReq, { end: true });
}

// ==================== WebSocket 反向代理 ====================

function proxyWebSocket(clientReq, clientSocket, clientHead) {
  const bffSocket = net.connect(BFF_PORT, BFF_HOST, () => {
    // 重新构造原始 HTTP Upgrade 请求发给 BFF
    let rawRequest = `${clientReq.method} ${clientReq.url} HTTP/${clientReq.httpVersion}\r\n`;
    for (let i = 0; i < clientReq.rawHeaders.length; i += 2) {
      rawRequest += `${clientReq.rawHeaders[i]}: ${clientReq.rawHeaders[i + 1]}\r\n`;
    }
    rawRequest += '\r\n';

    bffSocket.write(rawRequest);
    if (clientHead && clientHead.length) {
      bffSocket.write(clientHead);
    }

    // 双向管道: BFF ↔ Client
    bffSocket.pipe(clientSocket);
    clientSocket.pipe(bffSocket);
  });

  const cleanup = () => {
    try { bffSocket.destroy(); } catch (_) {}
    try { clientSocket.destroy(); } catch (_) {}
  };

  bffSocket.on('error', cleanup);
  clientSocket.on('error', cleanup);
  clientSocket.on('close', () => { try { bffSocket.end(); } catch (_) {} });
  bffSocket.on('close', () => { try { clientSocket.end(); } catch (_) {} });
}

// ==================== 主服务器 ====================

const server = http.createServer((clientReq, clientRes) => {
  // 图片文件服务
  if (clientReq.url === '/images' || clientReq.url === '/images/') {
    return serveImageList(clientRes);
  }
  if (clientReq.url.startsWith('/images/')) {
    return serveImage(clientReq.url, clientRes);
  }

  // 其他请求透传给 BFF
  proxyHttpRequest(clientReq, clientRes);
});

// WebSocket 透传
server.on('upgrade', proxyWebSocket);

server.listen(LISTEN_PORT, () => {
  console.log(`🖼️  Image proxy listening on :${LISTEN_PORT}`);
  console.log(`📷 Images:  http://localhost:${LISTEN_PORT}/images/`);
  console.log(`tunnel:  http://${BFF_HOST}:${BFF_PORT}`);
});
