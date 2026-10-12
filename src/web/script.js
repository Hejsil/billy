// The page is a shell: every block of a conversation is rendered by the server
// and put in whole, so nothing here lays out an answer or escapes a file.
const list = document.getElementById('list');
const headerBox = document.getElementById('header');
const conversation = document.getElementById('conversation');
const form = document.getElementById('prompt');
const input = document.getElementById('text');
const modeSelect = document.getElementById('mode');
const menuButton = document.getElementById('menu');
const backdrop = document.getElementById('backdrop');
const latestButton = document.getElementById('latest');
let selected = null;
let working = false;
// Whether the end of the conversation follows what comes in. It is true while
// the user is at the bottom, and false once they scroll away: a turn that keeps
// adding blocks then no longer pulls them down, which is what makes reading
// earlier messages possible while an answer arrives.
let stick = true;
// The tool call the turn is in the middle of: the `<details>` opened by a
// `tool_begin` event, whose body the `tool_end` event fills in. Null when no
// call is open.
let openCall = null;

// The sessions are listed again when a new one is started and when a turn ends,
// since which session was written to last is what orders them. The list is
// returned, or null when it could not be read, so a caller can tell an empty
// list from a server it could not reach.
async function refresh(select) {
  let sessions;
  try {
    const res = await fetch('/api/sessions');
    if (!res.ok) throw new Error('the server answered ' + res.status);
    sessions = (await res.json()).sessions;
  } catch (err) {
    // The list is left as it was rather than wiped, so a hiccup does not empty
    // what is on screen.
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
    // Rename and delete sit at the right of the row. Each is a child, so its
    // click must not also open the session.
    item.append(action('ren', '\u270e', 'rename this session', () => rename(session.id, session.title)));
    item.append(action('del', '\u2715', 'delete this session', () => remove(session.id)));
    if (session.id === select) item.classList.add('selected');
    item.onclick = () => open(session.id);
    list.append(item);
  }
  return sessions;
}

// Shows a session's name in its list item: the title, with the id it can be
// resumed by under it in a smaller, dimmer line. A session that has not been
// named shows its id in the title's place. Every value is set as text, since an
// id or a title could be anything.
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

// Opens a session: the header above the conversation, and the conversation
// itself, both of which the server rendered.
async function open(id) {
  // Switching sessions while a turn is streaming would clear the conversation
  // the turn is still appending to, so it waits for the turn to end.
  if (working) return;
  let body;
  try {
    const res = await fetch('/api/sessions/' + encodeURIComponent(id));
    if (!res.ok) {
      note('could not open the session (' + res.status + ')');
      return;
    }
    body = await res.json();
  } catch (err) {
    note('lost the connection: ' + err.message);
    return;
  }
  selected = id;
  for (const item of list.children) item.classList.toggle('selected', item.dataset.id === id);
  closeDrawer();
  headerBox.innerHTML = body.header;
  conversation.innerHTML = body.blocks;
  // The mode is only chosen for a session that has no conversation yet, so it is
  // shown read-only once there is one.
  modeSelect.value = body.mode;
  modeSelect.disabled = body.blocks.trim() !== '';
  // Whatever the old conversation had open is gone with it.
  openCall = null;
  // Opening a session is a deliberate move to it, so it starts at the end
  // whatever the previous one was being read at.
  scrollToEnd(true);
  input.focus();
}

// One of a session row's buttons: a glyph that runs `run`, and does not open the
// session when it is clicked.
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

// Renames a session. The new name is asked for with a prompt, and sent to the
// server, which trims and cuts it. The list is refreshed so the row shows it.
async function rename(id, current) {
  if (working) return;
  const typed = prompt('rename this session', current || '');
  if (typed === null || typed.trim() === '') return;
  try {
    const res = await fetch('/api/sessions/' + encodeURIComponent(id), {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ title: typed }),
    });
    if (!res.ok) {
      note('could not rename the session (' + res.status + ')');
      return;
    }
  } catch (err) {
    note('lost the connection: ' + err.message);
    return;
  }
  refresh(selected);
}

