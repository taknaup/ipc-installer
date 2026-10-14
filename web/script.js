(() => {
    'use strict';

    const $ = (id) => document.getElementById(id);
    const radio = (name) => {
        const el = document.querySelector(`input[name="${name}"]:checked`);
        return el ? el.value : '';
    };

    // ------------------------------------------------------------------ wizard

    const LABELS = { task: 'Task', unit: 'This iPC', network: 'Network', confirm: 'Confirm', install: 'Install' };

    const MODES = {
        install: {
            label: 'Install Ignition & modules',
            notes: [
                'Ignition Edge will be installed and loaded with the standard gateway configuration.',
                'Network settings are not changed. Run this tool again later to set them.',
                'Any existing Ignition data is backed up first.'
            ]
        },
        network: {
            label: 'Set up the network only',
            notes: ['Only the network settings are changed. Ignition is not installed or modified.']
        },
        full: {
            label: 'Install & set up the network',
            notes: [
                'The network is configured first, then Ignition Edge is installed and loaded with the standard gateway configuration.',
                'Any existing Ignition data is backed up first.'
            ]
        }
    };

    const needsNetwork = () => radio('work_mode') !== 'install';
    // An Ignition-only SAP install applies nothing that depends on the node, so the screen does not ask.
    const asksNode = () => !(radio('work_mode') === 'install' && radio('system_type') === 'SAP');
    const askHac = () => needsNetwork() && radio('system_type') === 'HAC';

    function screenOrder() {
        const order = ['task', 'unit'];
        if (needsNetwork()) order.push('network');
        order.push('confirm', 'install');
        return order;
    }

    let current = 'task';
    let installStarted = false;

    function renderStepper() {
        const order = screenOrder();
        const idx = order.indexOf(current);
        $('stepper').innerHTML = '';
        order.forEach((name, i) => {
            const pip = document.createElement('div');
            pip.className = 'pip' + (i < idx ? ' done' : i === idx ? ' active' : '');
            pip.textContent = `${i + 1}. ${LABELS[name]}`;
            $('stepper').appendChild(pip);
        });
    }

    function show(name) {
        current = name;
        document.querySelectorAll('.screen').forEach(s => s.classList.toggle('active', s.id === `screen-${name}`));
        $('screens').scrollTop = 0;
        // The install screen is laid out to fit; the wizard pips are not needed there and the space is better used.
        $('screens').classList.toggle('fit', name === 'install' || name === 'closed');
        setVisible('stepper', name !== 'install' && name !== 'closed');
        if (name !== 'closed') renderStepper();
        updateButtons();
    }

    function setVisible(id, visible) { $(id).classList.toggle('hidden', !visible); }

    // Which footer buttons show depends on the screen and, during setup, on how it is going.
    let installState = 'idle'; // idle | running | failed | done
    function updateButtons() {
        const onInstall = current === 'install';
        const order = screenOrder();
        setVisible('btn-back', !onInstall && order.indexOf(current) > 0 && current !== 'closed');
        setVisible('btn-next', !onInstall && current !== 'confirm' && current !== 'closed');
        setVisible('btn-install', current === 'confirm');
        setVisible('btn-retry', onInstall && installState === 'failed');
        setVisible('btn-hmi', onInstall && installState === 'done' && radio('work_mode') !== 'network');
        setVisible('btn-restart', onInstall && installState === 'done');
        setVisible('btn-finish', onInstall && (installState === 'done' || installState === 'failed'));
    }

    function showFormError(message) {
        let el = document.querySelector('.screen.active .form-error');
        if (!el) {
            el = document.createElement('p');
            el.className = 'form-error';
            el.setAttribute('role', 'alert');
            document.querySelector('.screen.active').appendChild(el);
        }
        el.textContent = message || '';
    }
    function clearFormErrors() {
        document.querySelectorAll('.form-error').forEach(e => { e.textContent = ''; });
        document.querySelectorAll('.field.invalid').forEach(f => f.classList.remove('invalid'));
    }

    function isValidIPv4(v) {
        const p = v.split('.');
        return p.length === 4 && p.every(x => /^\d{1,3}$/.test(x) && Number(x) <= 255);
    }
    const subnetOf = (ip) => ip.split('.').slice(0, 3).join('.');
    const defaultGateway = (ip) => `${subnetOf(ip)}.1`;

    // Returns an error message, or '' if the current screen is complete.
    function validateScreen(name) {
        if (name === 'network') {
            const gw = $('enp4s0_gateway').value.trim();
            if (radio('system_type') === 'HAC') {
                if (!radio('hac_selection')) return 'Choose which HAC this is.';
                const ip = $('enp4s0_ip').value.trim();
                if (!isValidIPv4(ip)) { $('enp4s0_ip').classList.add('invalid'); return 'Enter the facility network address, for example 192.168.10.10.'; }
            }
            if (gw && !isValidIPv4(gw)) {
                $('enp4s0_gateway').classList.add('invalid');
                return 'Enter the gateway as four numbers, for example 192.168.100.1, or leave it blank.';
            }
        }
        return '';
    }

    // Asks the installer's own logic which port the default route will be set on.
    async function showRoutePreview(el) {
        const q = new URLSearchParams({
            system: radio('system_type'), hac: radio('hac_selection'), node: asksNode() ? radio('node_type') : 'Primary',
            ip: $('enp4s0_ip').value.trim(), gw: $('enp4s0_gateway').value.trim()
        });
        try {
            const res = await fetch(`/api/route-preview?${q}`, { cache: 'no-store' });
            const data = await res.json();
            el.textContent = data.text.replace(/^Default gateway /, '').replace(/^No default gateway.*/, 'None (no default route)');
            // A gateway the installer would reject: show why and keep Start disabled until it is fixed.
            el.style.color = data.ok ? '' : '#fca5a5';
            $('btn-install').disabled = !data.ok;
        } catch (err) {
            el.textContent = $('enp4s0_gateway').value.trim()
                || (radio('system_type') === 'HAC' ? `${defaultGateway($('enp4s0_ip').value.trim())} (facility default)` : 'None (no default route)');
        }
    }

    function buildSummary() {
        const mode = radio('work_mode') || 'install';
        const rows = [['Task', MODES[mode].label], ['System type', radio('system_type')]];
        if (asksNode()) rows.push(['Node', radio('node_type')]);
        if (askHac()) {
            const ip = $('enp4s0_ip').value.trim();
            rows.push(['HAC', radio('hac_selection')], ['Facility address', ip]);
        }
        if (needsNetwork()) rows.push(['Default gateway', 'Working it out...']);
        const list = $('summary-list');
        list.innerHTML = '';
        let routeEl = null;
        rows.forEach(([k, v]) => {
            const li = document.createElement('li');
            const span = document.createElement('span');
            const strong = document.createElement('strong');
            span.textContent = k;
            strong.textContent = v;
            li.append(span, strong);
            list.appendChild(li);
            if (k === 'Default gateway') routeEl = strong;
        });
        $('btn-install').disabled = false;
        if (routeEl) showRoutePreview(routeEl);
        const note = $('summary-note');
        note.innerHTML = '';
        [...MODES[mode].notes, 'When you press Start, a window will ask for the administrator password.'].forEach(t => {
            const p = document.createElement('p');
            p.textContent = t;
            note.appendChild(p);
        });
    }

    $('btn-next').addEventListener('click', () => {
        clearFormErrors();
        const error = validateScreen(current);
        if (error) { showFormError(error); return; }
        const order = screenOrder();
        const next = order[order.indexOf(current) + 1];
        if (next === 'confirm') buildSummary();
        show(next);
    });

    $('btn-back').addEventListener('click', () => {
        clearFormErrors();
        const order = screenOrder();
        show(order[order.indexOf(current) - 1]);
    });

    // The network screen: HAC asks for its number and facility address as well; SAP only has the gateway.
    function updateNetworkScreen() {
        const hac = radio('system_type') === 'HAC';
        $('network-title').textContent = hac ? 'HAC network settings' : 'SAP network settings';
        setVisible('hac-grid-group', hac);
        setVisible('facility-ip-group', hac);
        $('enp4s0_gateway').placeholder = hac ? 'Tap to enter (blank: facility .1)' : 'Tap to enter (blank: none)';
        $('gateway-hint').textContent = hac
            ? "Leave blank to use the facility network's .1 address. A gateway is set on the port it belongs to (controls, SAP or facility); any other address is used on the facility port."
            : 'Leave blank for no default gateway. If you enter one, it is set as the default route on this iPC\'s network port.';
    }

    function updateNodeVisibility() { setVisible('node-group', asksNode()); }
    document.querySelectorAll('input[name="work_mode"], input[name="system_type"]').forEach(r =>
        r.addEventListener('change', () => { renderStepper(); updateNodeVisibility(); updateNetworkScreen(); }));
    updateNodeVisibility();
    updateNetworkScreen();

    // ------------------------------------------------------------------ number pad

    const keypad = { target: null, original: '', allowEmpty: false, ghost: '', emptyHint: '' };
    const kpOverlay = $('keypad-overlay');

    function kpValidate(value) {
        if (!value) return keypad.allowEmpty ? { cls: '', text: keypad.emptyHint } : { cls: '', text: 'Enter four numbers separated by dots.' };
        if (isValidIPv4(value)) return { cls: 'ok', text: 'Looks good' };
        const parts = value.split('.');
        if (parts.length > 4) return { cls: 'bad', text: 'Too many parts: an address has four numbers.' };
        if (parts.some(p => p !== '' && Number(p) > 255)) return { cls: 'bad', text: 'Each number must be 255 or less.' };
        return { cls: '', text: `${parts.length} of 4 numbers entered` };
    }

    function kpRender() {
        const value = keypad.target.value;
        const d = $('keypad-display');
        d.textContent = value || keypad.ghost;
        d.classList.toggle('empty', !value);
        const v = kpValidate(value);
        const m = $('keypad-msg');
        m.textContent = v.text;
        m.className = 'keypad-msg ' + v.cls;
    }

    function kpOpen(input, title, allowEmpty, ghost) {
        keypad.ghost = ghost;
        keypad.target = input;
        keypad.original = input.value;
        keypad.allowEmpty = allowEmpty;
        $('keypad-title').textContent = title;
        kpOverlay.classList.remove('hidden');
        kpRender();
        $('keypad-done').focus();
    }

    function kpClose(commit) {
        if (!keypad.target) return;
        if (!commit) keypad.target.value = keypad.original;
        keypad.target.classList.remove('invalid');
        keypad.target = null;
        kpOverlay.classList.add('hidden');
    }

    function kpPress(key) {
        const t = keypad.target;
        if (!t) return;
        let v = t.value;
        if (/^\d$/.test(key)) {
            const last = v.split('.').pop();
            // An octet has at most three digits, no leading zero, and cannot exceed 255.
            if (last !== '0' && last.length < 3 && Number(last + key) <= 255) v += key;
        } else if (key === '.') {
            if (v && !v.endsWith('.') && v.split('.').length < 4) v += '.';
        } else if (key === 'back') {
            v = v.slice(0, -1);
        } else if (key === 'clear') {
            v = '';
        } else if (key === 'done') {
            if (v && !isValidIPv4(v)) { $('keypad-msg').textContent = 'That address is not complete yet.'; $('keypad-msg').className = 'keypad-msg bad'; return; }
            kpClose(true);
            return;
        } else if (key === 'cancel') {
            kpClose(false);
            return;
        }
        t.value = v;
        kpRender();
    }

    $('keypad').addEventListener('click', (e) => {
        const btn = e.target.closest('.key');
        if (btn) kpPress(btn.dataset.key);
    });
    kpOverlay.addEventListener('click', (e) => { if (e.target === kpOverlay) kpPress('done'); });
    document.addEventListener('keydown', (e) => {
        if (!keypad.target) return;
        if (/^\d$/.test(e.key) || e.key === '.') kpPress(e.key);
        else if (e.key === 'Backspace') kpPress('back');
        else if (e.key === 'Enter') kpPress('done');
        else if (e.key === 'Escape') kpPress('cancel');
        else return;
        e.preventDefault();
    });

    $('enp4s0_ip').addEventListener('click', () => { clearFormErrors(); kpOpen($('enp4s0_ip'), 'Facility network address', false, '192.168.10.10'); });
    $('enp4s0_gateway').addEventListener('click', () => {
        clearFormErrors();
        const ip = $('enp4s0_ip').value.trim();
        const hac = radio('system_type') === 'HAC';
        keypad.emptyHint = hac ? 'Leave empty to use the facility default.' : 'Leave empty for no default gateway.';
        kpOpen($('enp4s0_gateway'), 'Default gateway (optional)', true,
            hac ? (isValidIPv4(ip) ? `${defaultGateway(ip)}  (default)` : '192.168.10.1') : 'None');
    });

    // ------------------------------------------------------------------ confirm dialog

    function confirmDialog(title, text, yesLabel) {
        return new Promise((resolve) => {
            $('modal-title').textContent = title;
            $('modal-text').textContent = text;
            $('modal-yes').textContent = yesLabel;
            $('modal-overlay').classList.remove('hidden');
            const done = (answer) => {
                $('modal-overlay').classList.add('hidden');
                $('modal-yes').onclick = $('modal-no').onclick = null;
                resolve(answer);
            };
            $('modal-yes').onclick = () => done(true);
            $('modal-no').onclick = () => done(false);
        });
    }

    // ------------------------------------------------------------------ install progress

    const terminal = $('terminal-output');
    let runId = '';
    let offset = 0;
    let pollTimer = null;
    let sawTerminalEvent = false;
    let connectionLost = false;
    let startedAt = 0;
    let clockTimer = null;
    let stepEls = {};
    let gotFirstEvent = false;

    function appendLog(text, cls, timestamp) {
        const line = document.createElement('div');
        line.className = 'terminal-line';
        const ts = document.createElement('span');
        ts.className = 'log-timestamp';
        ts.textContent = `[${timestamp || new Date().toTimeString().split(' ')[0]}]`;
        const msg = document.createElement('span');
        if (cls) msg.className = cls;
        msg.textContent = text;
        line.append(ts, msg);
        terminal.appendChild(line);
        terminal.scrollTop = terminal.scrollHeight;
    }

    function tickClock() {
        const s = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
        $('elapsed').textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
    }
    function startClock() {
        if (!startedAt) startedAt = Date.now();
        if (!clockTimer) clockTimer = setInterval(tickClock, 1000);
        tickClock();
    }
    function stopClock() { clearInterval(clockTimer); clockTimer = null; }

    function resetInstallView() {
        terminal.innerHTML = '';
        $('step-list').innerHTML = '';
        $('health-list').innerHTML = '';
        stepEls = {};
        $('progress-fill').style.width = '0%';
        $('progress-fill').classList.remove('failed');
        $('progress-pct').textContent = '0%';
        $('install-title').textContent = 'Setting up this iPC...';
        setVisible('error-panel', false);
        setVisible('done-panel', false);
        setVisible('now-box', true);
        $('now-text').textContent = 'Starting...';
    }

    function setStep(name, state) {
        const li = stepEls[name];
        if (!li) return;
        li.className = state;
        if (state === 'active') $('now-text').textContent = li.dataset.label || '';
    }

    // A retried or resumed run supersedes an earlier failure.
    function clearFailure() {
        if (installState === 'failed') installState = 'running';
        sawTerminalEvent = false;
        $('progress-fill').classList.remove('failed');
        $('install-title').textContent = 'Setting up this iPC...';
        setVisible('error-panel', false);
        setVisible('now-box', true);
        updateButtons();
    }

    function handleEvent(ev) {
        switch (ev.type) {
            case 'plan':
                clearFailure();
                $('step-list').innerHTML = '';
                stepEls = {};
                ev.steps.forEach((s) => {
                    const li = document.createElement('li');
                    const ico = document.createElement('span');
                    ico.className = 'ico';
                    const label = document.createElement('span');
                    label.textContent = s.label;
                    li.dataset.label = s.label;
                    li.append(ico, label);
                    $('step-list').appendChild(li);
                    stepEls[s.name] = li;
                });
                break;
            case 'step':
                if (ev.state === 'start') clearFailure();
                setStep(ev.name, ev.state === 'start' ? 'active' : 'done');
                break;
            case 'progress':
                $('progress-fill').style.width = `${ev.percent}%`;
                $('progress-pct').textContent = `${ev.percent}%`;
                break;
            case 'health': {
                const li = document.createElement('li');
                li.textContent = ev.message;
                if (!ev.ok) li.className = 'warn';
                $('health-list').appendChild(li);
                break;
            }
            case 'log':
                appendLog(ev.message, ev.level === 'error' ? 'error' : '', ev.timestamp);
                break;
            case 'error':
                appendLog(ev.hint ? `${ev.message} ${ev.hint}` : ev.message, 'error');
                fail(ev.message, ev.hint, ev.step);
                break;
            case 'done':
                sawTerminalEvent = true;
                installState = 'done';
                setVisible('error-panel', false);
                $('progress-fill').classList.remove('failed');
                stopClock();
                $('install-title').textContent = 'All done';
                $('progress-fill').style.width = '100%';
                $('progress-pct').textContent = '100%';
                Object.values(stepEls).forEach(li => { li.className = 'done'; });
                $('done-title').textContent = radio('work_mode') === 'network' ? 'Network settings applied' : 'This iPC is ready';
                setVisible('now-box', false);
                setVisible('done-panel', true);
                updateButtons();
                break;
        }
    }

    function fail(message, hint, step) {
        sawTerminalEvent = true;
        installState = 'failed';
        stopClock();
        if (step && stepEls[step]) setStep(step, 'failed');
        $('progress-fill').classList.add('failed');
        $('install-title').textContent = 'Setup did not finish';
        $('error-msg').textContent = message || 'The installer stopped unexpectedly.';
        $('error-hint').textContent = hint || 'Nothing is lost: press "Try again" to continue from where it stopped.';
        setVisible('now-box', false);
        setVisible('error-panel', true);
        updateButtons();
    }

    async function poll() {
        pollTimer = null;
        let again = true;
        try {
            const res = await fetch(`/api/events?run=${encodeURIComponent(runId)}&offset=${offset}`, { cache: 'no-store' });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const body = await res.json();
            if (connectionLost) { connectionLost = false; appendLog('Reconnected to the installer.'); }
            if (body.events.length && !gotFirstEvent) {
                gotFirstEvent = true;
                if (installState === 'running') $('install-title').textContent = 'Setting up this iPC...';
            }
            body.events.forEach(handleEvent);
            offset = body.offset;
            if (!body.running && body.events.length === 0) {
                // Drained and the installer process is gone.
                if (!sawTerminalEvent) fail(body.launch_error || 'The installer stopped unexpectedly.', '', '');
                again = false;
            } else if (sawTerminalEvent && body.events.length === 0) {
                again = false;
            }
        } catch (err) {
            // The install keeps running on the iPC; keep trying to reach this page's server.
            if (!connectionLost) { connectionLost = true; appendLog(`Lost connection to the installer page (${err.message}). Retrying...`, 'error'); }
        }
        if (again) pollTimer = setTimeout(poll, 1000);
    }

    function startPolling() {
        if (pollTimer) clearTimeout(pollTimer);
        gotFirstEvent = false;
        sawTerminalEvent = false;
        poll();
    }

    async function startInstall(retry) {
        installStarted = true;
        installState = 'running';
        show('install');
        if (!retry) { resetInstallView(); startedAt = 0; offset = 0; }
        else {
            setVisible('error-panel', false);
            $('progress-fill').classList.remove('failed');
            $('install-title').textContent = 'Setting up this iPC...';
            setVisible('now-box', true);
        }
        startClock();
        updateButtons();

        $('install-title').textContent = 'Waiting for the administrator password...';
        const mode = radio('work_mode') || 'install';
        const system = radio('system_type') || 'HAC';
        const payload = { work_mode: mode, system_type: system, node_type: (asksNode() ? radio('node_type') : '') || 'Primary', retry: !!retry };
        if (askHac()) {
            payload.hac_selection = radio('hac_selection');
            payload.enp4s0_ip = $('enp4s0_ip').value.trim();
        }
        if (needsNetwork()) {
            const gw = $('enp4s0_gateway').value.trim();
            if (gw) payload.enp4s0_gateway = gw;
        }

        try {
            const res = await fetch('/api/install', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
            const body = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
            runId = body.run_id;
            if (!body.resumed) offset = 0;
            startPolling();
        } catch (err) {
            appendLog(`Could not start: ${err.message}`, 'error');
            fail(`Could not start the setup: ${err.message}`, '', '');
        }
    }

    $('btn-install').addEventListener('click', () => startInstall(false));
    $('btn-retry').addEventListener('click', () => startInstall(true));
    $('btn-details').addEventListener('click', () => {
        $('log-overlay').classList.remove('hidden');
        terminal.scrollTop = terminal.scrollHeight;
    });
    $('btn-log-close').addEventListener('click', () => $('log-overlay').classList.add('hidden'));
    $('log-overlay').addEventListener('click', (e) => { if (e.target === $('log-overlay')) $('log-overlay').classList.add('hidden'); });

    async function postJson(url, body) {
        const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
        return data;
    }

    $('btn-hmi').addEventListener('click', async () => {
        try { await postJson('/api/launch-hmi'); }
        catch (err) { await confirmDialog('Could not open Perspective Workstation', err.message, 'OK'); }
    });

    $('btn-restart').addEventListener('click', async () => {
        const yes = await confirmDialog('Restart the iPC?', 'The iPC will restart now. Save anything you have open first.', 'Restart');
        if (!yes) return;
        try {
            await postJson('/api/restart', { confirm: true });
            $('install-title').textContent = 'Restarting...';
        } catch (err) {
            await confirmDialog('Could not restart', err.message, 'OK');
        }
    });

    $('btn-finish').addEventListener('click', async () => {
        try { await postJson('/api/quit'); } catch (err) { /* server may already be closing */ }
        show('closed');
        ['btn-back', 'btn-next', 'btn-install', 'btn-retry', 'btn-hmi', 'btn-restart', 'btn-finish'].forEach(id => setVisible(id, false));
        $('stepper').innerHTML = '';
        window.close();
    });

    // If the page is opened or refreshed while a setup is running, pick up where it is.
    fetch('/api/status', { cache: 'no-store' })
        .then(r => r.json())
        .then((status) => {
            if (status.running && status.run_id) {
                runId = status.run_id;
                offset = 0;
                const modeRadio = document.querySelector(`input[name="work_mode"][value="${status.mode}"]`);
                if (modeRadio) modeRadio.checked = true;
                installStarted = true;
                installState = 'running';
                resetInstallView();
                show('install');
                startClock();
                startPolling();
            }
        })
        .catch(() => {});

    show('task');
})();
