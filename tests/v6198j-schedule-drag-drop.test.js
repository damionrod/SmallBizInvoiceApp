const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');
const schedule=fs.readFileSync('public/schedule.js','utf8'),html=fs.readFileSync('public/index.html','utf8'),saas=fs.readFileSync('public/saas.js','utf8'),css=fs.readFileSync('public/styles.css','utf8');

test('quote drag-drop does not block its own atomic save',()=>{
 assert.match(schedule,/if\(r\.virtual_quote\).*?const res=await atomicSave\(null,payload,\[\]\)/s);
 assert.doesNotMatch(schedule,/moveToSlot=async function\(\.\.\.args\)\{if\(S\.saving\)return;setSaving\(true\);try\{return await rawMoveToSlot\(\.\.\.args\)\}/);
 assert.match(schedule,/moveToSlot=async function\(\.\.\.args\)\{if\(S\.saving\)return;try\{return await rawMoveToSlot\(\.\.\.args\)\}finally\{if\(S\.saving\)setSaving\(false\)\}\}/);
 assert.match(schedule,/if\(res\.duplicate\)return;if\(res\.error\)return toast\(`\$\{saveErrorMessage\(res\.error\)\} The quote was not changed\.`/);
});

test('schedule cache tags are bumped for fixed drag/drop and refreshed styles',()=>{
 assert.match(html,/styles\.css\?v=61\.98L-dashboard-overlap/);
 assert.match(html,/saas\.js\?v=61\.98J-schedule-fix/);
 assert.match(saas,/schedule\.js\?v=61\.98J-drag-drop-fix/);
});

test('schedule visual polish is scoped to the Schedule page only',()=>{
 assert.match(css,/V61\.98J Schedule drag-drop reliability \+ modern visual polish/);
 assert.match(css,/#view-schedule \.schedule-toolbar/);
 assert.match(css,/#view-schedule \.week-hour\.drag-over/);
 assert.match(css,/#view-schedule \.schedule-job\.quote-card/);
});
