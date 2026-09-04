package main

// weatherUIHTML is the entire frontend: one static page (HTML + CSS + JS),
// no build step, no framework. It only talks back to this server through
// the plain JSON endpoints in http_handlers.go (GET/POST /cities, GET
// /readings/latest) - kept in its own file so the Go logic files above
// don't have hundreds of lines of markup interrupting them.
const weatherUIHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Weather stack</title>
<style>
  :root {
    --bg: #0f1420;
    --panel: #161d2e;
    --panel-2: #1d2740;
    --border: #2a3550;
    --text: #e8ecf5;
    --muted: #8b96b3;
    --accent: #4fc3f7;
    --accent-2: #29b6f6;
    --ok: #4ade80;
    --err: #f87171;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    background: radial-gradient(circle at 20% -10%, #1b2540 0%, var(--bg) 55%);
    color: var(--text);
    font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
    display: flex;
    justify-content: center;
    padding: 4rem 1.25rem;
  }
  .card {
    width: 100%;
    max-width: 460px;
  }
  h1 {
    font-size: 1.5rem;
    font-weight: 600;
    margin: 0 0 .3rem;
    letter-spacing: -.01em;
  }
  .sub {
    color: var(--muted);
    font-size: .9rem;
    margin: 0 0 1.75rem;
  }
  .search-wrap {
    position: relative;
  }
  .search-box {
    display: flex;
    align-items: center;
    gap: .6rem;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: .75rem 1rem;
    transition: border-color .15s;
  }
  .search-box:focus-within {
    border-color: var(--accent);
  }
  .search-box svg { flex-shrink: 0; color: var(--muted); }
  .search-box input {
    flex: 1;
    background: none;
    border: none;
    outline: none;
    color: var(--text);
    font-size: 1rem;
  }
  .search-box input::placeholder { color: var(--muted); }
  .dropdown {
    position: absolute;
    top: calc(100% + 8px);
    left: 0;
    right: 0;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 12px 32px rgba(0,0,0,.4);
    z-index: 5;
    display: none;
  }
  .dropdown.open { display: block; }
  .dropdown-item {
    padding: .7rem 1rem;
    cursor: pointer;
    font-size: .95rem;
    display: flex;
    justify-content: space-between;
    color: var(--text);
  }
  .dropdown-item:hover, .dropdown-item.active {
    background: var(--panel-2);
  }
  .dropdown-item .coords {
    color: var(--muted);
    font-size: .8rem;
  }
  .dropdown-item.add {
    color: var(--accent);
    font-weight: 500;
  }
  .dropdown-item.add .coords {
    color: var(--accent);
    opacity: .7;
  }
  .result {
    margin-top: 1.75rem;
    background: linear-gradient(160deg, var(--panel-2), var(--panel));
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 1.5rem;
    display: none;
  }
  .result.show { display: block; }
  .result .city {
    font-size: 1.1rem;
    font-weight: 600;
  }
  .result .temp {
    font-size: 3rem;
    font-weight: 700;
    line-height: 1.1;
    margin: .4rem 0;
    background: linear-gradient(90deg, var(--accent), var(--accent-2));
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
  }
  .result .meta {
    color: var(--muted);
    font-size: .85rem;
    display: flex;
    gap: 1.25rem;
    margin-top: .5rem;
  }
  .msg {
    margin-top: 1rem;
    font-size: .9rem;
    min-height: 1.2rem;
  }
  .msg.error { color: var(--err); }
  .msg.ok { color: var(--ok); }
  .msg.loading { color: var(--muted); }
</style>
</head>
<body>
  <div class="card">
    <h1>Weather stack</h1>
    <p class="sub">Search a city, or add a new one to start tracking it</p>

    <div class="search-wrap">
      <div class="search-box">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="7"></circle>
          <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
        </svg>
        <input id="q" type="text" placeholder="Search city, e.g. Tehran" autocomplete="off">
      </div>
      <div id="dropdown" class="dropdown"></div>
    </div>

    <div id="msg" class="msg"></div>

    <div id="result" class="result">
      <div class="city" id="r-city"></div>
      <div class="temp" id="r-temp"></div>
      <div class="meta">
        <span id="r-wind"></span>
        <span id="r-time"></span>
      </div>
    </div>
  </div>

<script>
let allCities = [];
let activeIndex = -1;

const q = document.getElementById('q');
const dropdown = document.getElementById('dropdown');
const msg = document.getElementById('msg');
const result = document.getElementById('result');

function setMsg(text, kind) {
  msg.textContent = text || '';
  msg.className = 'msg' + (kind ? ' ' + kind : '');
}