// Deletes a session for good. It is asked for first, since there is no trash to
// recover it from; the list is refreshed after, and if the deleted session was
// the one on screen the page clears to a new one.
async function remove(id) {
  if (working) return;
  if (!confirm('delete this session? this cannot be undone')) return;
  try {
    const res = await fetch('/api/sessions/' + encodeURIComponent(id), { method: 'DELETE' });
    if (!res.ok && res.status !== 404) {
      note('could not delete the session (' + res.status + ')');
      return;
    }
  } catch (err) {
    note('lost the connection: ' + err.message);
    return;
  }
  if (selected === id) newDraft();
  refresh(selected);
}

// Sends what was typed and shows the answer as it arrives. The whole exchange is
// one request: the server streams each block of it back as it is finished.
async function send(text) {
  if (working || text.trim() === '') return;
  // A session with no id yet is a new one: its first message creates it.
  const creating = selected === null;
  working = true;
  form.classList.add('working');
  input.disabled = true;
  // A turn makes the session one that has been asked something, so the mode is
  // fixed from here on.
  modeSelect.disabled = true;
  input.value = '';
  grow();
  // A turn the user asked for is followed to the end: they just sent it.
  stick = true;

  try {
    const url = creating ? '/api/sessions' : '/api/sessions/' + encodeURIComponent(selected) + '/message';
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text: text, mode: modeSelect.value }),
    });
    if (res.status === 409) note('the session is busy; wait for the answer');
    else if (!res.ok) note('the prompt was refused (' + res.status + ')');
    else await readStream(res);
  } catch (err) {
    note('lost the connection: ' + err.message);
  } finally {
    working = false;
    // A turn that ended mid-call leaves nothing to fill in.
    openCall = null;
    form.classList.remove('working');
    input.disabled = false;
    input.focus();
    // The turn wrote to the session, so it is now the most recent one.
    refresh(selected);
  }
}

// Reads the event stream: frames are separated by a blank line, and each is a
// name and a line of JSON data.
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
  // Whatever is left could not be a whole frame, but show it rather than lose it.
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
  if (event === 'block') {
    // The block is the server's HTML, which is what it is for.
    conversation.insertAdjacentHTML('beforeend', JSON.parse(data).html);
    scrollToEnd();
  } else if (event === 'tool_begin') {
    // The whole call, collapsed, while it runs: its body is empty and its exit
    // status is not known yet.
    conversation.insertAdjacentHTML('beforeend', JSON.parse(data).html);
    openCall = conversation.lastElementChild;
    scrollToEnd();
  } else if (event === 'tool_end') {
    // The whole call again, now with its body and its exit status. It replaces
    // the one on screen, which keeps its place in the conversation and whether
    // the user had opened it.
    conversation.insertAdjacentHTML('beforeend', JSON.parse(data).html);
    const finished = conversation.lastElementChild;
    if (openCall) {
      finished.open = openCall.open;
      conversation.replaceChild(finished, openCall);
    }
    openCall = null;
    scrollToEnd();
  } else if (event === 'session') {
    // The first message created a session; its id is here, so the page adds it
    // to the list and marks it as the one being asked.
    selected = JSON.parse(data).id;
    refresh(selected);
  } else if (event === 'header') {
    headerBox.innerHTML = JSON.parse(data).html;
  } else if (event === 'title') {
    // The session being asked was just named; its list item is updated in place,
    // rather than the whole list asked for again, since the name is here.
    const title = JSON.parse(data).title;
    for (const item of list.children) {
      if (item.dataset.id === selected) setListedName(item, title);
    }
  } else if (event === 'error') {
    note(JSON.parse(data).message);
  }
}

