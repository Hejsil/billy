// The server renders every block of a conversation; the page only puts them in.
const list = document.getElementById('list');
const headerBox = document.getElementById('header');
const conversation = document.getElementById('conversation');
const form = document.getElementById('prompt');
const input = document.getElementById('text');
const menuButton = document.getElementById('menu');
const backdrop = document.getElementById('backdrop');
const latestButton = document.getElementById('latest');
let selected = null;
let working = false;
// Whether the end of the conversation follows what comes in: true while the user
// is at the bottom, false once they scroll away.
let stick = true;
// The `<details>` opened by `tool_begin`, which `tool_end` replaces.
let openCall = null;
// Where the running turn's tool calls go; open until another block closes it.
let fold = null;

// Asks the server and returns the response, or null after showing why it failed.
// A status in `tolerate` counts as success.
async function ask(what, url, options, tolerate) {
  try {
    const res = await fetch(url, options);
    if (res.ok || res.status === tolerate) return res;
    note('could not ' + what + ' (' + res.status + ')');
  } catch (err) {
    note('lost the connection: ' + err.message);
  }
  return null;
}

const sessionUrl = (id) => '/api/sessions/' + encodeURIComponent(id);

// Lists the sessions again. Returns them, or null if they could not be read.
async function refresh(select) {
  let sessions;
  try {
    const res = await fetch('/api/sessions');
    if (!res.ok) throw new Error('the server answered ' + res.status);
    sessions = (await res.json()).sessions;
  } catch (err) {
    // The list is left as it was so a hiccup does not empty the screen.
    console.error('could not list the sessions:', err);
    return null;
  }
  list.replaceChildren();
  if (sessions.length === 0) {
    const empty = document.createElement('li');
    empty.className = 'empty';
    empty.textContent = 'no sessions';
    list.append(empty);
    return sessions;
  }
  for (const session of sessions) {
    const item = document.createElement('li');
    item.dataset.id = session.id;
    const name = document.createElement('div');
    name.className = 'name';
    item.append(name);
    setListedName(item, session.title);
    item.append(action('ren', '\u270e', 'rename this session', () => rename(session.id, session.title)));
    item.append(action('del', '\u2715', 'delete this session', () => remove(session.id)));
    if (session.id === select) item.classList.add('selected');
    item.onclick = () => open(session.id);
    list.append(item);
  }
  return sessions;
}

// Shows the title with the id under it, or the id alone if there is no title.
// Set as text, since either could be anything.
function setListedName(item, title) {
  const column = item.querySelector('.name');
  column.replaceChildren();
  const name = document.createElement('div');
  name.className = 'title';
  name.textContent = title || item.dataset.id;
  column.append(name);
  if (title) {
    const ident = document.createElement('div');
    ident.className = 'ident';
    ident.textContent = item.dataset.id;
    column.append(ident);
  }
}

async function open(id) {
  // Switching mid-turn would clear the conversation the turn is appending to.
  if (working) return;
  const res = await ask('open the session', sessionUrl(id));
  if (res === null) return;
  const body = await res.json();
  selected = id;
  for (const item of list.children) item.classList.toggle('selected', item.dataset.id === id);
  closeDrawer();
  headerBox.innerHTML = body.header;
  conversation.replaceChildren();
  fold = null;
  const stored = document.createElement('template');
  stored.innerHTML = body.blocks;
  for (const el of [...stored.content.children]) {
    conversation.append(el);
    place(el);
  }
  // A turn that ended on a tool call has no later block to close its fold.
  if (fold) closeFold();
  openCall = null;
  scrollToEnd(true);
  input.focus();
}

// A button on a session row. Its click must not also open the session.
function action(name, glyph, label, run) {
  const button = document.createElement('button');
  button.className = 'act ' + name;
  button.title = label;
  button.textContent = glyph;
  button.onclick = (event) => {
    event.stopPropagation();
    run();
  };
  return button;
}

async function rename(id, current) {
  if (working) return;
  const typed = prompt('rename this session', current || '');
  if (typed === null || typed.trim() === '') return;
  const res = await ask('rename the session', sessionUrl(id), {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ title: typed }),
  });
  if (res !== null) refresh(selected);
}

async function remove(id) {
  if (working) return;
  // There is no trash to recover it from.
  if (!confirm('delete this session? this cannot be undone')) return;
  const res = await ask('delete the session', sessionUrl(id), { method: 'DELETE' }, 404);
  if (res === null) return;
  if (selected === id) newDraft();
  refresh(selected);
}

// Sends the prompt and shows the answer as the server streams it back.
async function send(text) {
  if (working || text.trim() === '') return;
  // A session with no id yet is created by its first message.
  const creating = selected === null;
  working = true;
  form.classList.add('working');
  input.disabled = true;
  input.value = '';
  grow();
  stick = true;

  try {
    const url = creating ? '/api/sessions' : sessionUrl(selected) + '/message';
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text: text }),
    });
    if (res.status === 409 || !res.ok) {
      // Nothing was asked, so what was typed is given back.
      input.value = text;
      grow();
      note(res.status === 409 ? 'the session is busy; wait for the answer' : 'the prompt was refused (' + res.status + ')');
    } else await readStream(res);
  } catch (err) {
    note('lost the connection: ' + err.message);
  } finally {
    working = false;
    openCall = null;
    fold = null;
    form.classList.remove('working');
    input.disabled = false;
    input.focus();
    // The turn made this the most recent session.
    refresh(selected);
  }
}

