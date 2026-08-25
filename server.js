'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const os = require('node:os');

const packageJson = require('./package.json');

const HOST = process.env.HOST || '0.0.0.0';
const PORT = Number.parseInt(process.env.PORT || '3000', 10);
const PUBLIC_DIR = path.join(__dirname, 'public');

const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8'
};

function baseHeaders(extra = {}) {
  return {
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Cache-Control': 'no-store',
    ...extra
  };
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, baseHeaders({ 'Content-Type': 'application/json; charset=utf-8' }));
  response.end(JSON.stringify(payload, null, 2));
}

function sendText(response, statusCode, message) {
  response.writeHead(statusCode, baseHeaders({ 'Content-Type': 'text/plain; charset=utf-8' }));
  response.end(message);
}

function getClientIp(request) {
  const forwardedFor = request.headers['x-forwarded-for'];

  if (typeof forwardedFor === 'string' && forwardedFor.length > 0) {
    return forwardedFor.split(',')[0].trim();
  }

  return request.socket.remoteAddress || 'desconhecido';
}

function safeStaticPath(urlPathname) {
  let pathname = urlPathname;

  try {
    pathname = decodeURIComponent(pathname);
  } catch (_) {
    return null;
  }

  if (pathname === '/') {
    pathname = '/index.html';
  }

  const normalizedPath = path.normalize(pathname).replace(/^([/\\])+/, '');
  const filePath = path.join(PUBLIC_DIR, normalizedPath);

  if (!filePath.startsWith(PUBLIC_DIR)) {
    return null;
  }

  return filePath;
}

function metricsPayload() {
  return {
    updatedAt: new Date().toISOString(),
    cards: [
      {
        label: 'Clientes online',
        value: 128,
        change: '+12%',
        tone: 'success'
      },
      {
        label: 'Tráfego hoje',
        value: '1.8 TB',
        change: '+8%',
        tone: 'info'
      },
      {
        label: 'Planos ativos',
        value: 420,
        change: '+21',
        tone: 'success'
      },
      {
        label: 'Chamados abertos',
        value: 7,
        change: '-3',
        tone: 'warning'
      }
    ],
    network: {
      availability: '99.98%',
      latencyMs: 24,
      signalQuality: 'Excelente',
      towerStatus: 'Operacional'
    },
    plans: [
      {
        name: '4G Plus Start',
        speed: '20 Mbps',
        customers: 96,
        status: 'Ativo'
      },
      {
        name: '4G Plus Família',
        speed: '50 Mbps',
        customers: 184,
        status: 'Ativo'
      },
      {
        name: '4G Plus Pro',
        speed: '100 Mbps',
        customers: 140,
        status: 'Ativo'
      }
    ]
  };
}

async function serveStatic(request, response, pathname) {
  let filePath = safeStaticPath(pathname);

  if (!filePath) {
    sendText(response, 400, 'Caminho inválido.');
    return;
  }

  try {
    let stats = await fsp.stat(filePath);

    if (stats.isDirectory()) {
      filePath = path.join(filePath, 'index.html');
      stats = await fsp.stat(filePath);
    }

    if (!stats.isFile()) {
      sendText(response, 404, 'Arquivo não encontrado.');
      return;
    }

    const extension = path.extname(filePath).toLowerCase();
    const contentType = contentTypes[extension] || 'application/octet-stream';
    const shouldCache = ['.css', '.js', '.svg', '.png', '.jpg', '.jpeg', '.ico'].includes(extension);

    response.writeHead(200, baseHeaders({
      'Content-Type': contentType,
      'Content-Length': stats.size,
      'Cache-Control': shouldCache ? 'public, max-age=3600' : 'no-store'
    }));

    fs.createReadStream(filePath).pipe(response);
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      const indexPath = path.join(PUBLIC_DIR, 'index.html');
      const stats = await fsp.stat(indexPath);

      response.writeHead(200, baseHeaders({
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': stats.size,
        'Cache-Control': 'no-store'
      }));
      fs.createReadStream(indexPath).pipe(response);
      return;
    }

    console.error('[4pluspainel] erro ao servir arquivo:', error);
    sendText(response, 500, 'Erro interno ao carregar o painel.');
  }
}

const server = http.createServer(async (request, response) => {
  const startedAt = Date.now();

  try {
    const url = new URL(request.url || '/', `http://${request.headers.host || 'localhost'}`);

    if (request.method === 'GET' && url.pathname === '/health') {
      sendJson(response, 200, {
        status: 'ok',
        app: '4G Plus Painel',
        timestamp: new Date().toISOString()
      });
      return;
    }

    if (request.method === 'GET' && url.pathname === '/api/status') {
      sendJson(response, 200, {
        app: '4G Plus Painel',
        version: packageJson.version,
        environment: process.env.NODE_ENV || 'development',
        uptimeSeconds: Math.round(process.uptime()),
        hostname: os.hostname(),
        platform: `${os.type()} ${os.release()}`,
        node: process.version,
        port: PORT,
        repository: process.env.GIT_REPO || 'https://github.com/Alefsousa5/4pluspainel-.git',
        branch: process.env.GIT_BRANCH || 'arena/01a039e9-4pluspainel',
        requestIp: getClientIp(request),
        timestamp: new Date().toISOString()
      });
      return;
    }

    if (request.method === 'GET' && url.pathname === '/api/metrics') {
      sendJson(response, 200, metricsPayload());
      return;
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      sendJson(response, 405, {
        error: 'Método não permitido',
        allowed: ['GET', 'HEAD']
      });
      return;
    }

    await serveStatic(request, response, url.pathname);
  } catch (error) {
    console.error('[4pluspainel] erro na requisição:', error);
    sendJson(response, 500, {
      error: 'Erro interno do servidor'
    });
  } finally {
    const durationMs = Date.now() - startedAt;
    console.log(`${request.method} ${request.url} ${response.statusCode} ${durationMs}ms`);
  }
});

server.on('error', (error) => {
  console.error('[4pluspainel] falha ao iniciar servidor:', error);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`[4pluspainel] servidor online em http://${HOST}:${PORT}`);
});
