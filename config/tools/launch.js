// Starts a program in its own visible window and returns immediately.
// mpv's subprocesses get no console window, so scripts use this to show one (e.g. the updater).
// Usage: wscript launch.js <program> [arguments...]
var args = WScript.Arguments;

function quote(s) {
    if (s !== "" && !/[\s"]/.test(s)) return s;
    return '"' + s.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"';
}

var parts = [];
for (var i = 0; i < args.length; i++) parts.push(quote(args(i)));
new ActiveXObject("WScript.Shell").Run(parts.join(" "), 1, false);
