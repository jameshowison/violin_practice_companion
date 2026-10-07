// Runs the app's own ABC -> MusicXML converter (assets/abc/) under Node, the
// way the app does: abcjs and abc_to_musicxml.js loaded as plain scripts into
// one global scope, no DOM. Used to regenerate the golden fixtures in
// test/fixtures/ after a converter change.
//
//   node scripts/abc_to_musicxml.cjs test/fixtures/circle.abc > test/fixtures/circle.musicxml
//
// Warnings go to stderr; a failed conversion exits 1.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const abcDir = path.join(__dirname, '..', 'assets', 'abc');
const ctx = vm.createContext({});
for (const f of ['abcjs-basic-min.js', 'abc_to_musicxml.js']) {
  vm.runInContext(fs.readFileSync(path.join(abcDir, f), 'utf8'), ctx, { filename: f });
}
const res = JSON.parse(ctx.abcToMusicXml(fs.readFileSync(process.argv[2], 'utf8')));
for (const w of res.warnings || []) process.stderr.write('warning: ' + w + '\n');
if (!res.ok) { process.stderr.write('error: ' + res.error + '\n'); process.exit(1); }
process.stdout.write(res.xml);