async function loadCities() {
  try {
    const res = await fetch('/cities');
    allCities = (await res.json()) || [];
  } catch (e) {
    setMsg('Could not load city list: ' + e.message, 'error');
  }
}

function renderDropdown(filter) {
  const term = (filter || '').trim();
  const lower = term.toLowerCase();
  const matches = allCities.filter(c => c.Name.toLowerCase().includes(lower));
  activeIndex = -1;

  if (matches.length === 0) {
    if (!term) {
      dropdown.classList.remove('open');
      dropdown.innerHTML = '';
      return;
    }
    // No known city matches - offer to add it.
    dropdown.innerHTML =
      '<div class="dropdown-item add" data-add="' + term + '">' +
        '<span>+ Add "' + term + '"</span>' +
        '<span class="coords">new city</span>' +
      '</div>';
    dropdown.classList.add('open');
    dropdown.querySelector('.dropdown-item').addEventListener('click', () => addCity(term));
    return;
  }

  dropdown.innerHTML = matches.map((c, i) =>
    '<div class="dropdown-item" data-name="' + c.Name + '" data-i="' + i + '">' +
      '<span>' + c.Name + '</span>' +
      '<span class="coords">' + c.Lat.toFixed(2) + ', ' + c.Lon.toFixed(2) + '</span>' +
    '</div>'
  ).join('');
  dropdown.classList.add('open');
  dropdown.querySelectorAll('.dropdown-item').forEach(el => {
    el.addEventListener('click', () => {
      q.value = el.dataset.name;
      dropdown.classList.remove('open');
      lookup(el.dataset.name);
    });
  });
}

async function addCity(name) {
  dropdown.classList.remove('open');
  result.classList.remove('show');
  setMsg('Looking up "' + name + '" and fetching its temperature...', 'loading');
  try {
    const res = await fetch('/cities', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(text || ('status ' + res.status));
    }
    const city = await res.json();
    await loadCities();
    q.value = city.Name;
    await lookup(city.Name);
  } catch (e) {
    setMsg('Could not add city: ' + e.message, 'error');
  }
}

async function lookup(name) {
  const city = (name || q.value).trim();
  if (!city) return;
  result.classList.remove('show');
  setMsg('Looking up ' + city + '...', 'loading');
  try {
    const res = await fetch('/readings/latest?city=' + encodeURIComponent(city));
    if (!res.ok) throw new Error('status ' + res.status);
    const data = await res.json();
    if (!data || data.length === 0) {
      setMsg('No data yet for "' + city + '". Only configured cities have readings.', 'error');
      return;
    }
    const r = data[0];
    document.getElementById('r-city').textContent = r.city;
    document.getElementById('r-temp').textContent = r.temperature_c.toFixed(1) + '°C';
    document.getElementById('r-wind').textContent = 'Wind ' + r.windspeed_kph.toFixed(0) + ' km/h';
    document.getElementById('r-time').textContent = r.observed_at.replace('T', ' ');
    result.classList.add('show');
    setMsg('', '');
  } catch (e) {
    setMsg('Error: ' + e.message, 'error');
  }
}

q.addEventListener('input', () => renderDropdown(q.value));
q.addEventListener('focus', () => renderDropdown(q.value));
q.addEventListener('keydown', (e) => {
  const items = Array.from(dropdown.querySelectorAll('.dropdown-item'));
  if (e.key === 'ArrowDown' && items.length) {
    e.preventDefault();
    activeIndex = Math.min(activeIndex + 1, items.length - 1);
    items.forEach((el, i) => el.classList.toggle('active', i === activeIndex));
  } else if (e.key === 'ArrowUp' && items.length) {
    e.preventDefault();
    activeIndex = Math.max(activeIndex - 1, 0);
    items.forEach((el, i) => el.classList.toggle('active', i === activeIndex));
  } else if (e.key === 'Enter') {
    e.preventDefault();
    const chosen = (activeIndex >= 0 && items[activeIndex]) ? items[activeIndex] : items[0];
    if (chosen && chosen.dataset.add) {
      addCity(chosen.dataset.add);
    } else if (chosen && chosen.dataset.name) {
      q.value = chosen.dataset.name;
      dropdown.classList.remove('open');
      lookup(chosen.dataset.name);
    } else {
      dropdown.classList.remove('open');
      lookup();
    }
  } else if (e.key === 'Escape') {
    dropdown.classList.remove('open');
  }
});
document.addEventListener('click', (e) => {
  if (!e.target.closest('.search-wrap')) dropdown.classList.remove('open');
});

loadCities();
</script>
</body>
</html>`
