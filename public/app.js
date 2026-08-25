'use strict';

const state = {
  token: localStorage.getItem('4pluspainel-admin-token') || '',
  status: null,
  summary: null,
  users: [],
  servers: [],
  lastCredentials: ''
};

const elements = {
  metricCards: document.querySelector('#metricCards'),
  usersTable: document.querySelector('#usersTable'),
  serversTable: document.querySelector('#serversTable'),
  refreshButton: document.querySelector('#refreshButton'),
  loginButton: document.querySelector('#loginButton'),
  loginModal: document.querySelector('#loginModal'),
  loginForm: document.querySelector('#loginForm'),
  adminTokenInput: document.querySelector('#adminTokenInput'),
  authState: document.querySelector('#authState'),
  serverUptime: document.querySelector('#serverUptime'),
  provisionMode: document.querySelector('#provisionMode'),
  usersCount: document.querySelector('#usersCount'),
  statusEnvironment: document.querySelector('#statusEnvironment'),
  statusNode: document.querySelector('#statusNode'),
  statusBranch: document.querySelector('#statusBranch'),
  statusSshHost: document.querySelector('#statusSshHost'),
  statusDataDir: document.querySelector('#statusDataDir'),
  serverSelect: document.querySelector('#serverSelect'),
  createUserForm: document.querySelector('#createUserForm'),
  usernameInput: document.querySelector('#usernameInput'),
  passwordInput: document.querySelector('#passwordInput'),
  daysInput: document.querySelector('#daysInput'),
  maxConnectionsInput: document.querySelector('#maxConnectionsInput'),
  generatePasswordButton: document.querySelector('#generatePasswordButton'),
  credentialsCard: document.querySelector('#credentialsCard'),
  credentialsTitle: document.querySelector('#credentialsTitle'),
  credentialsOutput: document.querySelector('#credentialsOutput'),
  copyCredentialsButton: document.querySelector('#copyCredentialsButton'),
  createServerForm: document.querySelector('#createServerForm'),
  serverNameInput: document.querySelector('#serverNameInput'),
  serverHostInput: document.querySelector('#serverHostInput'),
  serverPortInput: document.querySelector('#serverPortInput'),
  serverCapacityInput: document.querySelector('#serverCapacityInput'),
  serverKindInput: document.querySelector('#serverKindInput'),
  toast: document.querySelector('#toast')
};

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function formatDateTime(value) {
  if (!value) {
    return '--';
  }

  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short'
  }).format(new Date(value));
}

function formatDate(value) {
  if (!value) {
    return '--';
  }

  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short'
  }).format(new Date(value));
}

function formatUptime(seconds) {
  if (!Number.isFinite(seconds)) {
    return 'Tempo indisponível';
  }

  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);

  if (days > 0) {
    return `${days}d ${hours}h ${minutes}min`;
  }

  if (hours > 0) {
    return `${hours}h ${minutes}min`;
  }

  return `${Math.max(minutes, 1)}min`;
}

function showToast(message, tone = 'success') {
  elements.toast.textContent = message;
  elements.toast.dataset.tone = tone;
  elements.toast.classList.remove('hidden');

  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => {
    elements.toast.classList.add('hidden');
  }, 3600);
}

function showLogin(clearToken = false) {
  if (clearToken) {
    state.token = '';
    localStorage.removeItem('4pluspainel-admin-token');
  }

  elements.authState.textContent = 'Login necessário';
  elements.loginButton.textContent = 'Entrar';
  elements.loginModal.classList.remove('hidden');
  setTimeout(() => elements.adminTokenInput.focus(), 50);
}

function hideLogin() {
  elements.loginModal.classList.add('hidden');
  elements.authState.textContent = 'Administrador logado';
  elements.loginButton.textContent = 'Sair';
}

async function api(path, options = {}) {
  const headers = {
    Accept: 'application/json',
    ...(options.headers || {})
  };

  if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }

  if (options.auth !== false && state.token) {
    headers.Authorization = `Bearer ${state.token}`;
  }

  const response = await fetch(path, {
    ...options,
    headers,
    body: options.body !== undefined ? JSON.stringify(options.body) : undefined
  });

  const contentType = response.headers.get('content-type') || '';
  const payload = contentType.includes('application/json') ? await response.json() : await response.text();

  if (!response.ok) {
    if (response.status === 401) {
      showLogin(true);
    }

    const message = typeof payload === 'object' ? payload.error : payload;
    throw new Error(message || `Erro HTTP ${response.status}`);
  }

  return payload;
}

