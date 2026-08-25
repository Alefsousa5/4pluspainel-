'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');

const packageJson = require('./package.json');

const HOST = process.env.HOST || '0.0.0.0';
const PORT = Number.parseInt(process.env.PORT || '3000', 10);
const PUBLIC_DIR = path.join(__dirname, 'public');
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DB_FILE = process.env.DB_FILE || path.join(DATA_DIR, 'db.json');
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || process.env.ADMIN_PASSWORD || (process.env.NODE_ENV === 'production' ? '' : 'admin');
const ENABLE_SYSTEM_SSH = parseBoolean(process.env.ENABLE_SYSTEM_SSH, false);
const STORE_USER_PASSWORDS = parseBoolean(process.env.STORE_USER_PASSWORDS, false);
const SSH_HELPER = process.env.SSH_HELPER || '/usr/local/sbin/4pluspainel-ssh-helper';
const DEFAULT_SSH_HOST = process.env.DEFAULT_SSH_HOST || process.env.SSH_HOST || process.env.DOMAIN || 'SEU_IP_DA_VPS';
const DEFAULT_SSH_PORT = Number.parseInt(process.env.DEFAULT_SSH_PORT || process.env.SSH_PORT || '22', 10);
const DEFAULT_SERVER_CAPACITY = Number.parseInt(process.env.DEFAULT_SERVER_CAPACITY || '200', 10);

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

const reservedUsernames = new Set([
  'root', 'admin', 'administrator', 'ubuntu', 'debian', 'centos', 'fedora', 'ec2-user',
  'www-data', 'nginx', 'apache', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp',
  'mail', 'news', 'uucp', 'proxy', 'backup', 'list', 'irc', 'gnats', 'nobody', 'systemd',
  'systemd-network', 'systemd-resolve', 'sshd', 'messagebus', 'polkitd'
]);

function parseBoolean(value, defaultValue = false) {
  if (value === undefined || value === null || value === '') {
    return defaultValue;
  }

  return ['1', 'true', 'yes', 'sim', 'on'].includes(String(value).toLowerCase());
}

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

function randomId(prefix) {
  return `${prefix}_${crypto.randomBytes(8).toString('hex')}`;
}

function randomPassword(length = 14) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789@#%+-_';
  let output = '';

  for (let index = 0; index < length; index += 1) {
    output += alphabet[crypto.randomInt(0, alphabet.length)];
  }

  return output;
}

function nowIso() {
  return new Date().toISOString();
}

function addDays(days) {
  return new Date(Date.now() + days * 24 * 60 * 60 * 1000).toISOString();
}

function dateOnly(value) {
  return new Date(value).toISOString().slice(0, 10);
}

function normalizeUsername(value) {
  return String(value || '').trim().toLowerCase();
}

function assertValidUsername(username) {
  if (!/^[a-z_][a-z0-9_-]{2,31}$/.test(username)) {
    throw httpError(400, 'Usuário inválido. Use 3 a 32 caracteres: letras minúsculas, números, _ ou -, começando com letra ou _.');
  }

  if (reservedUsernames.has(username)) {
    throw httpError(400, `O usuário "${username}" é reservado pelo sistema.`);
  }
}

function assertValidPassword(password) {
  if (typeof password !== 'string' || password.length < 6 || password.length > 128) {
    throw httpError(400, 'A senha precisa ter entre 6 e 128 caracteres.');
  }

  if (/[\n\r:]/.test(password)) {
    throw httpError(400, 'A senha não pode conter quebra de linha ou dois pontos.');
  }
}

function assertValidPort(port, label = 'Porta') {
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw httpError(400, `${label} inválida.`);
  }
}

function httpError(statusCode, message, details) {
  const error = new Error(message);
  error.statusCode = statusCode;
  error.details = details;
  return error;
}

function ensureDataStore() {
  fs.mkdirSync(DATA_DIR, { recursive: true });

  if (!fs.existsSync(DB_FILE)) {
    writeDb({
      version: 1,
      servers: [createDefaultLocalServer()],
      users: [],
      audit: []
    });
    return;
  }

  const db = readDb();
  let changed = false;

  if (!Array.isArray(db.servers)) {
    db.servers = [];
    changed = true;
  }

  if (!Array.isArray(db.users)) {
    db.users = [];
    changed = true;
  }

  if (!Array.isArray(db.audit)) {
    db.audit = [];
    changed = true;
  }

  if (db.servers.length === 0) {
    db.servers.push(createDefaultLocalServer());
    changed = true;
  }

  if (changed) {
    writeDb(db);
  }
}

