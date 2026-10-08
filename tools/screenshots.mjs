#!/usr/bin/env node
// Take the README's screenshots from a running LuCI with Aquamarine active: a
// router, or a test copy. Drives a headless Chromium over the DevTools protocol,
// so it needs nothing from npm; Node 22 or later (built-in fetch and WebSocket).
//
//   LUCI_PASSWORD=... node tools/screenshots.mjs --url http://192.168.1.1 \
//       --chrome /path/to/chrome-headless-shell [--out docs/screenshots] [name ...]
//
// The password comes from the environment so that it never shows in a process
// list. Shots are 2x device pixels. Names: see SHOTS below (default: all).
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const SHOTS = [
	// name, LuCI path, width, height, colour scheme, extra step
	['login-dark', '', 1280, 800, 'dark', 'logout'],
	['overview-dark', 'admin/status/overview', 1280, 900, 'dark'],
	['interfaces-dark', 'admin/network/network', 1280, 760, 'dark'],
	['firewall-dark', 'admin/network/firewall/zones', 1280, 900, 'dark'],
	['bandwidth-dark', 'admin/status/realtime/bandwidth', 1280, 760, 'dark'],
	['overview-light', 'admin/status/overview', 1280, 900, 'light'],
	['system-light', 'admin/system/system', 1280, 760, 'light'],
	['phone-overview-dark', 'admin/status/overview', 390, 844, 'dark'],
	['phone-menu-dark', 'admin/status/overview', 390, 844, 'dark', 'menu'],
	['phone-interfaces-light', 'admin/network/network', 390, 844, 'light'],
];

const args = process.argv.slice(2);
const opt = { url: null, chrome: null, out: 'docs/screenshots' }, only = [];
for (let i = 0; i < args.length; i++) {
	if (args[i] === '--url') opt.url = args[++i].replace(/\/$/, '');
	else if (args[i] === '--chrome') opt.chrome = args[++i];
	else if (args[i] === '--out') opt.out = args[++i];
	else only.push(args[i]);
}
const password = process.env.LUCI_PASSWORD;
if (!opt.url || !opt.chrome || password === undefined) {
	console.error('usage: LUCI_PASSWORD=... node tools/screenshots.mjs --url URL --chrome PATH [--out DIR] [name ...]');
	process.exit(2);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// LuCI's login: a form post; the answer sets the session cookie
async function login() {
	const r = await fetch(`${opt.url}/cgi-bin/luci/`, {
		method: 'POST', redirect: 'manual',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({ luci_username: 'root', luci_password: password })
	});
	const c = (r.headers.getSetCookie?.() || []).map((s) => s.split(';')[0]).find((s) => /^sysauth/.test(s));
	if (!c) throw new Error(`login failed (HTTP ${r.status}): wrong password, or not a LuCI address`);
	const [name, value] = c.split('=');
	return { name, value };
}

// one CDP connection to one page
function cdp(ws) {
	let id = 0;
	const waiting = new Map(), listeners = [];
	ws.addEventListener('message', (ev) => {
		const m = JSON.parse(ev.data);
		if (m.id && waiting.has(m.id)) {
			const { res, rej } = waiting.get(m.id);
			waiting.delete(m.id);
			m.error ? rej(new Error(m.error.message)) : res(m.result);
		} else if (m.method) listeners.forEach((l) => l(m));
	});
	return {
		send: (method, params = {}) => new Promise((res, rej) => {
			const n = ++id;
			waiting.set(n, { res, rej });
			ws.send(JSON.stringify({ id: n, method, params }));
		}),
		once: (method, ms) => new Promise((res) => {
			const t = setTimeout(() => res(null), ms);
			const l = (m) => { if (m.method === method) { clearTimeout(t); listeners.splice(listeners.indexOf(l), 1); res(m); } };
			listeners.push(l);
		})
	};
}

const profile = mkdtempSync(join(tmpdir(), 'aq-shots-'));
const chrome = spawn(opt.chrome, ['--headless', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
	'--hide-scrollbars', '--no-first-run', '--no-default-browser-check', 'about:blank'], { stdio: 'ignore' });
let exitCode = 0;
try {
	let port = null;
	for (let i = 0; i < 100 && !port; i++) {
		await sleep(100);
		const f = join(profile, 'DevToolsActivePort');
		if (existsSync(f)) port = readFileSync(f, 'utf8').split('\n')[0];
	}
	if (!port) throw new Error('Chromium did not start');
	const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
	const ws = new WebSocket(target.webSocketDebuggerUrl);
	await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
	const c = cdp(ws);
	await c.send('Page.enable');
	await c.send('Network.enable');
	const cookie = await login();
	const host = new URL(opt.url).hostname;
	mkdirSync(opt.out, { recursive: true });

	for (const [name, path, width, height, scheme, extra] of SHOTS) {
		if (only.length && !only.includes(name)) continue;
		await c.send('Network.clearBrowserCookies');
		if (extra !== 'logout')
			await c.send('Network.setCookie', { name: cookie.name, value: cookie.value, domain: host, path: '/' });
		await c.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: width < 600 });
		await c.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
		const loaded = c.once('Page.loadEventFired', 20000);
		await c.send('Page.navigate', { url: `${opt.url}/cgi-bin/luci/${path}` });
		await loaded;
		// wait for LuCI's view (or the login dialog) to finish drawing
		for (let i = 0; i < 75; i++) {
			const { result } = await c.send('Runtime.evaluate', { returnByValue: true, expression: `(() => {
				const v = document.querySelector('#view');
				if (document.querySelector('#modal_overlay .modal.login, .modal.login')) return true;
				return !!(v && v.children.length && !/Loading view/.test(v.innerText) && !v.querySelector(':scope > .spinning'));
			})()` });
			if (result.value) break;
			await sleep(200);
		}
		await sleep(2500);	// the polls a page makes after its first paint
		if (extra === 'menu') {
			await c.send('Runtime.evaluate', { expression: `document.querySelector('.menu-toggle')?.click()` });
			await sleep(600);
		}
		const shot = await c.send('Page.captureScreenshot', { format: 'png' });
		const file = join(opt.out, `${name}.png`);
		writeFileSync(file, Buffer.from(shot.data, 'base64'));
		console.log(`${file}  ${width}x${height} ${scheme}`);
	}
	ws.close();
} catch (e) {
	console.error(String(e.message || e));
	exitCode = 1;
} finally {
	chrome.kill();
	await sleep(300);
	rmSync(profile, { recursive: true, force: true });
}
process.exit(exitCode);
