const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const helper = fs.readFileSync(path.join(root, 'public', 'finlo-helper.js'), 'utf8');
const index = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');

function ok(condition, message) {
  if (!condition) throw new Error(`FAIL: ${message}`);
}

ok(/function startConversation\(\)\{[\s\S]*?startLiveVoice\(\)/.test(helper), 'conversation entry point uses Live Voice');
ok(!/function startConversation\(\)\{if\(!speechCtor\(\)\)/.test(helper), 'legacy browser speech conversation is not the active entry point');
ok(/natural conversation unavailable; legacy robotic voice was not used/.test(helper), 'legacy fallback is explicit and disabled');
ok(/finlo-live-voice-session/.test(helper), 'natural conversation uses the Live Voice Edge Function');
ok(/model:'gpt-live-1'/.test(helper), 'natural conversation diagnostic model is present');
ok(/Start natural voice conversation/.test(index), 'UI identifies the natural conversation action');

console.log('Finlo Helper conversational voice regression checks PASS');