// A line the page writes itself, such as why a turn did not happen. The text is
// set as text, since it is not the server's HTML.
function note(text) {
  const line = document.createElement('div');
  line.className = 'notice failed';
  line.textContent = text;
  conversation.append(line);
  scrollToEnd();
}

// How far the end of the conversation is below the bottom of what is on screen,
// which is 0 when it is in view. A couple of pixels are allowed for, since a
// fractional scroll position never lands exactly on the end.
function distanceFromEnd() {
  return Math.max(0, conversation.scrollHeight - conversation.scrollTop - conversation.clientHeight);
}

function atEnd() {
  return distanceFromEnd() <= 2;
}

// Follows the end of the conversation if the user is there, which is the usual
// case; a user who has scrolled up keeps their place. Either way the pill is
// told whether there is more below.
function scrollToEnd(force) {
  if (force || stick) {
    conversation.scrollTop = conversation.scrollHeight;
    stick = true;
  }
  showLatest();
}

// Whether the pill is shown: the end is off screen, so there is more to read
// below wherever the user is.
function showLatest() {
  document.body.classList.toggle('offscreen', distanceFromEnd() > 2);
}

// The user scrolling is what decides whether the end is followed, so it is read
// from the position they left rather than from a flag they never set.
conversation.addEventListener('scroll', () => {
  stick = atEnd();
  showLatest();
});
latestButton.onclick = () => scrollToEnd(true);

// The session list is a drawer on a narrow screen: the menu button opens it and
// the backdrop or a chosen session closes it. On a wide screen it is always
// shown, so opening it is a no-op there.
function closeDrawer() {
  document.body.classList.remove('drawer');
}
menuButton.onclick = () => document.body.classList.toggle('drawer');
backdrop.onclick = closeDrawer;

// Sizes the app to the part of the screen the user can actually see. An
// on-screen keyboard does not shrink `dvh`, so without this the prompt box sits
// behind the keyboard; the visual viewport is the rectangle above it. `scrollTo`
// undoes the pan iOS does to reveal the focused box, so the layout stays put.
function fitViewport() {
  const view = window.visualViewport;
  if (!view) return;
  document.documentElement.style.setProperty('--app-height', view.height + 'px');
  window.scrollTo(0, 0);
}
if (window.visualViewport) {
  window.visualViewport.addEventListener('resize', fitViewport);
  window.visualViewport.addEventListener('scroll', fitViewport);
  fitViewport();
}

form.onsubmit = (event) => {
  event.preventDefault();
  send(input.value);
  return false;
};

// A prompt box is a textarea, so a newline can be typed into it. It is one line
// tall to begin with and grows to fit what is written, up to the height the
// stylesheet caps it at; past that it scrolls.
function grow() {
  input.style.height = 'auto';
  input.style.height = input.scrollHeight + 'px';
}
input.addEventListener('input', grow);
input.addEventListener('keydown', (event) => {
  // Enter sends, the way it does in a chat box. Shift+Enter is the newline, so a
  // prompt can still be written over several lines; every other key is left to
  // the textarea.
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    form.requestSubmit();
  }
});

// Clears the view to a session that has not been asked anything: no id, an empty
// conversation, and the mode picker ready. Nothing is created on the server until
// the first message is sent.
function newDraft() {
  if (working) return;
  selected = null;
  openCall = null;
  headerBox.innerHTML = '';
  conversation.innerHTML = '';
  modeSelect.value = 'chat';
  modeSelect.disabled = false;
  input.value = '';
  grow();
  // An empty conversation has nothing to scroll back to, so the end is where it
  // starts.
  stick = true;
  for (const item of list.children) item.classList.remove('selected');
  closeDrawer();
  input.focus();
}

document.getElementById('new').onclick = newDraft;

// The page opens on a fresh session, so there is nothing to pick before asking
// something. The list is still read, so it is there behind the menu.
(async () => {
  const sessions = await refresh();
  if (sessions === null) note('could not reach the server');
  newDraft();
})();
