// Browserless checks for the phone attachment helper and send plumbing.
const fs = require("fs"), path = require("path"), vm = require("vm");
const src = fs.readFileSync(path.join(__dirname, "..", "lib", "webapp", "index.html"), "utf8");
let pass = 0, fail = 0;
function ok(cond, msg) { if (cond) { pass++; console.log("  ok: " + msg); }
  else { fail++; console.log("  FAIL: " + msg); } }
function lift(name) {
  const start = src.indexOf(name), end = src.indexOf("\n}\n", start);
  if (start < 0 || end < 0) throw new Error("cannot lift " + name);
  return src.slice(start, end + 3);
}

console.log("phone attachment client:");
ok(/id="attachment-input"[^>]+type="file"[^>]+accept="image\/jpeg,image\/png,image\/webp,image\/gif"/.test(src),
   "the control invokes the system image picker for camera or gallery");
ok(/id="attachment-preview"/.test(src) && /id="attachment-remove"/.test(src),
   "a selected photo has a preview and removal control");
ok(/if \(!v && !attachment\) return;/.test(src),
   "a photo may send without a caption while an empty turn still cannot");
ok(/queueTurn\(text, attachment\)/.test(src) && /attachment: attachment \|\| null/.test(src),
   "busy turns keep the photo with their queued message");
ok(/attachment \? \{ attachment \} : \{\}/.test(src),
   "the creating and retrying say payload carries the image beside text");
ok(/if \(r\.status === 400\)/.test(src) && /the photo was refused/.test(src),
   "a rejected photo ends visibly instead of retrying the bad bytes forever");

const sandbox = { JSON, Object };
vm.createContext(sandbox);
vm.runInContext(lift("function turnPayload"), sandbox);
const doc = JSON.parse(sandbox.turnPayload("caption", "abc", {lat:1},
  {type:"image/png", data:"AAAA"}));
ok(doc.text === "caption" && doc.turn === "abc" && doc.loc.lat === 1 &&
   doc.attachment.type === "image/png", "the JSON helper preserves text, id, location, and photo");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