function createDefaultLocalServer() {
  return {
    id: 'local',
    name: 'Servidor SSH local',
    host: DEFAULT_SSH_HOST,
    sshPort: Number.isInteger(DEFAULT_SSH_PORT) ? DEFAULT_SSH_PORT : 22,
    capacity: Number.isInteger(DEFAULT_SERVER_CAPACITY) ? DEFAULT_SERVER_CAPACITY : 200,
    active: true,
    kind: 'local',
    notes: 'Servidor principal da VPS onde o painel está instalado.',
    createdAt: nowIso(),
    updatedAt: nowIso()
  };
}

function readDb() {
  try {
    const raw = fs.readFileSync(DB_FILE, 'utf8');
    return JSON.parse(raw);
  } catch (error) {
    if (error.code === 'ENOENT') {
      ensureDataStore();
      return readDb();
    }

    throw error;
  }
}

function writeDb(db) {
  const tempFile = `${DB_FILE}.${process.pid}.tmp`;
  fs.mkdirSync(path.dirname(DB_FILE), { recursive: true });
  fs.writeFileSync(tempFile, `${JSON.stringify(db, null, 2)}\n`, { mode: 0o640 });
  fs.renameSync(tempFile, DB_FILE);
}

function audit(db, action, request, details = {}) {
  db.audit.unshift({
    id: randomId('log'),
    action,
    ip: getClientIp(request),
    userAgent: request.headers['user-agent'] || '',
    details,
    createdAt: nowIso()
  });

  db.audit = db.audit.slice(0, 200);
}

function activeStatus(user) {
  if (user.status === 'disabled') {
    return 'disabled';
  }

  if (user.expiresAt && new Date(user.expiresAt).getTime() < Date.now()) {
    return 'expired';
  }

  return 'active';
}

function userIsActive(user) {
  return activeStatus(user) === 'active';
}

function serverStats(server, db) {
  const assigned = db.users.filter((user) => user.serverId === server.id && activeStatus(user) !== 'disabled').length;
  const active = db.users.filter((user) => user.serverId === server.id && userIsActive(user)).length;
  const capacity = Number(server.capacity) || 0;

  return {
    assigned,
    activeUsers: active,
    freeSlots: Math.max(capacity - active, 0),
    loadPercent: capacity > 0 ? Math.round((active / capacity) * 100) : 0
  };
}

function serializeServer(server, db) {
  return {
    ...server,
    ...serverStats(server, db)
  };
}

function serializeUser(user, db, includePassword = false) {
  const server = db.servers.find((item) => item.id === user.serverId);
  const output = {
    ...user,
    status: activeStatus(user),
    server: server ? {
      id: server.id,
      name: server.name,
      host: server.host,
      sshPort: server.sshPort,
      kind: server.kind
    } : null
  };

  if (!includePassword) {
    delete output.password;
  }

  return output;
}

function summaryPayload(db) {
  const activeUsers = db.users.filter(userIsActive).length;
  const disabledUsers = db.users.filter((user) => activeStatus(user) === 'disabled').length;
  const expiredUsers = db.users.filter((user) => activeStatus(user) === 'expired').length;
  const activeServers = db.servers.filter((server) => server.active).length;
  const totalCapacity = db.servers.filter((server) => server.active).reduce((sum, server) => sum + (Number(server.capacity) || 0), 0);

  return {
    updatedAt: nowIso(),
    cards: [
      {
        label: 'Usuários SSH ativos',
        value: activeUsers,
        change: `${db.users.length} cadastrados`,
        tone: 'success'
      },
      {
        label: 'Servidores ativos',
        value: activeServers,
        change: `${totalCapacity} vagas`,
        tone: 'info'
      },
      {
        label: 'Usuários expirados',
        value: expiredUsers,
        change: `${disabledUsers} bloqueados`,
        tone: expiredUsers > 0 ? 'warning' : 'success'
      },
      {
        label: 'Provisionamento local',
        value: ENABLE_SYSTEM_SSH ? 'Ativo' : 'Manual',
        change: ENABLE_SYSTEM_SSH ? 'Linux useradd' : 'Somente alocação',
        tone: ENABLE_SYSTEM_SSH ? 'success' : 'warning'
      }
    ],
    totalUsers: db.users.length,
    activeUsers,
    disabledUsers,
    expiredUsers,
    activeServers,
    totalServers: db.servers.length,
    totalCapacity,
    systemSshEnabled: ENABLE_SYSTEM_SSH,
    storeUserPasswords: STORE_USER_PASSWORDS
  };
}

