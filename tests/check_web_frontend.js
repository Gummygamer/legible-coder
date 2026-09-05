// Execute the served script with a minimal DOM and deterministic API responses.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

class Element {
  constructor() {
    this.children = [];
    this.value = '';
    this.style = {};
    this.classList = {add() {}, remove() {}};
    this.parts = new Map();
  }
  appendChild(child) { this.children.push(child); child.parentNode = this; }
  removeChild(child) { this.children = this.children.filter(c => c !== child); }
  addEventListener() {}
  focus() {}
  querySelectorAll() { return []; }
  querySelector(selector) {
    if (!this.parts.has(selector)) this.parts.set(selector, new Element());
    return this.parts.get(selector);
  }
}

const elements = new Map();
const document = {
  createElement: () => new Element(),
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  },
};
const context = vm.createContext({document, assert, setInterval: () => 1, clearInterval() {}});
const html = fs.readFileSync(0, 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
// Startup fetches are unrelated to the send/poll lifecycle under test.
vm.runInContext(script.replace('loadState().then(() => loadMessages());', ''), context);
vm.runInContext(`
  (async () => {
    assert.equal(typeof startLive, 'function');
    assert.equal(typeof finishTurn, 'function');
    let renders = 0;
    let rejectSend = false;
    let eventReply = {};
    renderMessages = () => { renders += 1; };
    loadState = async () => {};
    api = async path => {
      if (path === '/api/send') return rejectSend ? {error: 'launch failed'} :
        {ok: true, started: true, ws: 'ws-test', conv: 'cv-test', messages: []};
      if (path.startsWith('/api/events')) return eventReply;
      return {messages: []};
    };
    const input = document.getElementById('input');
    const button = document.getElementById('sendbtn');
    input.value = 'Hello';
    await send();
    assert.equal(busy, true);
    assert.equal(button.disabled, true);
    assert.ok(liveBox);
    eventReply = {next: 1, running: true, events: [
      {type: 'tool_start', n: '1', name: 'shell_exec', label: 'shell_exec', arguments: '{}'}
    ]};
    await pollEvents();
    assert.ok(liveChips['1']);
    assert.equal(busy, true);
    eventReply = {next: 3, running: false, events: [
      {type: 'tool_end', n: '1', result: 'done'}, {type: 'done'}
    ]};
    await pollEvents();
    assert.equal(busy, false);
    assert.equal(button.disabled, false);
    assert.equal(evDone, true);
    const finishedRenders = renders;
    await Promise.all([finishTurn(), finishTurn()]);
    assert.equal(renders, finishedRenders, 'completion must only run once');
    rejectSend = true;
    input.value = 'Retry me';
    await send();
    assert.equal(input.value, 'Retry me');
    assert.equal(busy, false);
    assert.equal(button.disabled, false);
    assert.equal(renders, finishedRenders + 1);
    rejectSend = false;
    await send();
    assert.equal(busy, true);
    assert.equal(evDone, false);
    assert.ok(liveBox);
  })()
`, context).catch(error => { console.error(error); process.exitCode = 1; });
