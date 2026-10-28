'use strict';
'require baseclass';
'require rpc';
'require mayhem.common as mh';

// Latency checks of the dashboard: the URL test over kept-alive connections,
// TCP and ICMP pings of many servers per call, and the ping and external
// address of the main section. The numbers are kept here by server tag; the
// dashboard draws them.

const callProbe = rpc.declare({ object: 'luci.mayhem', method: 'probe', params: [ 'tag', 'method' ], expect: { '': {} } });
const callProbeIcmp = rpc.declare({ object: 'luci.mayhem', method: 'probe_icmp', params: [ 'tags' ], expect: { '': {} } });
const callProbeTcp = rpc.declare({ object: 'luci.mayhem', method: 'probe_tcp', params: [ 'tags' ], expect: { '': {} } });
const callWarm = rpc.declare({ object: 'luci.mayhem', method: 'warm', params: [ 'now' ], expect: { '': {} } });
const callExitInfo = rpc.declare({ object: 'luci.mayhem', method: 'exit_info', params: [ 'section', 'lang' ], expect: { '': {} } });
const callSetPing = rpc.declare({ object: 'luci.mayhem', method: 'set_ping_method', params: [ 'method' ], expect: { '': {} } });

const PROBE_PARALLEL = 4;
// ICMP and TCP: servers per call; the router checks all of them at once.
const ICMP_CHUNK = 64;

function pageLang() {
	return document.documentElement.getAttribute('lang') || (L.env && L.env.lang) || navigator.language || 'en';
}

// Languages the geo services know city names in.
function geoLang() {
	const l = pageLang().replace('_', '-');
	const known = [ 'en', 'de', 'es', 'fr', 'ja', 'pt-BR', 'ru', 'zh-CN' ];

	return known.indexOf(l) >= 0 ? l : (known.indexOf(l.split('-')[0]) >= 0 ? l.split('-')[0] : 'en');
}

