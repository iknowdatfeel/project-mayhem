// Checks that LuCI's minifier does not change the meaning of our JS: the
// package build runs every file through jsmin, which tells a regex from a
// division only by the character before it. After `return` it guesses
// division (after `=>` too), so `return /a\/\//` turns `//` into a comment.
// Write `return (/.../).test(x)` instead.
//
//   JSMIN=/path/to/jsmin node tests/jsmin.js FILE...
// Needs the acorn parser (npm install acorn; NODE_PATH pointing at it).
'use strict';

const fs = require('fs');
const { execFileSync } = require('child_process');
const acorn = require('acorn');

// The AST without source positions and raw literal text.
function tree(src) {
	const ast = acorn.parse(`(function(){${src}\n})`, { ecmaVersion: 'latest' });

	return JSON.stringify(ast, (k, v) => (k == 'start' || k == 'end' || k == 'raw') ? undefined : v);
}

let failed = 0;

for (const f of process.argv.slice(2)) {
	const src = fs.readFileSync(f, 'utf8');
	const min = execFileSync(process.env.JSMIN || 'jsmin', { input: src }).toString();
	let want, err = null;

	try {
		want = tree(src);
	}
	catch (e) {
		continue; // the syntax check reports broken sources
	}

	try {
		if (tree(min) !== want)
			err = 'minified code differs from the source';
	}
	catch (e) {
		err = `minified code does not parse: ${e.message}`;
	}

	if (err) {
		console.log(`FAIL ${f}: ${err}`);
		failed++;
	}
}

process.exit(failed ? 1 : 0);