function renderStatus() {
  const status = state.status;
  if (!status) {
    return;
  }

  elements.serverUptime.textContent = `Uptime: ${formatUptime(status.uptimeSeconds)}`;
  elements.statusEnvironment.textContent = status.environment;
  elements.statusNode.textContent = status.node;
  elements.statusBranch.textContent = status.branch;
  elements.statusSshHost.textContent = `${status.defaultSshHost}:${status.defaultSshPort}`;
  elements.statusDataDir.textContent = status.dataDir;
  elements.provisionMode.textContent = status.systemSshEnabled ? 'Automático' : 'Manual';
}

function renderMetrics() {
  const cards = state.summary?.cards || [];

  if (cards.length === 0) {
    elements.metricCards.innerHTML = `
      <article class="metric-card skeleton"></article>
      <article class="metric-card skeleton"></article>
      <article class="metric-card skeleton"></article>
      <article class="metric-card skeleton"></article>
    `;
    return;
  }

  elements.metricCards.innerHTML = cards.map((card) => `
    <article class="metric-card" data-tone="${escapeHtml(card.tone)}">
      <small>${escapeHtml(card.label)}</small>
      <strong>${escapeHtml(card.value)}</strong>
      <span>${escapeHtml(card.change)}</span>
    </article>
  `).join('');
}

function statusBadge(status) {
  const labels = {
    active: 'Ativo',
    disabled: 'Bloqueado',
    expired: 'Expirado'
  };

  return `<span class="badge ${escapeHtml(status)}">${escapeHtml(labels[status] || status)}</span>`;
}

function serverBadge(server) {
  if (!server.active) {
    return '<span class="badge disabled">Inativo</span>';
  }

  if (server.freeSlots <= 0) {
    return '<span class="badge expired">Lotado</span>';
  }

  return '<span class="badge active">Ativo</span>';
}

function renderUsers() {
  elements.usersCount.textContent = `${state.users.length} usuário(s)`;

  if (state.users.length === 0) {
    elements.usersTable.innerHTML = '<tr><td colspan="6">Nenhum usuário SSH cadastrado ainda.</td></tr>';
    return;
  }

  elements.usersTable.innerHTML = state.users.map((user) => {
    const serverName = user.server
      ? `${escapeHtml(user.server.name)}<small>${escapeHtml(user.server.host)}:${escapeHtml(user.server.sshPort)}</small>`
      : 'Sem servidor';
    const actionButton = user.status === 'disabled'
      ? `<button class="mini-button" data-action="enable" data-id="${escapeHtml(user.id)}">Ativar</button>`
      : `<button class="mini-button" data-action="disable" data-id="${escapeHtml(user.id)}">Bloquear</button>`;

    return `
      <tr>
        <td><strong>${escapeHtml(user.username)}</strong><small>${escapeHtml(user.provisionMode || 'allocation')}</small></td>
        <td>${serverName}</td>
        <td>${formatDate(user.expiresAt)}</td>
        <td>${escapeHtml(user.maxConnections)} simultânea(s)</td>
        <td>${statusBadge(user.status)}</td>
        <td>
          <div class="row-actions">
            ${actionButton}
            <button class="mini-button" data-action="password" data-id="${escapeHtml(user.id)}">Senha</button>
            <button class="mini-button" data-action="extend" data-id="${escapeHtml(user.id)}">+30d</button>
            <button class="mini-button danger" data-action="delete" data-id="${escapeHtml(user.id)}">Excluir</button>
          </div>
        </td>
      </tr>
    `;
  }).join('');
}