// Frames are separated by a blank line; each is an event name and a line of JSON.
async function readStream(res) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let end;
    while ((end = buffer.indexOf('\n\n')) >= 0) {
      handleFrame(buffer.slice(0, end));
      buffer = buffer.slice(end + 2);
    }
  }
  if (buffer.trim() !== '') handleFrame(buffer);
}

function handleFrame(frame) {
  let event = 'message';
  let data = '';
  for (const line of frame.split('\n')) {
    if (line.startsWith('event:')) event = line.slice(6).trim();
    else if (line.startsWith('data:')) data += line.slice(5).trim();
  }
  if (data === '') return;
  const payload = JSON.parse(data);
  if (event === 'block') {
    show(payload.html);
    scrollToEnd();
  } else if (event === 'tool_begin') {
    openCall = show(payload.html);
    labelFold(false);
    scrollToEnd();
  } else if (event === 'tool_end') {
    // Replaces the begun call in place, keeping whether the user opened it.
    const finished = show(payload.html);
    if (openCall) {
      finished.open = openCall.open;
      openCall.replaceWith(finished);
    }
    openCall = null;
    labelFold(false);
    scrollToEnd();
  } else if (event === 'session') {
    selected = payload.id;
    refresh(selected);
  } else if (event === 'header') {
    headerBox.innerHTML = payload.html;
  } else if (event === 'title') {
    for (const item of list.children) {
      if (item.dataset.id === selected) setListedName(item, payload.title);
    }
  } else if (event === 'error') {
    note(payload.message);
  }
}

// Adds a block of the running turn and returns its element.
function show(html) {
  conversation.insertAdjacentHTML('beforeend', html);
  return place(conversation.lastElementChild);
}

// Tool calls go in a fold, made when the first one comes; any other block closes it.
function place(el) {
  if (el.matches('details.tool')) {
    if (!fold) {
      fold = document.createElement('details');
      fold.className = 'steps';
      fold.open = true;
      fold.append(document.createElement('summary'), document.createElement('div'));
      fold.firstChild.className = 'steps-head';
      fold.lastChild.className = 'tool-body';
      el.before(fold);
    }
    fold.lastChild.append(el);
  } else if (fold) {
    closeFold();
  }
  return el;
}

function closeFold() {
  labelFold(true);
  fold.open = false;
  fold = null;
}

function labelFold(done) {
  const count = fold.querySelectorAll('details.tool').length;
  fold.firstChild.textContent = (done ? 'completed ' : '') + count + (count === 1 ? ' step' : ' steps');
}

// A line the page writes itself, as text since it is not the server's HTML.
function note(text) {
  const line = document.createElement('div');
  line.className = 'notice failed';
  line.textContent = text;
  conversation.append(line);
  scrollToEnd();
}

// Pixels of conversation below the visible part; 0 when the end is in view.
function distanceFromEnd() {
  return Math.max(0, conversation.scrollHeight - conversation.scrollTop - conversation.clientHeight);
}

// A couple of pixels are allowed, since a fractional scroll never lands on the end.
function atEnd() {
  return distanceFromEnd() <= 2;
}

// Follows the end if the user is there; a user who scrolled up keeps their place.
function scrollToEnd(force) {
  if (force || stick) {
    conversation.scrollTop = conversation.scrollHeight;
    stick = true;
  }
  showLatest();
}

function showLatest() {
  document.body.classList.toggle('offscreen', distanceFromEnd() > 2);
}

function closeDrawer() {
  document.body.classList.remove('drawer');
}

// An on-screen keyboard does not shrink `dvh`, so the app is sized to the visual
// viewport. `scrollTo` undoes the pan iOS does to reveal the focused box.
function fitViewport() {
  const view = window.visualViewport;
  if (!view) return;
  document.documentElement.style.setProperty('--app-height', view.height + 'px');
  window.scrollTo(0, 0);
}

// The prompt box grows with its text, up to the height the stylesheet caps it at.
function grow() {
  input.style.height = 'auto';
  // scrollHeight leaves out the border, which a border-box height includes.
  input.style.height = input.scrollHeight + input.offsetHeight - input.clientHeight + 'px';
}

// Clears the view to a session with no id; nothing is created until the first message.
function newDraft() {
  if (working) return;
  selected = null;
  openCall = null;
  fold = null;
  headerBox.innerHTML = '';
  conversation.innerHTML = '';
  input.value = '';
  grow();
  stick = true;
  for (const item of list.children) item.classList.remove('selected');
  closeDrawer();
  input.focus();
}

if (window.visualViewport) {
  window.visualViewport.addEventListener('resize', fitViewport);
  window.visualViewport.addEventListener('scroll', fitViewport);
  fitViewport();
}

conversation.addEventListener('scroll', () => {
  stick = atEnd();
  showLatest();
});

latestButton.onclick = () => scrollToEnd(true);
menuButton.onclick = () => document.body.classList.toggle('drawer');
backdrop.onclick = closeDrawer;

form.onsubmit = (event) => {
  event.preventDefault();
  send(input.value);
  return false;
};

input.addEventListener('input', grow);
input.addEventListener('keydown', (event) => {
  // Enter sends and shift+enter is a newline; isComposing is an input method confirming text.
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    form.requestSubmit();
  }
});

document.getElementById('new').onclick = newDraft;

// The page opens on a fresh session; the list is read so it is there behind the menu.
(async () => {
  const sessions = await refresh();
  if (sessions === null) note('could not reach the server');
  newDraft();
})();
