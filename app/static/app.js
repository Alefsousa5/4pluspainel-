/* 4Plus Painel — helpers de UI */

function toast(message, type = 'ok') {
  const wrap = document.getElementById('toast-wrap');
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = message;
  wrap.appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; setTimeout(() => el.remove(), 300); }, 3800);
}

/* Escapa texto vindo do banco antes de interpolar em HTML/atributos. */
function esc(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function openModal(html) {
  document.getElementById('modal-box').innerHTML = html;
  document.getElementById('modal-backdrop').classList.add('show');
  const first = document.querySelector('#modal-box input:not([type=hidden])');
  if (first) setTimeout(() => first.focus(), 60);
}

function closeModal() {
  document.getElementById('modal-backdrop').classList.remove('show');
  document.getElementById('modal-box').innerHTML = '';
}

document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeModal(); });

async function apiPost(url, data) {
  const body = new FormData();
  Object.entries(data || {}).forEach(([k, v]) => body.append(k, v));
  const res = await fetch(url, { method: 'POST', body, headers: { Accept: 'application/json' } });
  let json = {};
  try { json = await res.json(); } catch (_) { json = { ok: false, error: 'Resposta inválida do servidor.' }; }
  if (!res.ok || !json.ok) throw new Error(json.error || `Erro ${res.status}`);
  return json;
}

/* Submete um <form> de modal para a API e recarrega a página no sucesso */
function submitModal(form, url, { reload = true, onSuccess = null } = {}) {
  const btn = form.querySelector('button[type=submit]');
  const original = btn ? btn.textContent : '';
  if (btn) { btn.disabled = true; btn.textContent = 'Aguarde...'; }

  const data = Object.fromEntries(new FormData(form).entries());
  apiPost(url, data)
    .then((json) => {
      toast(json.message || 'Operação concluída.', 'ok');
      if (onSuccess) onSuccess(json);
      else if (reload) setTimeout(() => location.reload(), 600);
      else closeModal();
    })
    .catch((err) => {
      toast(err.message, 'err');
      if (btn) { btn.disabled = false; btn.textContent = original; }
    });
  return false;
}

function confirmAction(message, url, data) {
  if (!confirm(message)) return;
  apiPost(url, data || {})
    .then((json) => { toast(json.message || 'Pronto.', 'ok'); setTimeout(() => location.reload(), 600); })
    .catch((err) => toast(err.message, 'err'));
}

function copyText(text, label = 'Copiado!') {
  const done = () => toast(label, 'ok');
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(done).catch(() => fallbackCopy(text, done));
  } else {
    fallbackCopy(text, done);
  }
}

function fallbackCopy(text, done) {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); done(); } catch (_) { toast('Não foi possível copiar.', 'err'); }
  ta.remove();
}

async function suggestPassword(inputId) {
  try {
    const res = await fetch('/api/password', { headers: { Accept: 'application/json' } });
    const json = await res.json();
    const input = document.getElementById(inputId);
    if (json.password && input) { input.value = json.password; input.type = 'text'; }
  } catch (_) { toast('Falha ao gerar senha.', 'err'); }
}

/* Relógio do topo */
function startClock() {
  const el = document.getElementById('clock');
  if (!el) return;
  const tick = () => {
    el.textContent = new Date().toLocaleString('pt-BR', {
      day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
  };
  tick();
  setInterval(tick, 1000);
}
startClock();