return baseclass.extend({
	METHODS: [ [ 'url', _('URL test') ], [ 'tcp', _('TCP ping') ], [ 'icmp', _('ICMP ping') ] ],

	method: 'url',
	probes: {},		// tag -> { method, value: ms or an error, at }
	conn: null,		// ping and exit of the default section, checked on demand
	warm: null,		// the last answer of the kept-alive URL test
	firstCheck: false,	// the first check after the page opened is running

	// The dashboard: its data, busy flags and redraw.
	bind(view) {
		this.view = view;
	},

	load() {
		return callWarm(false);
	},

	known(m) {
		return this.METHODS.some((p) => p[0] === m);
	},

	// Ping and external address of the default section: once when the page
	// opens, after a server change and with the latency test. Never polled.
	checkConnection() {
		const d = this.view.data;
		const main = mh.mainServer(d);
		const sec = main.section;

		if (!sec || !d.running) {
			this.conn = null;
			this.view.redraw();
			return Promise.resolve();
		}

		const conn = this.conn = { section: sec.name, busy: true };
		const method = this.method;

		this.view.redraw();

		// The same check is the server's latency in its box: one number for
		// one server, not two from two checks.
		const warm = (method === 'url' && main.node) ? this.warmResult(main.node.tag) : null;
		const ping = warm
			? Promise.resolve().then(() => {
				conn.ms = warm.ms;
				conn.pingError = warm.error;
			})
			: main.node
			? callProbe(main.node.tag, method).then((r) => {
				conn.ms = r.ms;
				conn.pingError = r.error;
				this.probes[main.node.tag] = { method: method, value: (r.ms != null) ? r.ms : (r.error || 'error') };
			})
			: Promise.resolve();
		const exit = callExitInfo(sec.name, geoLang()).then((r) => { conn.exit = r; });

		return Promise.all([ ping, exit ]).catch(() => {}).finally(() => {
			conn.busy = false;

			if (this.conn === conn)
				this.view.redraw();
		});
	},

	setMethod(m) {
		this.method = m;
		callSetPing(m);

		if (m === 'url')
			this.pollWarm(false);
	},

	// URL test over kept-alive connections: the router keeps a connection
	// through every server open while the dashboard asks (every poll), and
	// sends a request over it every few seconds. The numbers are there at
	// once and stay current. now: every server is asked at once.
	pollWarm(now) {
		return callWarm(now ? true : false).then((r) => {
			if (this.applyWarm(r))
				this.view.redraw();

			return this.warm;
		}).catch(() => null);
	},

	applyWarm(r) {
		this.warm = (r && r.ok) ? r : null;

		if (!this.warm || this.method !== 'url')
			return false;

		for (const tag in r.results) {
			const x = r.results[tag];

			this.probes[tag] = { method: 'url', value: (x.ms != null) ? x.ms : (x.error || 'error'), at: x.at };
		}

		return true;
	},

	warmResult(tag) {
		const r = this.warm && this.warm.results && this.warm.results[tag];

		return r || null;
	},

	// "Test latency" with kept-alive connections: every server at once, then
	// a few looks until each has a number newer than the press.
	probeWarm(nodes) {
		return this.pollWarm(true).then((w) => {
			if (!w)
				return nodes;

			const since = w.now;
			const covered = nodes.filter((n) => w.tags.indexOf(n.tag) >= 0);
			const rest = nodes.filter((n) => w.tags.indexOf(n.tag) < 0);
			let tries = 0;

			const look = () => new Promise((r) => window.setTimeout(r, 700)).then(() => this.pollWarm(false)).then((w2) => {
				const res = (w2 && w2.results) || {};

				if (++tries < 15 && covered.some((n) => !(res[n.tag] && res[n.tag].at >= since)))
					return look();

				return rest;
			});

			return covered.length ? look() : rest;
		});
	},

	// Checks every server of the section with the chosen method, a few at a
	// time, but never two of one address at once: subscriptions often have
	// many servers on one host, and a burst of connections to it makes its
	// firewall drop some (a lost SYN costs a second or three of "ping").
	probeSection(sec, cold) {
		const method = this.method;
		const queue = sec.nodes.slice();
		const key = 'probe:' + sec.name;
		const busyHost = {};

		if (this.view.busy[key])
			return Promise.resolve();

		this.view.busy[key] = true;
		this.view.redraw();

		// The URL test goes over the kept-alive connections; servers they do
		// not cover (too many, or the router cannot keep them) are tested one
		// by one as before.
		if (method === 'url' && this.warm && !cold) {
			return this.probeWarm(queue.slice()).then((rest) => {
				delete this.view.busy[key];

				if (!rest.length) {
					this.view.redraw();
					return;
				}

				return this.probeSection(Object.assign({}, sec, { nodes: rest }), true);
			});
		}

		// A ping costs the router next to nothing, a call a whole process:
		// ICMP asks for many servers at once.
		// TCP too, in waves on the router; tunnels are tested one by one, through
		// their interface.
		if (method === 'icmp' || (method === 'tcp' && !cold)) {
			const batch = method === 'tcp' ? queue.filter((n) => !n.iface) : queue;
			const rest = method === 'tcp' ? queue.filter((n) => n.iface) : [];
			const call = method === 'tcp' ? callProbeTcp : callProbeIcmp;
			const chunks = [];

			for (let i = 0; i < batch.length; i += ICMP_CHUNK)
				chunks.push(batch.slice(i, i + ICMP_CHUNK));

			if (rest.length)
				delete this.view.busy[key];

			return Promise.all(chunks.map((c) => call(c.map((n) => n.tag)).then((r) => {
				for (const n of c) {
					const x = (r.results || {})[n.tag] || { error: r.error || 'error' };

					this.probes[n.tag] = { method: method, value: (x.ms != null) ? x.ms : (x.error || 'error') };
				}

				this.view.redraw();
			}).catch(() => {})).concat(rest.length ? [ this.probeSection(Object.assign({}, sec, { nodes: rest }), true) ] : [])).finally(() => {
				delete this.view.busy[key];
				this.view.redraw();
			});
		}

		const next = () => {
			const i = queue.findIndex((n) => !n.address || !busyHost[n.address]);

			return i < 0 ? null : queue.splice(i, 1)[0];
		};

		const worker = () => {
			const n = next();

			if (!n)
				return queue.length ? new Promise((r) => window.setTimeout(r, 150)).then(worker) : Promise.resolve();

			if (n.address)
				busyHost[n.address] = true;

			return callProbe(n.tag, method).then((r) => {
				this.probes[n.tag] = { method: method, value: (r.ms != null) ? r.ms : (r.error || 'error') };
				this.view.redraw();
			}).catch(() => {}).finally(() => {
				if (n.address)
					delete busyHost[n.address];
			}).then(worker);
		};

		const workers = [];

		for (let i = 0; i < PROBE_PARALLEL; i++)
			workers.push(worker());

		return Promise.all(workers).finally(() => {
			delete this.view.busy[key];
			this.view.redraw();
		});
	},

	probeAll(sections) {
		this.view.busy.probeAll = true;
		this.view.redraw();

		return Promise.all(sections.map((s) => this.probeSection(s)).concat([ this.checkConnection() ])).finally(() => {
			delete this.view.busy.probeAll;
			this.view.redraw();
		});
	}
});