function renderServers() {
  if (state.servers.length === 0) {
    elements.serversTable.innerHTML = '<tr><td colspan="7">Nenhum servidor SSH cadastrado.</td></tr>';
    elements.serverSelect.innerHTML = '<option value="auto">Alocar automaticamente</option>';
    return;
  }

  elements.serversTable.innerHTML = state.servers.map((server) => `
    <tr>
      <td><strong>${escapeHtml(server.name)}</strong><small>${escapeHtml(server.notes || '')}</small></td>
      <td>${escapeHtml(server.host)}</td>
      <td>${escapeHtml(server.sshPort)}</td>
      <td>
        <div class="usage-line">
          <span>${escapeHtml(server.activeUsers)} / ${escapeHtml(server.capacity)}</span>
          <meter min="0" max="100" value="${escapeHtml(server.loadPercent)}"></meter>
        </div>
      </td>
      <td>${server.kind === 'local' ? 'Local' : 'Remoto'}</td>
      <td>${serverBadge(server)}</td>
      <td>
        <div class="row-actions">
          <button class="mini-button" data-server-action="toggle" data-id="${escapeHtml(server.id)}" data-active="${escapeHtml(server.active)}">
            ${server.active ? 'Desativar' : 'Ativar'}
          </button>
          ${server.id === 'local' ? '' : `<button class="mini-button danger" data-server-action="delete" data-id="${escapeHtml(server.id)}">Excluir</button>`}
        </div>
      </td>
    </tr>
  `).join('');

  const options = ['<option value="auto">Alocar automaticamente</option>'].concat(
    state.servers
      .filter((server) => server.active && server.freeSlots > 0)
      .map((server) => `<option value="${escapeHtml(server.id)}">${escapeHtml(server.name)} - ${escapeHtml(server.host)}:${escapeHtml(server.sshPort)} (${escapeHtml(server.freeSlots)} vagas)</option>`)
  );

  elements.serverSelect.innerHTML = options.join('');
}

function renderAll() {
  renderStatus();
  renderMetrics();
  renderUsers();
  renderServers();
}

async function loadPublicStatus() {
  state.status = await api('/api/status', { auth: false });
  renderStatus();
}

async function loadProtectedData() {
  if (!state.token) {
    showLogin();
    return;
  }

  elements.refreshButton.disabled = true;
  elements.refreshButton.textContent = 'Atualizando...';

  try {
    const [summary, users, servers] = await Promise.all([
      api('/api/ssh/summary'),
      api('/api/ssh/users'),
      api('/api/ssh/servers')
    ]);

    state.summary = summary;
    state.users = users.users || [];
    state.servers = servers.servers || [];
    hideLogin();
    renderAll();
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    elements.refreshButton.disabled = false;
    elements.refreshButton.textContent = 'Atualizar';
  }
}

function generatedPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789@#%+-_';
  const cryptoObj = window.crypto || window.msCrypto;
  const bytes = new Uint32Array(14);
  cryptoObj.getRandomValues(bytes);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

function showCredentials(credentials, provision) {
  const lines = [
    `Servidor: ${credentials.serverName}`,
    `Host/IP: ${credentials.host}`,
    `Porta: ${credentials.port}`,
    `Usuário: ${credentials.username}`,
    `Senha: ${credentials.password}`,
    `Validade: ${formatDate(credentials.expiresAt)}`,
    `Comando: ${credentials.command}`
  ];

  if (provision?.message) {
    lines.push('', `Observação: ${provision.message}`);
  }

  state.lastCredentials = lines.join('\n');
  elements.credentialsTitle.textContent = `${credentials.username} criado em ${credentials.serverName}`;
  elements.credentialsOutput.textContent = state.lastCredentials;
  elements.credentialsCard.classList.remove('hidden');
}

