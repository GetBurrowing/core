"""Exercise the real Windows updater against HTTP + ZIP fixtures, without Core/BEAM."""
import hashlib, http.server, io, json, os, pathlib, subprocess, tempfile, threading, zipfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'apps/platform/priv/game_player/BurrowPlayer.ps1'
state = {}
def package(version, traversal=False):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w') as z:
        z.writestr('Play Voltron.bat', '@echo off\r\nrem fixture '+version)
        z.writestr('../escaped.txt' if traversal else 'version.txt', version)
    body = stream.getvalue()
    return dict(version=version, sha256=hashlib.sha256(body).hexdigest(), byte_size=len(body), download_path='/games/voltron/player/releases/'+version, launch_path='Play Voltron.bat'), body
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith('/updates'):
            body = json.dumps(state['manifest']).encode()
        else:
            if state.get('redirect'):
                state['redirects'] = state.get('redirects', 0) + 1
                self.send_response(302); self.send_header('Location', '/capture'); self.end_headers(); return
            assert self.headers.get('Authorization') == 'Bearer fixture-token'
            state['downloads'] += 1
            body = state['body']
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
def windows(path):
    return str(path) if os.name == 'nt' else subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()
ps = 'powershell.exe' if os.name == 'nt' else '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
# Windows processes need a Windows-accessible temp directory, including on WSL.
parent = None if os.name == 'nt' else '/mnt/c/Users/Jordan/AppData/Local/Temp'
with tempfile.TemporaryDirectory(prefix='burrow-player-test-', dir=parent) as tmp:
    directory = pathlib.Path(tmp); config = directory/'player.json'; data = directory/'game'
    config.write_text(json.dumps(dict(base_url=f'http://127.0.0.1:{server.server_port}', slug='voltron', token='fixture-token')))
    def run(success=True):
        result = subprocess.run([ps, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', windows(SCRIPT), '-ConfigPath', windows(config), '-DataRoot', windows(data), '-CheckOnly'], capture_output=True, text=True, timeout=60)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
    def current(): return json.loads((data/'current.json').read_text(encoding='utf-8-sig'))
    original = package('one'); state['manifest'], state['body'] = original; state['downloads'] = 0
    run(); assert current()['version'] == 'one'
    run(); assert state['downloads'] == 1, 'same release should not download again'
    state['manifest'], state['body'] = package('two')
    run(); assert current()['version'] == 'two'
    state['manifest'], state['body'] = package('bad'); state['body'] = state['body'][:-1] + bytes([state['body'][-1] ^ 1])
    run(False); assert current()['version'] == 'two', 'failed update must keep installed game'
    state['manifest'], state['body'] = package('redirected'); state['redirect'] = True
    run(False); assert current()['version'] == 'two'; assert state['redirects'] == 1, 'must not follow download redirects'
    state['redirect'] = False
    state['manifest'], state['body'] = package('traversal', traversal=True)
    run(False); assert current()['version'] == 'two'; assert not (data/'escaped.txt').exists()
    state['manifest'], state['body'] = original
    run(); assert current()['version'] == 'one', 'rollback should work'
    assert len(list((data/'versions').iterdir())) == 2
    assert not list(data.glob('.update-*')), 'staging is cleaned'
server.shutdown()
print('WINDOWS_PLAYER PASS: install, no-op, update, same-size corruption, redirect rejection, ZIP traversal, rollback, cleanup')
