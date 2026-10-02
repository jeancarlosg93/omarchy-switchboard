const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../UiScale.js'), 'utf8');
const scale = vm.createContext({});
vm.runInContext(source.replace(/^\.pragma library\s*/, ''), scale);
const id = 'krall.switchboard';
for (const section of ['left', 'center', 'right']) {
  const config = { layout: { [section]: [{ id: 'other', scale: 2 }, { id, scale: 1.2 }] } };
  assert.equal(scale.fromBarConfig(config, id), 1.2);
  config.layout[section][1].scale = 1.4;
  assert.equal(scale.fromBarConfig(config, id), 1.4);
}
for (const invalid of [undefined, null, '1.2', NaN, Infinity, {}, true]) {
  assert.equal(scale.fromBarConfig({ layout: { left: [{ id, scale: invalid }] } }, id), 1);
}
for (const config of [null, {}, {layout: {}}, {layout: {left: [null, 'krall.switchboard']} }]) {
  assert.equal(scale.fromBarConfig(config, id), 1);
}
assert.equal(scale.fromBarConfig({layout: {left: [{id, scale: 0.1}]}}, id), 0.75);
assert.equal(scale.fromBarConfig({layout: {left: [{id, scale: 9}]}}, id), 2);
assert.equal(scale.size(680, 1.2), 816);
assert.equal(scale.size(12, 1.2), 14);
for (const px of [0, 1, 4, 12, 680]) assert.equal(scale.size(px, 1), px);
console.log('UI scale: configuration, fallback, limits, and dimensions passed');

for (const section of ['left', 'center', 'right']) {
  const config = {layout: {[section]: [{id, verticalAlignment: 'center'}]}};
  assert.equal(scale.alignmentFromBarConfig(config, id), 'center');
  config.layout[section][0].verticalAlignment = 'top';
  assert.equal(scale.alignmentFromBarConfig(config, id), 'top');
}
for (const value of [undefined, null, false, 'bottom', 'CENTER', 1]) {
  assert.equal(scale.alignmentFromBarConfig({layout: {left: [{id, verticalAlignment: value}]}}, id), 'top');
}
assert.equal(scale.alignmentFromBarConfig(null, id), 'top');
console.log('Vertical alignment: explicit center and original-position fallback passed');