async function handleCreateUser(event) {
  event.preventDefault();

  try {
    const payload = {
      username: elements.usernameInput.value,
      password: elements.passwordInput.value,
      days: Number(elements.daysInput.value || 30),
      maxConnections: Number(elements.maxConnectionsInput.value || 1),
      serverId: elements.serverSelect.value || 'auto'
    };

    const result = await api('/api/ssh/users', {
      method: 'POST',
      body: payload
    });

    elements.createUserForm.reset();
    elements.daysInput.value = '30';
    elements.maxConnectionsInput.value = '1';
    showCredentials(result.credentials, result.provision);
    showToast('Usuário SSH criado e alocado com sucesso.');
    await loadProtectedData();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function handleCreateServer(event) {
  event.preventDefault();

  try {
    const payload = {
      name: elements.serverNameInput.value,
      host: elements.serverHostInput.value,
      sshPort: Number(elements.serverPortInput.value || 22),
      capacity: Number(elements.serverCapacityInput.value || 100),
      kind: elements.serverKindInput.value
    };

    await api('/api/ssh/servers', {
      method: 'POST',
      body: payload
    });

    elements.createServerForm.reset();
    elements.serverPortInput.value = '22';
    elements.serverCapacityInput.value = '100';
    showToast('Servidor SSH adicionado.');
    await loadProtectedData();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function handleUserAction(action, id) {
  const user = state.users.find((item) => item.id === id);
  if (!user) {
    return;
  }

  try {
    if (action === 'delete') {
      if (!confirm(`Excluir o usuário SSH ${user.username}? Essa ação remove a conta do painel e, no servidor local, remove o usuário Linux.`)) {
        return;
      }

      await api(`/api/ssh/users/${encodeURIComponent(id)}`, {
        method: 'DELETE'
      });
      showToast('Usuário excluído.');
    }

    if (action === 'disable') {
      await api(`/api/ssh/users/${encodeURIComponent(id)}/disable`, {
        method: 'POST',
        body: {}
      });
      showToast('Usuário bloqueado.');
    }

    if (action === 'enable') {
      await api(`/api/ssh/users/${encodeURIComponent(id)}/enable`, {
        method: 'POST',
        body: { days: 30 }
      });
      showToast('Usuário ativado.');
    }

    if (action === 'extend') {
      await api(`/api/ssh/users/${encodeURIComponent(id)}/extend`, {
        method: 'POST',
        body: { days: 30 }
      });
      showToast('Validade renovada por 30 dias.');
    }

    if (action === 'password') {
      const password = prompt(`Nova senha para ${user.username}. Deixe vazio para gerar automaticamente:`) || '';
      const result = await api(`/api/ssh/users/${encodeURIComponent(id)}/password`, {
        method: 'POST',
        body: { password }
      });

      if (result.credentials) {
        showCredentials(result.credentials, result.provision);
      }
      showToast('Senha atualizada.');
    }

    await loadProtectedData();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function handleServerAction(action, id, button) {
  const server = state.servers.find((item) => item.id === id);
  if (!server) {
    return;
  }

  try {
    if (action === 'toggle') {
      await api(`/api/ssh/servers/${encodeURIComponent(id)}`, {
        method: 'PATCH',
        body: { active: !server.active }
      });
      showToast(server.active ? 'Servidor desativado.' : 'Servidor ativado.');
    }

    if (action === 'delete') {
      if (!confirm(`Excluir o servidor ${server.name}?`)) {
        return;
      }

      await api(`/api/ssh/servers/${encodeURIComponent(id)}`, {
        method: 'DELETE'
      });
      showToast('Servidor excluído.');
    }

    if (button) {
      button.disabled = true;
    }

    await loadProtectedData();
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    if (button) {
      button.disabled = false;
    }
  }
}

elements.loginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const token = elements.adminTokenInput.value.trim();

  if (!token) {
    showToast('Informe o token administrativo.', 'error');
    return;
  }

  state.token = token;

  try {
    await api('/api/auth/check', {
      method: 'POST',
      body: {}
    });

    localStorage.setItem('4pluspainel-admin-token', token);
    elements.adminTokenInput.value = '';
    hideLogin();
    showToast('Login realizado.');
    await loadProtectedData();
  } catch (error) {
    state.token = '';
    localStorage.removeItem('4pluspainel-admin-token');
    showToast(error.message, 'error');
  }
});

elements.loginButton.addEventListener('click', () => {
  if (state.token) {
    state.token = '';
    localStorage.removeItem('4pluspainel-admin-token');
    showToast('Sessão encerrada.');
    showLogin();
    return;
  }

  showLogin();
});

elements.refreshButton.addEventListener('click', async () => {
  await loadPublicStatus();
  await loadProtectedData();
});

elements.generatePasswordButton.addEventListener('click', () => {
  elements.passwordInput.value = generatedPassword();
});

elements.createUserForm.addEventListener('submit', handleCreateUser);
elements.createServerForm.addEventListener('submit', handleCreateServer);

elements.usersTable.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-action]');
  if (!button) {
    return;
  }

  handleUserAction(button.dataset.action, button.dataset.id);
});

elements.serversTable.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-server-action]');
  if (!button) {
    return;
  }

  handleServerAction(button.dataset.serverAction, button.dataset.id, button);
});

elements.copyCredentialsButton.addEventListener('click', async () => {
  if (!state.lastCredentials) {
    return;
  }

  await navigator.clipboard.writeText(state.lastCredentials);
  showToast('Credenciais copiadas.');
});

(async function boot() {
  try {
    await loadPublicStatus();

    if (state.token) {
      await loadProtectedData();
    } else {
      showLogin();
    }
  } catch (error) {
    showToast(error.message, 'error');
  }
})();
