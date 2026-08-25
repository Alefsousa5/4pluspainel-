'use strict';

const metricCards = document.querySelector('#metricCards');
const plansTable = document.querySelector('#plansTable');
const refreshButton = document.querySelector('#refreshButton');
const updatedAt = document.querySelector('#updatedAt');
const signalQuality = document.querySelector('#signalQuality');
const serverUptime = document.querySelector('#serverUptime');
const statusEnvironment = document.querySelector('#statusEnvironment');
const statusNode = document.querySelector('#statusNode');
const statusBranch = document.querySelector('#statusBranch');
const statusHost = document.querySelector('#statusHost');

function formatDateTime(value) {
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'medium'
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

function renderMetrics(cards) {
  metricCards.innerHTML = cards.map((card) => `
    <article class="metric-card" data-tone="${card.tone}">
      <small>${card.label}</small>
      <strong>${card.value}</strong>
      <span>${card.change}</span>
    </article>
  `).join('');
}

function renderPlans(plans) {
  plansTable.innerHTML = plans.map((plan) => `
    <tr>
      <td>${plan.name}</td>
      <td>${plan.speed}</td>
      <td>${plan.customers}</td>
      <td>${plan.status}</td>
    </tr>
  `).join('');
}

async function getJson(url) {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/json'
    }
  });

  if (!response.ok) {
    throw new Error(`Falha ao carregar ${url}: ${response.status}`);
  }

  return response.json();
}

async function loadDashboard() {
  refreshButton.disabled = true;
  refreshButton.textContent = 'Atualizando...';

  try {
    const [metrics, status] = await Promise.all([
      getJson('/api/metrics'),
      getJson('/api/status')
    ]);

    renderMetrics(metrics.cards);
    renderPlans(metrics.plans);

    updatedAt.textContent = `Atualizado ${formatDateTime(metrics.updatedAt)}`;
    signalQuality.textContent = metrics.network.signalQuality;
    serverUptime.textContent = `Uptime: ${formatUptime(status.uptimeSeconds)}`;
    statusEnvironment.textContent = status.environment;
    statusNode.textContent = status.node;
    statusBranch.textContent = status.branch;
    statusHost.textContent = status.hostname;
  } catch (error) {
    console.error(error);
    serverUptime.textContent = 'Falha ao sincronizar';
  } finally {
    refreshButton.disabled = false;
    refreshButton.textContent = 'Atualizar';
  }
}

refreshButton.addEventListener('click', loadDashboard);

for (const button of document.querySelectorAll('.quick-actions button')) {
  button.addEventListener('click', () => {
    button.animate([
      { transform: 'scale(1)' },
      { transform: 'scale(0.98)' },
      { transform: 'scale(1)' }
    ], {
      duration: 180,
      easing: 'ease-out'
    });
  });
}

loadDashboard();
setInterval(loadDashboard, 60000);