function getAuthToken(request) {
  const authorization = request.headers.authorization || '';
  const match = authorization.match(/^Bearer\s+(.+)$/i);

  if (match) {
    return match[1].trim();
  }

  return '';
}

function timingSafeEqualString(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));

  if (left.length !== right.length) {
    return false;
  }

  return crypto.timingSafeEqual(left, right);
}

function requireAuth(request) {
  if (!ADMIN_TOKEN) {
    throw httpError(503, 'ADMIN_TOKEN não está configurado no servidor. Rode o instalador ou configure o arquivo .env.');
  }

  const token = getAuthToken(request);

  if (!token || !timingSafeEqualString(token, ADMIN_TOKEN)) {
    throw httpError(401, 'Token administrativo inválido ou ausente.');
  }
}

async function readJsonBody(request) {
  const chunks = [];
  let total = 0;

  for await (const chunk of request) {
    total += chunk.length;

    if (total > 1024 * 1024) {
      throw httpError(413, 'Corpo da requisição muito grande.');
    }

    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    return {};
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (_) {
    throw httpError(400, 'JSON inválido.');
  }
}

function runHelper(args) {
  return new Promise((resolve, reject) => {
    execFile('sudo', ['-n', SSH_HELPER, ...args], {
      timeout: 20000,
      maxBuffer: 1024 * 1024
    }, (error, stdout, stderr) => {
      if (error) {
        const message = (stderr || stdout || error.message || '').trim();
        reject(httpError(500, `Falha no helper SSH: ${message || 'erro desconhecido'}`));
        return;
      }

      const raw = stdout.trim();

      if (!raw) {
        resolve({ ok: true });
        return;
      }

      try {
        resolve(JSON.parse(raw));
      } catch (_) {
        resolve({ ok: true, output: raw });
      }
    });
  });
}

async function provisionUser(server, action, payload) {
  if (!server || server.kind !== 'local') {
    return {
      mode: 'allocation_only',
      ok: true,
      message: 'Servidor remoto: usuário alocado no painel. Provisione no servidor remoto ou instale o painel/agente nele.'
    };
  }

  if (!ENABLE_SYSTEM_SSH) {
    return {
      mode: 'allocation_only',
      ok: true,
      message: 'Provisionamento local desativado. O usuário foi salvo apenas no painel.'
    };
  }

  if (action === 'create') {
    return runHelper(['create', payload.username, payload.password, dateOnly(payload.expiresAt), String(payload.maxConnections)]);
  }

  if (action === 'delete') {
    return runHelper(['delete', payload.username]);
  }

  if (action === 'disable') {
    return runHelper(['disable', payload.username]);
  }

  if (action === 'enable') {
    return runHelper(['enable', payload.username, dateOnly(payload.expiresAt)]);
  }

  if (action === 'password') {
    return runHelper(['password', payload.username, payload.password]);
  }

  if (action === 'extend') {
    return runHelper(['extend', payload.username, dateOnly(payload.expiresAt)]);
  }

  return { mode: 'none', ok: true };
}

function pickServerForUser(db, requestedServerId) {
  if (requestedServerId && requestedServerId !== 'auto') {
    const server = db.servers.find((item) => item.id === requestedServerId);

    if (!server) {
      throw httpError(404, 'Servidor SSH não encontrado.');
    }

    if (!server.active) {
      throw httpError(409, 'Servidor SSH selecionado está inativo.');
    }

    const stats = serverStats(server, db);
    if (stats.activeUsers >= Number(server.capacity || 0)) {
      throw httpError(409, 'Servidor SSH selecionado está sem vagas livres.');
    }

    return server;
  }

  const availableServers = db.servers
    .filter((server) => server.active)
    .map((server) => ({ server, stats: serverStats(server, db) }))
    .filter((entry) => entry.stats.activeUsers < Number(entry.server.capacity || 0))
    .sort((a, b) => {
      const aLoad = a.server.capacity > 0 ? a.stats.activeUsers / a.server.capacity : 1;
      const bLoad = b.server.capacity > 0 ? b.stats.activeUsers / b.server.capacity : 1;
      return aLoad - bLoad;
    });

  if (availableServers.length === 0) {
    throw httpError(409, 'Nenhum servidor SSH ativo com vagas livres para alocar o usuário.');
  }

  return availableServers[0].server;
}

function parseDays(value, defaultValue = 30) {
  const days = Number.parseInt(value || defaultValue, 10);

  if (!Number.isInteger(days) || days < 1 || days > 3650) {
    throw httpError(400, 'Validade inválida. Use entre 1 e 3650 dias.');
  }

  return days;
}

function parseMaxConnections(value, defaultValue = 1) {
  const maxConnections = Number.parseInt(value || defaultValue, 10);

  if (!Number.isInteger(maxConnections) || maxConnections < 1 || maxConnections > 999) {
    throw httpError(400, 'Limite de conexões inválido. Use entre 1 e 999.');
  }

  return maxConnections;
}

function serverConnectionPayload(server, user, password) {
  return {
    serverId: server.id,
    serverName: server.name,
    host: server.host,
    port: server.sshPort,
    username: user.username,
    password,
    expiresAt: user.expiresAt,
    command: `ssh ${user.username}@${server.host} -p ${server.sshPort}`
  };
}

async function handleAuthRoutes(request, response, pathname) {
  if (request.method === 'POST' && pathname === '/api/auth/check') {
    requireAuth(request);
    sendJson(response, 200, {
      ok: true,
      app: '4G Plus SSH Painel',
      timestamp: nowIso()
    });
    return true;
  }

  return false;
}

async function handleSshRoutes(request, response, pathname) {
  if (!pathname.startsWith('/api/ssh/')) {
    return false;
  }

  requireAuth(request);
  ensureDataStore();

  if (request.method === 'GET' && pathname === '/api/ssh/summary') {
    const db = readDb();
    sendJson(response, 200, summaryPayload(db));
    return true;
  }

  if (request.method === 'GET' && pathname === '/api/ssh/users') {
    const db = readDb();
    sendJson(response, 200, {
      users: db.users.map((user) => serializeUser(user, db)),
      total: db.users.length
    });
    return true;
  }

  if (request.method === 'POST' && pathname === '/api/ssh/users') {
    const body = await readJsonBody(request);
    const db = readDb();
    const username = normalizeUsername(body.username);
    const password = typeof body.password === 'string' && body.password.length > 0 ? body.password : randomPassword();
    const days = parseDays(body.days, 30);
    const maxConnections = parseMaxConnections(body.maxConnections, 1);
    const expiresAt = addDays(days);

    assertValidUsername(username);
    assertValidPassword(password);

    if (db.users.some((user) => user.username === username && activeStatus(user) !== 'expired')) {
      throw httpError(409, 'Já existe um usuário SSH ativo ou bloqueado com esse nome.');
    }

    const server = pickServerForUser(db, body.serverId || 'auto');
    const provision = await provisionUser(server, 'create', {
      username,
      password,
      expiresAt,
      maxConnections
    });

    const user = {
      id: randomId('usr'),
      username,
      password: STORE_USER_PASSWORDS ? password : undefined,
      serverId: server.id,
      status: 'active',
      expiresAt,
      maxConnections,
      systemManaged: server.kind === 'local' && ENABLE_SYSTEM_SSH,
      provisionMode: provision.mode || (server.kind === 'local' && ENABLE_SYSTEM_SSH ? 'system' : 'allocation_only'),
      lastProvisionResult: provision.message || provision.output || 'ok',
      createdAt: nowIso(),
      updatedAt: nowIso()
    };

    db.users.push(user);
    audit(db, 'create_user', request, { username, serverId: server.id });
    writeDb(db);

    sendJson(response, 201, {
      user: serializeUser(user, db, STORE_USER_PASSWORDS),
      credentials: serverConnectionPayload(server, user, password),
      provision
    });
    return true;
  }

  const userActionMatch = pathname.match(/^\/api\/ssh\/users\/([^/]+)\/(disable|enable|password|extend)$/);
  if (userActionMatch && request.method === 'POST') {
    const [, userId, action] = userActionMatch;
    const body = await readJsonBody(request);
    const db = readDb();
    const user = db.users.find((item) => item.id === userId);

    if (!user) {
      throw httpError(404, 'Usuário SSH não encontrado.');
    }

    const server = db.servers.find((item) => item.id === user.serverId);
    let credentials = null;
    let provision;

    if (action === 'disable') {
      provision = await provisionUser(server, 'disable', user);
      user.status = 'disabled';
    }

    if (action === 'enable') {
      if (new Date(user.expiresAt).getTime() < Date.now()) {
        const days = parseDays(body.days, 30);
        user.expiresAt = addDays(days);
      }
      provision = await provisionUser(server, 'enable', user);
      user.status = 'active';
    }

    if (action === 'password') {
      const password = typeof body.password === 'string' && body.password.length > 0 ? body.password : randomPassword();
      assertValidPassword(password);
      provision = await provisionUser(server, 'password', { username: user.username, password });
      if (STORE_USER_PASSWORDS) {
        user.password = password;
      }
      user.lastPasswordChangeAt = nowIso();
      credentials = server ? serverConnectionPayload(server, user, password) : null;
    }

    if (action === 'extend') {
      const days = parseDays(body.days, 30);
      user.expiresAt = addDays(days);
      provision = await provisionUser(server, 'extend', user);
      if (user.status !== 'disabled') {
        user.status = 'active';
      }
    }

    user.lastProvisionResult = provision?.message || provision?.output || 'ok';
    user.updatedAt = nowIso();
    audit(db, `${action}_user`, request, { username: user.username, serverId: user.serverId });
    writeDb(db);

    sendJson(response, 200, {
      user: serializeUser(user, db, STORE_USER_PASSWORDS),
      credentials,
      provision
    });
    return true;
  }

  const deleteUserMatch = pathname.match(/^\/api\/ssh\/users\/([^/]+)$/);
  if (deleteUserMatch && request.method === 'DELETE') {
    const [, userId] = deleteUserMatch;
    const db = readDb();
    const index = db.users.findIndex((item) => item.id === userId);

    if (index === -1) {
      throw httpError(404, 'Usuário SSH não encontrado.');
    }

    const [user] = db.users.splice(index, 1);
    const server = db.servers.find((item) => item.id === user.serverId);
    const provision = await provisionUser(server, 'delete', user);

    audit(db, 'delete_user', request, { username: user.username, serverId: user.serverId });
    writeDb(db);

    sendJson(response, 200, {
      ok: true,
      deleted: serializeUser(user, db),
      provision
    });
    return true;
  }

  if (request.method === 'GET' && pathname === '/api/ssh/servers') {
    const db = readDb();
    sendJson(response, 200, {
      servers: db.servers.map((server) => serializeServer(server, db)),
      total: db.servers.length
    });
    return true;
  }

  if (request.method === 'POST' && pathname === '/api/ssh/servers') {
    const body = await readJsonBody(request);
    const db = readDb();
    const name = String(body.name || '').trim();
    const host = String(body.host || '').trim();
    const sshPort = Number.parseInt(body.sshPort || 22, 10);
    const capacity = Number.parseInt(body.capacity || 100, 10);
    const kind = body.kind === 'local' ? 'local' : 'remote';

    if (name.length < 2 || name.length > 80) {
      throw httpError(400, 'Nome do servidor inválido.');
    }

    if (!/^[a-zA-Z0-9._:-]+$/.test(host) || host.length < 2 || host.length > 120) {
      throw httpError(400, 'Host/IP do servidor inválido.');
    }

    assertValidPort(sshPort, 'Porta SSH');

    if (!Number.isInteger(capacity) || capacity < 1 || capacity > 100000) {
      throw httpError(400, 'Capacidade inválida.');
    }

    if (db.servers.some((server) => server.host === host && Number(server.sshPort) === sshPort)) {
      throw httpError(409, 'Já existe um servidor cadastrado com esse host e porta.');
    }

    const server = {
      id: randomId('srv'),
      name,
      host,
      sshPort,
      capacity,
      active: body.active !== false,
      kind,
      notes: String(body.notes || '').trim().slice(0, 300),
      createdAt: nowIso(),
      updatedAt: nowIso()
    };

    db.servers.push(server);
    audit(db, 'create_server', request, { serverId: server.id, host });
    writeDb(db);

    sendJson(response, 201, {
      server: serializeServer(server, db)
    });
    return true;
  }

  const serverMatch = pathname.match(/^\/api\/ssh\/servers\/([^/]+)$/);
  if (serverMatch && request.method === 'PATCH') {
    const [, serverId] = serverMatch;
    const body = await readJsonBody(request);
    const db = readDb();
    const server = db.servers.find((item) => item.id === serverId);

    if (!server) {
      throw httpError(404, 'Servidor SSH não encontrado.');
    }

    if (body.name !== undefined) {
      const name = String(body.name || '').trim();
      if (name.length < 2 || name.length > 80) {
        throw httpError(400, 'Nome do servidor inválido.');
      }
      server.name = name;
    }

    if (body.host !== undefined) {
      const host = String(body.host || '').trim();
      if (!/^[a-zA-Z0-9._:-]+$/.test(host) || host.length < 2 || host.length > 120) {
        throw httpError(400, 'Host/IP do servidor inválido.');
      }
      server.host = host;
    }

    if (body.sshPort !== undefined) {
      const sshPort = Number.parseInt(body.sshPort, 10);
      assertValidPort(sshPort, 'Porta SSH');
      server.sshPort = sshPort;
    }

    if (body.capacity !== undefined) {
      const capacity = Number.parseInt(body.capacity, 10);
      if (!Number.isInteger(capacity) || capacity < 1 || capacity > 100000) {
        throw httpError(400, 'Capacidade inválida.');
      }
      server.capacity = capacity;
    }

    if (body.active !== undefined) {
      server.active = Boolean(body.active);
    }

    if (body.kind !== undefined) {
      server.kind = body.kind === 'local' ? 'local' : 'remote';
    }

    if (body.notes !== undefined) {
      server.notes = String(body.notes || '').trim().slice(0, 300);
    }

    server.updatedAt = nowIso();
    audit(db, 'update_server', request, { serverId: server.id, host: server.host });
    writeDb(db);

    sendJson(response, 200, {
      server: serializeServer(server, db)
    });
    return true;
  }

  if (serverMatch && request.method === 'DELETE') {
    const [, serverId] = serverMatch;
    const db = readDb();

    if (serverId === 'local') {
      throw httpError(400, 'O servidor local padrão não pode ser removido. Você pode desativá-lo.');
    }

    if (db.users.some((user) => user.serverId === serverId)) {
      throw httpError(409, 'Não é possível remover servidor com usuários alocados. Exclua ou mova os usuários primeiro.');
    }

    const index = db.servers.findIndex((item) => item.id === serverId);
    if (index === -1) {
      throw httpError(404, 'Servidor SSH não encontrado.');
    }

    const [server] = db.servers.splice(index, 1);
    audit(db, 'delete_server', request, { serverId: server.id, host: server.host });
    writeDb(db);

    sendJson(response, 200, {
      ok: true,
      deleted: server
    });
    return true;
  }

  return false;
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

    if (request.method === 'HEAD') {
      response.end();
      return;
    }

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

      if (request.method === 'HEAD') {
        response.end();
        return;
      }

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
        app: '4G Plus SSH Painel',
        timestamp: nowIso()
      });
      return;
    }

    if (request.method === 'GET' && url.pathname === '/api/status') {
      sendJson(response, 200, {
        app: '4G Plus SSH Painel',
        version: packageJson.version,
        environment: process.env.NODE_ENV || 'development',
        uptimeSeconds: Math.round(process.uptime()),
        hostname: os.hostname(),
        platform: `${os.type()} ${os.release()}`,
        node: process.version,
        port: PORT,
        repository: process.env.GIT_REPO || 'https://github.com/Alefsousa5/4pluspainel-.git',
        branch: process.env.GIT_BRANCH || 'arena/01a039e9-4pluspainel',
        authConfigured: Boolean(ADMIN_TOKEN),
        systemSshEnabled: ENABLE_SYSTEM_SSH,
        dataDir: DATA_DIR,
        defaultSshHost: DEFAULT_SSH_HOST,
        defaultSshPort: DEFAULT_SSH_PORT,
        requestIp: getClientIp(request),
        timestamp: nowIso()
      });
      return;
    }

    if (await handleAuthRoutes(request, response, url.pathname)) {
      return;
    }

    if (await handleSshRoutes(request, response, url.pathname)) {
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
    const statusCode = error.statusCode || 500;

    if (statusCode >= 500) {
      console.error('[4pluspainel] erro na requisição:', error);
    }

    sendJson(response, statusCode, {
      error: error.message || 'Erro interno do servidor',
      details: error.details
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

ensureDataStore();

if (process.env.NODE_ENV === 'production' && !ADMIN_TOKEN) {
  console.warn('[4pluspainel] AVISO: ADMIN_TOKEN não configurado. APIs administrativas ficarão bloqueadas.');
}

server.listen(PORT, HOST, () => {
  console.log(`[4pluspainel] SSH painel online em http://${HOST}:${PORT}`);
  console.log(`[4pluspainel] dados em ${DB_FILE}`);
  console.log(`[4pluspainel] provisionamento local SSH: ${ENABLE_SYSTEM_SSH ? 'ativo' : 'manual/desativado'}`);
});
